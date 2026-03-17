/**
 * @description Focused tests for ChatConversationalRuntimeService using shared TestFactory helpers
 */
@IsTest
private class ChatConversationalRuntimeServiceTest {
    private static TestFactory.AgentSetup createConversationalAgentCapabilitySetup(String agentNamePrefix) {
        LLMConfiguration__c sharedLlm = TestFactory.newLLMConfiguration().withName(agentNamePrefix + ' LLM').save();
        AIAgentDefinition__c childAgent = TestFactory.newAgentDefinition().withName(agentNamePrefix + '_Child').withType('Direct').withLLM(sharedLlm.Id).save();

        AgentCapability__c agentCap = TestFactory.newCapability().forChildAgent(childAgent.DeveloperName__c).build();
        return TestFactory.createFullAgentSetup().withLlm(sharedLlm).withCapability(agentCap).save();
    }

    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).withAsyncDispatchType('Low').save();

        TestFactory.newExecution().withAgent(agent.Id).withUser(UserInfo.getUserId()).save();
    }

    @IsTest
    static void testStart_NewExecutionLowDispatch_CreatesPendingExecution() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, AsyncDispatchType__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('Hello there')
            .withTurn('turn-new-001')
            .withTriggerSource('UI')
            .build();

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);

        System.assertNotEquals(null, result.executionId, 'Should create execution');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Result should be Processing');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        System.assertEquals('Pending', execution.ExecutionStatus__c, 'New execution starts as Pending');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing status should be Idle on create');
        System.assertEquals(
            'turn-new-001',
            execution.CurrentTurnIdentifier__c,
            'New execution should pre-stamp payload turn so async updateStatus(Processing) passes the stale check'
        );
    }

    @IsTest
    static void testStart_ExistingExecutionSync_CompletesAndCreatesSteps() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];
        execution.CurrentTurnIdentifier__c = 'turn-sync-001';
        update execution;

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('Please summarize')
            .withTurn('turn-sync-001')
            .withExistingExecution(execution.Id)
            .withTriggerSource('UI')
            .build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Summary complete.'));

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);
        Test.stopTest();

        System.assertEquals(execution.Id, result.executionId, 'Should reuse existing execution');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, result.status, 'Synchronous path should finish as Idle');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updatedExecution.ExecutionStatus__c, 'Execution should complete');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updatedExecution.ProcessingStatus__c, 'Processing should be Idle');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];
        Boolean hasUserInput = false;
        Boolean hasAgentResponse = false;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'UserInput') {
                hasUserInput = true;
            } else if (step.StepType__c == 'AgentResponse') {
                hasAgentResponse = true;
            }
        }
        System.assert(hasUserInput, 'Should record user input');
        System.assert(hasAgentResponse, 'Should record agent response');
    }

    /**
     * Verifies that when the sync path processes a turn whose identifier differs from the
     * execution's CurrentTurnIdentifier__c (the previous turn's id), syncFinalizeExecution
     * correctly stamps the new turn and sets status to Completed.
     * This is the primary regression test for the sync-path stale-check fix.
     */
    @IsTest
    static void testStart_ExistingExecutionSync_StaleTurnFinalizesStatus() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];

        // Simulate the execution having a PREVIOUS turn's identifier (not the one we are about to use)
        update new AgentExecution__c(
            Id = execution.Id,
            CurrentTurnIdentifier__c = 'turn-previous-stale',
            ExecutionStatus__c = 'Completed',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('New message after previous turn')
            .withTurn('turn-new-after-stale')
            .withExistingExecution(execution.Id)
            .withTriggerSource('UI')
            .build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Got it.'));

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);
        Test.stopTest();

        System.assertEquals(AIAgentConstants.STATUS_IDLE, result.status, 'Sync path should finish as Idle');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'syncFinalizeExecution should recover and set Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing status should be Idle after recovery');
        System.assertEquals('turn-new-after-stale', updated.CurrentTurnIdentifier__c, 'syncFinalizeExecution should stamp the new turn identifier');
    }

    @IsTest
    static void testStart_MissingUserMessage_ThrowsOrchestrationException() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withTurn('turn-missing-msg-001')
            .withTriggerSource('UI')
            .build();

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        Boolean threw = false;
        try {
            orchestrator.start(agent.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing user message should throw OrchestrationException');
    }

    @IsTest
    static void testStart_MissingTurnIdentifier_ThrowsOrchestrationException() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('Hello')
            .withTriggerSource('UI')
            .build();

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        Boolean threw = false;
        try {
            orchestrator.start(agent.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing turn identifier should throw OrchestrationException');
    }

    @IsTest
    static void testStart_ExistingExecutionAsyncDispatch_UpdatesStatus() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, AsyncDispatchType__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];
        execution.LastActivityTime__c = Datetime.now();
        execution.CurrentTurnIdentifier__c = 'turn-async-002';
        update execution;

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('Async path')
            .withTurn('turn-async-002')
            .withExistingExecution(execution.Id)
            .withTriggerSource('UI')
            .build();

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);

        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Async dispatch should return Processing status');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Processing', updatedExecution.ExecutionStatus__c, 'Execution should be Processing');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, updatedExecution.ProcessingStatus__c, 'Processing status should be Processing');
    }

    @IsTest
    static void testResume_RetryFailedHttpTool_AvoidsDmlBeforeCallout() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Resume HTTP LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
            .withName('Resume_HTTP_Conversational_Agent')
            .withLLM(llm.Id)
            .withAsyncDispatchType('Low')
            .save();

        AgentCapability__c capability = TestFactory.newCapability().withAgent(agent.Id).withName('resume_http_tool').build();
        capability.ImplementationType__c = 'Standard';
        capability.StandardActionType__c = 'HttpCallout';
        capability.BackendConfiguration__c = '{"namedCredential":"ResumeHttpNc","endpoint":"/retry","method":"GET"}';
        capability.Parameters__c = '{"type":"object","properties":{}}';
        insert capability;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_FAILED)
            .withTurnIdentifier('turn-resume-http-old')
            .save();

        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolCall',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                ToolCallId__c = 'call-resume-http-001',
                ToolArguments__c = '{}',
                TurnCount__c = 1
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                ToolCallId__c = 'call-resume-http-001',
                ToolResult__c = '{"isSuccess":false}',
                IsError__c = true,
                TurnCount__c = 1
            )
        };

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.serverError());

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);

        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, new ExecutionResumeModels.ResumeOptions().withRetryFailedTool(true));
        Test.stopTest();

        System.assertEquals(execution.Id, result.executionId, 'Resume should target the existing execution');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Failed HTTP retry should fail the execution instead of throwing a callout exception');
        System.assertNotEquals('turn-resume-http-old', updated.CurrentTurnIdentifier__c, 'Resume should stamp a new turn after the tool call completes');
        System.assert(String.isNotBlank(updated.ErrorMessage__c), 'Failure details should be persisted after the retry');
    }

    @IsTest
    static void testEvaluateToolOutcome_ApprovalRequired_CompletesTurn() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];
        execution.CurrentTurnIdentifier__c = 'turn-approval-001';
        update execution;

        ToolCallResponseHandler.ToolExecutionResult result = new ToolCallResponseHandler.ToolExecutionResult(
            'call-approval-001',
            'approve_action',
            ActionOutcome.success(),
            10L,
            false,
            1,
            null
        );

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withExecution(execution.Id)
            .withAgent(agent.Id)
            .withTurn('turn-approval-001', 1)
            .withLlmResult(TestFactory.createLlmToolCallResult('Approval requested', new List<Map<String, String>>()))
            .build();

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);
        String outcome = orchestrator.evaluateToolOutcome(context, new List<ToolCallResponseHandler.ToolExecutionResult>{ result }, 'APPROVAL_REQUIRED');

        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome, 'Approval-required outcome should complete the turn');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'Execution should be completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing should be idle after completion');

        ExecutionStep__c responseStep = [
            SELECT StepType__c, Content__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c = 'AgentResponse'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        System.assert(responseStep.Content__c.contains('approval'), 'Agent response should explain approval flow');
    }

    @IsTest
    static void testResume_RetryFailedTool_RequeuesFollowUp() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        Case testCase = TestFactory.newCase().withSubject('Retry Case').save();
        AgentCapability__c capability = TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Account').async().save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_FAILED)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-failed-001')
            .save();

        ExecutionStep__c toolCall = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolCall',
            StepRole__c = 'Assistant',
            ToolCallId__c = 'call-failed-001',
            ToolName__c = capability.CapabilityName__c,
            ToolArguments__c = '{"recordData":{"Name":"Retry Account"}}',
            TurnIdentifier__c = 'turn-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-2)
        );
        insert toolCall;

        ExecutionStep__c toolResult = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolCallId__c = 'call-failed-001',
            ToolName__c = capability.CapabilityName__c,
            ToolResult__c = '{"isSuccess":false}',
            IsError__c = true,
            TurnIdentifier__c = 'turn-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-1)
        );
        insert toolResult;

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);
        ExecutionResumeModels.ResumeOptions options = new ExecutionResumeModels.ResumeOptions().withRetryFailedTool(true).withReason('Retry failed tool');

        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, options);

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Resume should return processing status');
        System.assertEquals('Processing', updated.ExecutionStatus__c, 'Execution should be processing after resume');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_ACTION, updated.ProcessingStatus__c, 'Async retry should move to awaiting action');

        AgentExecution__c asyncTracking = [
            SELECT PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
            LIMIT 1
        ];
        System.assertEquals(1, Integer.valueOf(asyncTracking.PendingAsyncToolCount__c), 'Async retry should track pending tool count');
        System.assertEquals(updated.CurrentTurnIdentifier__c, asyncTracking.AsyncToolTurnIdentifier__c, 'Async retry should track the new turn identifier');
    }

    @IsTest
    static void testResume_RetryFailedTool_UsesSynchronousExecution() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        Account sourceAccount = TestFactory.newAccount().withName('Sync Retry Source').save();
        AgentCapability__c capability = TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Account').save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_FAILED)
            .withSourceRecord(sourceAccount.Id)
            .withTurnIdentifier('turn-sync-failed-001')
            .save();

        ExecutionStep__c toolCall = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolCall',
            StepRole__c = 'Assistant',
            ToolCallId__c = 'call-sync-failed-001',
            ToolName__c = capability.CapabilityName__c,
            ToolArguments__c = '{}',
            TurnIdentifier__c = 'turn-sync-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-2)
        );
        insert toolCall;

        ExecutionStep__c toolResult = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolCallId__c = 'call-sync-failed-001',
            ToolName__c = capability.CapabilityName__c,
            ToolResult__c = '{"isSuccess":false}',
            IsError__c = true,
            TurnIdentifier__c = 'turn-sync-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-1)
        );
        insert toolResult;

        ChatConversationalRuntimeService orchestrator = new ChatConversationalRuntimeService(agent);
        ExecutionResumeModels.ResumeOptions options = new ExecutionResumeModels.ResumeOptions().withRetryFailedTool(true).withReason('Retry failed sync tool');

        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, options);

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Resume should return processing status');

        List<ExecutionStep__c> retrySteps = [
            SELECT StepType__c, ToolCallId__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND ToolCallId__c LIKE 'retry_%'
        ];
        System.assertEquals(2, retrySteps.size(), 'Sync retry should create ToolCall and ToolResult steps');

        AgentExecution__c refreshed = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', refreshed.ExecutionStatus__c, 'Failed sync retry should mark execution failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, refreshed.ProcessingStatus__c, 'Failed sync retry should set failed status');
    }

    /**
     * C-8: Verifies that validateExecutionAccess() rejects an existingExecutionId that belongs to
     * a different agent than the one the orchestrator was configured for.
     * Without this check a user who owns an Idle execution for AgentA could drive it through
     * AgentB's orchestrator by passing a mismatched existingExecutionId.
     */
    @IsTest
    static void testStart_ExistingExecutionOwnedByDifferentAgent_ThrowsAccessDenied() {
        AIAgentDefinition__c agentA = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        AIAgentDefinition__c agentB = TestFactory.newAgentDefinition().withName('CrossAgent_AgentB').withType('Conversational').withLLM(llm.Id).save();

        // Create an Idle execution owned by the current user but bound to AgentA
        AgentExecution__c executionForAgentA = TestFactory.newExecution()
            .withAgent(agentA.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-cross-001')
            .save();

        // Attempt to continue the AgentA execution through AgentB's orchestrator
        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withUserMessage('Injection attempt')
            .withTurn('turn-cross-001')
            .withExistingExecution(executionForAgentA.Id)
            .withTriggerSource('UI')
            .build();

        ChatConversationalRuntimeService orchestratorB = new ChatConversationalRuntimeService(agentB);

        Boolean threw = false;
        try {
            orchestratorB.start(agentB.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
            System.assert(
                e.getMessage().contains('does not belong to the requested agent'),
                'Exception message should indicate cross-agent mismatch: ' + e.getMessage()
            );
        }
        System.assertEquals(true, threw, 'Passing an execution from a different agent should throw OrchestrationException');
    }

    @IsTest
    static void testOnChildComplete_CreatesToolResultStep() {
        TestFactory.AgentSetup setup = createConversationalAgentCapabilitySetup('Conv_AgentCap');

        AgentCapability__c agentCap = [
            SELECT CapabilityName__c, ImplementationDetail__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND ImplementationType__c = 'Agent'
            LIMIT 1
        ];

        AIAgentDefinition__c childAgentDef = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c = :agentCap.ImplementationDetail__c
            LIMIT 1
        ];

        AgentExecution__c parentExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-onchild-conv-001')
            .save();

        String toolCallId = 'call_agent_conv_001';
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Completed')
            .withTurnIdentifier('turn-child-conv-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        childExec.TriggerPayload__c = JSON.serialize(
            new Map<String, String>{ 'toolCallId' => toolCallId, 'toolName' => agentCap.CapabilityName__c, 'parentExecutionId' => parentExec.Id }
        );
        update childExec;

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'childExecutionId' => childExec.Id,
            'completedAgent' => childAgentDef.DeveloperName__c,
            'success' => true,
            'response' => 'Conversational child completed.',
            'errorMessage' => null,
            'errorCode' => null
        };

        Test.startTest();
        ChatConversationalRuntimeService orch = new ChatConversationalRuntimeService();
        orch.configure(setup.agentDefinition);
        orch.onChildComplete(parentExec.Id, asyncPayload);
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT ToolCallId__c, ToolName__c, Content__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :parentExec.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResults.size(), 'Should create ToolResult step on conversational parent');
        System.assertEquals(toolCallId, toolResults[0].ToolCallId__c, 'Should map to original toolCallId');
        System.assertEquals(false, toolResults[0].IsError__c, 'Successful child should not be error');
    }
}
