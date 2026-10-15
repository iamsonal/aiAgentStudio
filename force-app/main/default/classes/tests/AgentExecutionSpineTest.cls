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
private class AgentExecutionSpineTest {
    @IsTest
    static void modelToolModelPathCompletesThroughWorkers() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolCallId = 'provider-call-1';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = leaseCurrent(run.Id);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_TOOL, tool.CommandType__c);
        System.assertEquals('provider-call-1', tool.ProviderToolCallId__c);
        new ToolCommandQueueable(run.Id, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        model = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c);
        System.assertEquals(2, KernelTestModelProvider.invocationCount);
        System.assertEquals(1, KernelTestTool.invocationCount);
        System.assertEquals(3, KernelTestModelProvider.lastTranscript.size(), 'Original input, then the tool call and its result.');
        System.assertEquals(AgentKernelModels.TRANSCRIPT_ORIGINAL_INPUT, KernelTestModelProvider.lastTranscript[0].type);
        System.assertEquals('provider-call-1', KernelTestModelProvider.lastTranscript[1].toolCallId);
        System.assertEquals(AgentKernelModels.TRANSCRIPT_TOOL_RESULT, KernelTestModelProvider.lastTranscript[2].type);
    }

    @IsTest
    static void toolRationaleIsRequestedRecordedAndNeverReachesTheTool() {
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolInput = '{"_rationale":"The customer reports a team-wide outage.","value":"test"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        // A tool with external effects may need reconciling, so the model explains each call.
        AgentTool__c external = AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        external.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(external);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        AgentKernelModels.ModelRequest sent = (AgentKernelModels.ModelRequest) JSON.deserialize(
            KernelTestModelProvider.lastRequestJson,
            AgentKernelModels.ModelRequest.class
        );
        String schemaJson = sent.tools[0].inputSchema;
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(schemaJson);
        System.assert(
            schemaJson.indexOf('"' + AgentKernelModels.TOOL_RATIONALE_PROPERTY + '"') < schemaJson.indexOf('"value"'),
            'The model states why before it writes the arguments: ' + schemaJson
        );
        System.assert(((List<Object>) schema.get('required')).contains(AgentKernelModels.TOOL_RATIONALE_PROPERTY));
        System.assertEquals(false, schema.get('additionalProperties'), 'The tool schema stays closed.');

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = leaseCurrent(run.Id);
        System.assertEquals('{"value":"test"}', tool.Input__c, 'The closed schema accepted the call once the rationale was removed.');
        System.assertEquals('The customer reports a team-wide outage.', [SELECT Rationale__c FROM AgentCommand__c WHERE Id = :tool.Id].Rationale__c);
        new ToolCommandQueueable(run.Id, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);
        System.assertEquals('{"value":"test"}', KernelTestTool.lastRequest.input, 'The tool never receives the rationale.');
    }

    @IsTest
    static void onlyReviewableCallsAreAskedWhyAndTheReasonIsReplayed() {
        AgentTool__c readOnly = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.IN_ORG);
        AgentTool__c approved = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.IN_ORG, ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED);
        AgentTool__c external = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.EXTERNAL);
        String approver = ModelRequestAssembler.APPROVER_RATIONALE;
        String reviewer = ModelRequestAssembler.REVIEWER_RATIONALE;
        System.assertEquals(null, ModelRequestAssembler.rationalePrompt(readOnly), 'A read-only call is not asked why.');
        System.assertEquals(approver, ModelRequestAssembler.rationalePrompt(approved));
        System.assertEquals(reviewer, ModelRequestAssembler.rationalePrompt(external), 'An operator may reconcile an external effect.');
        external.ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY;
        System.assertEquals(approver, ModelRequestAssembler.rationalePrompt(external), 'An approver may read a call the policy holds.');
        AgentTool__c readOnlyExternal = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        System.assertEquals(null, ModelRequestAssembler.rationalePrompt(readOnlyExternal), 'A read-only outside lookup is not asked why.');
        readOnlyExternal.ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY;
        System.assertEquals(approver, ModelRequestAssembler.rationalePrompt(readOnlyExternal), 'A policy may still ask for approval.');
        String schema = '{"type":"object","properties":{"value":{"type":"string"}},"additionalProperties":false}';
        System.assert(
            ModelRequestAssembler.withRationale(schema, approver).contains(approver),
            'An approval call asks what it will do and which conditions were not confirmed.'
        );
        System.assert(
            approver.contains('If this call only reads'),
            'A policy agent asks reads for the approver text too, so the text keeps a read to one sentence.'
        );

        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolInput = '{"_rationale":"Needed to notify the partner.","value":"test"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        AgentCommand__c call = leaseCurrent(started.runId);
        new ToolCommandQueueable(started.runId, call.Id, call.ExpectedRunRevision__c, call.OperationKey__c, call.LeaseToken__c).execute(null);
        AgentCommand__c next = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, next.Id, next.ExpectedRunRevision__c, next.OperationKey__c, next.LeaseToken__c).execute(null);
        String replayed;
        for (AgentKernelModels.TranscriptEntry entry : KernelTestModelProvider.lastTranscript) {
            if (entry.type == AgentKernelModels.TRANSCRIPT_TOOL_CALL) {
                replayed = entry.content;
            }
        }
        System.assertEquals('{"_rationale":"Needed to notify the partner.","value":"test"}', replayed, 'History matches the schema the model was asked for.');
    }

    @IsTest
    static void toolRationaleIsOptionalBoundedAndReserved() {
        System.assertEquals(null, ModelCommandQueueable.withoutRationale('{"value":"test"}').rationale, 'A missing rationale is not an error.');
        System.assertEquals('{"value":"test"}', ModelCommandQueueable.withoutRationale('{"value":"test"}').input);
        ModelCommandQueueable.ToolArguments notText = ModelCommandQueueable.withoutRationale('{"_rationale":42,"value":"test"}');
        System.assertEquals(null, notText.rationale);
        System.assertEquals('{"value":"test"}', notText.input, 'A non-text rationale is still removed.');
        System.assertEquals('not json', ModelCommandQueueable.withoutRationale('not json').input, 'Malformed input is left for schema validation to reflect.');
        String longRationale = ''.leftPad(AgentKernelModels.MAX_TOOL_RATIONALE_CHARACTERS + 50, 'x');
        System.assertEquals(
            AgentKernelModels.MAX_TOOL_RATIONALE_CHARACTERS,
            ModelCommandQueueable.withoutRationale('{"_rationale":"' + longRationale + '"}').rationale.length()
        );

        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c reserved = new AgentTool__c(
            Name = 'Reserved',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'reserved_tool',
            Description__c = 'Declares the reserved property.',
            ToolType__c = AgentToolTypeTestFixtures.IN_ORG,
            InputSchema__c = '{"type":"object","properties":{"_rationale":{"type":"string"}},"required":["_rationale"],"additionalProperties":false}',
            IsActive__c = true
        );
        Database.SaveResult saved = Database.insert(reserved, false);
        System.assert(!saved.isSuccess(), 'A tool may not declare the property Core adds.');
        System.assert(saved.getErrors()[0].getMessage().contains('_rationale'), saved.getErrors()[0].getMessage());
    }

    @IsTest
    static void onlyTheApprovalsReviewersReadTheToolRationale() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = started.commandId, Rationale__c = 'The customer reports a team-wide outage.'));
        Id approverId = AgentKernelTestFactory.approverUser();
        AgentApproval__c approval = AgentApprovalService.open(
            AgentKernelTestFactory.getRun(started.runId),
            AgentKernelTestFactory.getCommand(started.commandId),
            AgentKernelTestFactory.approvalRequest(approverId)
        );
        User outsider = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelHumanDecision' });
        Test.startTest();
        System.runAs(new User(Id = approverId)) {
            System.assertEquals('The customer reports a team-wide outage.', AgentApprovalActions.reviewRequest(approval.Id).rationale);
        }
        System.runAs(outsider) {
            try {
                AgentApprovalActions.reviewRequest(approval.Id);
                System.assert(false, 'A Human Decision user who is not assigned cannot read the rationale.');
            } catch (AuraHandledException expected) {
                System.assert(true);
            }
        }
        Test.stopTest();
    }

    @IsTest
    static void conversationalAgentWaitsForTheReplyAndRemembersItsAnswer() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ReplyWindowHours__c = 24;
        AgentKernelTestFactory.updateRecord(definition);
        AgentConfigService.clearCacheForTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c, 'A conversational answer waits for the reply.');
        System.assertEquals(AgentKernelModels.CONTINUATION_CONVERSATION, run.ContinuationMode__c);
        System.assertEquals(KernelTestModelProvider.finalOutput, run.Output__c);
        System.assert(run.WaitExpiresAt__c > System.now().addHours(23));

        AgentKernel.resume(run.Id, run.Revision__c, '{"message":"And what should happen next?"}');
        model = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        List<AgentKernelModels.TranscriptEntry> transcript = KernelTestModelProvider.lastTranscript;
        System.assertEquals(3, transcript.size(), 'Original input, the earlier answer, then the reply.');
        System.assertEquals(AgentKernelModels.TRANSCRIPT_ORIGINAL_INPUT, transcript[0].type);
        System.assertEquals(AgentKernelModels.TRANSCRIPT_ASSISTANT_OUTPUT, transcript[1].type);
        System.assertEquals(KernelTestModelProvider.finalOutput, transcript[1].content);
        System.assertEquals(AgentKernelModels.TRANSCRIPT_USER_INPUT, transcript[2].type);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = run.Id, WaitExpiresAt__c = System.now().addMinutes(-1)));
        AgentKernelRecovery.expireIntentionalWaits(new Map<Id, Decimal>{ run.Id => run.Revision__c }, System.now());

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, 'An unanswered conversation ends with its last answer.');
        System.assertEquals(null, run.ErrorCode__c);
        System.assertNotEquals(null, run.CompletedAt__c);
    }

    @IsTest
    static void eachReplyOfAConversationGetsAFreshBudget() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(1, 10);
        definition.ReplyWindowHours__c = 24;
        AgentKernelTestFactory.updateRecord(definition);
        AgentConfigService.clearCacheForTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);

        Id resumed = AgentKernel.resume(run.Id, run.Revision__c, '{"message":"One more question."}');

        System.assertNotEquals(null, resumed, 'The reply opens a new budget window, so its model call is dispatched.');
        AgentRun__c window = [
            SELECT Status__c, ModelCallCount__c, ReplyModelCallBase__c, ReplyToolCallBase__c, ReplyTokenBase__c
            FROM AgentRun__c
            WHERE Id = :run.Id
            WITH SYSTEM_MODE
        ];
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, window.Status__c);
        System.assertEquals(1, window.ReplyModelCallBase__c, 'The window starts after the first answer.');
        System.assertEquals(0, window.ReplyToolCallBase__c);
        System.assertEquals(0, window.ReplyTokenBase__c);

        model = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c, 'The second answer fits its own one-call window.');
        System.assertEquals(2, run.ModelCallCount__c, 'The run total still counts every call.');
    }

    @IsTest
    static void cancelledBatchCallsReachTheModelAsNotRun() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'second_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.CommandOutcome modelOutcome = AgentKernelModels.continueWith(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            null,
            null
        );
        modelOutcome.nextCommands = new List<AgentKernelModels.CommandSpec>{
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{"step":1}', 'first_tool'),
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{"step":2}', 'second_tool')
        };
        AgentKernelTestFactory.applyOutcome(modelOutcome);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c first = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueAfterToolFailure(
                run.Id,
                first.Id,
                run.Revision__c,
                first.OperationKey__c,
                'TOOL_ERROR',
                'The first call failed.',
                new AgentKernelModels.CommandSpec(
                    AgentKernelModels.COMMAND_TYPE_MODEL,
                    AgentKernelModels.toolFailurePayload('TOOL_ERROR', 'The first call failed.'),
                    null
                )
            )
        );

        run = AgentKernelTestFactory.getRun(run.Id);
        AgentCommand__c model = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        List<AgentKernelModels.TranscriptEntry> transcript = KernelTestModelProvider.lastTranscript;
        System.assertEquals(5, transcript.size(), 'Original input, then both requested calls with their results.');
        System.assertEquals('second_tool', transcript[3].toolName);
        System.assertEquals('{"step":2}', transcript[3].content);
        System.assert(transcript[4].content.contains(ModelRequestAssembler.TOOL_NOT_RUN), 'The model must learn the cancelled call did not run.');
        AgentCommand__c second = [
            SELECT Status__c, PayloadProtected__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :run.Id AND ToolName__c = 'second_tool'
            WITH SYSTEM_MODE
        ];
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, second.Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelTestFactory.getRun(run.Id).Status__c);
        System.assertEquals(true, second.PayloadProtected__c, 'The retention mode applies once the run ends.');
    }

    @IsTest
    static void retrySchedulesThenExhaustsTheConfiguredBudget() {
        resetDoubles();
        KernelTestModelProvider.mode = 'retry';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(2, 0, 1);
        AgentExecutionPolicyService.Policy fastRetry = AgentExecutionPolicyService.resolve(definition);
        fastRetry.retryBaseDelaySeconds = 1;
        fastRetry.retryMaxDelaySeconds = 1;
        fastRetry.retryJitterPercent = 0;
        AgentKernelTestFactory.configureExecutionPolicy(fastRetry);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentCommand__c command = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(1, run.RetryCount__c);
        System.assertEquals(0, run.ModelCallCount__c, 'A retry gave no answer, so it does not spend Max Model Calls.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, command.Status__c);
        System.assertNotEquals(null, command.AvailableAt__c);

        update new AgentCommand__c(Id = command.Id, AvailableAt__c = System.now().addSeconds(-1));
        command = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('RETRY_EXHAUSTED', run.ErrorCode__c);
        System.assertEquals(2, run.RetryCount__c);
    }

    @IsTest
    static void fixedModelContentOverBudgetFailsBeforeProviderInvocation() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.Instructions__c = ''.leftPad(51000, 'x');
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        AgentRun__c failed = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, failed.Status__c);
        System.assertEquals('MODEL_REQUEST_BUDGET_EXCEEDED', failed.ErrorCode__c);
        System.assertEquals(0, KernelTestModelProvider.invocationCount);
    }

    @IsTest
    static void latestToolResultsAreSentBeforeOptionalContext() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
        definition.MaxModelRequestCharacters__c = 5000;
        update definition;
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelTestFactory.createContextProvider(definition.Id, 'beta', 'KernelTestContextProviderBeta');
        KernelTestContextProviderBeta.content = 'Account history. '.repeat(180);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.CommandOutcome modelOutcome = AgentKernelModels.continueWith(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            null,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{"step":1}', 'first_tool')
        );
        AgentKernelTestFactory.applyOutcome(modelOutcome);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        String toolOutput = '{"rows":"' + ''.leftPad(2500, 'r') + '"}';
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                tool.Id,
                run.Revision__c,
                tool.OperationKey__c,
                toolOutput,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, toolOutput, null)
            )
        );

        AgentCommand__c model = leaseCurrent(run.Id);
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        System.assertEquals(1, KernelTestModelProvider.invocationCount, 'Context that does not fit is shortened instead of failing the turn.');
        List<AgentKernelModels.TranscriptEntry> transcript = KernelTestModelProvider.lastTranscript;
        System.assertEquals(toolOutput, transcript[transcript.size() - 1].content, 'The complete tool result is sent.');
        Map<String, Object> request = (Map<String, Object>) JSON.deserializeUntyped(KernelTestModelProvider.lastRequestJson);
        Map<String, Object> context = (Map<String, Object>) ((List<Object>) request.get('contexts'))[0];
        System.assertEquals(true, context.get('truncated'));
        Integer sentCharacters = ((String) context.get('content')).length();
        System.assert(sentCharacters > 0 && sentCharacters < KernelTestContextProviderBeta.content.length());
        System.assert(KernelTestModelProvider.lastCharacterCount <= 5000);
        Boolean reported = false;
        for (AgentEvent__c eventRecord : [SELECT Payload__c FROM AgentEvent__c WHERE AgentRun__c = :run.Id WITH SYSTEM_MODE]) {
            reported = reported || (eventRecord.Payload__c != null && eventRecord.Payload__c.contains('"includedCharacters":' + sentCharacters));
        }
        System.assert(reported, 'Context telemetry reports what was finally sent.');
    }

    @IsTest
    static void serviceUserSeesToolResultsOnRunsItCannotShare() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5);
        User principal = new User(
            Alias = 'svcmin',
            Email = 'agent-service-user@example.com',
            Username = 'agent-service-user-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'Service User',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert principal;
        }
        AgentKernelTestFactory.grant(principal.Id, new List<String>{ AgentKernelTestFactory.SERVICE_PRINCIPAL });
        AgentKernelTestFactory.useDelegatedPrincipal(definition, principal.Id);
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{"step":1}', 'first_tool')
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        String toolOutput = '{"rows":"found"}';
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                tool.Id,
                run.Revision__c,
                tool.OperationKey__c,
                toolOutput,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, toolOutput, null)
            )
        );

        run = AgentKernelTestFactory.getRun(run.Id);
        AgentCommand__c model = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        User serviceUser = AgentKernelTestFactory.worker(run.Id);
        System.runAs(serviceUser) {
            CommandLeaseService.tryLease(run.Id, model.Id, run.Revision__c, model.OperationKey__c, model.DispatchToken__c);
        }
        model = AgentKernelTestFactory.getCommand(model.Id);
        System.runAs(serviceUser) {
            new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        }

        List<AgentKernelModels.TranscriptEntry> transcript = KernelTestModelProvider.lastTranscript;
        System.assertEquals(AgentKernelModels.TRANSCRIPT_TOOL_RESULT, transcript[transcript.size() - 1].type, 'The tool result is replayed.');
        System.assertEquals(toolOutput, transcript[transcript.size() - 1].content);
    }

    @IsTest
    static void contextCutsNeverSplitAProtectedValueToken() {
        String content = 'Reach jane at {{EMAIL_1_9f2c61ab}} today.';
        Integer tokenStart = content.indexOf('{{');
        System.assertEquals(tokenStart, ModelRequestAssembler.tokenSafeLength(content, tokenStart + 5));
        System.assertEquals(tokenStart, ModelRequestAssembler.tokenSafeLength(content, tokenStart + 1));
        Integer afterToken = content.indexOf('}}') + 2;
        System.assertEquals(afterToken, ModelRequestAssembler.tokenSafeLength(content, afterToken));
        System.assertEquals(8, ModelRequestAssembler.tokenSafeLength(content, 8));
    }

    @IsTest
    static void maximumModelRequestPayloadStaysWithinCpuAndHeapSafetyMargins() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.Instructions__c = ''.leftPad(49000, 'x');
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        Test.startTest();
        Integer cpuBefore = Limits.getCpuTime();
        Integer heapBefore = Limits.getHeapSize();
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        Integer cpuUsed = Limits.getCpuTime() - cpuBefore;
        Integer heapUsed = Limits.getHeapSize() - heapBefore;

        AgentRun__c completedRun = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(
            1,
            KernelTestModelProvider.invocationCount,
            'Run status=' + completedRun.Status__c + ', errorCode=' + completedRun.ErrorCode__c + ', errorMessage=' + completedRun.ErrorMessage__c
        );
        System.assert(KernelTestModelProvider.lastCharacterCount <= AgentConfigService.DEFAULT_MODEL_REQUEST_CHARACTERS);
        System.assert(cpuUsed < 8000, 'Maximum model request processing must retain synchronous CPU headroom.');
        System.assert(heapUsed < 5000000, 'Maximum model request processing must retain synchronous heap headroom.');
        Test.stopTest();
    }

    @IsTest
    static void maximumToolInputPayloadStaysWithinCpuAndHeapSafetyMargins() {
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolInput = '{"value":"' + ''.leftPad(95000, 'x') + '"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = leaseCurrent(run.Id);
        Test.startTest();
        Integer cpuBefore = Limits.getCpuTime();
        Integer heapBefore = Limits.getHeapSize();
        new ToolCommandQueueable(run.Id, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);
        Integer cpuUsed = Limits.getCpuTime() - cpuBefore;
        Integer heapUsed = Limits.getHeapSize() - heapBefore;

        AgentRun__c completedRun = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(
            1,
            KernelTestTool.invocationCount,
            'Run status=' + completedRun.Status__c + ', errorCode=' + completedRun.ErrorCode__c + ', errorMessage=' + completedRun.ErrorMessage__c
        );
        System.assertEquals(KernelTestModelProvider.toolInput, KernelTestTool.lastRequest.input);
        System.assertEquals(UserInfo.getUserId(), KernelTestTool.lastRequest.principal.initiatingUserId);
        System.assertEquals(null, KernelTestTool.lastRequest.principal.executionIdentityId);
        System.assert(cpuUsed < 8000, 'Maximum tool input processing must retain synchronous CPU headroom.');
        System.assert(heapUsed < 5000000, 'Maximum tool input processing must retain synchronous heap headroom.');
        Test.stopTest();
    }

    @IsTest
    static void oversizedLatestToolResultPausesInsteadOfCallingTheModelBlind() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolCallId = 'bounded-call';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = leaseCurrent(run.Id);
        new ToolCommandQueueable(run.Id, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);
        tool = AgentKernelTestFactory.getCommand(tool.Id);
        tool.Output__c = ''.leftPad(50500, 'x');
        AgentKernelTestFactory.updateRecord(tool);
        run = AgentKernelTestFactory.getRun(run.Id);
        model = leaseCurrent(run.Id);

        Integer queriesBefore = Limits.getQueries();
        new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        System.assert(Limits.getQueries() - queriesBefore <= 20, 'Transcript loading must not issue one hydration query per historical command.');
        System.assertEquals(1, KernelTestModelProvider.invocationCount, 'The model must not run without the tool result it asked for.');
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('MODEL_REQUEST_BUDGET_EXCEEDED', run.ErrorCode__c);
    }

    @IsTest
    static void contextProviderDmlBecomesDeterministicKernelPause() {
        resetDoubles();
        KernelTestContextProviderFailing.performDml = true;
        Integer accountsBefore = [SELECT COUNT() FROM Account WHERE Name = 'Context providers must remain query-only'];
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createContextProvider(definition.Id, 'failing', 'KernelTestContextProviderFailing');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('CONTEXT_PROVIDER_INVALID', run.ErrorCode__c);
        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account WHERE Name = 'Context providers must remain query-only']);
        KernelTestContextProviderFailing.performDml = false;
    }

    @IsTest
    static void aToolWhoseSchemaCannotBeBuiltPausesTheRun() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        insertAuthoringTool(definition.Id, '{"inputs":["orderId"]}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);
        KernelTestAuthoringTool.problemOnNextRun = 'Field Region__c on Case does not exist.';
        // Starting the run built the schema in this test's one transaction; the model's job is a later one.
        ToolSchemaService.forgetResolved();

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('TOOL_SCHEMA_UNAVAILABLE', run.ErrorCode__c);
        System.assert(run.ErrorMessage__c.contains('test_tool') && run.ErrorMessage__c.contains('Region__c'), run.ErrorMessage__c);
        System.assertEquals(0, KernelTestModelProvider.invocationCount, 'The model is not called with a tool it cannot use.');
        KernelTestAuthoringTool.problemOnNextRun = null;
    }

    @IsTest
    static void aValueRemovedSinceTheModelsTurnIsRefusedBeforeTheToolRuns() {
        InPlaceToolRunner.headroomChecksForTest = 0;
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestAuthoringTool.offeredValues = new List<String>{ 'test', 'other' };
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        insertAuthoringTool(definition.Id, '{"inputs":["value"]}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        // The picklist value is deactivated before the tool's own job starts.
        KernelTestAuthoringTool.offeredValues = new List<String>{ 'other' };
        ToolSchemaService.forgetResolved();
        AgentCommand__c tool = leaseCurrent(started.runId);
        new ToolCommandQueueable(started.runId, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);

        System.assertEquals(0, KernelTestTool.invocationCount, 'A call that no longer matches never runs.');
        AgentCommand__c finished = [SELECT Status__c, ErrorCode__c FROM AgentCommand__c WHERE Id = :tool.Id];
        System.assertEquals('TOOL_INPUT_SCHEMA_INVALID', finished.ErrorCode__c);
        System.assertNotEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(started.runId).Status__c, 'The model is told why.');
    }

    @IsTest
    static void aToolWhoseSchemaBreaksBeforeItRunsPausesWithoutRunning() {
        InPlaceToolRunner.headroomChecksForTest = 0;
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        insertAuthoringTool(definition.Id, '{"inputs":["value"]}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        KernelTestAuthoringTool.problemOnNextRun = 'Field Region__c on Case does not exist.';
        ToolSchemaService.forgetResolved();
        AgentCommand__c tool = leaseCurrent(started.runId);
        new ToolCommandQueueable(started.runId, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('TOOL_SCHEMA_UNAVAILABLE', run.ErrorCode__c);
        System.assertEquals(0, KernelTestTool.invocationCount, 'The tool did not run, so a retry is safe.');
    }

    private static void insertAuthoringTool(Id definitionId, String configuration) {
        insert new AgentTool__c(
            Name = 'Order Lookup',
            AgentDefinition__c = definitionId,
            DeveloperName__c = 'test_tool',
            Description__c = 'Looks up an order.',
            ToolType__c = AgentToolTypeTestFixtures.AUTHORING,
            ImplementationConfiguration__c = configuration,
            IsActive__c = true,
            SortOrder__c = 1
        );
    }

    private static AgentCommand__c leaseCurrent(Id runId) {
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

    private static void resetDoubles() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestModelProvider.finalOutput = '{"result":"test model output"}';
        KernelTestModelProvider.toolCallId = null;
        KernelTestModelProvider.toolInput = '{"value":"test"}';
        KernelTestModelProvider.lastTranscript = null;
        KernelTestModelProvider.lastTranscriptTruncated = null;
        KernelTestModelProvider.lastCharacterBudget = null;
        KernelTestModelProvider.lastCharacterCount = null;
        KernelTestModelProvider.lastRequestJson = null;
        KernelTestTool.invocationCount = 0;
        KernelTestTool.awaitInput = false;
        KernelTestTool.throwUnexpected = false;
        KernelTestContextProviderFailing.performDml = false;
        KernelTestAuthoringTool.problemOnNextRun = null;
        KernelTestAuthoringTool.offeredValues = null;
    }
}
