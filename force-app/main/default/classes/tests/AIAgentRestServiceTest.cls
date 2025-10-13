/**
 * @description Tests for AIAgentRestService using TestFactory utilities
 */
@IsTest
private class AIAgentRestServiceTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testProcessMessage_ValidRequest_Success() {
        // Given: Valid request
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));
        RestContext.response = new RestResponse();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Processing message
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should succeed
        System.assert(response.success);
        System.assertEquals('Processing', response.outcome);
        System.assertEquals(null, response.error);
        System.assertNotEquals(null, response.requestId);
    }

    @IsTest
    static void testProcessMessage_WithRecordId_Success() {
        // Given: Request with record ID
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';
        request.currentRecordId = session.Id;

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));
        RestContext.response = new RestResponse();

        // When: Processing
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should succeed
        System.assert(response.success);
    }

    // ===================================================================================
    // VALIDATION FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testProcessMessage_EmptyBody_BadRequest() {
        // Given: Empty request body
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = null;
        RestContext.response = new RestResponse();

        // When: Processing
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should fail
        System.assert(!response.success);
        System.assert(response.error.contains('Request body is required'));
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testProcessMessage_InvalidJson_BadRequest() {
        // Given: Invalid JSON
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf('invalid json {');
        RestContext.response = new RestResponse();

        // When: Processing
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should fail
        System.assert(!response.success);
        System.assert(response.error.contains('Invalid JSON format'));
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testProcessMessage_MissingSessionId_BadRequest() {
        // Given: Request missing sessionId
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn';
        request.userMessage = 'Test';

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));
        RestContext.response = new RestResponse();

        // When: Processing
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should fail
        System.assert(!response.success);
        System.assert(response.error.contains('sessionId is required'));
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testProcessMessage_InvalidIdFormats_BadRequest() {
        // Given: Invalid ID formats
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = 'invalid-id';
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = 'invalid-id';
        request.turnIdentifier = 'test-turn';
        request.userMessage = 'Test';

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));
        RestContext.response = new RestResponse();

        // When: Processing
        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Should fail
        System.assert(!response.success);
        System.assertEquals(400, RestContext.response.statusCode);
    }

    // ===================================================================================
    // DTO TESTS
    // ===================================================================================

    @IsTest
    static void testAIAgentRequest_SettersGetters_Work() {
        // Given: Request object
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();

        // When: Setting properties
        request.sessionId = 'test-session';
        request.originalUserId = 'test-user';
        request.agentDefinitionId = 'test-agent';
        request.turnIdentifier = 'test-turn';
        request.userMessage = 'test-message';
        request.currentRecordId = 'test-record';

        // Then: Getters should work
        System.assertEquals('test-session', request.sessionId);
        System.assertEquals('test-user', request.originalUserId);
        System.assertEquals('test-agent', request.agentDefinitionId);
        System.assertEquals('test-turn', request.turnIdentifier);
        System.assertEquals('test-message', request.userMessage);
        System.assertEquals('test-record', request.currentRecordId);
    }

    @IsTest
    static void testAIAgentResponse_Constructor_SetsProperties() {
        // When: Creating response
        AIAgentRestService.AIAgentResponse response = new AIAgentRestService.AIAgentResponse(
            true,
            'Success',
            null,
            'req-123'
        );

        // Then: Properties should be set
        System.assert(response.success);
        System.assertEquals('Success', response.outcome);
        System.assertEquals(null, response.error);
        System.assertEquals('req-123', response.requestId);
    }

    @IsTest
    static void testGenerateRequestId_ReturnsUniqueIds() {
        // Given: Multiple requests
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn';
        request.userMessage = 'Test';

        String requestBody = JSON.serialize(request);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Processing multiple requests
        Test.startTest();
        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(requestBody);
        RestContext.response = new RestResponse();
        AIAgentRestService.AIAgentResponse response1 = AIAgentRestService.processMessage();

        RestContext.request = new RestRequest();
        RestContext.request.requestBody = Blob.valueOf(requestBody);
        RestContext.response = new RestResponse();
        AIAgentRestService.AIAgentResponse response2 = AIAgentRestService.processMessage();
        Test.stopTest();

        // Then: Request IDs should be unique
        System.assertNotEquals(null, response1.requestId);
        System.assertNotEquals(null, response2.requestId);
        System.assertNotEquals(response1.requestId, response2.requestId);
    }

    @IsTest
    static void testAIAgentRestException_CanBeThrown() {
        Test.startTest();
        try {
            throw new AIAgentRestService.AIAgentRestException('Test exception');
        } catch (AIAgentRestService.AIAgentRestException e) {
            System.assertEquals('Test exception', e.getMessage());
        }
        Test.stopTest();
    }
}
