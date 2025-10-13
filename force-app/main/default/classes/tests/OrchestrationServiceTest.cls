/**
 * @description Tests for OrchestrationService using TestFactory utilities and mock dependencies
 */
@IsTest
private class OrchestrationServiceTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup()
            .withStandardActions()
            .save();
    }

    // ===================================================================================
    // CONSTRUCTOR TESTS
    // ===================================================================================

    @IsTest
    static void testConstructor_DefaultConstructor_Success() {
        // When: Creating service with default constructor
        Test.startTest();
        OrchestrationService service = new OrchestrationService();
        Test.stopTest();

        // Then: Service should be created
        System.assertNotEquals(null, service);
    }

    @IsTest
    static void testConstructor_WithDependencies_Success() {
        // Given: Mock dependencies
        TurnLifecycleService turnSvc = new TurnLifecycleService();
        CapabilityExecutionRouter actionSvc = new CapabilityExecutionRouter();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
        ContextManagerService contextSvc = new ContextManagerService();

        // When: Creating service with dependencies
        Test.startTest();
        OrchestrationService service = new OrchestrationService(turnSvc, actionSvc, dispatchSvc, contextSvc);
        Test.stopTest();

        // Then: Service should be created
        System.assertNotEquals(null, service);
    }

    @IsTest
    static void testConstructor_WithNullDependencies_ThrowsException() {
        // Given: Null dependencies
        Boolean exceptionThrown = false;
        String exceptionMessage = '';

        // When: Creating service with null dependencies
        Test.startTest();
        try {
            OrchestrationService service = new OrchestrationService(null, null, null, null);
        } catch (IllegalArgumentException e) {
            exceptionThrown = true;
            exceptionMessage = e.getMessage();
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Expected IllegalArgumentException');
        System.assert(exceptionMessage.contains('required'), 'Exception message should mention required dependencies');
    }

    // ===================================================================================
    // PROCESS LLM RESULT - SUCCESS SCENARIOS (TEXT RESPONSE)
    // ===================================================================================

    @IsTest
    static void testProcessLlmResult_TextResponse_Success() {
        // Given: Valid LLM interaction result with text only
        TestFactory.AgentSetup setup = getTestSetup();
        LLMInteractionService.LLMInteractionResult llmResult = createTextResponse('Hello! How can I help you?');
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-001');

        OrchestrationService service = new OrchestrationService();

        // When: Processing LLM result
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-001',
            1,
            createUserMessage('What is my account status?'),
            null,
            logger
        );
        Test.stopTest();

        // Then: Should complete successfully
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);
    }

    @IsTest
    static void testProcessLlmResult_TextResponseWithUserMessage_Success() {
        // Given: LLM result with user message context
        TestFactory.AgentSetup setup = getTestSetup();
        LLMInteractionService.LLMInteractionResult llmResult = createTextResponse('Your account is active.');
        LLMInteractionService.MessageData userMessage = createUserMessage('Check my account');
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-002');

        OrchestrationService service = new OrchestrationService();

        // When: Processing with user message
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-002',
            1,
            userMessage,
            null,
            logger
        );
        Test.stopTest();

        // Then: Should complete successfully and create execution steps
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);

        List<ExecutionStep__c> steps = [SELECT Id, StepType__c FROM ExecutionStep__c
                                       WHERE AgentExecution__c = :setup.agentExecution.Id];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    // ===================================================================================
    // PROCESS LLM RESULT - FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testProcessLlmResult_NullResult_ReturnsFailed() {
        // Given: Null LLM result
        TestFactory.AgentSetup setup = getTestSetup();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-003');

        OrchestrationService service = new OrchestrationService();

        // When: Processing null result
        Test.startTest();
        String outcome = service.processLlmResult(
            null,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-003',
            1,
            null,
            null,
            logger
        );
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    @IsTest
    static void testProcessLlmResult_FailedLLMInteraction_ReturnsFailed() {
        // Given: Failed LLM interaction result
        TestFactory.AgentSetup setup = getTestSetup();
        LLMInteractionService.LLMInteractionResult llmResult = createFailedResponse(
            'API rate limit exceeded',
            AIAgentConstants.ERR_CODE_LLM_CALL_FAILED
        );
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-004');

        OrchestrationService service = new OrchestrationService();

        // When: Processing failed result
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-004',
            1,
            null,
            null,
            logger
        );
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    @IsTest
    static void testProcessLlmResult_EmptyContent_ReturnsFailed() {
        // Given: LLM result with empty content
        TestFactory.AgentSetup setup = getTestSetup();
        LLMInteractionService.LLMInteractionResult llmResult = createTextResponse('');
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-005');

        OrchestrationService service = new OrchestrationService();

        // When: Processing empty content
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-005',
            1,
            null,
            null,
            logger
        );
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    // ===================================================================================
    // PROCESS LLM RESULT - TOOL CALL SCENARIOS
    // ===================================================================================

    @IsTest
    static void testProcessLlmResult_ToolCallResponse_QueuesFollowup() {
        // Given: LLM result with tool call
        TestFactory.AgentSetup setup = getTestSetup();
        AgentCapability__c capability = [SELECT Id, CapabilityName__c FROM AgentCapability__c LIMIT 1];

        LLMInteractionService.LLMInteractionResult llmResult = createToolCallResponse(
            capability.CapabilityName__c,
            '{"searchQuery":"test accounts"}'
        );
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-006');

        OrchestrationService service = new OrchestrationService();

        // When: Processing tool call
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-006',
            1,
            createUserMessage('Find my accounts'),
            null,
            logger
        );
        Test.stopTest();

        // Then: Should queue follow-up
        System.assert(
            outcome == OrchestrationService.OUTCOME_QUEUED_FOLLOWUP ||
            outcome == OrchestrationService.OUTCOME_QUEUED_ACTION,
            'Should queue action or follow-up for tool call'
        );
    }

    @IsTest
    static void testProcessLlmResult_ToolCallWithAsyncCapability_QueuesAction() {
        // Given: LLM result with async tool call
        TestFactory.AgentSetup setup = getTestSetup();

        // Create an async capability with a completely unique configuration
        String uniqueCapabilityName = 'async_search_' + String.valueOf(System.currentTimeMillis()).substring(7);
        AgentCapability__c asyncCapability = new AgentCapability__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            CapabilityName__c = uniqueCapabilityName,
            Description__c = 'Async search capability for testing',
            ImplementationType__c = 'Standard',
            StandardActionType__c = 'FindEntities',
            Parameters__c = '{"type":"object","properties":{"searchQuery":{"type":"string"}}}',
            ExecutionPriority__c = 10,
            RunAsynchronously__c = true,  // This is the key difference - async execution
            RequiresApproval__c = false,
            HaltAndReportError__c = false
        );
        insert asyncCapability;

        LLMInteractionService.LLMInteractionResult llmResult = createToolCallResponse(
            uniqueCapabilityName,
            '{"searchQuery":"test"}'
        );
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-007');

        OrchestrationService service = new OrchestrationService();

        // When: Processing async tool call
        Test.startTest();
        String outcome = service.processLlmResult(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-007',
            1,
            null,
            null,
            logger
        );
        Test.stopTest();

        // Then: Should queue action
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, outcome);
    }

    // ===================================================================================
    // STATIC UTILITY METHOD TESTS - SERIALIZE ACTION OUTCOME
    // ===================================================================================

    @IsTest
    static void testSerializeActionOutcome_SuccessWithData_ReturnsJson() {
        // Given: Success outcome with data
        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'recordId' => '001xx000003DHP0',
                'name' => 'Test Account'
            }
        );

        // When: Serializing
        Test.startTest();
        String result = OrchestrationService.serializeActionOutcome(outcome, '[Test] ');
        Test.stopTest();

        // Then: Should return JSON
        System.assertNotEquals(null, result);
        System.assert(result.contains('recordId'), 'Should contain data');
    }

    @IsTest
    static void testSerializeActionOutcome_SuccessWithoutData_ReturnsSuccess() {
        // Given: Success outcome without data
        ActionOutcome outcome = ActionOutcome.success(null);

        // When: Serializing
        Test.startTest();
        String result = OrchestrationService.serializeActionOutcome(outcome, '[Test] ');
        Test.stopTest();

        // Then: Should return success JSON
        System.assertNotEquals(null, result);
        System.assert(result.contains('success'), 'Should indicate success');
    }

    @IsTest
    static void testSerializeActionOutcome_Failure_ReturnsError() {
        // Given: Failure outcome
        ActionOutcome outcome = ActionOutcome.failure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'Invalid input provided'
        );

        // When: Serializing
        Test.startTest();
        String result = OrchestrationService.serializeActionOutcome(outcome, '[Test] ');
        Test.stopTest();

        // Then: Should return error JSON
        System.assertNotEquals(null, result);
        System.assert(result.contains('false') || result.contains('error'), 'Should indicate failure');
        System.assert(result.contains(AIAgentConstants.ERR_CODE_INPUT_VALIDATION), 'Should contain error code');
    }

    @IsTest
    static void testSerializeActionOutcome_NullOutcome_ReturnsError() {
        // Given: Null outcome
        ActionOutcome outcome = null;

        // When: Serializing
        Test.startTest();
        String result = OrchestrationService.serializeActionOutcome(outcome, '[Test] ');
        Test.stopTest();

        // Then: Should return error JSON
        System.assertNotEquals(null, result);
        System.assert(result.contains('error'), 'Should contain error message');
    }

    @IsTest
    static void testSerializeActionOutcome_WithLLMFriendlyMessage_UsesLLMMessage() {
        // Given: Failure with automatically generated LLM-friendly message
        ActionOutcome outcome = ActionOutcome.failure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'Technical error'
        );

        // When: Serializing
        Test.startTest();
        String result = OrchestrationService.serializeActionOutcome(outcome, '[Test] ');
        Test.stopTest();

        // Then: Should use LLM-friendly message (auto-generated by ActionOutcome)
        System.assertNotEquals(null, result);
        System.assert(result.contains('false') || result.contains('messageForUser'), 'Should contain error information');
    }

    // ===================================================================================
    // STATIC UTILITY METHOD TESTS - EXTRACT RECORD ID
    // ===================================================================================

    @IsTest
    static void testExtractRecordIdFromOutcome_DirectRecordId_ReturnsId() {
        // Given: Outcome with direct recordId
        Account testAccount = TestFactory.newAccount().save();
        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'status' => 'SUCCESS',
                'data' => new Map<String, Object>{
                    'recordId' => testAccount.Id
                }
            }
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should extract ID
        System.assertEquals(testAccount.Id, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_RecordsList_ReturnsId() {
        // Given: Outcome with records list
        Account testAccount = TestFactory.newAccount().save();
        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'status' => 'SUCCESS',
                'data' => new Map<String, Object>{
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Id' => testAccount.Id, 'Name' => 'Test' }
                    }
                }
            }
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should extract ID
        System.assertEquals(testAccount.Id, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_RecordObject_ReturnsId() {
        // Given: Outcome with record object
        Account testAccount = TestFactory.newAccount().save();
        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'status' => 'SUCCESS',
                'data' => new Map<String, Object>{
                    'record' => new Map<String, Object>{
                        'Id' => testAccount.Id,
                        'Name' => 'Test Account'
                    }
                }
            }
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should extract ID
        System.assertEquals(testAccount.Id, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_NullOutcome_ReturnsNull() {
        // Given: Null outcome
        ActionOutcome outcome = null;

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_FailedOutcome_ReturnsNull() {
        // Given: Failed outcome
        ActionOutcome outcome = ActionOutcome.failure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'Error'
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_NoRecordId_ReturnsNull() {
        // Given: Outcome without record ID
        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'status' => 'SUCCESS',
                'data' => new Map<String, Object>{
                    'message' => 'Success but no record'
                }
            }
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, recordId);
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_MultipleRecords_ReturnsNull() {
        // Given: Outcome with multiple records
        Account acc1 = TestFactory.newAccount().save();
        Account acc2 = TestFactory.newAccount().save();

        ActionOutcome outcome = ActionOutcome.success(
            new Map<String, Object>{
                'status' => 'SUCCESS',
                'data' => new Map<String, Object>{
                    'records' => new List<Object>{
                        new Map<String, Object>{ 'Id' => acc1.Id },
                        new Map<String, Object>{ 'Id' => acc2.Id }
                    }
                }
            }
        );

        // When: Extracting record ID
        Test.startTest();
        Id recordId = OrchestrationService.extractRecordIdFromOutcome(outcome);
        Test.stopTest();

        // Then: Should return null (ambiguous case)
        System.assertEquals(null, recordId);
    }

    // ===================================================================================
    // EXCEPTION CLASS TESTS
    // ===================================================================================

    @IsTest
    static void testOrchestrationException_CanBeThrown() {
        Test.startTest();
        try {
            throw new OrchestrationService.OrchestrationException('Test orchestration exception');
        } catch (OrchestrationService.OrchestrationException e) {
            System.assertEquals('Test orchestration exception', e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testConfigurationException_CanBeThrown() {
        Test.startTest();
        try {
            throw new OrchestrationService.ConfigurationException('Test configuration exception');
        } catch (OrchestrationService.ConfigurationException e) {
            System.assertEquals('Test configuration exception', e.getMessage());
        }
        Test.stopTest();
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    private static TestFactory.AgentSetup getTestSetup() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        TestFactory.AgentSetup setup = new TestFactory.AgentSetup();
        setup.agentDefinition = agent;
        setup.agentExecution = execution;
        setup.llmConfig = llm;
        setup.capabilities = [SELECT Id, CapabilityName__c FROM AgentCapability__c];

        return setup;
    }

    private static LLMInteractionService.LLMInteractionResult createTextResponse(String content) {
        // Create provider result with no tool calls
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = content;
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.requestedActions = new List<Map<String, String>>();

        // Create message data
        LLMInteractionService.MessageData messageData = new LLMInteractionService.MessageData();
        messageData.role = 'assistant';
        messageData.content = content;
        messageData.processingTimeMs = 100;
        messageData.tokensUsed = 150;

        // Use the success constructor
        return new LLMInteractionService.LLMInteractionResult(providerResult, messageData);
    }

    private static LLMInteractionService.LLMInteractionResult createToolCallResponse(String toolName, String arguments) {
        // Create provider result with tool call
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = 'Let me help you with that.';
        providerResult.promptTokens = 150;
        providerResult.completionTokens = 75;
        providerResult.totalTokens = 225;
        providerResult.requestedActions = new List<Map<String, String>>{
            new Map<String, String>{
                'id' => 'call_' + String.valueOf(Math.random()).substring(2, 10),
                'name' => toolName,
                'arguments' => arguments
            }
        };

        // Create message data
        LLMInteractionService.MessageData messageData = new LLMInteractionService.MessageData();
        messageData.role = 'assistant';
        messageData.content = 'Let me help you with that.';
        messageData.processingTimeMs = 150;
        messageData.tokensUsed = 225;

        // Use the success constructor
        return new LLMInteractionService.LLMInteractionResult(providerResult, messageData);
    }

    private static LLMInteractionService.LLMInteractionResult createFailedResponse(String errorMessage, String errorCode) {
        // Use the failure constructor
        return new LLMInteractionService.LLMInteractionResult(errorMessage, errorCode, null);
    }

    private static LLMInteractionService.MessageData createUserMessage(String content) {
        LLMInteractionService.MessageData message = new LLMInteractionService.MessageData();
        message.role = 'user';
        message.content = content;

        return message;
    }
}

