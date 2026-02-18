/**
 * @description Focused tests for ConversationalOrchestrator using shared TestFactory helpers
 */
@IsTest
private class ConversationalOrchestratorTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).withAsyncDispatchType('Low').save();

        TestFactory.newExecution().withAgent(agent.Id).withUser(UserInfo.getUserId()).save();
    }

    @IsTest
    static void testStart_NewExecution_LowDispatch_CreatesPendingExecution() {
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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);

        System.assertNotEquals(null, result.executionId, 'Should create execution');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Result should be Processing');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        System.assertEquals('Pending', execution.ExecutionStatus__c, 'New execution starts as Pending');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing status should be Idle on create');
    }

    @IsTest
    static void testStart_ExistingExecution_Synchronous_CompletesAndCreatesSteps() {
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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

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

    @IsTest
    static void testStart_MissingUserMessage_Throws() {
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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        Boolean threw = false;
        try {
            orchestrator.start(agent.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing user message should throw OrchestrationException');
    }

    @IsTest
    static void testStart_MissingTurnIdentifier_Throws() {
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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        Boolean threw = false;
        try {
            orchestrator.start(agent.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing turn identifier should throw OrchestrationException');
    }

    @IsTest
    static void testStart_ExistingExecution_AsyncDispatch_UpdatesStatus() {
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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

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

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);
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
            IsDependencyValidationFailure__c = false,
            TurnIdentifier__c = 'turn-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-1)
        );
        insert toolResult;

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);
        BaseAgentOrchestrator.ResumeOptions options = new BaseAgentOrchestrator.ResumeOptions().withRetryFailedTool(true).withReason('Retry failed tool');

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
    static void testResume_RetryFailedTool_SynchronousExecution() {
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
            ToolArguments__c = '{"recordData":{"Name":"Retry Sync Account"}}',
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
            IsDependencyValidationFailure__c = false,
            TurnIdentifier__c = 'turn-sync-failed-001',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-1)
        );
        insert toolResult;

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);
        BaseAgentOrchestrator.ResumeOptions options = new BaseAgentOrchestrator.ResumeOptions().withRetryFailedTool(true).withReason('Retry failed sync tool');

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
    static void testStart_ExistingExecutionBelongingToWrongAgent_ThrowsAccessDenied() {
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

        ConversationalOrchestrator orchestratorB = new ConversationalOrchestrator(agentB);

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
}
