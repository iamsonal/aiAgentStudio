/**
 * @description Tests for ConversationalOrchestrator
 */
@IsTest
private class ConversationalOrchestratorTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
    }

    // ===================================================================================
    // INITIATE - NEW EXECUTION TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_NewExecutionLowDispatchType_Success() {
        // Given: Agent with low dispatch type
        AIAgentDefinition__c agent = [
            SELECT Id, LLMConfiguration__c, AsyncDispatchType__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        update new AIAgentDefinition__c(Id = agent.Id, AsyncDispatchType__c = 'Low');

        agent = [SELECT Id, LLMConfiguration__c, AsyncDispatchType__c FROM AIAgentDefinition__c WHERE Id = :agent.Id];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'UI';
        payload.userMessage = 'Hello!';
        payload.turnIdentifier = 'turn-001';

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        // When: Initiating execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution and enqueue queueable
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status);
    }

    @IsTest
    static void testInitiate_NewExecutionHighDispatchType_Success() {
        // Given: Agent with high dispatch type
        AIAgentDefinition__c agent = [
            SELECT Id, LLMConfiguration__c, AsyncDispatchType__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        update new AIAgentDefinition__c(Id = agent.Id, AsyncDispatchType__c = 'High');

        agent = [SELECT Id, LLMConfiguration__c, AsyncDispatchType__c FROM AIAgentDefinition__c WHERE Id = :agent.Id];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'UI';
        payload.userMessage = 'Hello!';
        payload.turnIdentifier = 'turn-001';

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        // When: Initiating execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution and publish event
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status);
    }

    // ===================================================================================
    // INITIATE - EXISTING EXECUTION TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_ExistingExecution_Success() {
        // Given: Existing execution
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [
            SELECT Id, LLMConfiguration__c, AsyncDispatchType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.existingExecutionId = execution.Id;
        payload.triggerSource = 'UI';
        payload.userMessage = 'Follow up message';
        payload.turnIdentifier = 'turn-002';

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        // When: Initiating with existing execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should use existing execution
        System.assertEquals(execution.Id, result.executionId);
    }

    @IsTest
    static void testInitiate_ExistingExecution_SynchronousMode_Success() {
        // Given: Existing execution and custom setting enabled for synchronous execution
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [
            SELECT Id, LLMConfiguration__c, AsyncDispatchType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        // Create custom setting to enable synchronous execution
        AIAgentSettings__c agentSettings = new AIAgentSettings__c(Name = agent.DeveloperName__c, ExecuteInitialLLMCallSynchronously__c = true);
        insert agentSettings;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.existingExecutionId = execution.Id;
        payload.triggerSource = 'UI';
        payload.userMessage = 'Follow up message for sync execution';
        payload.turnIdentifier = 'turn-003';
        payload.currentRecordId = null;

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        // Set up mock HTTP response for LLM callout
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Initiating with existing execution and synchronous mode enabled
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should use existing execution and complete synchronously
        System.assertEquals(execution.Id, result.executionId, 'Should use existing execution ID');
        System.assertNotEquals(null, result.status, 'Status should be set');

        // Verify decision steps were created (indicates synchronous execution happened)
        List<AgentDecisionStep__c> steps = [
            SELECT Id, Title__c
            FROM AgentDecisionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];
        System.assert(steps.size() > 0, 'Decision steps should be created for synchronous execution');
    }

    // ===================================================================================
    // INITIATE - VALIDATION TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_MissingUserMessage_ThrowsException() {
        // Given: Payload without user message
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'UI';
        payload.turnIdentifier = 'turn-001';
        // userMessage is missing

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);
        Boolean exceptionThrown = false;

        // When: Initiating without user message
        Test.startTest();
        try {
            orchestrator.initiate('Test_Agent', payload);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('User message is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception for missing user message');
    }

    @IsTest
    static void testInitiate_MissingTurnIdentifier_ThrowsException() {
        // Given: Payload without turn identifier
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'UI';
        payload.userMessage = 'Hello';
        // turnIdentifier is missing

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);
        Boolean exceptionThrown = false;

        // When: Initiating without turn identifier
        Test.startTest();
        try {
            orchestrator.initiate('Test_Agent', payload);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Turn identifier is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception for missing turn identifier');
    }

    // ===================================================================================
    // CONSTRUCTOR TESTS
    // ===================================================================================

    @IsTest
    static void testConstructor_NullAgent_ThrowsException() {
        Boolean exceptionThrown = false;

        // When: Creating with null agent
        Test.startTest();
        try {
            ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(null);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Agent definition is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception for null agent');
    }

    // ===================================================================================
    // PROCESS ASYNC RESULT TESTS
    // ===================================================================================

    @IsTest
    static void testProcessAsyncResult_Success() {
        // Given: Existing execution
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        Map<String, Object> asyncPayload = new Map<String, Object>{ 'result' => 'success' };

        ConversationalOrchestrator orchestrator = new ConversationalOrchestrator(agent);

        // When: Processing async result
        Test.startTest();
        orchestrator.processAsyncResult(execution.Id, asyncPayload);
        Test.stopTest();

        // Then: Should complete without error (method is for extensibility)
        System.assert(true, 'Should complete successfully');
    }
}
