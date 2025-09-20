@IsTest
private class HumanApprovalRequestTriggerHandlerTest {
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
    static void handleAfterUpdate_approvalStatusChanged_approved() {
        // Setup test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        ChatSession__c session = new ChatSession__c(
            User__c = UserInfo.getUserId(),
            AIAgentDefinition__c = agent.Id,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert session;

        ChatMessage__c assistantMessage = new ChatMessage__c(
            ChatSession__c = session.Id,
            Role__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will search for sales records.',
            ExternalId__c = 'turn-123',
            Timestamp__c = System.now()
        );
        insert assistantMessage;

        String argumentsJson = JSON.serialize(
            new Map<String, Object>{
                'sObjectTypes' => new List<String>{ 'Account' },
                'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
                'filters' => new Map<String, Object>{ 'Name' => 'test query' }
            }
        );

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = session.Id,
            OriginalAssistantMessage__c = assistantMessage.Id,
            LLMConfirmationMessage__c = 'User requested sales records search',
            LLMToolCallId__c = 'call_123',
            LLMToolName__c = 'find_sales_records',
            LLMToolArgumentsJSON__c = argumentsJson,
            OriginalTurnIdentifier__c = 'turn-123',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        Account vAccount = new Account(Name = 'Test Account');
        insert vAccount;
        Test.setFixedSearchResults(new List<Id>{ vAccount.Id });

        Test.startTest();
        // Simulate approval process updating the status to Approved
        har.ApprovalStatus__c = 'Approved';
        har.ApproverComments__c = 'Approved by manager for business analysis';
        update har;
        Test.stopTest();

        // Verify the approval request was processed
        HumanApprovalRequest__c updatedHar = [
            SELECT Id, ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        // The assertion should now pass because the action will succeed
        System.assertEquals('Approved', updatedHar.ApprovalStatus__c);
        System.assert(updatedHar.ApproverComments__c.contains('Action completed successfully'));
    }

    @IsTest
    static void handleAfterUpdate_approvalStatusChanged_rejected() {
        // Setup test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        ChatSession__c session = new ChatSession__c(
            User__c = UserInfo.getUserId(),
            AIAgentDefinition__c = agent.Id,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert session;

        ChatMessage__c assistantMessage = new ChatMessage__c(
            ChatSession__c = session.Id,
            Role__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will search for sales records.',
            ExternalId__c = 'turn-456',
            Timestamp__c = System.now()
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = session.Id,
            OriginalAssistantMessage__c = assistantMessage.Id,
            LLMConfirmationMessage__c = 'User requested sales records search',
            LLMToolCallId__c = 'call_456',
            LLMToolName__c = 'find_sales_records',
            LLMToolArgumentsJSON__c = '{"searchQuery":"sensitive query","submission_comment":"Need access to confidential data"}',
            OriginalTurnIdentifier__c = 'turn-456',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        Test.startTest();
        // Simulate approval process updating the status to Rejected
        har.ApprovalStatus__c = 'Rejected';
        har.ApproverComments__c = 'Request denied - insufficient business justification';
        update har;
        Test.stopTest();

        // Verify the rejection was processed
        HumanApprovalRequest__c updatedHar = [
            SELECT Id, ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Rejected', updatedHar.ApprovalStatus__c);
        System.assert(updatedHar.ApproverComments__c.contains('Rejection processed and user notified'));

        // Verify tool result message was created for rejection
        List<ChatMessage__c> toolMessages = [
            SELECT Id, Role__c, Content__c, ToolCallId__c, IsSuccess__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :session.Id AND Role__c = 'tool'
        ];

        System.assertEquals(1, toolMessages.size());
        ChatMessage__c toolMessage = toolMessages[0];
        System.assertEquals('call_456', toolMessage.ToolCallId__c);
        System.assertEquals(false, toolMessage.IsSuccess__c); // Rejection should mark as unsuccessful

        // Verify the tool result content indicates rejection
        Map<String, Object> toolResult = (Map<String, Object>) JSON.deserializeUntyped(toolMessage.Content__c);
        System.assertEquals('rejected', toolResult.get('status'));
        System.assert(String.valueOf(toolResult.get('reason')).contains('rejected by an approver'));
        System.assert(String.valueOf(toolResult.get('reason')).contains('insufficient business justification'));
    }

    @IsTest
    static void handleAfterUpdate_multipleRecords_mixedStatuses() {
        // Setup test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        ChatSession__c session = new ChatSession__c(
            User__c = UserInfo.getUserId(),
            AIAgentDefinition__c = agent.Id,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert session;

        List<ChatMessage__c> assistantMessages = new List<ChatMessage__c>();
        for (Integer i = 1; i <= 3; i++) {
            assistantMessages.add(
                new ChatMessage__c(
                    ChatSession__c = session.Id,
                    Role__c = AIAgentConstants.ROLE_ASSISTANT,
                    Content__c = 'I will process request ' + i,
                    ExternalId__c = 'turn-' + i,
                    Timestamp__c = System.now()
                )
            );
        }
        insert assistantMessages;

        String approvedArgsJson = JSON.serialize(
            new Map<String, Object>{
                'sObjectTypes' => new List<String>{ 'Account' },
                'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
                'filters' => new Map<String, Object>{ 'Name' => 'query 1' },
                'submission_comment' => 'Request 1'
            }
        );

        List<HumanApprovalRequest__c> hars = new List<HumanApprovalRequest__c>{
            new HumanApprovalRequest__c(
                ChatSession__c = session.Id,
                OriginalAssistantMessage__c = assistantMessages[0].Id,
                LLMToolCallId__c = 'call_1',
                LLMToolName__c = 'find_sales_records',
                LLMToolArgumentsJSON__c = approvedArgsJson,
                OriginalTurnIdentifier__c = 'turn-1',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            ),
            new HumanApprovalRequest__c(
                ChatSession__c = session.Id,
                OriginalAssistantMessage__c = assistantMessages[1].Id,
                LLMToolCallId__c = 'call_2',
                LLMToolName__c = 'find_sales_records',
                LLMToolArgumentsJSON__c = '{}',
                OriginalTurnIdentifier__c = 'turn-2',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            ),
            new HumanApprovalRequest__c(
                ChatSession__c = session.Id,
                OriginalAssistantMessage__c = assistantMessages[2].Id,
                LLMToolCallId__c = 'call_3',
                LLMToolName__c = 'find_sales_records',
                LLMToolArgumentsJSON__c = '{}',
                OriginalTurnIdentifier__c = 'turn-3',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            )
        };
        insert hars;

        Account vAccount = new Account(Name = 'Test Account 1');
        insert vAccount;
        Test.setFixedSearchResults(new List<Id>{ vAccount.Id });

        Test.startTest();
        hars[0].ApprovalStatus__c = 'Approved';
        hars[0].ApproverComments__c = 'Approved - good business case';
        hars[1].ApprovalStatus__c = 'Rejected';
        hars[1].ApproverComments__c = 'Rejected - security concerns';
        hars[2].ApproverComments__c = 'Under review';
        update hars;
        Test.stopTest();

        List<HumanApprovalRequest__c> updatedHars = [
            SELECT Id, ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            ORDER BY LLMToolCallId__c ASC
        ];

        System.assertEquals('Approved', updatedHars[0].ApprovalStatus__c);
        System.assert(updatedHars[0].ApproverComments__c.contains('Action completed successfully'));

        System.assertEquals('Rejected', updatedHars[1].ApprovalStatus__c);
        System.assert(updatedHars[1].ApproverComments__c.contains('Rejection processed and user notified'));

        System.assertEquals('Pending', updatedHars[2].ApprovalStatus__c);
    }

    @IsTest
    static void handleAfterUpdate_noStatusChange_noProcessing() {
        // Setup test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        ChatSession__c session = new ChatSession__c(
            User__c = UserInfo.getUserId(),
            AIAgentDefinition__c = agent.Id,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert session;

        ChatMessage__c assistantMessage = new ChatMessage__c(
            ChatSession__c = session.Id,
            Role__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will search for sales records.',
            ExternalId__c = 'turn-789',
            Timestamp__c = System.now()
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = session.Id,
            OriginalAssistantMessage__c = assistantMessage.Id,
            LLMConfirmationMessage__c = 'User requested sales records search',
            LLMToolCallId__c = 'call_789',
            LLMToolName__c = 'find_sales_records',
            LLMToolArgumentsJSON__c = '{"searchQuery":"test query","submission_comment":"Business analysis"}',
            OriginalTurnIdentifier__c = 'turn-789',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        Test.startTest();
        // Update record without changing approval status
        har.ApproverComments__c = 'Under review by manager';
        update har;
        Test.stopTest();

        // Verify no processing occurred
        HumanApprovalRequest__c updatedHar = [
            SELECT Id, ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Pending', updatedHar.ApprovalStatus__c);
        System.assertEquals('Under review by manager', updatedHar.ApproverComments__c);

        // Verify no tool messages were created
        List<ChatMessage__c> toolMessages = [
            SELECT Id
            FROM ChatMessage__c
            WHERE ChatSession__c = :session.Id AND Role__c = 'tool'
        ];

        System.assertEquals(0, toolMessages.size());
    }

    @IsTest
    static void handleAfterUpdate_invalidCapability_errorHandling() {
        // Setup test data with invalid capability name
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        ChatSession__c session = new ChatSession__c(
            User__c = UserInfo.getUserId(),
            AIAgentDefinition__c = agent.Id,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert session;

        ChatMessage__c assistantMessage = new ChatMessage__c(
            ChatSession__c = session.Id,
            Role__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will execute invalid action.',
            ExternalId__c = 'turn-error',
            Timestamp__c = System.now()
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = session.Id,
            OriginalAssistantMessage__c = assistantMessage.Id,
            LLMConfirmationMessage__c = 'User requested invalid action',
            LLMToolCallId__c = 'call_error',
            LLMToolName__c = 'invalid_capability_name', // This capability doesn't exist
            LLMToolArgumentsJSON__c = '{"param":"value"}',
            OriginalTurnIdentifier__c = 'turn-error',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        Test.startTest();
        // Approve the request with invalid capability
        har.ApprovalStatus__c = 'Approved';
        har.ApproverComments__c = 'Approved without knowing capability is invalid';
        update har;
        Test.stopTest();

        // Verify error handling occurred
        HumanApprovalRequest__c updatedHar = [
            SELECT Id, ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Error', updatedHar.ApprovalStatus__c);
        System.assert(updatedHar.ApproverComments__c.contains('Exception during resume'));
        System.assert(updatedHar.ApproverComments__c.contains('invalid_capability_name'));
    }

    @IsTest
    static void handleAfterUpdate_emptyList_noProcessing() {
        Test.startTest();
        // Call handler with empty list
        HumanApprovalRequestTriggerHandler.handleAfterUpdate(new List<HumanApprovalRequest__c>(), new Map<Id, HumanApprovalRequest__c>());
        Test.stopTest();

        // No assertions needed - just verify no exceptions are thrown
        System.assert(true, 'Handler should handle empty lists gracefully');
    }
}
