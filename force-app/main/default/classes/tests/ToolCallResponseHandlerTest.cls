/**
 * @description Tests for ToolCallResponseHandler
 */
@IsTest
private class ToolCallResponseHandlerTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withStandardActions().save();
    }

    // ===================================================================================
    // HANDLE - SYNCHRONOUS TOOL EXECUTION TESTS
    // ===================================================================================

    @IsTest
    static void testHandle_SyncToolCall_Success() {
        // Given: Context with sync tool call
        TestFactory.AgentSetup setup = getTestSetup();
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        OrchestrationContext context = createToolCallContext(setup, capability.CapabilityName__c, '{"searchQuery":"test"}');

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // When: Handling sync tool call
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should queue follow-up
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome);
    }

    @IsTest
    static void testHandle_SyncToolCallWithUserMessage_CreatesSteps() {
        // Given: Context with user message and tool call
        TestFactory.AgentSetup setup = getTestSetup();
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        OrchestrationContext context = createToolCallContextWithUser(
            setup,
            'Find my records',
            capability.CapabilityName__c,
            '{"searchQuery":"records"}'
        );

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // When: Handling
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should create execution steps
        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    // ===================================================================================
    // HANDLE - ASYNCHRONOUS TOOL EXECUTION TESTS
    // ===================================================================================

    @IsTest
    static void testHandle_AsyncToolCall_QueuesAction() {
        // Given: Context with async tool call
        TestFactory.AgentSetup setup = getTestSetup();

        // Create async capability
        String asyncCapName = 'async_tool_' + String.valueOf(System.currentTimeMillis()).substring(7);
        AgentCapability__c asyncCap = new AgentCapability__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            CapabilityName__c = asyncCapName,
            Description__c = 'Async tool for testing',
            ImplementationType__c = 'Standard',
            StandardActionType__c = 'CreateRecord',
            BackendConfiguration__c = '{"objectApiName":"Account"}',
            Parameters__c = '{"type":"object"}',
            RunAsynchronously__c = true,
            RequiresApproval__c = false
        );
        insert asyncCap;

        OrchestrationContext context = createToolCallContext(setup, asyncCapName, '{"searchQuery":"async test"}');

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // When: Handling async tool call
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should queue action
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, outcome);
    }

    // ===================================================================================
    // HANDLE - APPROVAL WORKFLOW TESTS
    // ===================================================================================

    @IsTest
    static void testHandle_ApprovalRequired_CreatesApprovalRequest() {
        // Given: Tool requiring approval
        TestFactory.AgentSetup setup = getTestSetup();

        // Create capability requiring approval
        String approvalCapName = 'approval_tool_' + String.valueOf(System.currentTimeMillis()).substring(7);
        AgentCapability__c approvalCap = new AgentCapability__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            CapabilityName__c = approvalCapName,
            Description__c = 'Tool requiring approval',
            ImplementationType__c = 'Standard',
            StandardActionType__c = 'PostChatter',
            Parameters__c = '{"type":"object","properties":{"submission_comment":{"type":"string"}}}',
            RunAsynchronously__c = false,
            RequiresApproval__c = true
        );
        insert approvalCap;

        OrchestrationContext context = createToolCallContext(
            setup,
            approvalCapName,
            '{"text":"Test message","topics":["Test"],"submission_comment":"Please approve"}'
        );

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // When: Handling tool requiring approval
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should queue follow-up and create approval request
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome);

        List<HumanApprovalRequest__c> approvals = [
            SELECT Id, ApprovalStatus__c
            FROM HumanApprovalRequest__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assertEquals(1, approvals.size(), 'Should create approval request');
        System.assertEquals('Pending', approvals[0].ApprovalStatus__c);
    }

    @IsTest
    static void testHandle_ApprovalRequiredWithoutComment_Fails() {
        // Given: Tool requiring approval without submission comment
        TestFactory.AgentSetup setup = getTestSetup();

        String approvalCapName = 'approval_tool2_' + String.valueOf(System.currentTimeMillis()).substring(7);
        AgentCapability__c approvalCap = new AgentCapability__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            CapabilityName__c = approvalCapName,
            Description__c = 'Tool requiring approval',
            ImplementationType__c = 'Standard',
            StandardActionType__c = 'PostChatter',
            Parameters__c = '{"type":"object"}',
            RunAsynchronously__c = false,
            RequiresApproval__c = true
        );
        insert approvalCap;

        OrchestrationContext context = createToolCallContext(
            setup,
            approvalCapName,
            '{"text":"Test message"}' // No submission_comment
        );

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // When: Handling without submission comment
        Test.startTest();
        String outcome = handler.handle(context);
        Test.stopTest();

        // Then: Should fail
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome);
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testToolProcessingException_CanBeThrown() {
        Test.startTest();
        try {
            throw new ToolCallResponseHandler.ToolProcessingException('Test exception');
        } catch (ToolCallResponseHandler.ToolProcessingException e) {
            System.assertEquals('Test exception', e.getMessage());
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

    private static OrchestrationContext createToolCallContext(TestFactory.AgentSetup setup, String toolName, String toolArguments) {
        // Create LLM result with tool call
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = 'Let me help with that.';
        providerResult.promptTokens = 150;
        providerResult.completionTokens = 75;
        providerResult.totalTokens = 225;
        providerResult.modelIdentifier = 'gpt-4o-mini';
        providerResult.llmCalloutDurationMs = 1000;
        providerResult.requestedActions = new List<Map<String, String>>{
            new Map<String, String>{
                'id' => 'call_' + String.valueOf(Math.random()).substring(2, 10),
                'name' => toolName,
                'arguments' => toolArguments
            }
        };

        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = 'Let me help with that.';
        assistantData.processingTimeMs = 100;
        assistantData.assistantToolCallsJson = JSON.serialize(providerResult.requestedActions);

        LLMInteractionService.LLMInteractionResult llmResult = new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create services
        TurnLifecycleService turnSvc = new TurnLifecycleService();
        CapabilityExecutionService actionSvc = new CapabilityExecutionService();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
        ContextManagerService contextSvc = new ContextManagerService();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-001');

        return new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-001',
            1,
            null,
            turnSvc,
            actionSvc,
            dispatchSvc,
            contextSvc,
            null,
            logger
        );
    }

    private static OrchestrationContext createToolCallContextWithUser(
        TestFactory.AgentSetup setup,
        String userMessage,
        String toolName,
        String toolArguments
    ) {
        // Create LLM result with tool call
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = 'I can help find those records.';
        providerResult.promptTokens = 150;
        providerResult.completionTokens = 75;
        providerResult.totalTokens = 225;
        providerResult.modelIdentifier = 'gpt-4o-mini';
        providerResult.llmCalloutDurationMs = 1000;
        providerResult.requestedActions = new List<Map<String, String>>{
            new Map<String, String>{
                'id' => 'call_' + String.valueOf(Math.random()).substring(2, 10),
                'name' => toolName,
                'arguments' => toolArguments
            }
        };

        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = 'I can help find those records.';
        assistantData.processingTimeMs = 100;
        assistantData.assistantToolCallsJson = JSON.serialize(providerResult.requestedActions);

        LLMInteractionService.LLMInteractionResult llmResult = new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create user message
        LLMInteractionService.MessageData userData = new LLMInteractionService.MessageData();
        userData.role = 'user';
        userData.content = userMessage;

        // Create services
        TurnLifecycleService turnSvc = new TurnLifecycleService();
        CapabilityExecutionService actionSvc = new CapabilityExecutionService();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
        ContextManagerService contextSvc = new ContextManagerService();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'turn-002');

        return new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-002',
            1,
            userData,
            turnSvc,
            actionSvc,
            dispatchSvc,
            contextSvc,
            null,
            logger
        );
    }
}
