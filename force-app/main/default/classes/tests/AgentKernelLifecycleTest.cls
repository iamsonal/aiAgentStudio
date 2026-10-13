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
private class AgentKernelLifecycleTest {
    @IsTest
    static void startAndSucceedPersistsLifecycle() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();

        Test.startTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        Test.stopTest();

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(1, run.Revision__c);
        System.assertEquals(started.commandId, run.CurrentCommand__c);
        System.assertEquals(0, run.ModelCallCount__c);
        System.assertEquals(0, run.ToolCallCount__c);

        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, command.CommandType__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, command.Status__c);
        System.assertEquals(1, command.ExpectedRunRevision__c);
        System.assertEquals(started.operationKey, command.OperationKey__c);
        System.assertEquals(started.runId, command.AgentRun__c);

        List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(started.runId);
        System.assertEquals(2, events.size());
        System.assertEquals(1, events[0].Sequence__c);
        System.assertEquals(AgentKernelModels.EVENT_RUN_STARTED, events[0].EventType__c);
        System.assertEquals(2, events[1].Sequence__c);
        System.assertEquals(AgentKernelModels.EVENT_INPUT_ACCEPTED, events[1].EventType__c);

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, '{"answer":"done"}')
        );

        run = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(started.commandId);
        events = AgentKernelTestFactory.getEvents(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c);
        System.assertEquals(2, run.Revision__c);
        System.assertEquals(1, run.ModelCallCount__c);
        System.assertEquals(null, run.CurrentCommand__c);
        System.assertEquals('{"answer":"done"}', run.Output__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertEquals(3, events.size());
        System.assertEquals(3, events[2].Sequence__c);
        System.assertEquals(AgentKernelModels.EVENT_RUN_COMPLETED, events[2].EventType__c);
    }

    @IsTest
    static void continueModelToToolAndBackCountsCalls() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelModels.CommandSpec toolSpec = new AgentKernelModels.CommandSpec(
            AgentKernelModels.COMMAND_TYPE_TOOL,
            '{"query":"account"}',
            'lookup_account'
        );

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(started.runId, started.commandId, started.revision, started.operationKey, '{"tool":"lookup_account"}', toolSpec)
        );

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(2, run.Revision__c);
        System.assertEquals(1, run.ModelCallCount__c);
        System.assertEquals(0, run.ToolCallCount__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_TOOL, toolCommand.CommandType__c);
        System.assertEquals(2, toolCommand.ExpectedRunRevision__c);
        System.assertEquals('lookup_account', toolCommand.ToolName__c);

        AgentKernelModels.CommandSpec modelSpec = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, '{"toolResult":"found"}', null);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(run.Id, toolCommand.Id, run.Revision__c, toolCommand.OperationKey__c, '{"found":true}', modelSpec)
        );

        run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c nextModel = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(3, run.Revision__c);
        System.assertEquals(1, run.ModelCallCount__c);
        System.assertEquals(1, run.ToolCallCount__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, nextModel.CommandType__c);
        System.assertEquals(3, nextModel.ExpectedRunRevision__c);

        List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(run.Id);
        System.assertEquals(4, events.size());
        System.assertEquals(AgentKernelModels.EVENT_TOOL_REQUESTED, events[2].EventType__c);
        System.assertEquals(toolCommand.OperationKey__c, events[2].CommandKey__c);
        System.assertEquals(AgentKernelModels.EVENT_MODEL_REQUESTED, events[3].EventType__c);
        System.assertEquals(nextModel.OperationKey__c, events[3].CommandKey__c);
    }

    @IsTest
    static void duplicateOutcomeIsRejectedWithoutEvent() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.succeed(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            'complete'
        );
        AgentKernelTestFactory.applyOutcome(outcome);
        Integer eventCount = AgentKernelTestFactory.getEvents(started.runId).size();

        Boolean rejected = false;
        try {
            AgentKernelTestFactory.applyOutcome(outcome);
        } catch (AgentKernelException.ConcurrencyException e) {
            rejected = true;
        } catch (AgentKernelException.InvalidTransitionException e) {
            rejected = true;
        }

        System.assert(rejected, 'A duplicate durable outcome must be rejected.');
        System.assertEquals(eventCount, AgentKernelTestFactory.getEvents(started.runId).size(), 'A rejected duplicate must not append an event.');
    }

    @IsTest
    static void cancelIsRevisionSafeAndRejectsLateOutcome() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());

        AgentRunService.cancel(started.runId, started.revision, 'No longer needed.');

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, run.Status__c);
        System.assertEquals(2, run.Revision__c);
        System.assertEquals(null, run.CurrentCommand__c);
        System.assertEquals('RUN_CANCELLED', run.ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, command.Status__c);
        System.assertEquals('RUN_CANCELLED', command.ErrorCode__c);

        Boolean rejected = false;
        try {
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, 'too late')
            );
        } catch (AgentKernelException.ConcurrencyException e) {
            rejected = true;
        } catch (AgentKernelException.InvalidTransitionException e) {
            rejected = true;
        }
        System.assert(rejected, 'A late outcome for a cancelled run must be rejected.');

        List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(started.runId);
        System.assertEquals(3, events.size());
        System.assertEquals(AgentKernelModels.EVENT_RUN_CANCELLED, events[2].EventType__c);
    }

    @IsTest
    static void immediateCancelProtectsSensitiveAuditPayload() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy fullRetention = AgentExecutionPolicyService.defaults();
        fullRetention.payloadRetentionMode = PayloadProtectionService.MODE_FULL;
        AgentKernelTestFactory.configureExecutionPolicy(fullRetention);
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentRunService.cancel(started.runId, started.revision, 'Requested by alice@example.com.');

        AgentRun__c cancelled = AgentKernelTestFactory.getRun(started.runId);
        AgentEvent__c cancelEvent = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_RUN_CANCELLED
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assert(!cancelled.CancellationReason__c.contains('alice@example.com'));
        System.assert(TrustService.containsToken(cancelled.CancellationReason__c));
        System.assert(!cancelEvent.Payload__c.contains('alice@example.com'));
        System.assert(TrustService.containsToken(cancelEvent.Payload__c));
    }

    @IsTest
    static void leasedCancellationWaitsForKnownOutcome() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'active-model-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        AgentKernelTestFactory.updateRecord(command);

        AgentRunService.cancel(started.runId, started.revision, 'Stop after active work.');

        AgentRun__c requested = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, requested.Status__c);
        System.assertEquals(started.revision, requested.Revision__c);
        System.assertNotEquals(null, requested.CancellationRequestedAt__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, command.Status__c);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.succeed(
            requested.Id,
            command.Id,
            requested.Revision__c,
            command.OperationKey__c,
            '{"answer":"completed"}'
        );
        outcome.leaseToken = command.LeaseToken__c;
        AgentKernel.applyOutcome(outcome);

        AgentRun__c cancelled = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, cancelled.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertEquals('RUN_CANCELLED', cancelled.ErrorCode__c);
        System.assertEquals(null, cancelled.CurrentCommand__c);
    }

    @IsTest
    static void leasedSideEffectCancellationBecomesUnknownWhenLeaseExpires() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'cancelled_external', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.LeaseToken__c = 'active-external-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(-1);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);

        AgentRunService.cancel(started.runId, started.revision, 'Stop external work.');
        AgentKernel.StaleLeaseRecoveryResult recovery = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());

        AgentRun__c waiting = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(1, recovery.unknown);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waiting.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, command.Status__c);
    }

    @IsTest
    static void unknownOutcomeRequiresMatchingReconciliation() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'reconciled_tool', '{"type":"object"}');
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
            AgentRun__c activeRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c originalCommand = AgentKernelTestFactory.getCommand(activeRun.CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(
                    activeRun.Id,
                    originalCommand.Id,
                    activeRun.Revision__c,
                    originalCommand.OperationKey__c,
                    'OUTCOME_UNKNOWN',
                    'The external result could not be confirmed.'
                )
            );

            AgentRun__c waitingRun = AgentKernelTestFactory.getRun(started.runId);
            originalCommand = AgentKernelTestFactory.getCommand(originalCommand.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waitingRun.Status__c);
            System.assertEquals(3, waitingRun.Revision__c);
            System.assertEquals(null, waitingRun.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, originalCommand.Status__c);

            AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
            request.runId = waitingRun.Id;
            request.commandId = originalCommand.Id;
            request.expectedRunRevision = waitingRun.Revision__c;
            request.operationKey = originalCommand.OperationKey__c;
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
            request.confirmedOutput = '{"confirmed":true}';
            request.reason = 'Verified in the external system.';
            AgentKernelModels.ReconciliationResult reconciliation = AgentRunService.reconcileUnknownOutcome(request);
            Id resumedCommandId = reconciliation.dispatchedCommandId;
            AgentRun__c resumedRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c resumedCommand = AgentKernelTestFactory.getCommand(resumedCommandId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, resumedRun.Status__c);
            System.assertEquals(4, resumedRun.Revision__c);
            System.assertEquals(resumedCommandId, resumedRun.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, resumedCommand.CommandType__c);
            System.assertEquals(4, resumedCommand.ExpectedRunRevision__c);

            List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(started.runId);
            System.assertEquals(5, events.size());
            System.assertEquals(AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN, events[3].EventType__c);
            System.assertEquals(AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED, events[4].EventType__c);

            Boolean staleRejected = false;
            try {
                AgentRunService.reconcileUnknownOutcome(request);
            } catch (AgentKernelException.ConcurrencyException e) {
                staleRejected = true;
            }
            System.assert(staleRejected, 'A stale resume revision must be rejected.');
            System.assertEquals(5, AgentKernelTestFactory.getEvents(started.runId).size());
        }
    }

    @IsTest
    static void confirmedUnknownOutcomePausesWhenTheModelBudgetIsSpent() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(1, 10);
            AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'reconciled_tool', '{"type":"object"}');
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
            AgentRun__c activeRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(activeRun.CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(activeRun.Id, toolCommand.Id, activeRun.Revision__c, toolCommand.OperationKey__c, 'OUTCOME_UNKNOWN', 'Unconfirmed.')
            );
            AgentRun__c waitingRun = AgentKernelTestFactory.getRun(started.runId);

            AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
            request.runId = waitingRun.Id;
            request.commandId = toolCommand.Id;
            request.expectedRunRevision = waitingRun.Revision__c;
            request.operationKey = toolCommand.OperationKey__c;
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
            request.confirmedOutput = '{"confirmed":true}';
            request.reason = 'Verified in the external system.';
            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(request);

            AgentRun__c pausedRun = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(null, result.dispatchedCommandId, 'No model call remains, so nothing is dispatched.');
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, pausedRun.Status__c, 'The confirmation is kept and the run pauses.');
            System.assertEquals('BUDGET_EXCEEDED', pausedRun.ErrorCode__c);
            System.assertEquals(null, pausedRun.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, AgentKernelTestFactory.getCommand(toolCommand.Id).Status__c);
        }
    }

    @IsTest
    static void modelBudgetPausePreventsNextCommand() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition(1, 10));
        AgentKernelModels.CommandSpec nextModel = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, 'continue', null);

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(started.runId, started.commandId, started.revision, started.operationKey, 'first response', nextModel)
        );

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals(2, run.Revision__c);
        System.assertEquals(1, run.ModelCallCount__c);
        System.assertEquals(null, run.CurrentCommand__c);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :started.runId],
            'Budget pause must not schedule another model command.'
        );
        AgentEvent__c paused = AgentKernelTestFactory.getEvents(started.runId)[2];
        System.assertEquals(AgentKernelModels.EVENT_RUN_PAUSED, paused.EventType__c);
        System.assert(run.ErrorMessage__c.contains('used 1 of 1'), run.ErrorMessage__c);
        Map<String, Object> budget = (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(paused.Payload__c)).get('budget');
        System.assertEquals('model', budget.get('exceeded'), 'The pause records which budget ran out, since rescue clears the run error.');
        System.assertEquals(1, budget.get('modelCalls'));
        System.assertEquals(1, budget.get('maxModelCalls'));
        System.assertEquals(1, budget.get('requestedModelCalls'));
    }

    @IsTest
    static void toolBudgetPausePreventsNextCommand() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition(5, 1));
        AgentKernelModels.CommandSpec firstTool = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, 'first', 'test_tool');
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(started.runId, started.commandId, started.revision, started.operationKey, 'model response', firstTool)
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        AgentKernelModels.CommandSpec secondTool = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, 'second', 'test_tool');

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(run.Id, toolCommand.Id, run.Revision__c, toolCommand.OperationKey__c, 'tool response', secondTool)
        );

        run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals(1, run.ToolCallCount__c);
        System.assertEquals(null, run.CurrentCommand__c);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assertEquals(
            2,
            [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :started.runId],
            'Budget pause must not schedule a second tool command.'
        );
        System.assert(run.ErrorMessage__c.endsWith('raise Max Tool Calls and rescue the run.'), run.ErrorMessage__c);
    }

    @IsTest
    static void toolBudgetPauseAlsoNamesSpentModelCalls() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition(1, 1));
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                'model response',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, 'first', 'test_tool')
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                toolCommand.Id,
                run.Revision__c,
                toolCommand.OperationKey__c,
                'tool response',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, 'second', 'test_tool')
            )
        );

        run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assert(
            run.ErrorMessage__c.endsWith('model calls are used up too (1 of 1); raise Max Tool Calls and Max Model Calls and rescue the run.'),
            'Raising only tool calls would pause again, because the model must read the tool result: ' + run.ErrorMessage__c
        );
    }

    @IsTest
    static void traceServiceReturnsBoundedEventAndCommandPages() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentRunService.start(AgentKernelTestFactory.startRequest(definition, '{"request":"trace"}'));

        AgentKernelModels.RunRecord run = AgentTraceService.getRun(started.runId);
        AgentKernelModels.EventPageRequest eventRequest = new AgentKernelModels.EventPageRequest();
        eventRequest.runId = started.runId;
        AgentKernelModels.EventPage eventPage = AgentTraceService.getEventPage(eventRequest);
        AgentKernelModels.CommandPageRequest commandRequest = new AgentKernelModels.CommandPageRequest();
        commandRequest.runId = started.runId;
        AgentKernelModels.CommandPage commandPage = AgentTraceService.getCommandPage(commandRequest);

        System.assertEquals(started.runId, run.id);
        System.assertEquals(2, eventPage.events.size());
        System.assertEquals(1, commandPage.commands.size());
        System.assertEquals(AgentKernelModels.EVENT_RUN_STARTED, eventPage.events[0].eventType);
        System.assertEquals(started.operationKey, commandPage.commands[0].operationKey);
    }
}
