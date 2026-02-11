/**
 * @description Tests ServiceUserContextQueueable failure handling when Named Credential is missing.
 */
@IsTest
private class ServiceUserContextQueueableTest {
    private class MockSuccessResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new AIAgentRestService.AIAgentResponse(true, 'OK', null, 'req-1')));
            return res;
        }
    }

    private class MockErrorResponse implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody(JSON.serialize(new AIAgentRestService.AIAgentResponse(false, null, 'Bad request', 'req-2')));
            return res;
        }
    }

    @IsTest
    static void testExecute_MissingNamedCredential_FailsStubExecution() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withType('Conversational').withLLM(llm.Id).build();
        agent.ServiceUserNamedCredential__c = null;
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = 'Processing',
            TriggerSource__c = 'Apex'
        );
        insert execution;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.turnIdentifier = 'turn-svc-001';
        payload.userMessage = 'hello';
        payload.triggerSource = 'Apex';

        ServiceUserContextQueueable queueable = new ServiceUserContextQueueable(execution.Id, agent.Id, payload);

        Test.startTest();
        queueable.execute(null);
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];

        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Execution should be marked Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Processing status should be Failed');
        System.assert(
            updated.ErrorMessage__c != null && updated.ErrorMessage__c.contains('ServiceUserNamedCredential__c'),
            'Error message should mention missing Named Credential'
        );
    }

    @IsTest
    static void testExecute_SuccessfulResponse_DoesNotFailExecution() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withType('Conversational').withLLM(llm.Id).build();
        agent.ServiceUserNamedCredential__c = 'Test_NC';
        insert agent;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-svc-002')
            .save();

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.turnIdentifier = 'turn-svc-002';
        payload.userMessage = 'hello';
        payload.triggerSource = 'Apex';

        ServiceUserContextQueueable queueable = new ServiceUserContextQueueable(execution.Id, agent.Id, payload);

        Test.setMock(HttpCalloutMock.class, new MockSuccessResponse());
        Test.startTest();
        queueable.execute(null);
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Processing', updated.ExecutionStatus__c, 'Execution should remain Processing');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, updated.ProcessingStatus__c, 'Processing status should remain Processing');
        System.assertEquals(null, updated.ErrorMessage__c, 'No error message expected');
    }

    @IsTest
    static void testExecute_HttpError_FailsStubExecution() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withType('Conversational').withLLM(llm.Id).build();
        agent.ServiceUserNamedCredential__c = 'Test_NC';
        insert agent;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-svc-003')
            .save();

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.turnIdentifier = 'turn-svc-003';
        payload.userMessage = 'hello';
        payload.triggerSource = 'Apex';

        ServiceUserContextQueueable queueable = new ServiceUserContextQueueable(execution.Id, agent.Id, payload);

        Test.setMock(HttpCalloutMock.class, new MockErrorResponse());
        Test.startTest();
        queueable.execute(null);
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Execution should be marked Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Processing status should be Failed');
        System.assert(updated.ErrorMessage__c != null && updated.ErrorMessage__c.contains('routing failed'), 'Error message should indicate routing failure');
    }
}
