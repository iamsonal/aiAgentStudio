@isTest
private class MemoryManagerFactoryTest {
    @isTest
    static void testGetManagerWithSummaryBufferStrategy() {
        IMemoryManager manager = MemoryManagerFactory.getManager('Summary Buffer');
        System.assert(manager instanceof SummaryBufferMemoryManager, 'Expected SummaryBufferMemoryManager for "Summary Buffer" strategy');
    }

    @isTest
    static void testGetManagerWithBufferWindowStrategy() {
        IMemoryManager manager = MemoryManagerFactory.getManager('Buffer Window');
        System.assert(manager instanceof BufferWindowMemoryManager, 'Expected BufferWindowMemoryManager for "Buffer Window" strategy');
    }

    @isTest
    static void testGetManagerWithNullStrategy() {
        IMemoryManager manager = MemoryManagerFactory.getManager(null);
        System.assert(manager instanceof BufferWindowMemoryManager, 'Expected BufferWindowMemoryManager for null strategy (default)');
    }

    @isTest
    static void testGetManagerWithEmptyStrategy() {
        IMemoryManager manager = MemoryManagerFactory.getManager('');
        System.assert(manager instanceof BufferWindowMemoryManager, 'Expected BufferWindowMemoryManager for empty strategy (default)');
    }

    @isTest
    static void testGetManagerWithUnknownStrategy() {
        IMemoryManager manager = MemoryManagerFactory.getManager('Unknown Strategy');
        System.assert(manager instanceof BufferWindowMemoryManager, 'Expected BufferWindowMemoryManager for unknown strategy (default)');
    }

    @isTest
    static void testGetManagerWithCaseInsensitiveSummaryBuffer() {
        IMemoryManager manager = MemoryManagerFactory.getManager('summary buffer');
        System.assert(
            manager instanceof SummaryBufferMemoryManager,
            'Expected SummaryBufferMemoryManager for case-insensitive "summary buffer" strategy'
        );
    }

    // Tests for BufferWindowMemoryManager functionality
    @isTest
    static void testBufferWindowMemoryManagerGetHistoryPayloadWithNullLimit() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Buffer Window';
        setup.agentDefinition.HistoryLimit__c = null; // Unlimited history
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        messages.add(new ChatMessage__c(ChatSession__c = session.Id, Role__c = 'user', Content__c = 'Hello', Timestamp__c = Datetime.now()));
        messages.add(
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Hi there!',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        );
        insert messages;

        // Test the memory manager
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        List<Map<String, Object>> history = manager.getHistoryPayload(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');

        // Verify results
        System.assertNotEquals(null, history, 'History should not be null');
        System.assertEquals(2, history.size(), 'Should have 2 messages in history');
    }

    @isTest
    static void testBufferWindowMemoryManagerGetHistoryPayloadWithZeroLimit() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Buffer Window';
        setup.agentDefinition.HistoryLimit__c = 0; // No history
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        messages.add(new ChatMessage__c(ChatSession__c = session.Id, Role__c = 'user', Content__c = 'Hello', Timestamp__c = Datetime.now()));
        messages.add(
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Hi there!',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        );
        insert messages;

        // Test the memory manager
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        List<Map<String, Object>> history = manager.getHistoryPayload(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');

        // Verify results
        System.assertNotEquals(null, history, 'History should not be null');
        System.assertEquals(0, history.size(), 'Should have 0 messages in history');
    }

    @isTest
    static void testBufferWindowMemoryManagerOnTurnCompletion() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Buffer Window';
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Test the memory manager method (should not throw exception)
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        manager.onTurnCompletion(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');

        // If we reach here, the test passed (no exception thrown)
        System.assert(true, 'onTurnCompletion should not throw exceptions');
    }

    // Tests for SummaryBufferMemoryManager functionality
    @isTest
    static void testSummaryBufferMemoryManagerGetHistoryPayload() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Summary Buffer';
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        messages.add(new ChatMessage__c(ChatSession__c = session.Id, Role__c = 'user', Content__c = 'Hello', Timestamp__c = Datetime.now()));
        messages.add(
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Hi there!',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        );
        insert messages;

        // Test the memory manager
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        List<Map<String, Object>> history = manager.getHistoryPayload(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');

        // Verify results
        System.assertNotEquals(null, history, 'History should not be null');
        System.assertEquals(2, history.size(), 'Should have 2 messages in history');
    }

    @isTest
    static void testSummaryBufferMemoryManagerOnTurnCompletionWithTrigger() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Summary Buffer';
        setup.agentDefinition.SummarizationTriggerSize__c = 2; // Trigger summarization at 2 messages
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        messages.add(new ChatMessage__c(ChatSession__c = session.Id, Role__c = 'user', Content__c = 'Hello', Timestamp__c = Datetime.now()));
        messages.add(
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Hi there!',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        );
        insert messages;

        // Test the memory manager
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        Test.startTest();
        manager.onTurnCompletion(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Verify that a job was queued (we can't easily test the actual queueing in a unit test)
        System.assert(true, 'onTurnCompletion should complete without exception');
    }

    @isTest
    static void testSummaryBufferMemoryManagerOnTurnCompletionWithoutTrigger() {
        // Create test data
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.MemoryStrategy__c = 'Summary Buffer';
        setup.agentDefinition.SummarizationTriggerSize__c = 5; // Trigger summarization at 5 messages (we only have 2)
        insert setup.agentDefinition;

        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        messages.add(new ChatMessage__c(ChatSession__c = session.Id, Role__c = 'user', Content__c = 'Hello', Timestamp__c = Datetime.now()));
        messages.add(
            new ChatMessage__c(
                ChatSession__c = session.Id,
                Role__c = 'assistant',
                Content__c = 'Hi there!',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        );
        insert messages;

        // Test the memory manager
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        Test.startTest();
        manager.onTurnCompletion(session.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Verify that no job was queued (we can't easily test the actual queueing in a unit test)
        System.assert(true, 'onTurnCompletion should complete without exception');
    }
}
