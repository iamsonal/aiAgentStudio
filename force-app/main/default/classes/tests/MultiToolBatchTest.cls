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
private class MultiToolBatchTest {
    @IsTest
    static void toolBatchIsPersistedAndActivatedSequentially() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'second_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
        modelOutcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'first_tool'),
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'second_tool')
        };
        AgentKernelTestFactory.applyOutcome(modelOutcome);

        List<AgentCommand__c> tools = [
            SELECT Id, Status__c, ExpectedRunRevision__c, OperationKey__c, BatchKey__c, BatchOrdinal__c, BatchSize__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :started.runId AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
            ORDER BY BatchOrdinal__c ASC
        ];
        System.assertEquals(2, tools.size());
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, tools[0].Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_BLOCKED, tools[1].Status__c);
        System.assertEquals(tools[0].BatchKey__c, tools[1].BatchKey__c);
        System.assertEquals(1, tools[0].BatchOrdinal__c);
        System.assertEquals(2, tools[1].BatchOrdinal__c);

        AgentKernelModels.CommandOutcome firstTool = continuingOutcome(started.runId, tools[0].Id, 2, tools[0].OperationKey__c);
        firstTool.nextCommand = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, null, null);
        firstTool.eventType = AgentKernelModels.EVENT_TOOL_COMPLETED;
        AgentKernelTestFactory.applyOutcome(firstTool);
        AgentRun__c afterFirst = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(tools[1].Id, afterFirst.CurrentCommand__c);
        System.assertEquals(3, afterFirst.Revision__c);

        AgentKernelModels.CommandOutcome secondTool = continuingOutcome(started.runId, tools[1].Id, 3, tools[1].OperationKey__c);
        secondTool.nextCommand = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, null, null);
        secondTool.eventType = AgentKernelModels.EVENT_TOOL_COMPLETED;
        AgentKernelTestFactory.applyOutcome(secondTool);
        AgentRun__c afterSecond = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(4, afterSecond.Revision__c);
        System.assertEquals(
            AgentKernelModels.COMMAND_TYPE_MODEL,
            [SELECT CommandType__c FROM AgentCommand__c WHERE Id = :afterSecond.CurrentCommand__c].CommandType__c
        );
        System.assertEquals(
            2,
            [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_TOOL_REQUESTED]
        );
    }

    @IsTest
    static void confirmedUnknownBatchToolContinuesWithNextSibling() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
            AgentKernelTestFactory.createTool(definition.Id, 'second_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
            modelOutcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'first_tool'),
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'second_tool')
            };
            AgentKernelTestFactory.applyOutcome(modelOutcome);
            List<AgentCommand__c> tools = batchTools(started.runId);

            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(started.runId, tools[0].Id, 2, tools[0].OperationKey__c, 'OUTCOME_UNKNOWN', 'The first tool outcome is uncertain.')
            );
            AgentRun__c waiting = AgentKernelTestFactory.getRun(started.runId);
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(waiting, tools[0]);
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
            request.confirmedOutput = '{"confirmed":true}';

            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(request);

            AgentRun__c resumed = AgentKernelTestFactory.getRun(started.runId);
            tools = batchTools(started.runId);
            System.assertEquals(tools[1].Id, result.dispatchedCommandId);
            System.assertEquals(tools[1].Id, resumed.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, resumed.Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, tools[0].Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, tools[1].Status__c);
            System.assertEquals(resumed.Revision__c, tools[1].ExpectedRunRevision__c);
            System.assertEquals(
                1,
                [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :started.runId AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL],
                'Reconciliation must not skip the remaining batch and create a model command.'
            );
        }
    }

    @IsTest
    static void confirmedFailedUnknownBatchToolCancelsBlockedSiblings() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
            AgentKernelTestFactory.createTool(definition.Id, 'second_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
            modelOutcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'first_tool'),
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'second_tool')
            };
            AgentKernelTestFactory.applyOutcome(modelOutcome);
            List<AgentCommand__c> tools = batchTools(started.runId);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(started.runId, tools[0].Id, 2, tools[0].OperationKey__c, 'OUTCOME_UNKNOWN', 'The first tool outcome is uncertain.')
            );
            AgentRun__c waiting = AgentKernelTestFactory.getRun(started.runId);
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(waiting, tools[0]);
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmFailed;
            request.errorCode = 'CONFIRMED_FAILURE';
            request.errorMessage = 'The operation did not complete.';

            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(request);

            AgentRun__c continued = AgentKernelTestFactory.getRun(started.runId);
            tools = batchTools(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, continued.Status__c, 'A confirmed failure goes back to the model.');
            AgentCommand__c model = AgentKernelTestFactory.getCommand(continued.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, model.CommandType__c);
            System.assertEquals(model.Id, result.dispatchedCommandId);
            System.assert(model.Input__c.contains('CONFIRMED_FAILURE'));
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, tools[0].Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, tools[1].Status__c);
        }
    }

    @IsTest
    static void confirmedFailedWithPauseRequestPausesForTheOperator() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelTestFactory.createTool(definition.Id, 'only_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
            modelOutcome.nextCommand = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'only_tool');
            AgentKernelTestFactory.applyOutcome(modelOutcome);
            AgentCommand__c tool = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(started.runId, tool.Id, 2, tool.OperationKey__c, 'OUTCOME_UNKNOWN', 'The outcome is uncertain.')
            );
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(AgentKernelTestFactory.getRun(started.runId), tool);
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmFailed;
            request.pauseRun = true;

            AgentRunService.reconcileUnknownOutcome(request);

            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assertEquals(tool.Id, paused.CurrentCommand__c);
        }
    }

    @IsTest
    static void retryExhaustionCancelsBlockedSiblings() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
            policy.maxRetries = 0;
            AgentKernelTestFactory.configureExecutionPolicy(policy);
            update definition;
            AgentKernelTestFactory.createTool(definition.Id, 'first_retry_tool', '{"type":"object"}');
            AgentKernelTestFactory.createTool(definition.Id, 'second_retry_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
            modelOutcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'first_retry_tool'),
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'second_retry_tool')
            };
            AgentKernelTestFactory.applyOutcome(modelOutcome);
            List<AgentCommand__c> tools = batchTools(started.runId);
            AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(
                run.Id,
                tools[0].Id,
                run.Revision__c,
                tools[0].OperationKey__c,
                tools[0].DispatchToken__c
            );
            System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);

            AgentKernel.scheduleRetry(AgentKernelTestFactory.retryRequest(run, lease.command, 'TEMPORARY_FAILURE', 1));

            tools = batchTools(started.runId);
            run = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
            System.assertEquals('RETRY_EXHAUSTED', run.ErrorCode__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, tools[0].Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, tools[1].Status__c);

            String exhaustedOperationKey = tools[0].OperationKey__c;
            AgentKernelModels.RescueRequest request = new AgentKernelModels.RescueRequest();
            request.runId = run.Id;
            request.expectedRunRevision = run.Revision__c;
            Id rescuedCommandId = AgentKernel.rescue(request);

            AgentCommand__c rescued = AgentKernelTestFactory.getCommand(rescuedCommandId);
            System.assertEquals(tools[0].Id, rescuedCommandId);
            System.assertEquals(exhaustedOperationKey, rescued.OperationKey__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, rescued.Status__c);
        }
    }

    @IsTest
    static void bindingPauseRescuesThroughTheModelInsteadOfRearming() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
            AgentKernelTestFactory.createTool(definition.Id, 'bound_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.CommandOutcome modelOutcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
            modelOutcome.nextCommand = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'bound_tool');
            AgentKernelTestFactory.applyOutcome(modelOutcome);
            AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(run.Id, tool.Id, run.Revision__c, tool.OperationKey__c, tool.DispatchToken__c);
            System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
            System.assertEquals(true, AgentToolTypeService.isRetrySafe(lease.command));
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.pause(run.Id, tool.Id, run.Revision__c, tool.OperationKey__c, 'TOOL_BINDING_CHANGED', 'The admitted tool binding changed.')
            );
            run = AgentKernelTestFactory.getRun(run.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);

            AgentKernelModels.RescueRequest request = new AgentKernelModels.RescueRequest();
            request.runId = run.Id;
            request.expectedRunRevision = run.Revision__c;
            request.guidance = 'The tool configuration was corrected.';
            Id rescuedCommandId = AgentKernel.rescue(request);

            AgentCommand__c rescued = AgentKernelTestFactory.getCommand(rescuedCommandId);
            System.assertNotEquals(tool.Id, rescuedCommandId, 'A command whose admitted binding is frozen must not be re-armed.');
            System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, rescued.CommandType__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, AgentKernelTestFactory.getCommand(tool.Id).Status__c);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(run.Id).Status__c);
        }
    }

    @IsTest
    static void fullBatchBudgetIsReservedBeforeFirstTool() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 1);
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'second_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.CommandOutcome outcome = continuingOutcome(started.runId, started.commandId, 1, started.operationKey);
        outcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'first_tool'),
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'second_tool')
        };

        AgentKernelTestFactory.applyOutcome(outcome);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assertEquals(0, [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :started.runId AND BatchKey__c != NULL]);
    }

    private static List<AgentCommand__c> batchTools(Id runId) {
        return [
            SELECT Id, Status__c, ExpectedRunRevision__c, OperationKey__c, DispatchToken__c, LeaseToken__c, BatchOrdinal__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
            WITH SYSTEM_MODE
            ORDER BY BatchOrdinal__c ASC
        ];
    }

    private static AgentKernelModels.ReconciliationRequest reconciliationRequest(AgentRun__c waiting, AgentCommand__c command) {
        AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
        request.runId = waiting.Id;
        request.commandId = command.Id;
        request.expectedRunRevision = waiting.Revision__c;
        request.operationKey = command.OperationKey__c;
        request.reason = 'Verified against the effect boundary.';
        return request;
    }

    private static AgentKernelModels.CommandOutcome continuingOutcome(Id runId, Id commandId, Decimal revision, String operationKey) {
        AgentKernelModels.CommandOutcome outcome = new AgentKernelModels.CommandOutcome();
        outcome.runId = runId;
        outcome.commandId = commandId;
        outcome.expectedRunRevision = revision;
        outcome.operationKey = operationKey;
        outcome.commandStatus = AgentKernelModels.COMMAND_STATUS_SUCCEEDED;
        return outcome;
    }
}
