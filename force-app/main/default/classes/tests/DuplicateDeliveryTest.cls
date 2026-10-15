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

/**
 * "Any step may run twice. Running it twice must not do the work twice."
 * The platform can deliver a queued job twice, a loopback hop can be retried,
 * and an approver can click twice. After every step of a refund that needs
 * approval, this test delivers that step again and proves nothing changes:
 * no new event, no new revision, no second model or tool call.
 */
@IsTest
private class DuplicateDeliveryTest {
    private static final String REFUND_TOOL = 'issue_refund';

    /** Up to the approval: a repeated model turn, tool admission, and decision change nothing. */
    @IsTest
    static void repeatedDeliveriesAndDecisionsBeforeTheRefundChangeNothing() {
        Fixture fixture = refundAgent();
        Id runId = AgentKernelTestFactory.startRunWithoutDispatch(fixture.definition).runId;

        assertRepeatChangesNothing(deliver(runId));
        Test.startTest();
        assertRepeatChangesNothing(deliver(runId));
        AgentRun__c waiting = AgentKernelTestFactory.getRun(runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waiting.Status__c, waiting.ErrorCode__c + ': ' + waiting.ErrorMessage__c);
        System.assertEquals(0, KernelTestTool.invocationCount, 'The refund waits for its approver.');

        Id approvalId = AgentKernelTestFactory.pendingApproval(runId).Id;
        Id nextCommandId;
        System.runAs(new User(Id = fixture.approverId)) {
            nextCommandId = AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approvalId, true, 'Within policy.'));
            Snapshot afterDecision = snapshotOf(runId);
            System.assertEquals(
                null,
                AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approvalId, true, 'Within policy.')),
                'A repeated click is a no-op.'
            );
            try {
                AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approvalId, false, 'Changed my mind.'));
                System.assert(false, 'A decided approval cannot be reversed.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('already'), expected.getMessage());
            }
            afterDecision.assertUnchanged('A repeated or reversed decision');
        }
        Test.stopTest();
        System.assertNotEquals(null, nextCommandId, 'The approval continues the waiting refund.');
        AgentKernelTestFactory.assertLifecycleInvariants(runId);
    }

    /** After the approval: a repeated refund delivery never refunds twice, and a repeated final turn never answers twice. */
    @IsTest
    static void repeatedDeliveriesAfterApprovalNeverRefundTwice() {
        Fixture fixture = refundAgent();
        Id runId = AgentKernelTestFactory.startRunWithoutDispatch(fixture.definition).runId;
        AgentRun__c waiting = AgentKernelTestFactory.runUntilSettled(runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waiting.Status__c, waiting.ErrorCode__c + ': ' + waiting.ErrorMessage__c);

        Test.startTest();
        System.runAs(new User(Id = fixture.approverId)) {
            AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(AgentKernelTestFactory.pendingApproval(runId).Id, true, 'Within policy.'));
        }
        assertRepeatChangesNothing(deliver(runId));
        System.assertEquals(1, KernelTestTool.invocationCount, 'The approved refund runs once.');
        assertRepeatChangesNothing(deliver(runId));
        Test.stopTest();

        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        System.assertEquals(1, KernelTestTool.invocationCount, 'Repeated deliveries never refund twice.');
        System.assertEquals(2, KernelTestModelProvider.invocationCount, 'Repeated deliveries never ask the model twice.');
        AgentKernelTestFactory.assertLifecycleInvariants(runId);
    }

    private class Fixture {
        AgentDefinition__c definition;
        Id approverId;
    }

    /** A Delegated Principal agent whose refund has outside effects and needs a named approver. */
    private static Fixture refundAgent() {
        Fixture fixture = new Fixture();
        fixture.definition = AgentKernelTestFactory.createDefinition(6, 6);
        AgentKernelTestFactory.useDelegatedPrincipal(fixture.definition);
        fixture.approverId = AgentKernelTestFactory.approverUser();
        AgentTool__c refund = AgentKernelTestFactory.createTool(
            fixture.definition.Id,
            REFUND_TOOL,
            '{"type":"object","properties":{"amount":{"type":"number"}},"required":["amount"],"additionalProperties":false}'
        );
        refund.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        refund.ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED;
        refund.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        refund.ApproverType__c = AgentKernelModels.APPROVER_USER;
        refund.ApproverUser__c = fixture.approverId;
        refund.ApprovalTimeoutMinutes__c = 1440;
        AgentKernelTestFactory.updateRecord(refund);
        AgentConfigService.clearCacheForTest();
        AttendedAccessService.attendedForTest = false;
        KernelTestModelProvider.scriptToolCall(REFUND_TOOL, '{"amount":120}');
        KernelTestModelProvider.scriptFinal('{"reply":"Your refund is on its way."}');
        return fixture;
    }

    /** One delivered step: what the loopback, lease, and worker job were handed. */
    private class Delivery {
        Id runId;
        Id commandId;
        String commandType;
        Decimal revision;
        String operationKey;
        String dispatchToken;
        String leaseToken;
    }

    /** Delivers the run's current step once, as dispatch would, as the run's worker user. */
    private static Delivery deliver(Id runId) {
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        Delivery delivery = new Delivery();
        System.runAs(AgentKernelTestFactory.worker(runId)) {
            if (run.ResolvedPrincipalUser__c == null) {
                AgentKernel.acceptLoopbackDispatch(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
            }
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(
                run.Id,
                command.Id,
                run.Revision__c,
                command.OperationKey__c,
                command.DispatchToken__c
            );
            System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
            AgentCommand__c leased = AgentKernelTestFactory.getCommand(command.Id);
            delivery.runId = runId;
            delivery.commandId = leased.Id;
            delivery.commandType = leased.CommandType__c;
            delivery.revision = leased.ExpectedRunRevision__c;
            delivery.operationKey = leased.OperationKey__c;
            delivery.dispatchToken = leased.DispatchToken__c;
            delivery.leaseToken = leased.LeaseToken__c;
            execute(delivery);
        }
        AgentKernelTestFactory.assertLifecycleInvariants(runId);
        return delivery;
    }

    private static void execute(Delivery delivery) {
        if (delivery.commandType == AgentKernelModels.COMMAND_TYPE_MODEL) {
            new ModelCommandQueueable(delivery.runId, delivery.commandId, delivery.revision, delivery.operationKey, delivery.leaseToken).execute(null);
        } else {
            new ToolCommandQueueable(delivery.runId, delivery.commandId, delivery.revision, delivery.operationKey, delivery.leaseToken).execute(null);
        }
    }

    /** Hands the same step to the worker, the lease, and the loopback again; each must refuse it. */
    private static void assertRepeatChangesNothing(Delivery delivery) {
        Snapshot before = snapshotOf(delivery.runId);
        System.runAs(AgentKernelTestFactory.worker(delivery.runId)) {
            execute(delivery);
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(
                delivery.runId,
                delivery.commandId,
                delivery.revision,
                delivery.operationKey,
                delivery.dispatchToken
            );
            System.assertEquals(CommandLeaseService.Outcome.Noop, lease.outcome, 'A settled step cannot be leased again.');
            try {
                AgentKernel.acceptLoopbackDispatch(delivery.runId, delivery.commandId, delivery.revision, delivery.operationKey, delivery.dispatchToken);
                System.assert(false, 'A repeated loopback hop for a settled step must be refused.');
            } catch (AgentKernelException refused) {
                System.assert(
                    refused instanceof AgentKernelException.ConcurrencyException || refused instanceof AgentKernelException.InvalidTransitionException,
                    refused.getTypeName()
                );
            }
        }
        before.assertUnchanged('A repeated ' + delivery.commandType + ' delivery');
    }

    /** What a repeated step must not change. */
    private class Snapshot {
        Decimal revision;
        Decimal lastEvent;
        Integer modelCalls;
        Integer toolCalls;

        void assertUnchanged(String what) {
            Snapshot now = snapshotOf(runIdForCompare);
            System.assertEquals(revision, now.revision, what + ' must not advance the run.');
            System.assertEquals(lastEvent, now.lastEvent, what + ' must not record an event.');
            System.assertEquals(modelCalls, now.modelCalls, what + ' must not ask the model again.');
            System.assertEquals(toolCalls, now.toolCalls, what + ' must not run the tool again.');
        }

        Id runIdForCompare;
    }

    private static Snapshot snapshotOf(Id runId) {
        AgentRun__c run = [SELECT Revision__c, LastEventSequence__c FROM AgentRun__c WHERE Id = :runId WITH SYSTEM_MODE];
        Snapshot snapshot = new Snapshot();
        snapshot.runIdForCompare = runId;
        snapshot.revision = run.Revision__c;
        snapshot.lastEvent = run.LastEventSequence__c;
        snapshot.modelCalls = KernelTestModelProvider.invocationCount;
        snapshot.toolCalls = KernelTestTool.invocationCount;
        return snapshot;
    }
}
