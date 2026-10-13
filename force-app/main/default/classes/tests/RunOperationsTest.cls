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

/** Reference scenario 11: operators act on runs from Flow, and are told up front what only the starter can do. */
@IsTest
private class RunOperationsTest {
    @IsTest
    static void operatorWhoDidNotStartAnInitiatingUserRunCannotRescueItButCanCancel() {
        Id runId = pausedRunStartedBySelf();
        User other = sharedOperator(runId);

        List<AgentRescueRunAction.Result> rescued;
        Map<String, Object> view;
        List<AgentCancelRunAction.Result> cancelled;
        System.runAs(other) {
            view = AgentRunOperatorController.getRunView(runId);
            rescued = AgentRescueRunAction.rescue(new List<AgentRescueRunAction.Request>{ rescueRequest(runId) });
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(runId).Status__c, 'A refused rescue changes nothing.');
            AgentCancelRunAction.Request cancel = new AgentCancelRunAction.Request();
            cancel.runId = runId;
            cancel.reason = 'The starter is away.';
            cancelled = AgentCancelRunAction.cancel(new List<AgentCancelRunAction.Request>{ cancel });
        }

        System.assertEquals(false, view.get('canRescue'));
        System.assertEquals(AgentKernel.INITIATING_USER_CONTINUE_REFUSED, view.get('rescueBlockedReason'));
        System.assertEquals(AgentKernel.INITIATING_USER_CONTINUE_REFUSED, rescued[0].errorMessage);
        System.assertEquals(null, cancelled[0].errorMessage);
        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, AgentKernelTestFactory.getRun(runId).Status__c);
    }

    @IsTest
    static void starterWithRunControlRescuesFromFlow() {
        Id runId = pausedRunStartedBySelf();
        List<AgentRescueRunAction.Result> rescued;
        System.runAs(AgentKernelTestFactory.self()) {
            rescued = AgentRescueRunAction.rescue(new List<AgentRescueRunAction.Request>{ rescueRequest(runId) });
        }
        System.assertEquals(null, rescued[0].errorMessage);
        System.assertNotEquals(null, rescued[0].nextCommandId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(runId).Status__c);
    }

    @IsTest
    static void personWithoutRunControlIsRefusedByEveryOperationAction() {
        Id runId = pausedRunStartedBySelf();
        User runner = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        share(runId, runner.Id);

        List<AgentRescueRunAction.Result> rescued;
        List<AgentReconcileToolCallAction.Result> reconciled;
        System.runAs(runner) {
            rescued = AgentRescueRunAction.rescue(new List<AgentRescueRunAction.Request>{ rescueRequest(runId) });
            AgentReconcileToolCallAction.Request request = new AgentReconcileToolCallAction.Request();
            request.runId = runId;
            request.decision = 'ConfirmFailed';
            request.reason = 'Trying anyway.';
            reconciled = AgentReconcileToolCallAction.reconcile(new List<AgentReconcileToolCallAction.Request>{ request });
        }

        System.assertNotEquals(null, rescued[0].errorMessage);
        System.assertNotEquals(null, reconciled[0].errorMessage);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(runId).Status__c);
    }

    @IsTest
    static void operatorPausesFromFlowThenRescues() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition(5, 5));
            AgentPauseRunAction.Request request = new AgentPauseRunAction.Request();
            request.runId = started.runId;
            request.reason = 'Checking the agent instructions.';

            List<AgentPauseRunAction.Result> paused = AgentPauseRunAction.pause(new List<AgentPauseRunAction.Request>{ request });

            System.assertEquals(null, paused[0].errorMessage);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused[0].status);
        }
    }

    @IsTest
    static void otherOperatorMaySettleButNotContinueAnInitiatingUserCall() {
        Id runId = unknownRunStartedBySelf(2);
        User other = sharedOperator(runId);

        List<AgentReconcileToolCallAction.Result> continued;
        List<AgentReconcileToolCallAction.Result> settled;
        System.runAs(other) {
            AgentReconcileToolCallAction.Request succeed = reconcileRequest(runId, 'ConfirmSucceeded');
            succeed.confirmedOutput = '{}';
            continued = AgentReconcileToolCallAction.reconcile(new List<AgentReconcileToolCallAction.Request>{ succeed });
            AgentReconcileToolCallAction.Request fail = reconcileRequest(runId, 'ConfirmFailed');
            fail.failureMessage = 'No order exists.';
            fail.pauseRun = true;
            settled = AgentReconcileToolCallAction.reconcile(new List<AgentReconcileToolCallAction.Request>{ fail });
        }

        System.assertEquals(AgentKernel.INITIATING_USER_CONTINUE_REFUSED, continued[0].errorMessage);
        System.assertEquals(null, settled[0].errorMessage);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, settled[0].status);
    }

    @IsTest
    static void attestedRetryIsAllowedAfterAutomaticRetriesRanOut() {
        Id runId = unknownRunStartedBySelf(0);
        AgentCommand__c unknown = [SELECT Id FROM AgentCommand__c WHERE AgentRun__c = :runId AND Status__c = 'Unknown' WITH SYSTEM_MODE];
        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = unknown.Id, AttemptNumber__c = 1));

        List<AgentReconcileToolCallAction.Result> unattested;
        List<AgentReconcileToolCallAction.Result> attested;
        System.runAs(AgentKernelTestFactory.self()) {
            unattested = AgentReconcileToolCallAction.reconcile(new List<AgentReconcileToolCallAction.Request>{ reconcileRequest(runId, 'Retry') });
            AgentReconcileToolCallAction.Request request = reconcileRequest(runId, 'Retry');
            request.safeToRetry = true;
            attested = AgentReconcileToolCallAction.reconcile(new List<AgentReconcileToolCallAction.Request>{ request });
        }

        System.assertNotEquals(null, unattested[0].errorMessage, 'Retry without an attestation is refused.');
        System.assertEquals(null, attested[0].errorMessage, 'Max Retries 0 was spent, but the operator attested the repeat is safe.');
        AgentEvent__c reconciled = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :runId AND EventType__c = :AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED
            WITH SYSTEM_MODE
        ];
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(reconciled.Payload__c);
        System.assertEquals(true, payload.get('safeToRetryAttested'));
        System.assertEquals(UserInfo.getUserId(), payload.get('actorId'));
    }

    private static Id pausedRunStartedBySelf() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        AgentKernelModels.StartResult started;
        System.runAs(AgentKernelTestFactory.self()) {
            started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition(5, 5));
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.pause(
                    started.runId,
                    started.commandId,
                    started.revision,
                    started.operationKey,
                    'MODEL_PROVIDER_ERROR',
                    'Provider unavailable.'
                )
            );
        }
        return started.runId;
    }

    private static Id unknownRunStartedBySelf(Integer maxRetries) {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        Id runId;
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5, maxRetries);
            AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'order_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.continueWith(
                    started.runId,
                    started.commandId,
                    started.revision,
                    started.operationKey,
                    null,
                    new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'order_tool')
                )
            );
            AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(run.Id, command.Id, run.Revision__c, command.OperationKey__c, 'TOOL_OUTCOME_UNKNOWN', 'The ERP timed out.')
            );
            runId = run.Id;
        }
        return runId;
    }

    private static User sharedOperator(Id runId) {
        User operator = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.OPERATOR });
        share(runId, operator.Id);
        return operator;
    }

    private static void share(Id runId, Id userId) {
        System.runAs(AgentKernelTestFactory.self()) {
            insert new AgentRun__Share(ParentId = runId, UserOrGroupId = userId, AccessLevel = 'Edit', RowCause = Schema.AgentRun__Share.RowCause.Manual);
        }
    }

    private static AgentRescueRunAction.Request rescueRequest(Id runId) {
        AgentRescueRunAction.Request request = new AgentRescueRunAction.Request();
        request.runId = runId;
        request.guidance = 'Try again.';
        return request;
    }

    private static AgentReconcileToolCallAction.Request reconcileRequest(Id runId, String decision) {
        AgentReconcileToolCallAction.Request request = new AgentReconcileToolCallAction.Request();
        request.runId = runId;
        request.decision = decision;
        request.reason = 'Checked the ERP.';
        return request;
    }
}
