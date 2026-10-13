/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/** Scenarios 3, 5, and 11: failures that need a person become durable issues an operator can find, act on, and close. */
@IsTest
private class AgentOperationalIssuesTest {
    private static final Id WORK_ITEM_ID = Id.valueOf('04i000000000001');

    @IsTest
    static void deliveredSignalsBecomeOneIssuePerCodeAndSubject() {
        Test.startTest();
        EventBus.publish(
            new List<AgentOperationalSignal__e>{
                AgentOperationsLog.event('AGENT_HITL_RELAY_FAILED', null, null, null, WORK_ITEM_ID),
                AgentOperationsLog.event('AGENT_HITL_RELAY_FAILED', null, null, null, WORK_ITEM_ID),
                AgentOperationsLog.event('FLOW_START_LOST', null, null, 'Agent triage_agent; anchor none; 1 starts lost in this batch')
            }
        );
        Test.getEventBus().deliver();
        EventBus.publish(AgentOperationsLog.event('AGENT_HITL_RELAY_FAILED', null, null, null, WORK_ITEM_ID));
        Test.getEventBus().deliver();
        Test.stopTest();

        List<AgentOperationalIssue__c> relay = [
            SELECT OccurrenceCount__c, Status__c, SubjectId__c, NextStep__c, OpenKey__c
            FROM AgentOperationalIssue__c
            WHERE Code__c = 'AGENT_HITL_RELAY_FAILED'
            WITH SYSTEM_MODE
        ];
        System.assertEquals(1, relay.size(), 'Repeats of an open issue are grouped.');
        System.assertEquals(3, relay[0].OccurrenceCount__c);
        System.assertEquals(AgentOperationalIssues.STATUS_OPEN, relay[0].Status__c);
        System.assertEquals(String.valueOf(WORK_ITEM_ID), relay[0].SubjectId__c);
        System.assertEquals(AgentOperationalIssues.nextStep('AGENT_HITL_RELAY_FAILED'), relay[0].NextStep__c);
        AgentOperationalIssue__c lost = [
            SELECT Detail__c, RunId__c, CommandId__c
            FROM AgentOperationalIssue__c
            WHERE Code__c = 'FLOW_START_LOST'
            WITH SYSTEM_MODE
        ];
        System.assert(lost.Detail__c.contains('triage_agent'), 'A lost start names its agent.');
    }

    @IsTest
    static void recoveredRelayResolvesItsIssueAndANewFailureOpensAnother() {
        AgentOperationalIssues.record(
            new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('AGENT_HITL_RELAY_REFUSED', null, null, null, WORK_ITEM_ID) }
        );

