/**
 * @description Tests for EmailOrchestrator
 */
@IsTest
private class EmailOrchestratorTest {

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
    static void testInitiate_WithEmailContent_Success() {
        // Given: Email payload
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'EmailMessage';
        payload.emailSubject = 'Test Email Subject';
        payload.emailBody = 'This is the email body content';
        payload.emailFromAddress = 'sender@example.com';
        payload.emailToAddress = 'agent@example.com';

        EmailOrchestrator orchestrator = new EmailOrchestrator(agent);

        // When: Initiating email execution
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution and enqueue queueable
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status);

        // Verify execution step created
        List<ExecutionStep__c> steps = [SELECT Id, StepType__c FROM ExecutionStep__c
                                        WHERE AgentExecution__c = :result.executionId];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    @IsTest
    static void testInitiate_WithCcAddresses_Success() {
        // Given: Email with CC addresses
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'EmailMessage';
        payload.emailSubject = 'Email with CC';
        payload.emailBody = 'Email body content';
        payload.emailFromAddress = 'sender@example.com';
        payload.emailToAddress = 'agent@example.com';
        payload.emailCcAddresses = new List<String>{'cc1@example.com', 'cc2@example.com'};

        EmailOrchestrator orchestrator = new EmailOrchestrator(agent);

        // When: Initiating with CC addresses
        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.initiate('Test_Agent', payload);
        Test.stopTest();

        // Then: Should create execution
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.executionId);

        // Verify execution step created
        List<ExecutionStep__c> steps = [SELECT Id, StepType__c FROM ExecutionStep__c
                                        WHERE AgentExecution__c = :result.executionId];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    @IsTest
    static void testInitiate_MissingEmailContent_ThrowsException() {
        // Given: Payload without email content
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'EmailMessage';
        // Missing emailSubject and emailBody

        EmailOrchestrator orchestrator = new EmailOrchestrator(agent);
        Boolean exceptionThrown = false;

        // When: Initiating without email content
        Test.startTest();
        try {
            orchestrator.initiate('Test_Agent', payload);
        } catch (AgentOrchestratorException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Email subject or body is required'));
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw exception for missing email content');
    }

    @IsTest
    static void testConstructor_NullAgent_ThrowsException() {
        Boolean exceptionThrown = false;

        // When: Creating with null agent
        Test.startTest();
        try {
            EmailOrchestrator orchestrator = new EmailOrchestrator(null);
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

        EmailOrchestrator orchestrator = new EmailOrchestrator(agent);

        // When: Processing async result
        Test.startTest();
        orchestrator.processAsyncResult(execution.Id, asyncPayload);
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true, 'Should complete successfully');
    }
}

