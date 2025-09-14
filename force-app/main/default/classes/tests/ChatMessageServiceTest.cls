@isTest
private class ChatMessageServiceTest {
    @TestSetup
    static void makeData() {
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @isTest
    static void testGetHistoryWithNullSessionId() {
        List<ChatMessage__c> result = ChatMessageService.getHistory(null, 10, 'ASC', null);
        System.assertEquals(new List<ChatMessage__c>(), result);
    }

    @isTest
    static void testGetHistoryWithValidSession() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Add some test messages
        List<ChatMessage__c> testMessages = new List<ChatMessage__c>{
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'user',
                Content__c = 'Test message 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = DateTime.now()
            ),
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Test response 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = DateTime.now().addSeconds(1)
            )
        };
        insert testMessages;

        // Test retrieval
        List<ChatMessage__c> result = ChatMessageService.getHistory(session.Id, 10, 'ASC', null);
        System.assertEquals(2, result.size());
        System.assertEquals('Test message 1', result[0].Content__c);
        System.assertEquals('Test response 1', result[1].Content__c);
    }

    @isTest
    static void testSaveMessages() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create test messages
        List<ChatMessage__c> testMessages = new List<ChatMessage__c>{
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'user',
                Content__c = 'Test message 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = Datetime.now()
            ),
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Test response 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = Datetime.now()
            )
        };

        Test.startTest();
        List<Database.SaveResult> results = ChatMessageService.saveMessages(testMessages);
        Test.stopTest();

        System.assertEquals(2, results.size());
        System.assert(results[0].isSuccess());
        System.assert(results[1].isSuccess());
    }

    @isTest
    static void testSaveMessagesWithNullInput() {
        List<Database.SaveResult> results = ChatMessageService.saveMessages(null);
        System.assertEquals(new List<Database.SaveResult>(), results);

        results = ChatMessageService.saveMessages(new List<ChatMessage__c>());
        System.assertEquals(new List<Database.SaveResult>(), results);
    }

    @isTest
    static void testSaveUserMessage() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create user message data
        LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
        userMessageData.role = 'user';
        userMessageData.content = 'Test user message';

        Test.startTest();
        Id messageId = ChatMessageService.saveUserMessage(session.Id, 'test-turn-id', userMessageData, null, '[Test] ');
        Test.stopTest();

        System.assert(messageId != null);

        // Verify the message was saved
        ChatMessage__c savedMessage = [SELECT Id, Role__c, Content__c FROM ChatMessage__c WHERE Id = :messageId];
        System.assertEquals('user', savedMessage.Role__c);
        System.assertEquals('Test user message', savedMessage.Content__c);
    }

    @isTest
    static void testSaveAssistantMessage() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create assistant message data
        LLMInteractionService.MessageData assistantMessageData = new LLMInteractionService.MessageData();
        assistantMessageData.role = 'assistant';
        assistantMessageData.content = 'Test assistant message';

        Test.startTest();
        Id messageId = ChatMessageService.saveAssistantMessage(
            session.Id,
            'test-turn-id',
            null, // parent user message ID
            assistantMessageData,
            'TestCapability',
            '[Test] '
        );
        Test.stopTest();

        System.assert(messageId != null);

        // Verify the message was saved
        ChatMessage__c savedMessage = [SELECT Id, Role__c, Content__c, CapabilityName__c FROM ChatMessage__c WHERE Id = :messageId];
        System.assertEquals('assistant', savedMessage.Role__c);
        System.assertEquals('Test assistant message', savedMessage.Content__c);
        System.assertEquals('TestCapability', savedMessage.CapabilityName__c);
    }

    @isTest
    static void testSaveToolResultMessage() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Create a parent assistant message
        ChatMessage__c assistantMessage = new ChatMessage__c(
            ChatSession__c = session.Id,
            Role__c = 'assistant',
            Content__c = 'Test assistant message',
            TurnIdentifier__c = 'test-turn-id',
            Timestamp__c = Datetime.now()
        );
        insert assistantMessage;

        Test.startTest();
        Id messageId = ChatMessageService.saveToolResultMessage(
            session.Id,
            'test-turn-id',
            assistantMessage.Id,
            'test-tool-call-id',
            '{"result": "test"}',
            'Internal details',
            null, // no error
            100L, // duration
            null, // record context ID
            null, // record context data
            'TestCapability',
            '[Test] '
        );
        Test.stopTest();

        System.assert(messageId != null);

        // Verify the message was saved
        ChatMessage__c savedMessage = [
            SELECT Id, Role__c, Content__c, ToolCallId__c, CapabilityName__c, IsSuccess__c
            FROM ChatMessage__c
            WHERE Id = :messageId
        ];
        System.assertEquals('tool', savedMessage.Role__c);
        System.assertEquals('{"result": "test"}', savedMessage.Content__c);
        System.assertEquals('test-tool-call-id', savedMessage.ToolCallId__c);
        System.assertEquals('TestCapability', savedMessage.CapabilityName__c);
        System.assertEquals(true, savedMessage.IsSuccess__c);
    }

    @isTest
    static void testPersistenceException() {
        ChatMessageService.PersistenceException ex = new ChatMessageService.PersistenceException('Test message');
        System.assertEquals('Test message', ex.getMessage());
    }

    @isTest
    static void testGetHistoryWithCompleteTurns() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        // Add messages from the same turn
        List<ChatMessage__c> testMessages = new List<ChatMessage__c>{
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'user',
                Content__c = 'Test message 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = DateTime.now()
            ),
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Test response 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = DateTime.now().addSeconds(1)
            ),
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'tool',
                Content__c = 'Test tool result 1',
                TurnIdentifier__c = 'turn-1',
                Timestamp__c = DateTime.now().addSeconds(2)
            )
        };
        insert testMessages;

        // Test retrieval with complete turns
        List<ChatMessage__c> result = ChatMessageService.getHistoryWithCompleteTurns(
            session.Id,
            1, // base limit
            'ASC',
            false
        );

        // Should return all messages from the turn even though limit is 1
        System.assertEquals(3, result.size());
    }
}
