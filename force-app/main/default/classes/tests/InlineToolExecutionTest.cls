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
 * Stays in This Org tool calls run in the transaction of the model turn that asked
 * for them, or of the Reads Outside Systems call before them; other calls keep
 * their own job.
 */
@IsTest
private class InlineToolExecutionTest {
    @IsTest
    static void onlyThisOrgCallsRunInTheModelWorkersTransaction() {
        AgentDefinition__c definition = multiToolAgent();
        List<String> names = new List<String>{ 'tool_a', 'tool_b', 'tool_c' };
        for (String name : names) {
            AgentKernelTestFactory.createTool(definition.Id, name, '{"type":"object"}');
        }
        scriptCalls(names);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModelWorker(started.runId);

        System.assertEquals(3, KernelTestTool.invocationCount, 'All three calls ran in the model worker.');
        for (AgentCommand__c tool : toolCommands(started.runId)) {
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, tool.Status__c, tool.ToolName__c);
        }
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c next = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, next.CommandType__c, 'The next model turn waits for the finalizer.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, next.Status__c);
        System.assertEquals(0, Limits.getQueueableJobs(), 'Nothing is enqueued before the commit.');
    }

    @IsTest
    static void inPlaceCallsRecordNoQueueWait() {
        AgentDefinition__c definition = multiToolAgent();
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModelWorker(started.runId);

        Integer marked = 0;
        for (AgentEvent__c event : AgentKernelTestFactory.getEvents(started.runId)) {
            if (String.isBlank(event.Payload__c) || !event.Payload__c.startsWith('{')) {
                continue;
            }
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(event.Payload__c);
            if (payload.get('ranInline') == true) {
                System.assertEquals(0, Integer.valueOf(payload.get('queueWaitMs')));
                marked++;
            }
        }
        System.assertEquals(2, marked, 'Each in-place call is marked on its outcome.');
    }

    @IsTest
    static void theNextModelTurnSeesTheSameResultsInTheSameOrder() {
        List<String> inPlace = toolResultsSeenByTheNextTurn(false);
        Test.startTest();
        List<String> ownJobs = toolResultsSeenByTheNextTurn(true);
        Test.stopTest();
        System.assertEquals(3, inPlace.size());
        System.assertEquals(ownJobs, inPlace);
    }

    @IsTest
    static void lowHeadroomStopsBeforeTheNextCall() {
        AgentDefinition__c definition = multiToolAgent();
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        InPlaceToolRunner.headroomChecksForTest = 1;

        runModelWorker(started.runId);

        System.assertEquals(1, KernelTestTool.invocationCount);
        List<AgentCommand__c> tools = toolCommands(started.runId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, tools[0].Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, tools[1].Status__c, 'The second call is left for its own job.');
        System.assertEquals(tools[1].Id, AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
    }

    @IsTest
    static void aTurnWhoseWorkerFailedRunsEachCallInItsOwnJob() {
        AgentDefinition__c definition = multiToolAgent();
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        CommandDeliveryTracker.recordAnomaly(started.commandId, 'WORKER_FAILED');

        runModelWorker(started.runId);

        System.assertEquals(0, KernelTestTool.invocationCount);
        AgentCommand__c tool = toolCommands(started.runId)[0];
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, tool.Status__c);
        System.assertEquals(tool.Id, AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
    }

    @IsTest
    static void aChangesOutsideCallKeepsItsOwnJobAndHoldsTheRest() {
        AgentDefinition__c definition = multiToolAgent();
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        AgentTool__c outside = AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        outside.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(outside);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_c', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b', 'tool_c' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModelWorker(started.runId);

        System.assertEquals(1, KernelTestTool.invocationCount);
        List<AgentCommand__c> tools = toolCommands(started.runId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, tools[0].Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, tools[1].Status__c, 'The outside call waits for its own job.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_BLOCKED, tools[2].Status__c, 'The last call waits for the outside outcome.');
    }

    @IsTest
    static void aReadsOutsideCallKeepsItsOwnJob() {
        AgentDefinition__c definition = multiToolAgent();
        AgentTool__c reader = AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        reader.ToolType__c = AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL;
        AgentKernelTestFactory.updateRecord(reader);
        scriptCalls(new List<String>{ 'tool_a' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModelWorker(started.runId);

        System.assertEquals(0, KernelTestTool.invocationCount);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, toolCommands(started.runId)[0].Status__c);
    }

    @IsTest
    static void aCallThatNeedsApprovalStopsTheRest() {
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.RequireApproval;
        AgentDefinition__c definition = multiToolAgent();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModelWorker(started.runId);

        System.assertEquals(0, KernelTestTool.invocationCount);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c, 'Approval is handled as it is in a job of its own.');
        System.assertEquals('INITIATING_USER_APPROVAL_UNSUPPORTED', run.ErrorCode__c);
        System.assertNotEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, toolCommands(started.runId)[1].Status__c);
    }

    @IsTest
    static void aCallThePolicyDeniesIsRefusedTheSameWayInPlace() {
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.Deny;
        AgentCommand__c inPlace = deniedCall(false);
        Test.startTest();
        AgentCommand__c ownJob = deniedCall(true);
        Test.stopTest();
        System.assertEquals(0, KernelTestTool.invocationCount, 'A denied call never reaches the tool.');
        System.assertEquals(AgentKernelModels.ERROR_TOOL_AUTHORIZATION_DENIED, inPlace.ErrorCode__c);
        System.assertEquals(ownJob.Status__c, inPlace.Status__c);
        System.assertEquals(ownJob.ErrorCode__c, inPlace.ErrorCode__c);
        System.assertEquals(ownJob.ErrorMessage__c, inPlace.ErrorMessage__c);
    }

    @IsTest
    static void aToolThatFailsTheTurnInPlaceRunsAgainInItsOwnJob() {
        AgentDefinition__c definition = multiToolAgent();
        AgentKernelTestFactory.createTool(definition.Id, 'act_on_case', '{"type":"object"}');
        KernelTestTool.accountPrefixPerTool = 'Inline crash ';
        scriptCalls(new List<String>{ 'act_on_case' });
        KernelTestModelProvider.scriptFinal('{"reply":"Done."}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = lease(started.runId);
        String replayedAnswer = JSON.serialize(KernelTestModelProvider.script[0]);

        Savepoint job = Database.setSavepoint();
        CommandAttemptRuntime.failSettlementForTest = true;
        CommandAttemptRuntime.settlementsBeforeFailureForTest = 1;
        Boolean crashed = false;
        try {
            new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        } catch (AgentKernelException.PersistenceException crash) {
            crashed = true;
        } finally {
            CommandAttemptRuntime.failSettlementForTest = false;
        }
        System.assert(crashed, 'The tool settled after the model, in the same job, and that settlement failed.');
        System.assertEquals(1, KernelTestTool.invocationCount, 'The tool ran in the model worker before the crash.');
        Database.rollback(job);
        Database.releaseSavepoint(job);
        KernelTestModelProvider.script.add(0, (AgentKernelModels.ModelResponse) JSON.deserialize(replayedAnswer, AgentKernelModels.ModelResponse.class));
        // What the finalizer does for a failed job. Recovery leases the model command again in the same pass.
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandDeliveryTracker.recordAnomaly(model.Id, 'WORKER_FAILED');
        CommandLeaseRecoveryService.recoverFailedWorker(model.Id, model.LeaseToken__c);
        AgentCommand__c retried = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
        System.assertEquals(model.Id, retried.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, retried.Status__c);

        Test.startTest();
        new ModelCommandQueueable(started.runId, retried.Id, retried.ExpectedRunRevision__c, retried.OperationKey__c, retried.LeaseToken__c).execute(null);
        System.assertEquals(1, KernelTestTool.invocationCount, 'On the retry the tool waits for its own job.');
        AgentCommand__c tool = lease(started.runId);
        new ToolCommandQueueable(started.runId, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);
        runModelWorker(started.runId);
        Test.stopTest();

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelTestFactory.getRun(started.runId).Status__c);
        System.assertEquals(2, KernelTestTool.invocationCount, 'A Stays in This Org call is safe to run again.');
        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = 'Inline crash act_on_case'], 'The crashed call was rolled back.');
    }

    @IsTest
    static void aReadsOutsideJobRunsTheOnlyThisOrgCallsAfterIt() {
        AgentDefinition__c definition = multiToolAgent();
        typedTool(definition.Id, 'tool_a', AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'tool_c', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b', 'tool_c' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        runModelWorker(started.runId);

        runToolWorker(started.runId);

        System.assertEquals(3, KernelTestTool.invocationCount, 'Both later calls ran in the outside read\'s job, in the model\'s order.');
        for (AgentCommand__c tool : toolCommands(started.runId)) {
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, tool.Status__c, tool.ToolName__c);
        }
        AgentCommand__c next = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, next.CommandType__c, 'The next model turn waits for the finalizer.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, next.Status__c);
    }

    @IsTest
    static void aChangesOutsideJobLeavesTheNextCallForItsOwnJob() {
        AgentDefinition__c definition = multiToolAgent();
        typedTool(definition.Id, 'tool_a', AgentToolTypeTestFixtures.EXTERNAL);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        runModelWorker(started.runId);

        runToolWorker(started.runId);

        System.assertEquals(1, KernelTestTool.invocationCount, 'The outside change commits before anything else runs.');
        AgentCommand__c later = toolCommands(started.runId)[1];
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, later.Status__c);
        System.assertEquals(later.Id, AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
    }

    @IsTest
    static void aReadsOutsideCallWhoseJobFailedRunsAlone() {
        AgentDefinition__c definition = multiToolAgent();
        typedTool(definition.Id, 'tool_a', AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        runModelWorker(started.runId);
        CommandDeliveryTracker.recordAnomaly(toolCommands(started.runId)[0].Id, 'WORKER_FAILED');

        runToolWorker(started.runId);

        System.assertEquals(1, KernelTestTool.invocationCount, 'A call that failed the retried job is isolated in its own job.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, toolCommands(started.runId)[1].Status__c);
    }

    @IsTest
    static void aCallAfterAnOutsideReadIsStillDeniedByThePolicy() {
        AgentDefinition__c definition = multiToolAgent();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        AgentKernelTestFactory.updateRecord(definition);
        KernelTestToolPolicy.deniedToolNames.add('tool_b');
        typedTool(definition.Id, 'tool_a', AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_b', '{"type":"object"}');
        scriptCalls(new List<String>{ 'tool_a', 'tool_b' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        runModelWorker(started.runId);

        runToolWorker(started.runId);

        System.assertEquals(1, KernelTestTool.invocationCount, 'Running in the same job skips no check.');
        AgentCommand__c denied = [SELECT Status__c, ErrorCode__c FROM AgentCommand__c WHERE Id = :toolCommands(started.runId)[1].Id];
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, denied.Status__c);
        System.assertEquals(AgentKernelModels.ERROR_TOOL_AUTHORIZATION_DENIED, denied.ErrorCode__c);
    }

    private static AgentCommand__c deniedCall(Boolean ownJob) {
        AgentDefinition__c definition = multiToolAgent();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelTestFactory.createTool(definition.Id, 'tool_a', '{"type":"object"}');
        KernelTestModelProvider.script = null;
        scriptCalls(new List<String>{ 'tool_a' });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        if (ownJob) {
            CommandDeliveryTracker.recordAnomaly(started.commandId, 'WORKER_FAILED');
        }
        runModelWorker(started.runId);
        AgentCommand__c command = toolCommands(started.runId)[0];
        if (ownJob) {
            AgentCommand__c leased = lease(started.runId);
            new ToolCommandQueueable(started.runId, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
        }
        return [SELECT Status__c, ErrorCode__c, ErrorMessage__c FROM AgentCommand__c WHERE Id = :command.Id];
    }

    private static List<String> toolResultsSeenByTheNextTurn(Boolean ownJobs) {
        KernelTestTool.invocationCount = 0;
        KernelTestModelProvider.script = null;
        AgentDefinition__c definition = multiToolAgent();
        List<String> names = new List<String>{ 'tool_a', 'tool_b', 'tool_c' };
        for (String name : names) {
            AgentKernelTestFactory.createTool(definition.Id, name, '{"type":"object"}');
        }
        scriptCalls(names);
        KernelTestModelProvider.scriptFinal('{"result":"done"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        if (ownJobs) {
            CommandDeliveryTracker.recordAnomaly(started.commandId, 'WORKER_FAILED');
        }
        runModelWorker(started.runId);
        for (Integer index = 0; ownJobs && index < names.size(); index++) {
            AgentCommand__c leased = lease(started.runId);
            new ToolCommandQueueable(started.runId, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
        }
        runModelWorker(started.runId);
        List<String> results = new List<String>();
        for (AgentKernelModels.TranscriptEntry entry : KernelTestModelProvider.lastTranscript) {
            if (entry.toolCallId != null && entry.content != null && entry.type == AgentKernelModels.TRANSCRIPT_TOOL_RESULT) {
                results.add(entry.toolName + '|' + entry.toolCallId + '|' + entry.content);
            }
        }
        return results;
    }

    private static AgentDefinition__c multiToolAgent() {
        KernelTestTool.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.AllowMultipleToolCalls__c = true;
        AgentKernelTestFactory.updateRecord(definition);
        return definition;
    }

    private static void scriptCalls(List<String> toolNames) {
        AgentKernelModels.ModelResponse response = new AgentKernelModels.ModelResponse();
        response.isSuccess = true;
        response.isFinal = false;
        response.toolCalls = new List<AgentKernelModels.ModelToolCall>();
        for (Integer index = 0; index < toolNames.size(); index++) {
            AgentKernelModels.ModelToolCall call = new AgentKernelModels.ModelToolCall();
            call.toolName = toolNames[index];
            call.toolInput = '{}';
            call.toolCallId = 'call-' + (index + 1);
            response.toolCalls.add(call);
        }
        if (KernelTestModelProvider.script == null) {
            KernelTestModelProvider.script = new List<AgentKernelModels.ModelResponse>();
        }
        KernelTestModelProvider.script.add(response);
    }

    private static AgentCommand__c lease(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result result = CommandLeaseService.tryLease(
            run.Id,
            command.Id,
            run.Revision__c,
            command.OperationKey__c,
            command.DispatchToken__c
        );
        System.assertEquals(CommandLeaseService.Outcome.Leased, result.outcome);
        return AgentKernelTestFactory.getCommand(command.Id);
    }

    private static void runModelWorker(Id runId) {
        AgentCommand__c leased = lease(runId);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, leased.CommandType__c);
        new ModelCommandQueueable(runId, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
    }

    /** Runs the tool job with its own governor limits, as in production. */
    private static void runToolWorker(Id runId) {
        Test.startTest();
        AgentCommand__c leased = lease(runId);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_TOOL, leased.CommandType__c);
        new ToolCommandQueueable(runId, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
        Test.stopTest();
    }

    private static void typedTool(Id definitionId, String name, String toolType) {
        AgentTool__c tool = AgentKernelTestFactory.createTool(definitionId, name, '{"type":"object"}');
        tool.ToolType__c = toolType;
        AgentKernelTestFactory.updateRecord(tool);
    }

    private static List<AgentCommand__c> toolCommands(Id runId) {
        return [
            SELECT Id, ToolName__c, Status__c, ErrorMessage__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
            ORDER BY BatchOrdinal__c ASC NULLS FIRST, CreatedDate ASC, Id ASC
        ];
    }
}
