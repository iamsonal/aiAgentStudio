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

@IsTest(SeeAllData=false)
private class PayloadRetentionPurgeTest {
    @IsTest
    static void purgesOnlyTerminalDueRunsAndPreservesAuditMetadata() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.cancel(started.runId, started.revision, 'terminal payload');
            AgentRun__c terminal = new AgentRun__c(
                Id = started.runId,
                CompletedAt__c = System.now().addDays(-2),
                PayloadRetentionDays__c = 0,
                PurgeAfter__c = System.now().addMinutes(-1)
            );
            AgentKernelTestFactory.updateRecord(terminal);
            AgentKernelModels.StartResult active = AgentKernelTestFactory.startRunWithoutDispatch(definition);

            List<AgentEvent__c> retainedEvents = [
                SELECT Id, Payload__c, PayloadHash__c, Sequence__c
                FROM AgentEvent__c
                WHERE AgentRun__c = :started.runId
                WITH SYSTEM_MODE
                ORDER BY Sequence__c ASC
            ];
            AgentEvent__c beforePurge;
            for (AgentEvent__c candidate : retainedEvents) {
                if (candidate.Payload__c != null) {
                    beforePurge = candidate;
                    break;
                }
            }
            System.assertNotEquals(null, beforePurge, 'Expected a retained event payload before purge.');
            Test.startTest();
            PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(10);
            Test.stopTest();

