/**
 * @description Tests for ContentResponseHandler and ContentResponseHandler
 */
@IsTest
private class ContentResponseHandlerTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup with conversational agent
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create completion capability for non-conversational tests
        // Note: We set the name AFTER forPostChatter() to override the default name
        AgentCapability__c completionCap = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forPostChatter().build();

        completionCap.CapabilityName__c = 'send_email_completion';
        insert completionCap;
    }

    // ===================================================================================
    // CONTENT RESPONSE HANDLER - SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testHandle_ValidTextResponse_Success() {
        // Given: Valid orchestration context with text response
        TestFactory.AgentSetup setup = getTestSetup();
        OrchestrationContext context = createContext(setup, 'This is a helpful response.');
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling content response
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should complete successfully
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);

        // Verify execution steps were created
        List<ExecutionStep__c> steps = [
            SELECT Id, StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    @IsTest
    static void testHandle_WithUserMessage_CreatesUserInputStep() {
        // Given: Context with user message
        TestFactory.AgentSetup setup = getTestSetup();
        OrchestrationContext context = createContextWithUserMessage(setup, 'Hello!', 'How can I help you?');
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should create both user and assistant steps
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);
        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assert(steps.size() >= 2, 'Should create user and assistant steps');
    }

    @IsTest
    static void testHandle_WithMemoryStrategy_CallsMemoryManager() {
        // Given: Agent with memory strategy configured
        TestFactory.AgentSetup setup = getTestSetup();

        // Update agent to have memory strategy
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, MemoryStrategy__c = 'Buffer Window');

        OrchestrationContext context = createContext(setup, 'Response with memory');
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should complete successfully (memory manager called)
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);
    }

    // ===================================================================================
    // CONTENT RESPONSE HANDLER - FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testHandle_EmptyContent_ReturnsFailed() {
        // Given: Context with empty content
        TestFactory.AgentSetup setup = getTestSetup();
        OrchestrationContext context = createContext(setup, '');
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling empty content
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    @IsTest
    static void testHandle_NullContent_ReturnsFailed() {
        // Given: Context with null content
        TestFactory.AgentSetup setup = getTestSetup();
        OrchestrationContext context = createContext(setup, null);
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling null content
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    // ===================================================================================
    // COMPLETION CAPABILITY TESTS
    // ===================================================================================

    @IsTest
    static void testHandle_ConversationalAgent_SkipsCompletionCapability() {
        // Given: Conversational agent (default from TestFactory)
        TestFactory.AgentSetup setup = getTestSetup();

        // Verify it's conversational
        AIAgentDefinition__c agent = [
            SELECT AgentType__c
            FROM AIAgentDefinition__c
            WHERE Id = :setup.agentDefinition.Id
        ];
        System.assertEquals('Conversational', agent.AgentType__c);

        OrchestrationContext context = createContext(setup, 'Response text');
        ContentResponseHandler handler = new ContentResponseHandler();

        // When: Handling
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should complete without invoking completion capability
        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome);
    }

    // ===================================================================================
    // COMPLETION PARAMETER MAPPER TESTS
    // ===================================================================================

    @IsTest
    static void testContentResponseHandler_GetDefaultMapping_Email_ReturnsMapping() {
        // When: Getting default mapping for Email type
        Test.startTest();
        String mapping = ContentResponseHandler.getDefaultMapping('Email');
        Test.stopTest();

        // Then: Should return email mapping template
        System.assertNotEquals(null, mapping);
        System.assert(mapping.contains('toAddresses'), 'Should contain email fields');
        System.assert(mapping.contains('{{summary}}'), 'Should contain summary variable');
        System.assert(mapping.contains('{{triggerMetadata'), 'Should contain trigger metadata reference');
    }

    @IsTest
    static void testContentResponseHandler_GetDefaultMapping_UnknownType_ReturnsNull() {
        // When: Getting default mapping for unknown type
        Test.startTest();
        String mapping = ContentResponseHandler.getDefaultMapping('UnknownType');
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, mapping);
    }

    @IsTest
    static void testContentResponseHandler_GetDefaultMapping_BlankType_ReturnsNull() {
        // When: Getting default mapping for blank type
        Test.startTest();
        String mapping = ContentResponseHandler.getDefaultMapping('');
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, mapping);
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_SimpleVariables_Success() {
        // Given: Simple mapping template and context
        String template = '{"name": "{{userName}}", "message": "{{messageText}}"}';
        Map<String, Object> context = new Map<String, Object>{ 'userName' => 'John Doe', 'messageText' => 'Hello World' };

        // When: Applying mapping
        Test.startTest();
        String result = ContentResponseHandler.applyMapping(template, context);
        Test.stopTest();

        // Then: Should replace variables
        System.assertNotEquals(null, result);
        System.assert(result.contains('John Doe'), 'Should contain user name');
        System.assert(result.contains('Hello World'), 'Should contain message text');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_NestedPaths_Success() {
        // Given: Template with nested path
        String template = '{"email": "{{user.contact.email}}", "subject": "{{metadata.subject}}"}';
        Map<String, Object> context = new Map<String, Object>{
            'user' => new Map<String, Object>{ 'contact' => new Map<String, Object>{ 'email' => 'test@example.com' } },
            'metadata' => new Map<String, Object>{ 'subject' => 'Test Subject' }
        };

        // When: Applying mapping
        Test.startTest();
        String result = ContentResponseHandler.applyMapping(template, context);
        Test.stopTest();

        // Then: Should resolve nested paths
        System.assertNotEquals(null, result);
        System.assert(result.contains('test@example.com'), 'Should resolve nested email path');
        System.assert(result.contains('Test Subject'), 'Should resolve nested subject path');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_ComplexStructure_Success() {
        // Given: Complex template with arrays and objects
        String template = '{"toAddresses": ["{{email}}", "{{email2}}"], "body": "{{body}}", "metadata": {"priority": "{{priority}}"}}';
        Map<String, Object> context = new Map<String, Object>{
            'email' => 'user1@example.com',
            'email2' => 'user2@example.com',
            'body' => 'Email body content',
            'priority' => 'High'
        };

        // When: Applying mapping
        Test.startTest();
        String result = ContentResponseHandler.applyMapping(template, context);
        Test.stopTest();

        // Then: Should handle complex structure
        System.assertNotEquals(null, result);
        System.assert(result.contains('user1@example.com'), 'Should contain first email');
        System.assert(result.contains('user2@example.com'), 'Should contain second email');
        System.assert(result.contains('Email body content'), 'Should contain body');
        System.assert(result.contains('High'), 'Should contain priority');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_MissingVariable_UsesEmpty() {
        // Given: Template with missing variable
        String template = '{"name": "{{userName}}", "email": "{{userEmail}}"}';
        Map<String, Object> context = new Map<String, Object>{
            'userName' => 'John Doe'
            // userEmail is missing
        };

        // When: Applying mapping
        Test.startTest();
        String result = ContentResponseHandler.applyMapping(template, context);
        Test.stopTest();

        // Then: Should use empty string for missing variable
        System.assertNotEquals(null, result);
        System.assert(result.contains('John Doe'), 'Should contain provided variable');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_BlankTemplate_ThrowsException() {
        // Given: Blank template
        Map<String, Object> context = new Map<String, Object>{ 'key' => 'value' };
        Boolean exceptionThrown = false;

        // When: Applying blank template
        Test.startTest();
        try {
            ContentResponseHandler.applyMapping('', context);
        } catch (ContentResponseHandler.MappingException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw MappingException for blank template');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_NullContext_ThrowsException() {
        // Given: Null context
        String template = '{"name": "{{userName}}"}';
        Boolean exceptionThrown = false;

        // When: Applying with null context
        Test.startTest();
        try {
            ContentResponseHandler.applyMapping(template, null);
        } catch (ContentResponseHandler.MappingException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw MappingException for null context');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_EmptyContext_ThrowsException() {
        // Given: Empty context
        String template = '{"name": "{{userName}}"}';
        Map<String, Object> context = new Map<String, Object>();
        Boolean exceptionThrown = false;

        // When: Applying with empty context
        Test.startTest();
        try {
            ContentResponseHandler.applyMapping(template, context);
        } catch (ContentResponseHandler.MappingException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw MappingException for empty context');
    }

    @IsTest
    static void testContentResponseHandler_ApplyMapping_InvalidJson_ThrowsException() {
        // Given: Invalid JSON template
        String template = '{"invalid": json}';
        Map<String, Object> context = new Map<String, Object>{ 'key' => 'value' };
        Boolean exceptionThrown = false;

        // When: Applying invalid template
        Test.startTest();
        try {
            ContentResponseHandler.applyMapping(template, context);
        } catch (ContentResponseHandler.MappingException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw MappingException for invalid JSON');
    }

    @IsTest
    static void testContentResponseHandler_BuildCompletionContext_WithoutTriggerPayload_Success() {
        // Given: Execution without trigger payload
        TestFactory.AgentSetup setup = getTestSetup();
        AgentExecution__c execution = [
            SELECT Id, ExecutionType__c, TriggerSource__c, TriggerPayload__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];

        // When: Building context
        Test.startTest();
        Map<String, Object> context = ContentResponseHandler.buildCompletionContext('Test summary', execution);
        Test.stopTest();

        // Then: Should build context with empty metadata
        System.assertNotEquals(null, context);
        System.assertEquals('Test summary', context.get('summary'));
        System.assertNotEquals(null, context.get('triggerMetadata'), 'Should have empty metadata map');
    }

    @IsTest
    static void testContentResponseHandler_BuildCompletionContext_WithInvalidPayload_HandlesGracefully() {
        // Given: Execution with invalid JSON payload
        TestFactory.AgentSetup setup = getTestSetup();
        update new AgentExecution__c(Id = setup.agentExecution.Id, TriggerPayload__c = 'invalid json {');

        AgentExecution__c execution = [
            SELECT Id, ExecutionType__c, TriggerSource__c, TriggerPayload__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];

        // When: Building context
        Test.startTest();
        Map<String, Object> context = ContentResponseHandler.buildCompletionContext('Summary', execution);
        Test.stopTest();

        // Then: Should handle gracefully with empty metadata
        System.assertNotEquals(null, context);
        System.assertNotEquals(null, context.get('triggerMetadata'), 'Should have metadata map even if parsing failed');
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testCompletionCapabilityException_CanBeThrown() {
        Test.startTest();
        try {
            throw new ContentResponseHandler.CompletionCapabilityException('Test exception');
        } catch (ContentResponseHandler.CompletionCapabilityException e) {
            System.assertEquals('Test exception', e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void testMappingException_CanBeThrown() {
        Test.startTest();
        try {
            throw new ContentResponseHandler.MappingException('Test mapping exception');
        } catch (ContentResponseHandler.MappingException e) {
            System.assertEquals('Test mapping exception', e.getMessage());
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

        return setup;
    }

    private static OrchestrationContext createContext(TestFactory.AgentSetup setup, String assistantContent) {
        // Create LLM result
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = assistantContent;
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.requestedActions = new List<Map<String, String>>();

        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = assistantContent;
        assistantData.processingTimeMs = 100;

        LLMInteractionService.LLMInteractionResult llmResult = new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create services
        AgentStateService stateSvc = new AgentStateService();
        CapabilityExecutionService actionSvc = new CapabilityExecutionService();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
        ContextManagerService contextSvc = new ContextManagerService();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-001');

        // Create context
        return new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-001',
            1,
            null, // no user message
            stateSvc,
            actionSvc,
            dispatchSvc,
            contextSvc,
            null, // no page record
            logger
        );
    }

    private static OrchestrationContext createContextWithUserMessage(TestFactory.AgentSetup setup, String userContent, String assistantContent) {
        // Create LLM result
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = assistantContent;
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.requestedActions = new List<Map<String, String>>();

        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = assistantContent;
        assistantData.processingTimeMs = 100;

        LLMInteractionService.LLMInteractionResult llmResult = new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create user message
        LLMInteractionService.MessageData userData = new LLMInteractionService.MessageData();
        userData.role = 'user';
        userData.content = userContent;

        // Create services
        AgentStateService stateSvc = new AgentStateService();
        CapabilityExecutionService actionSvc = new CapabilityExecutionService();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
        ContextManagerService contextSvc = new ContextManagerService();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-002');

        // Create context
        return new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-002',
            1,
            userData, // with user message
            stateSvc,
            actionSvc,
            dispatchSvc,
            contextSvc,
            null, // no page record
            logger
        );
    }
}
