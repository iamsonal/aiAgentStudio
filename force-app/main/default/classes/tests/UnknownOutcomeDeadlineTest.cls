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

@IsTest
private class UnknownOutcomeDeadlineTest {
    /**
     * An Unknown outcome waits for reconciliation only until the run's payload
     * retention ends. Then recovery pauses the run without repeating the call,
     * and an operator can still reconcile it.
     */
    @IsTest
    static void unreconciledUnknownPausesAtItsDeadlineAndStaysReconcilable() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownRun fixture = unknownRun();
            AgentRun__c waiting = AgentKernelTestFactory.getRun(fixture.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waiting.Status__c);
            System.assertNotEquals(null, waiting.WaitExpiresAt__c, 'An Unknown outcome gets a reconciliation deadline.');
            System.assert(waiting.WaitExpiresAt__c > System.now().addDays(29), 'The deadline is the run\'s payload retention.');

            passDeadline(fixture.runId);
            CommandLeaseRecoveryService.recoverOperational(10);

            AgentRun__c paused = AgentKernelTestFactory.getRun(fixture.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assertEquals(AgentKernelRecovery.UNKNOWN_UNRESOLVED, paused.ErrorCode__c);
            System.assertEquals(null, paused.WaitExpiresAt__c);
            System.assert(paused.PurgeAfter__c <= System.now(), 'Retention may clear the data now.');
            System.assertEquals(
                AgentKernelModels.COMMAND_STATUS_UNKNOWN,
                AgentKernelTestFactory.getCommand(fixture.commandId).Status__c,
                'Pausing never repeats or settles the call.'
            );

            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(
                failedRequest(paused, AgentKernelTestFactory.getCommand(fixture.commandId))
            );

            AgentRun__c resumed = AgentKernelTestFactory.getRun(fixture.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, result.runStatus);
            System.assertEquals(null, resumed.PurgeAfter__c, 'A running run has no purge deadline.');
            System.assertEquals(null, resumed.WaitExpiresAt__c);
        }
    }

    /** Once retention cleared the run, reconciliation is refused and the operator cancels instead. */
    @IsTest
    static void purgedUnresolvedRunCanBeCancelledButNotReconciled() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR, AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownRun fixture = unknownRun();
            passDeadline(fixture.runId);
            CommandLeaseRecoveryService.recoverOperational(10);
            PayloadRetentionPurgeService.purge(10);

            AgentRun__c paused = AgentKernelTestFactory.getRun(fixture.runId);
            System.assertNotEquals(null, [SELECT PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :fixture.runId WITH SYSTEM_MODE].PayloadPurgedAt__c);
            try {
                AgentRunService.reconcileUnknownOutcome(failedRequest(paused, AgentKernelTestFactory.getCommand(fixture.commandId)));
                System.assert(false, 'A purged run cannot be reconciled.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('Cancel the run'), expected.getMessage());
            }

            AgentRunService.cancel(paused.Id, paused.Revision__c, 'Work no longer needed.');
            System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, AgentKernelTestFactory.getRun(fixture.runId).Status__c);
        }
    }

    /** Someone without Run Control cannot settle an Unknown call, even after its deadline. */
    @IsTest
    static void personWithoutRunControlCannotReconcileAPausedUnknown() {
        UnknownRun fixture = unknownRun();
        passDeadline(fixture.runId);
        CommandLeaseRecoveryService.recoverOperational(10);
        AgentRun__c paused = AgentKernelTestFactory.getRun(fixture.runId);
        AgentKernelModels.ReconciliationRequest request = failedRequest(paused, AgentKernelTestFactory.getCommand(fixture.commandId));
        User runner = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });

        System.runAs(runner) {
            try {
                AgentRunService.reconcileUnknownOutcome(request);
                System.assert(false, 'Reconciling needs Run Control.');
            } catch (AgentKernelException expected) {
                System.assert(!(expected instanceof AgentKernelException.InvalidTransitionException), expected.getMessage());
            }
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(fixture.runId).Status__c);
    }

    private class UnknownRun {
        Id runId;
        Id commandId;
    }

    private static UnknownRun unknownRun() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'outside_call', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', tool.DeveloperName__c)
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.unknown(run.Id, command.Id, run.Revision__c, command.OperationKey__c, 'OUTCOME_UNKNOWN', 'No answer arrived.')
        );
        UnknownRun fixture = new UnknownRun();
        fixture.runId = run.Id;
        fixture.commandId = command.Id;
        return fixture;
    }

    private static void passDeadline(Id runId) {
        AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = runId, WaitExpiresAt__c = System.now().addMinutes(-1)));
    }

    private static AgentKernelModels.ReconciliationRequest failedRequest(AgentRun__c run, AgentCommand__c command) {
        AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
        request.runId = run.Id;
        request.commandId = command.Id;
        request.expectedRunRevision = run.Revision__c;
        request.operationKey = command.OperationKey__c;
        request.decision = AgentKernelModels.ReconciliationDecision.ConfirmFailed;
        request.reason = 'Checked the outside system; nothing happened.';
        return request;
    }
}
