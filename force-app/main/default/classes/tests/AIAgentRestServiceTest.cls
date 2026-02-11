/**
 * @description Tests for AIAgentRestService validation responses.
 */
@IsTest
private class AIAgentRestServiceTest {
    @IsTest
    static void testProcessMessage_MissingBody_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Should fail when request body is missing');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('Request body is required'), 'Should return validation message');
    }

    @IsTest
    static void testProcessMessage_InvalidId_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => 'abc',
            'agentDefinitionId' => 'abc',
            'turnIdentifier' => 'turn-1',
            'userMessage' => 'hello'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Invalid IDs should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('Invalid originalUserId format'), 'Should flag invalid id format');
    }

    @IsTest
    static void testProcessMessage_MissingTurnIdentifier_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent').withType('Function').withLLM(llm.Id).save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agent.Id,
            'userMessage' => 'hello'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing turnIdentifier should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('turnIdentifier is required'), 'Should flag missing turnIdentifier');
    }

    @IsTest
    static void testProcessMessage_InvalidSourceRecordIds_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 2').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_2').withType('Function').withLLM(llm.Id).save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agent.Id,
            'turnIdentifier' => 'turn-rest-001',
            'sourceRecordIds' => new List<String>{ 'not-an-id' }
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Invalid sourceRecordIds should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('sourceRecordIds[0]'), 'Should flag invalid sourceRecordIds index');
    }

    @IsTest
    static void testFollowUp_MissingExecutionId_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/followup';

        Map<String, Object> payload = new Map<String, Object>{ 'turnIdentifier' => 'turn-followup-001', 'turnCount' => 1 };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing executionId should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('executionId is required'), 'Should flag missing executionId');
    }

    @IsTest
    static void testResume_CompletedExecution_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 3').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_3').withType('Function').withLLM(llm.Id).save();

        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Completed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-rest-resume-001')
            .save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/resume';

        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => exec.Id, 'resumeReason' => 'Test resume' };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Completed execution should not resume');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('already completed'), 'Should indicate execution completed');
    }

    @IsTest
    static void testProcessMessageInContext_Success() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 4').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_4').withType('Conversational').withLLM(llm.Id).save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agent.Id,
            'turnIdentifier' => 'turn-rest-ctx-001',
            'userMessage' => 'Hello there'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Hello!'));

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(true, response.success, 'Valid request should succeed');
        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 status');
        System.assertNotEquals(null, response.outcome, 'Should return an outcome message');
    }

    @IsTest
    static void testExecuteApprovedHITLTool_Success() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 5').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_5').withType('Function').withLLM(llm.Id).save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .save();

        Case testCase = TestFactory.newCase().withSubject('HITL Case').save();
        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-hitl-001')
            .save();

        PendingHITLAction__c pending = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = capability.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-001',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitl-001',
            ToolName__c = capability.CapabilityName__c,
            ToolArgumentsJSON__c = '{"Id":"' + testCase.Id + '"}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert pending;

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/execute';

        Map<String, Object> payload = new Map<String, Object>{
            'pendingActionId' => pending.Id,
            'executionId' => exec.Id,
            'capabilityId' => capability.Id,
            'toolCallId' => 'call-hitl-001',
            'toolName' => capability.CapabilityName__c,
            'toolArguments' => '{"Id":"' +
            testCase.Id +
            '"}',
            'turnIdentifier' => 'turn-hitl-001',
            'turnCount' => 1,
            'sourceRecordId' => testCase.Id,
            'needsFollowUp' => false
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(true, response.success, 'HITL execute should succeed');
        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 status');
    }

    @IsTest
    static void testExecuteFollowUpLLMCall_Success() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 6').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_6').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-followup-002')
            .save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/followup';

        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => exec.Id, 'turnIdentifier' => 'turn-followup-002', 'turnCount' => 1 };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        Test.startTest();
        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();
        Test.stopTest();

        System.assertNotEquals(null, response, 'Response should not be null');
        System.assertEquals(true, response.success, 'Follow-up should succeed');
        System.assertEquals(200, res.statusCode, 'Should return 200 status');
        System.assertEquals('QUEUED_FOLLOWUP', response.outcome, 'Should return queued follow-up message');
    }

    @IsTest
    static void testExecuteApprovedHITLTool_QueuesFollowUpAndNotifies() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 7').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_7').withType('Function').withLLM(llm.Id).save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .build();
        capability.HITLNotificationPreference__c = HITLGatewayService.NOTIFICATION_PREF_ALWAYS_NOTIFY;
        insert capability;

        Case testCase = TestFactory.newCase().withSubject('HITL Follow-up').save();
        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-hitl-followup-001')
            .save();

        PendingHITLAction__c pending = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = capability.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-followup-001',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitl-followup-001',
            ToolName__c = capability.CapabilityName__c,
            ToolArgumentsJSON__c = '{"Id":"' + testCase.Id + '"}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert pending;

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/execute';

        Map<String, Object> payload = new Map<String, Object>{
            'pendingActionId' => pending.Id,
            'executionId' => exec.Id,
            'capabilityId' => capability.Id,
            'toolCallId' => 'call-hitl-followup-001',
            'toolName' => capability.CapabilityName__c,
            'toolArguments' => '{"Id":"' +
            testCase.Id +
            '"}',
            'turnIdentifier' => 'turn-hitl-followup-001',
            'turnCount' => 1,
            'sourceRecordId' => testCase.Id,
            'needsFollowUp' => true,
            'requestingUserId' => UserInfo.getUserId()
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        AgentExecution__c updatedExec = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :exec.Id
        ];

        System.assertEquals(true, response.success, 'HITL execute should succeed');
        System.assertEquals(200, RestContext.response.statusCode, 'Should return 200 status');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, updatedExec.ProcessingStatus__c, 'Should move to awaiting follow-up');
        System.assertEquals('Processing', updatedExec.ExecutionStatus__c, 'Execution should remain Processing for follow-up');
    }

    @IsTest
    static void testResumeInServiceContext_Success() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 8').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_8').withType('Conversational').withLLM(llm.Id).save();

        Case testCase = TestFactory.newCase().withSubject('Resume Case').save();
        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_FAILED)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-resume-001')
            .save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/resume';

        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => exec.Id, 'resumeReason' => 'User requested resume' };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Resumed.'));

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(true, response.success, 'Resume should succeed');
        System.assertEquals(200, res.statusCode, 'Should return 200 status');
        System.assertNotEquals(null, response.outcome, 'Outcome should describe the resume result');
    }

    @IsTest
    static void testProcessMessage_InvalidJson_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';
        req.requestBody = Blob.valueOf('{invalid-json}');

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Invalid JSON should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('Invalid JSON format'), 'Should flag JSON error');
    }

    @IsTest
    static void testProcessMessage_MissingOriginalUserId_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 9').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_9').withType('Function').withLLM(llm.Id).save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{ 'agentDefinitionId' => agent.Id, 'turnIdentifier' => 'turn-rest-002' };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing originalUserId should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('originalUserId is required'), 'Should flag missing originalUserId');
    }

    @IsTest
    static void testProcessMessage_AgentDefinitionNotFound_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => 'a0X000000000000',
            'turnIdentifier' => 'turn-rest-003'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Non-existent agent should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('not found'), 'Should indicate agent not found');
    }

    @IsTest
    static void testProcessMessage_InvalidCurrentRecordId_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 10').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_10').withType('Function').withLLM(llm.Id).save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/process';

        Map<String, Object> payload = new Map<String, Object>{
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agent.Id,
            'turnIdentifier' => 'turn-rest-004',
            'currentRecordId' => 'not-a-valid-id'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Invalid currentRecordId should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('Invalid currentRecordId format'), 'Should flag invalid currentRecordId');
    }

    @IsTest
    static void testHITLExecute_MissingCapabilityId_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 11').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_11').withType('Function').withLLM(llm.Id).save();
        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-hitl-002')
            .save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/execute';

        Map<String, Object> payload = new Map<String, Object>{
            'pendingActionId' => exec.Id,
            'executionId' => exec.Id,
            'toolCallId' => 'call-hitl-002',
            'turnIdentifier' => 'turn-hitl-002'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing capabilityId should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('capabilityId is required'), 'Should flag missing capabilityId');
    }

    @IsTest
    static void testHITLExecute_CapabilityNotFound_ReturnsBadRequest() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Rest LLM 12').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Rest_Agent_12').withType('Function').withLLM(llm.Id).save();
        AgentExecution__c exec = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-hitl-003')
            .save();

        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/execute';

        Map<String, Object> payload = new Map<String, Object>{
            'pendingActionId' => exec.Id,
            'executionId' => exec.Id,
            'capabilityId' => 'a0X000000000000',
            'toolCallId' => 'call-hitl-003',
            'turnIdentifier' => 'turn-hitl-003',
            'toolArguments' => '{}'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Non-existent capability should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        // Error message contains "System error querying AgentCapability"
        System.assert(response.error != null, 'Should have error message');
    }

    @IsTest
    static void testFollowUp_MissingTurnIdentifier_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/hitl/followup';

        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => UserInfo.getUserId(), 'turnCount' => 1 };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing turnIdentifier should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('turnIdentifier is required'), 'Should flag missing turnIdentifier');
    }

    @IsTest
    static void testResume_MissingExecutionId_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/resume';

        Map<String, Object> payload = new Map<String, Object>{ 'resumeReason' => 'Test' };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Missing executionId should fail');
        System.assertEquals(400, RestContext.response.statusCode, 'Should set 400 status');
        System.assert(response.error != null && response.error.contains('executionId is required'), 'Should flag missing executionId');
    }

    @IsTest
    static void testResume_ExecutionNotFound_ReturnsBadRequest() {
        RestRequest req = new RestRequest();
        RestResponse res = new RestResponse();
        req.httpMethod = 'POST';
        req.requestURI = '/services/apexrest/ai/agent/resume';

        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => 'a0X000000000000', 'resumeReason' => 'Test' };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        RestContext.request = req;
        RestContext.response = res;

        AIAgentRestService.AIAgentResponse response = AIAgentRestService.processMessage();

        System.assertEquals(false, response.success, 'Non-existent execution should fail');
        System.assert(RestContext.response.statusCode >= 400, 'Should return error status');
    }
}
