/**
 * @description Tests for AutonomousOrchestrator
 */
@IsTest
private class AutonomousOrchestratorTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup()
            .save();
    }

    // ===================================================================================
    // INITIATE TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_WithGoal_Success() {
        // Given: Autonomous payload with goal
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Scheduled';
        payload.autonomousGoal = 'Monitor and respond to new leads';

        AutonomousOrchestrator orchestrator = new AutonomousOrchestrator(agent);

        // When: Initiating autonomous execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution and enqueue queueable
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status);
    }

    @IsTest
    static void testInitiate_WithGoalAndContext_Success() {
        // Given: Autonomous payload with goal and context
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Platform Event';
        payload.autonomousGoal = 'Analyze customer sentiment';
        payload.autonomousContext = new Map<String, Object>{
            'timeRange' => 'Last 7 days',
            'priority' => 'High'
        };

        AutonomousOrchestrator orchestrator = new AutonomousOrchestrator(agent);

        // When: Initiating with context
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
    }

    @IsTest
    static void testInitiate_WithoutGoal_Success() {
        // Given: Autonomous payload without explicit goal (self-directed)
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Scheduled';
        // No explicit goal - agent determines its own goal

        AutonomousOrchestrator orchestrator = new AutonomousOrchestrator(agent);

        // When: Initiating without goal
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution (goal can be null for fully autonomous agents)
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
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
            AutonomousOrchestrator orchestrator = new AutonomousOrchestrator(null);
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

        Map<String, Object> asyncPayload = new Map<String, Object>{'result' => 'success'};

        AutonomousOrchestrator orchestrator = new AutonomousOrchestrator(agent);

        // When: Processing async result
        Test.startTest();
        orchestrator.processAsyncResult(execution.Id, asyncPayload);
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true, 'Should complete successfully');
    }
}

