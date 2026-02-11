/**
 * @description Focused tests for AgentExecutionService routing and flow entry behavior
 */
@IsTest
private class AgentExecutionServiceTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('ExecSvc LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('ExecSvc_Agent').withType('Function').withLLM(llm.Id).save();

        agent.RequiresServiceUserContext__c = true;
        agent.ServiceUserNamedCredential__c = 'ServiceUser_NC';
        update agent;

        TestFactory.newAccount().withName('ExecSvc Account 1').save();
        TestFactory.newAccount().withName('ExecSvc Account 2').save();
    }

    @IsTest
    static void testStartExecution_ServiceUserWithPriorDML_SingleRecordCreatesStub() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        // Create prior DML to force queueable routing
        Account dmlMarker = new Account(Name = 'ExecSvc DML');
        insert dmlMarker;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;
        payload.triggerSource = 'Test';

        AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agent.DeveloperName__c, payload);

        System.assertEquals(true, result.success, 'Execution should return success');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, result.status, 'Should be Processing when queued');
        System.assertNotEquals(null, result.executionId, 'Stub execution ID should be returned');

        AgentExecution__c stub = [
            SELECT Id, ExecutionStatus__c, TriggerPayload__c, SourceRecordId__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
            LIMIT 1
        ];
        System.assertEquals('Pending', stub.ExecutionStatus__c, 'Stub execution should start Pending');
        System.assertEquals('Stub execution for service user routing', stub.TriggerPayload__c, 'Stub payload should match');
        System.assertEquals(source.Id, stub.SourceRecordId__c, 'Stub should track source record');
        System.assertEquals(agent.Id, stub.AIAgentDefinition__c, 'Stub should link to agent definition');
    }

    @IsTest
    static void testStartExecution_ServiceUserWithPriorDML_MultiRecordNoStub() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        List<Account> sources = [SELECT Id FROM Account WHERE Name LIKE 'ExecSvc Account%' ORDER BY Name];

        // Create prior DML to force queueable routing
        Account dmlMarker = new Account(Name = 'ExecSvc DML 2');
        insert dmlMarker;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordIds = new List<Id>{ sources[0].Id, sources[1].Id };
        payload.triggerSource = 'Flow';

        Integer beforeCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agent.Id AND SourceRecordId__c IN :payload.sourceRecordIds
        ];

        AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agent.DeveloperName__c, payload);

        Integer afterCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agent.Id AND SourceRecordId__c IN :payload.sourceRecordIds
        ];

        System.assertEquals(true, result.success, 'Execution should return success');
        System.assertEquals(null, result.executionId, 'Multi-record queueing should not return stub execution ID');
        System.assertEquals(beforeCount, afterCount, 'Multi-record queueing should not create stub execution');
        System.assert(result.message.contains('Multi-record execution queued'), 'Result message should describe multi-record queueing');
    }

    @IsTest
    static void testStartExecution_ServiceUserNoPriorDML_RoutesThroughRestApi() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;
        payload.triggerSource = 'API';

        Integer beforeCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agent.Id AND SourceRecordId__c = :source.Id
        ];

        Test.startTest();
        AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
        Test.stopTest();

        Integer afterCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agent.Id AND SourceRecordId__c = :source.Id
        ];

        System.assertEquals(true, result.success, 'REST routing should return success');
        System.assertEquals('QUEUED_ACTION', result.status, 'Status should reflect REST outcome');
        System.assertEquals('QUEUED_ACTION', result.message, 'Message should reflect REST outcome');
        System.assertEquals(beforeCount, afterCount, 'REST routing should not create stub execution records');
    }

    @IsTest
    static void testStartExecutionFromFlow_GroupsAndReturnsResults() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        List<Account> sources = [SELECT Id FROM Account WHERE Name LIKE 'ExecSvc Account%' ORDER BY Name];

        // Create prior DML to force queueable routing
        Account dmlMarker = new Account(Name = 'ExecSvc DML 3');
        insert dmlMarker;

        AgentExecutionService.InvocableRequest req1 = new AgentExecutionService.InvocableRequest();
        req1.agentName = agent.DeveloperName__c;
        req1.recordId = sources[0].Id;
        req1.userMessage = 'Hello';
        req1.triggerSource = 'Flow';

        AgentExecutionService.InvocableRequest req2 = new AgentExecutionService.InvocableRequest();
        req2.agentName = agent.DeveloperName__c;
        req2.recordId = sources[1].Id;
        req2.userMessage = 'Hello again';
        req2.triggerSource = 'Flow';

        List<AgentExecutionService.ExecutionResult> results = AgentExecutionService.startExecutionFromFlow(
            new List<AgentExecutionService.InvocableRequest>{ req1, req2 }
        );

        System.assertEquals(2, results.size(), 'Should return one result per input record');
        System.assertEquals(true, results[0].success, 'Result should be success');
        System.assertEquals(true, results[1].success, 'Result should be success');
    }

    @IsTest
    static void testStartExecution_ServiceUserNoPriorDML_RestErrorThrows() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockInternalApiError());

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;
        payload.triggerSource = 'API';

        Boolean threw = false;
        Test.startTest();
        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assertEquals(true, threw, 'REST routing errors should surface to callers');
    }

    private class MockInternalApiError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"Internal API failure"}');
            return res;
        }
    }

    // ========== validateRecordsExist Coverage ==========

    @IsTest
    static void testStartExecution_NonExistentSourceRecordId_ThrowsValidationError() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];

        // Temporarily disable service user context to trigger immediate validation
        agent.RequiresServiceUserContext__c = false;
        update agent;

        Id fakeAccountId = TestFactory.generateMockId(Schema.Account.SObjectType);

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = fakeAccountId;

        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
            System.assert(false, 'Should throw validation error for non-existent record');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('do not exist'), 'Should indicate record does not exist');
            System.assert(e.getMessage().contains(String.valueOf(fakeAccountId)), 'Should include the missing record ID');
        }
    }

    @IsTest
    static void testStartExecution_MixedExistingAndNonExistentRecords_ThrowsWithMissingOnly() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        agent.RequiresServiceUserContext__c = false;
        update agent;

        Account realAccount = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];
        Id fakeAccountId = TestFactory.generateMockId(Schema.Account.SObjectType);

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordIds = new List<Id>{ realAccount.Id, fakeAccountId };

        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
            System.assert(false, 'Should throw validation error for mixed records');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains(String.valueOf(fakeAccountId)), 'Should list the missing record ID');
            System.assert(!e.getMessage().contains(String.valueOf(realAccount.Id)), 'Should not list existing record');
        }
    }

    // ========== Edge Cases: Validation ==========

    @IsTest
    static void testStartExecution_BlankAgentName_Throws() {
        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();

        try {
            AgentExecutionService.startExecution('', payload);
            System.assert(false, 'Should throw for blank agent name');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Agent developer name is required'));
        }

        try {
            AgentExecutionService.startExecution(null, payload);
            System.assert(false, 'Should throw for null agent name');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Agent developer name is required'));
        }
    }

    @IsTest
    static void testStartExecution_NullPayload_Throws() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];

        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, null);
            System.assert(false, 'Should throw for null payload');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Execution payload is required'));
        }
    }

    @IsTest
    static void testStartExecution_NullIdsInSourceRecordIds_Throws() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        agent.RequiresServiceUserContext__c = false;
        update agent;

        Account realAccount = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordIds = new List<Id>{ realAccount.Id, null };

        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
            System.assert(false, 'Should throw for null ID in sourceRecordIds');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('null') || e.getMessage().contains('de-reference'), 'Should indicate null ID issue');
        }
    }

    @IsTest
    static void testStartExecution_PayloadWithAllOptionalFields_Succeeds() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c, AgentType__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        agent.RequiresServiceUserContext__c = false;
        agent.AgentType__c = 'Conversational'; // Use agent type that has orchestrator mapping
        update agent;

        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;
        payload.currentRecordId = source.Id;
        payload.userMessage = 'Test message';
        payload.triggerSource = 'API'; // Use valid picklist value
        payload.turnIdentifier = 'turn-123';
        payload.batchId = 'batch-abc';
        payload.priority = 5;
        payload.triggerPayload = 'Custom payload data';

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Response'));

        AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
        System.assertNotEquals(null, result, 'Should return a result');
    }

    // ========== Edge Cases: REST API success=false ==========

    @IsTest
    static void testStartExecution_RestApiReturnsSuccessFalse_Throws() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockRestApiFailure());

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;

        Test.startTest();
        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
            System.assert(false, 'Should throw when REST API returns success=false');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('REST API routing failed'), 'Should indicate REST API failure');
            System.assert(e.getMessage().contains('Agent is not configured correctly'), 'Should include API error message');
        }
        Test.stopTest();
    }

    // ========== Edge Cases: buildLoopbackHttpRequest ==========

    @IsTest
    static void testStartExecution_MissingServiceUserNamedCredential_Throws() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];
        agent.ServiceUserNamedCredential__c = '';
        update agent;

        Account source = [SELECT Id FROM Account WHERE Name = 'ExecSvc Account 1' LIMIT 1];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = source.Id;

        Test.startTest();
        try {
            AgentExecutionService.startExecution(agent.DeveloperName__c, payload);
            System.assert(false, 'Should throw when ServiceUserNamedCredential is blank');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('ServiceUserNamedCredential__c is not configured'), 'Should indicate missing Named Credential');
        }
        Test.stopTest();
    }

    // ========== Edge Cases: startExecutionFromFlow error handling ==========

    @IsTest
    static void testStartExecutionFromFlow_ExceptionInExecution_ReturnsErrorResults() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'ExecSvc_Agent%'
            LIMIT 1
        ];

        // Remove agent definition to cause exception
        delete agent;

        List<Account> sources = [SELECT Id FROM Account WHERE Name LIKE 'ExecSvc Account%' ORDER BY Name];

        AgentExecutionService.InvocableRequest req1 = new AgentExecutionService.InvocableRequest();
        req1.agentName = agent.DeveloperName__c;
        req1.recordId = sources[0].Id;

        AgentExecutionService.InvocableRequest req2 = new AgentExecutionService.InvocableRequest();
        req2.agentName = agent.DeveloperName__c;
        req2.recordId = sources[1].Id;

        List<AgentExecutionService.ExecutionResult> results = AgentExecutionService.startExecutionFromFlow(
            new List<AgentExecutionService.InvocableRequest>{ req1, req2 }
        );

        System.assertEquals(2, results.size(), 'Should return one error result per input');
        System.assertEquals(false, results[0].success, 'Result should be failure');
        System.assertEquals(false, results[1].success, 'Result should be failure');
        System.assert(results[0].errorMessage.contains('Failed to start execution'), 'Should contain error message');
    }

    @IsTest
    static void testStartExecutionFromFlow_EmptyRequests_ReturnsEmptyList() {
        List<AgentExecutionService.ExecutionResult> results = AgentExecutionService.startExecutionFromFlow(new List<AgentExecutionService.InvocableRequest>());

        System.assertEquals(0, results.size(), 'Empty input should return empty output');
    }

    // ========== Mock HTTP Responses ==========

    private class MockRestApiFailure implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"success":false,"error":"Agent is not configured correctly"}');
            return res;
        }
    }

    private class MockBlankResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(404);
            res.setBody('');
            return res;
        }
    }

    private class MockLongHtmlError implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);

            // Create a 300+ char HTML error page (unparsable as JSON)
            String longBody = '<html><body><h1>Internal Server Error</h1><p>';
            for (Integer i = 0; i < 10; i++) {
                longBody += 'The server encountered an unexpected condition that prevented it from fulfilling the request. ';
            }
            longBody += '</p></body></html>';

            res.setBody(longBody);
            return res;
        }
    }
}
