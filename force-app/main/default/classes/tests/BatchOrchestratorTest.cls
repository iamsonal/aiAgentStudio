/**
 * @description Tests for BatchOrchestrator
 */
@IsTest
private class BatchOrchestratorTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup()
            .save();

        // Create test accounts for batch processing
        TestFactory.createAccounts(5).save();
    }

    // ===================================================================================
    // INITIATE WITH RECORD IDS TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_WithRecordIds_Success() {
        // Given: Batch payload with record IDs
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];
        List<Account> accounts = [SELECT Id FROM Account LIMIT 5];
        List<Id> recordIds = new List<Id>();
        for (Account acc : accounts) {
            recordIds.add(acc.Id);
        }

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Manual';
        payload.batchRecordIds = recordIds;

        BatchOrchestrator orchestrator = new BatchOrchestrator(agent);

        // When: Initiating batch execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution and enqueue queueable
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status);
    }

    @IsTest
    static void testInitiate_WithParameters_Success() {
        // Given: Batch with parameters
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];
        List<Account> accounts = [SELECT Id FROM Account LIMIT 3];
        List<Id> recordIds = new List<Id>();
        for (Account acc : accounts) {
            recordIds.add(acc.Id);
        }

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Scheduled';
        payload.batchRecordIds = recordIds;
        payload.batchParameters = new Map<String, Object>{'processType' => 'Standard'};

        BatchOrchestrator orchestrator = new BatchOrchestrator(agent);

        // When: Initiating with parameters
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
    }

    // ===================================================================================
    // INITIATE WITH QUERY TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_WithQuery_Success() {
        // Given: Batch payload with SOQL query
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Scheduled';
        payload.batchQuery = 'SELECT Id, Name FROM Account';

        BatchOrchestrator orchestrator = new BatchOrchestrator(agent);

        // When: Initiating with query
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
    }

    // ===================================================================================
    // VALIDATION TESTS
    // ===================================================================================

    @IsTest
    static void testInitiate_MissingRecordsAndQuery_ThrowsException() {
        // Given: Payload without records or query
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Manual';
        // Missing batchRecordIds and batchQuery

        BatchOrchestrator orchestrator = new BatchOrchestrator(agent);
        Boolean exceptionThrown = false;

        // When: Initiating without records/query
        Test.startTest();
        try {
            orchestrator.initiate('Test_Agent', payload);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Batch record IDs or SOQL query is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception');
    }

    @IsTest
    static void testConstructor_NullAgent_ThrowsException() {
        Boolean exceptionThrown = false;

        // When: Creating with null agent
        Test.startTest();
        try {
            BatchOrchestrator orchestrator = new BatchOrchestrator(null);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Agent definition is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception for null agent');
    }

    @IsTest
    static void testProcessAsyncResult_Success() {
        // Given: Existing execution
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        Map<String, Object> asyncPayload = new Map<String, Object>{'result' => 'success'};

        BatchOrchestrator orchestrator = new BatchOrchestrator(agent);

        // When: Processing async result
        Test.startTest();
        orchestrator.processAsyncResult(execution.Id, asyncPayload);
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true, 'Should complete successfully');
    }
}

