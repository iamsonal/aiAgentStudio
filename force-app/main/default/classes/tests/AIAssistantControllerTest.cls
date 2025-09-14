@IsTest
private class AIAssistantControllerTest {
    @TestSetup
    static void makeData() {
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        List<AgentCapability__c> caps = TestFactory.createStandardCapabilities(agent.Id);
        insert caps;
    }

    @IsTest
    static void sendMessage_success_directProcessing() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(sessionDetails.sessionId, 'Test message', null, UuidUtils.generateUUID());
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals('Agent responded.', response.get('message'));

        ChatSession__c finalSession = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, finalSession.ProcessingStatus__c);

        List<Map<String, Object>> messages = AIAssistantController.getChatHistory(sessionDetails.sessionId, 10, System.now().addHours(1));
        System.assertEquals(2, messages.size());

        AIAssistantController.SessionDetails recentSessionDetails = AIAssistantController.getMostRecentSession(agent.DeveloperName__c, null);
        System.assertEquals(sessionDetails.sessionId, recentSessionDetails.sessionId);

        AIAssistantController.startOverFromMessage(sessionDetails.sessionId, messages[0].get('externalId').toString());

        List<ChatMessage__c> chatMessages = [SELECT Id FROM ChatMessage__c];
        System.assertEquals(0, chatMessages.size());
    }

    @IsTest
    static void sendMessage_success_serviceProcessing() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        agent.RequiresServiceUserContext__c = true;
        update agent;

        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(sessionDetails.sessionId, 'Test message', null, UuidUtils.generateUUID());
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assertEquals('Processing...', response.get('message'));

        ChatSession__c finalSession = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, finalSession.ProcessingStatus__c);
    }

    @IsTest
    static void sendMessage_llmFailure_httpError() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        // Tell the mock to fail the LLM callout
        MockHttpResponses.reset();
        MockHttpResponses.statusCode = 500;
        MockHttpResponses.responseBody = '{"error": {"message": "The server had an error."}}';
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(sessionDetails.sessionId, 'Test message', null, UuidUtils.generateUUID());
        Test.stopTest();

        System.assertEquals(false, response.get('success'));
        System.assert(String.valueOf(response.get('error')).contains('LLM Call Failed'));

        ChatSession__c finalSession = [SELECT ProcessingStatus__c, LastProcessingError__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_FAILED, finalSession.ProcessingStatus__c);
        System.assert(finalSession.LastProcessingError__c.contains('LLM Call Failed'));
    }

    @IsTest
    static void sendMessage_success_toolCallCapability() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        // No need to configure anything - the mock will intelligently respond based on request content
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(sessionDetails.sessionId, 'Find sales records for test query', null, UuidUtils.generateUUID());
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        // For tool calls, the initial response should be "Processing..." since it's async
        System.assertEquals('Processing...', response.get('message'));

        // After Test.stopTest(), all async jobs should have completed
        ChatSession__c finalSession = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, finalSession.ProcessingStatus__c);

        // Verify that the assistant message with tool calls was created
        List<ChatMessage__c> assistantMessages = [
            SELECT Id, Role__c, Content__c, AssistantToolCalls__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'assistant'
            ORDER BY CreatedDate ASC
        ];

        // Should have 2 assistant messages: one with tool call, one with final response
        System.assertEquals(2, assistantMessages.size());

        // First assistant message should have the tool call
        ChatMessage__c toolCallMessage = assistantMessages[0];
        System.assertEquals('I will search for sales records based on your query.', toolCallMessage.Content__c);
        System.assertNotEquals(null, toolCallMessage.AssistantToolCalls__c);

        // Verify the tool call structure
        List<Object> toolCalls = (List<Object>) JSON.deserializeUntyped(toolCallMessage.AssistantToolCalls__c);
        System.assertEquals(1, toolCalls.size());

        Map<String, Object> toolCall = (Map<String, Object>) toolCalls[0];
        System.assertEquals('call_123', toolCall.get('id'));
        System.assertEquals('function', toolCall.get('type'));

        Map<String, Object> functionCall = (Map<String, Object>) toolCall.get('function');
        System.assertEquals('find_sales_records', functionCall.get('name'));
        System.assertEquals('{"searchQuery":"test query"}', functionCall.get('arguments'));

        // Second assistant message should have the final response
        ChatMessage__c finalMessage = assistantMessages[1];
        System.assertEquals('Based on the search results, I found several sales records that match your query.', finalMessage.Content__c);
        System.assertEquals(null, finalMessage.AssistantToolCalls__c);

        // Verify that a tool result message was also created
        List<ChatMessage__c> toolMessages = [
            SELECT Id, Role__c, ToolCallId__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'tool'
        ];

        System.assertEquals(1, toolMessages.size());
        System.assertEquals('call_123', toolMessages[0].ToolCallId__c);
    }

    @IsTest
    static void sendMessage_success_toolCallCapability_runAsynchronously() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // Find and update the capability to run asynchronously
        AgentCapability__c capability = [
            SELECT Id, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agent.Id AND CapabilityName__c = 'find_sales_records'
            LIMIT 1
        ];
        capability.RunAsynchronously__c = true;
        update capability;

        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(
            sessionDetails.sessionId,
            'Find sales records for async test query',
            null,
            UuidUtils.generateUUID()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        // For async tool calls, the initial response should be "Processing..."
        System.assertEquals('Processing...', response.get('message'));

        // After Test.stopTest(), async action completes but session awaits followup LLM call
        ChatSession__c finalSession = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, finalSession.ProcessingStatus__c);

        // Verify that the assistant message with tool calls was created
        List<ChatMessage__c> assistantMessages = [
            SELECT Id, Role__c, Content__c, AssistantToolCalls__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'assistant'
            ORDER BY CreatedDate ASC
        ];

        // Should have 1 assistant message with tool call (followup LLM call hasn't happened yet)
        System.assertEquals(1, assistantMessages.size());

        // The assistant message should have the tool call
        ChatMessage__c toolCallMessage = assistantMessages[0];
        System.assertEquals('I will search for sales records based on your query.', toolCallMessage.Content__c);
        System.assertNotEquals(null, toolCallMessage.AssistantToolCalls__c);

        // Verify the tool call structure
        List<Object> toolCalls = (List<Object>) JSON.deserializeUntyped(toolCallMessage.AssistantToolCalls__c);
        System.assertEquals(1, toolCalls.size());

        Map<String, Object> toolCall = (Map<String, Object>) toolCalls[0];
        System.assertEquals('call_123', toolCall.get('id'));
        System.assertEquals('function', toolCall.get('type'));

        Map<String, Object> functionCall = (Map<String, Object>) toolCall.get('function');
        System.assertEquals('find_sales_records', functionCall.get('name'));
        System.assertEquals('{"searchQuery":"test query"}', functionCall.get('arguments'));

        // After Test.stopTest(), async job completes and tool result message is created
        List<ChatMessage__c> toolMessages = [
            SELECT Id, Role__c, ToolCallId__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'tool'
        ];

        System.assertEquals(1, toolMessages.size());
        System.assertEquals('call_123', toolMessages[0].ToolCallId__c);

        // Verify the capability was run asynchronously by checking it's still set to true
        AgentCapability__c updatedCapability = [
            SELECT Id, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE Id = :capability.Id
        ];
        System.assertEquals(true, updatedCapability.RunAsynchronously__c);
    }

    @IsTest
    static void sendMessage_success_toolCallCapability_requiresApproval() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // Find and update the capability to require approval
        AgentCapability__c capability = [
            SELECT Id, RequiresApproval__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agent.Id AND CapabilityName__c = 'find_sales_records'
            LIMIT 1
        ];
        capability.RequiresApproval__c = true;
        update capability;

        AIAssistantController.SessionDetails sessionDetails = AIAssistantController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = AIAssistantController.sendMessage(
            sessionDetails.sessionId,
            'Find sales records for approval test query',
            null,
            UuidUtils.generateUUID()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        // For approval-required tool calls, the initial response should be "Processing..."
        System.assertEquals('Processing...', response.get('message'));

        // After Test.stopTest(), approval process is submitted and follow-up LLM call completes
        ChatSession__c finalSession = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, finalSession.ProcessingStatus__c);

        // Verify that the assistant message with tool calls was created
        List<ChatMessage__c> assistantMessages = [
            SELECT Id, Role__c, Content__c, AssistantToolCalls__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'assistant'
            ORDER BY CreatedDate ASC
        ];

        // Should have 2 assistant messages: one with tool call, one with follow-up response
        System.assertEquals(2, assistantMessages.size());

        // First assistant message should have the tool call
        ChatMessage__c toolCallMessage = assistantMessages[0];
        System.assertEquals('I will search for sales records based on your query.', toolCallMessage.Content__c);
        System.assertNotEquals(null, toolCallMessage.AssistantToolCalls__c);

        // Verify the tool call structure
        List<Object> toolCalls = (List<Object>) JSON.deserializeUntyped(toolCallMessage.AssistantToolCalls__c);
        System.assertEquals(1, toolCalls.size());

        Map<String, Object> toolCall = (Map<String, Object>) toolCalls[0];
        System.assertEquals('call_123', toolCall.get('id'));
        System.assertEquals('function', toolCall.get('type'));

        Map<String, Object> functionCall = (Map<String, Object>) toolCall.get('function');
        System.assertEquals('find_sales_records', functionCall.get('name'));
        System.assertEquals(
            '{"searchQuery":"test query","submission_comment":"User requested sales records search for business analysis"}',
            functionCall.get('arguments')
        );

        // Second assistant message should have the follow-up response (mock returns generic tool followup)
        ChatMessage__c followUpMessage = assistantMessages[1];
        System.assertEquals('Based on the search results, I found several sales records that match your query.', followUpMessage.Content__c);
        System.assertEquals(null, followUpMessage.AssistantToolCalls__c);

        // Verify that a HumanApprovalRequest__c record was created
        List<HumanApprovalRequest__c> approvalRequests = [
            SELECT Id, ChatSession__c, LLMToolCallId__c, LLMToolName__c, ApprovalStatus__c
            FROM HumanApprovalRequest__c
            WHERE ChatSession__c = :sessionDetails.sessionId
        ];

        System.assertEquals(1, approvalRequests.size());
        HumanApprovalRequest__c approvalRequest = approvalRequests[0];
        System.assertEquals(sessionDetails.sessionId, approvalRequest.ChatSession__c);
        System.assertEquals('call_123', approvalRequest.LLMToolCallId__c);
        System.assertEquals('find_sales_records', approvalRequest.LLMToolName__c);
        System.assertEquals('Pending', approvalRequest.ApprovalStatus__c);

        // Verify that a tool result message was created with pending approval status
        List<ChatMessage__c> toolMessages = [
            SELECT Id, Role__c, ToolCallId__c, Content__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionDetails.sessionId AND Role__c = 'tool'
        ];

        System.assertEquals(1, toolMessages.size());
        ChatMessage__c toolMessage = toolMessages[0];
        System.assertEquals('call_123', toolMessage.ToolCallId__c);

        // Verify the tool result content indicates pending approval
        Map<String, Object> toolResult = (Map<String, Object>) JSON.deserializeUntyped(toolMessage.Content__c);
        System.assertEquals('pending_approval', toolResult.get('status'));
        System.assert(String.valueOf(toolResult.get('message')).contains('submitted for Salesforce Approval'));

        // Verify the capability was set to require approval
        AgentCapability__c updatedCapability = [
            SELECT Id, RequiresApproval__c
            FROM AgentCapability__c
            WHERE Id = :capability.Id
        ];
        System.assertEquals(true, updatedCapability.RequiresApproval__c);
    }
}
