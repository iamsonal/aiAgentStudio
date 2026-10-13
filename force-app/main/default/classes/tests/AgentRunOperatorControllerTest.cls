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

/** Reference scenario 11: an operator rescues, reconciles, and checks health without code or revisions. */
@IsTest
private class AgentRunOperatorControllerTest {
    @IsTest
    static void operatorRescuesAPausedRunWithoutKnowingItsRevision() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
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

            Map<String, Object> view = AgentRunOperatorController.getRunView(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, view.get('status'));
            System.assertEquals(true, view.get('canRescue'));
            System.assertEquals(false, view.get('canReconcile'));
            System.assertEquals(null, view.get('waitExpiresAt'));

            AgentRunOperatorController.rescue(started.runId, 'The provider is available again.');

            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(started.runId).Status__c);
            AgentEvent__c rescued = [
                SELECT Payload__c
                FROM AgentEvent__c
                WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_RUN_RESCUED
                WITH SYSTEM_MODE
            ];
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(rescued.Payload__c);
            System.assertEquals(UserInfo.getUserId(), payload.get('actorId'), 'The rescue records who performed it.');

            Datetime deadline = Datetime.newInstanceGmt(2030, 1, 1, 12, 0, 0);
            AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = started.runId, WaitExpiresAt__c = deadline));
            System.assertEquals(deadline, AgentRunOperatorController.getRunView(started.runId).get('waitExpiresAt'), 'The operator sees when a wait ends.');
        }
    }

    @IsTest
    static void operatorSeesWhichLimitHoldsABudgetPauseBeforeRescuing() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(1, 1);
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandSpec nextModel = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, 'continue', null);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.continueWith(started.runId, started.commandId, started.revision, started.operationKey, 'first response', nextModel)
            );

            Map<String, Object> budget = (Map<String, Object>) AgentRunOperatorController.getRunView(started.runId).get('budget');
            System.assertEquals(1, budget.get('modelCalls'));
            System.assertEquals(1, budget.get('maxModelCalls'));
            System.assertEquals('model', budget.get('rescueBlockedBy'), 'Rescue starts a model turn, which the spent model budget refuses.');

            AgentKernelTestFactory.updateRecord(new AgentDefinition__c(Id = definition.Id, MaxModelCalls__c = 5));
            budget = (Map<String, Object>) AgentRunOperatorController.getRunView(started.runId).get('budget');
            System.assertEquals(null, budget.get('rescueBlockedBy'), 'Once the limit is raised, rescue fits.');
            AgentRunOperatorController.rescue(started.runId, 'Limit raised.');
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(started.runId).Status__c);
            System.assertEquals(null, AgentRunOperatorController.getRunView(started.runId).get('budget'), 'Only a budget pause reports a budget.');
        }
    }

    @IsTest
    static void operatorReconcilesAnUnknownToolCallAndTheAgentContinues() {
        // Operator alone is enough: reconciling is checking the outside system, not approving.
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelTestFactory.createTool(definition.Id, 'order_tool', '{"type":"object"}');
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
            AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(run.Id, tool.Id, run.Revision__c, tool.OperationKey__c, 'TOOL_OUTCOME_UNKNOWN', 'The ERP timed out.')
            );

            Map<String, Object> view = AgentRunOperatorController.getRunView(run.Id);
            System.assertEquals(true, view.get('canReconcile'));
            System.assertEquals('order_tool', view.get('unknownToolName'));
            System.assertEquals(false, view.get('canCancel'), 'An unconfirmed call must be reconciled before cancelling.');

            String status = AgentRunOperatorController.reconcile(
                run.Id,
                'ConfirmFailed',
                'Checked the ERP: no order exists.',
                null,
                'No order was created.',
                false,
                false
            );

            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, status);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, AgentKernelTestFactory.getCommand(tool.Id).Status__c);
        }
    }

    @IsTest
    static void approverWithoutRunControlCannotReconcile() {
        User approver = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(approver) {
            try {
                ExecutionIdentityService.assertCanReconcile(delegatedRun(UserInfo.getUserId(), approver.Id));
                System.assert(false, 'Human Decision alone must not reconcile.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('not authorized'));
            }
            System.assertEquals(false, ExecutionIdentityService.canReconcile());
        }
    }

    @IsTest
    static void executionUserCannotReconcileItsOwnRunEvenWithRunControl() {
        User principal = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(principal) {
            try {
                ExecutionIdentityService.assertCanReconcile(delegatedRun(UserInfo.getUserId(), principal.Id));
                System.assert(false, 'The execution user must not settle its own call.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('its own run'));
            }
        }
    }

    private static AgentRun__c delegatedRun(Id initiatingUserId, Id principalId) {
        return new AgentRun__c(
            InitiatingUser__c = initiatingUserId,
            ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId(),
            ExpectedPrincipalUser__c = principalId,
            ResolvedPrincipalUser__c = principalId
        );
    }

    @IsTest
    static void healthIsReturnedAsPlainData() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            Map<String, Object> health = AgentRunOperatorController.getHealth(24);
            System.assert(health.containsKey('status'));
            System.assert(health.containsKey('actions'));
        }
    }
}
