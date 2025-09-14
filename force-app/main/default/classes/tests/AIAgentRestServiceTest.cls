@IsTest
private class AIAgentRestServiceTest {
    @TestSetup
    static void makeData() {
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        List<AgentCapability__c> caps = TestFactory.createStandardCapabilities(agent.Id);
        insert caps;

        // Create chat session
        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @IsTest
    static void processMessage_validRequest_success() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create valid request
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(true, response.success, 'Response should be successful');
        System.assertEquals('Processing', response.outcome, 'Should return Processing status');
        System.assertEquals(null, response.error, 'Should have no error');
        System.assertNotEquals(null, response.requestId, 'Should have request ID');
        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 status code');
    }

    @IsTest
    static void processMessage_validRequestWithRecordId_success() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create valid request with current record ID
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';
        request.currentRecordId = session.Id; // Use session ID as a valid record ID

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(true, response.success, 'Response should be successful');
        System.assertEquals('Processing', response.outcome, 'Should return Processing status');
        System.assertEquals(null, response.error, 'Should have no error');
        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 status code');
    }

    @IsTest
    static void processMessage_emptyRequestBody_badRequest() {
        // Set up REST context with empty body
        RestRequest req = new RestRequest();
        req.requestBody = null;
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assertEquals(null, response.outcome, 'Should have no outcome');
        System.assert(response.error.contains('Request body is required'), 'Should indicate missing request body');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_invalidJson_badRequest() {
        // Set up REST context with invalid JSON
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf('invalid json {');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assertEquals(null, response.outcome, 'Should have no outcome');
        System.assert(response.error.contains('Invalid JSON format'), 'Should indicate invalid JSON');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_missingSessionId_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        // Create request missing sessionId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('sessionId is required'), 'Should indicate missing sessionId');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_missingOriginalUserId_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request missing originalUserId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('originalUserId is required'), 'Should indicate missing originalUserId');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_missingAgentDefinitionId_badRequest() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request missing agentDefinitionId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('agentDefinitionId is required'), 'Should indicate missing agentDefinitionId');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_missingTurnIdentifier_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request missing turnIdentifier
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('turnIdentifier is required'), 'Should indicate missing turnIdentifier');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_missingUserMessage_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request missing userMessage
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('userMessage is required'), 'Should indicate missing userMessage');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_invalidSessionId_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        // Create request with invalid sessionId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = 'invalid-id';
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('Invalid sessionId format'), 'Should indicate invalid sessionId format');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_invalidOriginalUserId_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request with invalid originalUserId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = 'invalid-user-id';
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('Invalid originalUserId format'), 'Should indicate invalid originalUserId format');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_invalidAgentDefinitionId_badRequest() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request with invalid agentDefinitionId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = 'invalid-agent-id';
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('Invalid agentDefinitionId format'), 'Should indicate invalid agentDefinitionId format');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_invalidCurrentRecordId_badRequest() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create request with invalid currentRecordId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';
        request.currentRecordId = 'invalid-record-id';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assert(response.error.contains('Invalid currentRecordId format'), 'Should indicate invalid currentRecordId format');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void processMessage_nonExistentAgentDefinition_badRequest() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create a fake agent definition ID
        String fakeAgentId = '001000000000000'; // Valid ID format but doesn't exist

        // Create request with non-existent agentDefinitionId
        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = fakeAgentId;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        // Set up REST context
        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.debug(response);

        System.assertEquals(false, response.success, 'Response should be unsuccessful');
        System.assertEquals(400, RestContext.response.statusCode, 'Should return 400 status code');
    }

    @IsTest
    static void generateRequestId_returnsUniqueId() {
        Test.startTest();

        // Use reflection to call the private method (if accessible) or test indirectly
        // Since generateRequestId is private, we'll test it indirectly through processMessage
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = session.Id;
        request.originalUserId = UserInfo.getUserId();
        request.agentDefinitionId = agent.Id;
        request.turnIdentifier = 'test-turn-123';
        request.userMessage = 'Test message';

        String requestBody = JSON.serialize(request);

        RestRequest req = new RestRequest();
        req.requestBody = Blob.valueOf(requestBody);
        RestContext.request = req;
        RestContext.response = new RestResponse();

        AIAgentRestService.AIAgentResponse response1 = AIAgentRestService.processMessage();

        // Reset context for second call
        RestContext.request = req;
        RestContext.response = new RestResponse();

        AIAgentRestService.AIAgentResponse response2 = AIAgentRestService.processMessage();

        Test.stopTest();

        System.assertNotEquals(null, response1.requestId, 'First response should have request ID');
        System.assertNotEquals(null, response2.requestId, 'Second response should have request ID');
        System.assertNotEquals(response1.requestId, response2.requestId, 'Request IDs should be unique');
    }

    @IsTest
    static void aiAgentRequest_settersAndGetters_work() {
        Test.startTest();

        AIAgentRestService.AIAgentRequest request = new AIAgentRestService.AIAgentRequest();
        request.sessionId = 'test-session';
        request.originalUserId = 'test-user';
        request.agentDefinitionId = 'test-agent';
        request.turnIdentifier = 'test-turn';
        request.userMessage = 'test-message';
        request.currentRecordId = 'test-record';

        Test.stopTest();

        System.assertEquals('test-session', request.sessionId, 'Should set and get sessionId');
        System.assertEquals('test-user', request.originalUserId, 'Should set and get originalUserId');
        System.assertEquals('test-agent', request.agentDefinitionId, 'Should set and get agentDefinitionId');
        System.assertEquals('test-turn', request.turnIdentifier, 'Should set and get turnIdentifier');
        System.assertEquals('test-message', request.userMessage, 'Should set and get userMessage');
        System.assertEquals('test-record', request.currentRecordId, 'Should set and get currentRecordId');
    }

    @IsTest
    static void aiAgentResponse_constructor_setsProperties() {
        Test.startTest();

        AIAgentRestService.AIAgentResponse response = new AIAgentRestService.AIAgentResponse(true, 'Success outcome', null, 'req-123');

        Test.stopTest();

        System.assertEquals(true, response.success, 'Should set success');
        System.assertEquals('Success outcome', response.outcome, 'Should set outcome');
        System.assertEquals(null, response.error, 'Should set error');
        System.assertEquals('req-123', response.requestId, 'Should set requestId');
    }

    @IsTest
    static void aiAgentResponse_errorConstructor_setsProperties() {
        Test.startTest();

        AIAgentRestService.AIAgentResponse response = new AIAgentRestService.AIAgentResponse(false, null, 'Error message', 'req-456');

        Test.stopTest();

        System.assertEquals(false, response.success, 'Should set success to false');
        System.assertEquals(null, response.outcome, 'Should set outcome to null');
        System.assertEquals('Error message', response.error, 'Should set error message');
        System.assertEquals('req-456', response.requestId, 'Should set requestId');
    }

    @IsTest
    static void aiAgentRestException_canBeThrown() {
        Test.startTest();

        try {
            throw new AIAgentRestService.AIAgentRestException('Test exception');
        } catch (AIAgentRestService.AIAgentRestException e) {
            System.assertEquals('Test exception', e.getMessage(), 'Should preserve exception message');
        }

        Test.stopTest();
    }
}