            System.assertEquals(1, result.runsPurged);
            AgentRun__c purgedRun = [SELECT Input__c, Output__c, PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE];
            System.assertEquals(null, purgedRun.Input__c);
            System.assertNotEquals(null, purgedRun.PayloadPurgedAt__c);
            AgentEvent__c purgedEvent = [
                SELECT Payload__c, PayloadHash__c, Sequence__c, PayloadPurgedAt__c
                FROM AgentEvent__c
                WHERE Id = :beforePurge.Id
                WITH SYSTEM_MODE
            ];
            System.assertEquals(null, purgedEvent.Payload__c);
            System.assertEquals(beforePurge.PayloadHash__c, purgedEvent.PayloadHash__c);
            System.assertEquals(beforePurge.Sequence__c, purgedEvent.Sequence__c);
            System.assertNotEquals(null, purgedEvent.PayloadPurgedAt__c);
            System.assertNotEquals(null, [SELECT Input__c FROM AgentRun__c WHERE Id = :active.runId WITH SYSTEM_MODE].Input__c);
        }
    }

    @IsTest
    static void purgeClearsApprovalAndRunNarrativeButKeepsTheDecisionRecord() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentApproval__c opened = AgentKernelTestFactory.openApproval(
                AgentKernelTestFactory.getRun(started.runId),
                AgentKernelTestFactory.getCommand(started.commandId),
                UserInfo.getUserId()
            );
            AgentKernel.cancel(started.runId, started.revision, 'Customer sentinel-narrative asked to stop.');
            AgentKernelTestFactory.updateRecord(
                new AgentRun__c(
                    Id = started.runId,
                    CompletedAt__c = System.now().addDays(-2),
                    PayloadRetentionDays__c = 0,
                    PurgeAfter__c = System.now().addMinutes(-1)
                )
            );
            AgentApproval__c beforePurge = [SELECT Status__c, ClosedAt__c, OwnerId FROM AgentApproval__c WHERE Id = :opened.Id WITH SYSTEM_MODE];

            PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(10);

            AgentApproval__c purgedApproval = [
                SELECT Reason__c, DecisionComment__c, Status__c, ClosedAt__c, OwnerId
                FROM AgentApproval__c
                WHERE Id = :opened.Id
                WITH SYSTEM_MODE
            ];
            AgentRun__c purgedRun = [
                SELECT CancellationReason__c, WaitingReason__c, PayloadPurgedAt__c, Status__c
                FROM AgentRun__c
                WHERE Id = :started.runId
                WITH SYSTEM_MODE
            ];
            System.assertEquals(1, result.approvalsPurged);
            System.assertEquals(1, result.runsPurged);
            System.assertEquals(null, purgedApproval.Reason__c, 'The approval reason is narrative and leaves with the payloads.');
            System.assertEquals(null, purgedApproval.DecisionComment__c);
            System.assertEquals(beforePurge.Status__c, purgedApproval.Status__c, 'The decision outcome stays for audit.');
            System.assertEquals(beforePurge.ClosedAt__c, purgedApproval.ClosedAt__c);
            System.assertEquals(beforePurge.OwnerId, purgedApproval.OwnerId);
            System.assertEquals(null, purgedRun.CancellationReason__c, 'The cancellation narrative leaves with the payloads.');
            System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, purgedRun.Status__c);
            System.assertNotEquals(null, purgedRun.PayloadPurgedAt__c);
            System.assertEquals(0, PayloadRetentionPurgeService.purge(10).approvalsPurged, 'A purged approval is not purged again.');
        }
    }

    @IsTest
    static void erasureDeletesRunsAnchoredToTheDataSubject() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            Account subject = new Account(Name = 'Data subject');
            insert subject;
            AgentKernelModels.StartResult anchored = AgentKernelTestFactory.start(definition.Id, 'Summarize alice@example.com', subject.Id);
            AgentKernel.cancel(anchored.runId, anchored.revision, 'done');
            AgentKernelModels.StartResult unrelated = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.cancel(unrelated.runId, unrelated.revision, 'done');
            System.assertEquals(1, [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :anchored.runId WITH SYSTEM_MODE]);

            Test.startTest();
            PayloadRetentionPurgeService.ErasureResult scheduled = PayloadRetentionPurgeService.scheduleErasure(new Set<Id>{ subject.Id });
            PayloadRetentionPurgeScheduler.runNow();
            PayloadRetentionPurgeService.ErasureResult repeated = PayloadRetentionPurgeService.scheduleErasure(new Set<Id>{ subject.Id });
            Test.stopTest();

            System.assertEquals(1, scheduled.runsScheduled);
            System.assertEquals(0, scheduled.activeRunsDeferred);
            System.assertEquals(0, repeated.runsScheduled, 'Erasure is idempotent once the run is gone.');
            System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE Id = :anchored.runId WITH SYSTEM_MODE]);
            System.assertEquals(0, [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :anchored.runId WITH SYSTEM_MODE]);
            System.assertEquals(1, [SELECT COUNT() FROM AgentRun__c WHERE Id = :unrelated.runId WITH SYSTEM_MODE]);
        }
    }

    @IsTest
    static void erasureIsPermissionGated() {
        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                PayloadRetentionPurgeService.scheduleErasure(new Set<Id>{ UserInfo.getUserId() });
                System.assert(false, 'Expected erasure authorization failure.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('permission'));
            }
        }
    }

    @IsTest
    static void purgeIsPermissionGated() {
        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                PayloadRetentionPurgeService.purge(1);
                System.assert(false, 'Expected purge authorization failure.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('permission'));
            }
        }
    }

    @IsTest
    static void purgesPausedCheckpointAfterRetentionDeadline() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR, AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.pause(started.runId, started.revision, 'Awaiting operator repair.');
            AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = started.runId, PurgeAfter__c = System.now().addMinutes(-1)));

            PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(10);

            AgentRun__c purged = [
                SELECT Status__c, Input__c, PayloadPurgedAt__c
                FROM AgentRun__c
                WHERE Id = :started.runId
                WITH SYSTEM_MODE
            ];
            System.assertEquals(1, result.runsPurged);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, purged.Status__c);
            System.assertEquals(null, purged.Input__c);
            System.assertNotEquals(null, purged.PayloadPurgedAt__c);
            try {
                AgentKernel.rescue(rescueRequest(purged));
                System.assert(false, 'Purged paused checkpoint must not be rescued.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('purged'));
            }
        }
    }

    @IsTest
    static void purgesInvocationPayloadsAndPreservesHashes() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            InvocationEvidenceService.Capture capture = new InvocationEvidenceService.Capture();
            capture.runId = started.runId;
            capture.commandId = started.commandId;
            capture.commandRevision = started.revision;
            capture.attemptNumber = 1;
            capture.invocationType = 'Model';
            capture.outcome = 'Succeeded';
            capture.operationKey = started.operationKey;
            capture.startedAt = System.now();
            capture.requestJson = '{"request":"retain then purge"}';
            capture.responseJson = '{"response":"retain then purge"}';

            Id invocationId = InvocationEvidenceService.record(capture);
            AgentInvocation__c beforePurge = [SELECT RequestHash__c, ResponseHash__c FROM AgentInvocation__c WHERE Id = :invocationId WITH SYSTEM_MODE];
            AgentKernel.cancel(started.runId, started.revision, 'retention test');
            AgentKernelTestFactory.updateRecord(
                new AgentRun__c(
                    Id = started.runId,
                    CompletedAt__c = System.now().addDays(-2),
                    PayloadRetentionDays__c = 0,
                    PurgeAfter__c = System.now().addMinutes(-1)
                )
            );

            PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(10);

            AgentInvocation__c purged = [
                SELECT Request__c, Response__c, NativeEvidence__c, RequestHash__c, ResponseHash__c, PayloadPurgedAt__c
                FROM AgentInvocation__c
                WHERE Id = :invocationId
                WITH SYSTEM_MODE
            ];
            System.assertEquals(1, result.invocationsPurged);
            System.assertEquals(null, purged.Request__c);
            System.assertEquals(null, purged.Response__c);
            System.assertEquals(beforePurge.RequestHash__c, purged.RequestHash__c);
            System.assertEquals(beforePurge.ResponseHash__c, purged.ResponseHash__c);
            System.assertNotEquals(null, purged.PayloadPurgedAt__c);
        }
    }

    @IsTest
    static void largeRunCompletesAcrossBoundedPasses() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            List<AgentCommand__c> extraCommands = new List<AgentCommand__c>();
            for (Integer index = 0; index < 3; index++) {
                extraCommands.add(
                    new AgentCommand__c(
                        AgentRun__c = started.runId,
                        CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                        Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                        ExpectedRunRevision__c = started.revision,
                        OperationKey__c = 'retention-pass-' + index,
                        AttemptNumber__c = 1,
                        Input__c = '{"pass":' + index + '}',
                        Output__c = '{"done":true}'
                    )
                );
            }
            AgentKernelTestFactory.insertRecords(extraCommands);
            AgentKernel.cancel(started.runId, started.revision, 'bounded retention');
            AgentKernelTestFactory.updateRecord(
                new AgentRun__c(
                    Id = started.runId,
                    CompletedAt__c = System.now().addDays(-2),
                    PayloadRetentionDays__c = 0,
                    PurgeAfter__c = System.now().addMinutes(-1)
                )
            );
            PayloadRetentionPurgeService.childRowLimitOverride = 2;

            PayloadRetentionPurgeService.PurgeResult first = PayloadRetentionPurgeService.purge(1);
            PayloadRetentionPurgeService.PurgeResult second = PayloadRetentionPurgeService.purge(1);
            PayloadRetentionPurgeService.PurgeResult third = PayloadRetentionPurgeService.purge(1);

            PayloadRetentionPurgeService.childRowLimitOverride = null;
            System.assertEquals(0, first.runsPurged);
            System.assertEquals(true, first.hasMore);
            System.assertEquals(1, second.runsPurged);
            System.assertEquals(true, second.hasMore);
            System.assertEquals(0, third.runsPurged);
            System.assertEquals(false, third.hasMore);
            System.assertNotEquals(null, [SELECT PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE].PayloadPurgedAt__c);
        }
    }

    @IsTest
    static void purgesDueRunBehindMoreThanFiveHundredFutureTerminalRuns() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult templateStarted = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.cancel(templateStarted.runId, templateStarted.revision, 'retention template');
            AgentRun__c template = [
                SELECT
                    AgentDefinition__c,
                    Status__c,
                    Revision__c,
                    PayloadRetentionMode__c,
                    PayloadRetentionDays__c,
                    RetainedPayloadCharacters__c,
                    CompletedAt__c,
                    PurgeAfter__c
                FROM AgentRun__c
                WHERE Id = :templateStarted.runId
                WITH SYSTEM_MODE
            ];
            List<AgentRun__c> futureRuns = new List<AgentRun__c>();
            for (Integer index = 0; index < 501; index++) {
                AgentRun__c futureRun = template.clone(false, false, false, false);
                futureRun.CompletedAt__c = System.now().addDays(-1);
                futureRun.PayloadRetentionDays__c = 30;
                futureRun.PurgeAfter__c = System.now().addDays(29);
                futureRuns.add(futureRun);
            }
            AgentKernelTestFactory.insertRecords(futureRuns);

            AgentKernelModels.StartResult dueStarted = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.cancel(dueStarted.runId, dueStarted.revision, 'due retention');
            AgentKernelTestFactory.updateRecord(
                new AgentRun__c(
                    Id = dueStarted.runId,
                    CompletedAt__c = System.now().addDays(-1),
                    PayloadRetentionDays__c = 0,
                    PurgeAfter__c = System.now().addMinutes(-1)
                )
            );

            PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(1);

            System.assertEquals(1, result.runsPurged);
            System.assertNotEquals(null, [SELECT PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :dueStarted.runId WITH SYSTEM_MODE].PayloadPurgedAt__c);
            System.assertEquals(501, [SELECT COUNT() FROM AgentRun__c WHERE Id IN :futureRuns AND PayloadPurgedAt__c = NULL WITH SYSTEM_MODE]);
        }
    }

    @IsTest
    static void schedulerInstallationIsIdempotentAndRemovable() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            PayloadRetentionPurgeScheduler.remove();
            Id firstJob = PayloadRetentionPurgeScheduler.install();
            Id secondJob = PayloadRetentionPurgeScheduler.install();
            System.assertEquals(firstJob, secondJob);
            PayloadRetentionPurgeScheduler.runNow();
            new PayloadRetentionPurgeScheduler().execute(null);
            System.assertNotEquals(null, PayloadRetentionPurgeScheduler.lastResult);
            System.assertEquals(1, PayloadRetentionPurgeScheduler.remove());
        }
    }

    private static AgentKernelModels.RescueRequest rescueRequest(AgentRun__c run) {
        AgentKernelModels.RescueRequest request = new AgentKernelModels.RescueRequest();
        request.runId = run.Id;
        request.expectedRunRevision = [SELECT Revision__c FROM AgentRun__c WHERE Id = :run.Id WITH SYSTEM_MODE].Revision__c;
        request.guidance = 'Attempt late rescue.';
        return request;
    }
}