        Integer resolved = AgentOperationalIssues.resolve(
            new Set<String>{ 'AGENT_HITL_RELAY_FAILED', 'AGENT_HITL_RELAY_REFUSED' },
            new Set<String>{ String.valueOf(WORK_ITEM_ID) }
        );
        AgentOperationalIssues.record(
            new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('AGENT_HITL_RELAY_REFUSED', null, null, null, WORK_ITEM_ID) }
        );

        System.assertEquals(1, resolved);
        AgentOperationalIssue__c closed = [
            SELECT ClosedAt__c, OpenKey__c, ClosedBy__c
            FROM AgentOperationalIssue__c
            WHERE Status__c = 'Resolved'
            WITH SYSTEM_MODE
        ];
        System.assertNotEquals(null, closed.ClosedAt__c);
        System.assertEquals(null, closed.OpenKey__c, 'A closed issue frees its key.');
        System.assertEquals(null, closed.ClosedBy__c, 'Core, not a person, resolved it.');
        System.assertEquals(1, [SELECT COUNT() FROM AgentOperationalIssue__c WHERE Status__c = 'Open' WITH SYSTEM_MODE], 'A later failure opens a new issue.');
    }

    @IsTest
    static void workerFailureAlreadyRecoveredIsKeptClosed() {
        Id finishedCommandId = Id.valueOf(AgentCommand__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
        AgentOperationalIssues.record(
            new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('WORKER_FAILED', null, finishedCommandId, 'System.LimitException') }
        );

        AgentOperationalIssue__c issue = [SELECT Status__c, CommandId__c, Detail__c FROM AgentOperationalIssue__c WITH SYSTEM_MODE];
        System.assertEquals(AgentOperationalIssues.STATUS_RESOLVED, issue.Status__c, 'Recovery already moved the command on.');
        System.assertEquals('System.LimitException', issue.Detail__c);
    }

    @IsTest
    static void operatorDismissesWithAReason() {
        AgentOperationalIssues.record(new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('FLOW_START_FAILED', null, null, 'Agent not shared') });
        AgentOperationalIssue__c issue = [SELECT Id FROM AgentOperationalIssue__c WITH SYSTEM_MODE];
        User operator = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.OPERATOR });

        List<AgentDismissIssueAction.Result> results;
        System.runAs(operator) {
            AgentDismissIssueAction.Request request = new AgentDismissIssueAction.Request();
            request.issueId = issue.Id;
            request.reason = 'Shared the agent and started the runs again.';
            results = AgentDismissIssueAction.dismiss(new List<AgentDismissIssueAction.Request>{ request });
        }

        System.assertEquals(true, results[0].dismissed, 'Error: ' + results[0].errorMessage);
        AgentOperationalIssue__c closed = [SELECT Status__c, ClosedBy__c, CloseReason__c FROM AgentOperationalIssue__c WHERE Id = :issue.Id WITH SYSTEM_MODE];
        System.assertEquals(AgentOperationalIssues.STATUS_DISMISSED, closed.Status__c);
        System.assertEquals(operator.Id, closed.ClosedBy__c);
        System.assertEquals('Shared the agent and started the runs again.', closed.CloseReason__c);
    }

    @IsTest
    static void personWithoutRunControlCannotSeeOrDismissIssues() {
        AgentOperationalIssues.record(new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('FLOW_START_FAILED', null, null, 'Agent not shared') });
        AgentOperationalIssue__c issue = [SELECT Id FROM AgentOperationalIssue__c WITH SYSTEM_MODE];
        User runner = AgentKernelTestFactory.standardUserWith(new List<String>{ 'AgentKernelRunAgents' });

        List<AgentDismissIssueAction.Result> results;
        Map<String, Integer> visible;
        System.runAs(runner) {
            AgentDismissIssueAction.Request request = new AgentDismissIssueAction.Request();
            request.issueId = issue.Id;
            request.reason = 'Trying anyway.';
            results = AgentDismissIssueAction.dismiss(new List<AgentDismissIssueAction.Request>{ request });
            visible = AgentOperationalIssues.openCountsByCode();
        }

        System.assertEquals(false, results[0].dismissed);
        System.assert(results[0].errorMessage.contains('Agent Kernel Operator'), results[0].errorMessage);
        System.assert(visible.isEmpty(), 'Issue counts are hidden from people without access.');
        System.assertEquals('Open', [SELECT Status__c FROM AgentOperationalIssue__c WHERE Id = :issue.Id WITH SYSTEM_MODE].Status__c);
    }

    @IsTest
    static void failedWriteIsRedeliveredThenGivenUp() {
        AgentOperationalIssues.failRecordForTest = true;
        AgentOperationalIssues.retriesForTest = 0;
        try {
            AgentOperationalIssues.handleSignals(new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('WORKER_FAILED', null, null, null) });
            System.assert(false, 'An early failure asks the platform to redeliver the batch.');
        } catch (EventBus.RetryableException expected) {
            System.assert(true);
        }
        AgentOperationalIssues.retriesForTest = 4;
        AgentOperationalIssues.handleSignals(new List<AgentOperationalSignal__e>{ AgentOperationsLog.event('WORKER_FAILED', null, null, null) });
        System.assertEquals(
            0,
            [SELECT COUNT() FROM AgentOperationalIssue__c WITH SYSTEM_MODE],
            'After the last retry the batch is logged, not retried forever.'
        );
    }

    @IsTest
    static void dismissNeedsAReason() {
        System.runAs(AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.ADMIN })) {
            try {
                AgentOperationalIssues.dismiss(new Set<Id>(), ' ');
                System.assert(false, 'A blank reason is refused.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('why'), expected.getMessage());
            }
        }
    }

    @IsTest
    static void retentionDeletesIssuesClosedMoreThanThirtyDaysAgo() {
        insert new List<AgentOperationalIssue__c>{
            new AgentOperationalIssue__c(Code__c = 'OLD', Status__c = 'Dismissed', ClosedAt__c = System.now().addDays(-31)),
            new AgentOperationalIssue__c(Code__c = 'RECENT', Status__c = 'Resolved', ClosedAt__c = System.now().addDays(-2)),
            new AgentOperationalIssue__c(Code__c = 'OPEN', Status__c = 'Open', OpenKey__c = 'OPEN:org')
        };

        Integer deleted = AgentOperationalIssues.maintain();

        System.assertEquals(1, deleted);
        System.assertEquals(0, [SELECT COUNT() FROM AgentOperationalIssue__c WHERE Code__c = 'OLD' WITH SYSTEM_MODE]);
        System.assertEquals(2, [SELECT COUNT() FROM AgentOperationalIssue__c WITH SYSTEM_MODE]);
    }

    /** Every code this repository publishes has a next step; add new codes here and to AgentOperationalIssues. */
    @IsTest
    static void everyPublishedCodeHasANextStep() {
        Set<String> published = new Set<String>{
            'FLOW_START_LOST',
            'FLOW_START_FAILED',
            'WORKER_FAILED',
            'WORKER_FAILURE_RECOVERY_FAILED',
            'DISPATCH_RETRY_FAILED',
            'RECOVERY_ITEM_FAILED',
            'AGENT_HITL_RELAY_FAILED',
            'AGENT_HITL_RELAY_REFUSED',
            'AGENT_APPROVAL_NOTICE_FAILED',
            'CHANNEL_SUBSCRIBER_NOT_PRINCIPAL'
        };
        published.removeAll(AgentOperationalIssues.knownCodes());
        System.assert(published.isEmpty(), 'Codes without a next step: ' + published);
    }
}
