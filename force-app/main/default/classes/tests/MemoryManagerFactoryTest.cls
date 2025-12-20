/**
 * @description Tests for memory manager selection (now part of ContextManagerService)
 */
@IsTest
private class MemoryManagerFactoryTest {
    // ===================================================================================
    // MEMORY MANAGER SELECTION TESTS (Consolidated into ContextManagerService)
    // ===================================================================================

    @IsTest
    static void testGetManager_SummaryBuffer_ReturnsCorrectManager() {
        IMemoryManager manager = ContextManagerService.getMemoryManager('Summary Buffer');
        System.assert(manager instanceof SummaryBufferMemoryManager);
    }

    @IsTest
    static void testGetManager_BufferWindow_ReturnsCorrectManager() {
        IMemoryManager manager = ContextManagerService.getMemoryManager('Buffer Window');
        System.assert(manager instanceof BufferWindowMemoryManager);
    }

    @IsTest
    static void testGetManager_Null_ReturnsDefault() {
        IMemoryManager manager = ContextManagerService.getMemoryManager(null);
        System.assert(manager instanceof BufferWindowMemoryManager);
    }

    @IsTest
    static void testGetManager_Empty_ReturnsDefault() {
        IMemoryManager manager = ContextManagerService.getMemoryManager('');
        System.assert(manager instanceof BufferWindowMemoryManager);
    }

    @IsTest
    static void testGetManager_Unknown_ReturnsDefault() {
        IMemoryManager manager = ContextManagerService.getMemoryManager('Unknown Strategy');
        System.assert(manager instanceof BufferWindowMemoryManager);
    }

    @IsTest
    static void testGetManager_CaseInsensitive_Works() {
        IMemoryManager manager = ContextManagerService.getMemoryManager('summary buffer');
        System.assert(manager instanceof SummaryBufferMemoryManager);
    }

    // ===================================================================================
    // BUFFER WINDOW MEMORY MANAGER TESTS
    // ===================================================================================

    @IsTest
    static void testBufferWindow_GetHistoryPayload_WithNullLimit() {
        // Given: Setup with unlimited history
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Buffer Window').withHistoryTurnLimit(null).save();

        // Create messages
        List<ExecutionStep__c> messages = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'user',
                Content__c = 'Hello',
                StepType__c = 'UserInput',
                Timestamp__c = Datetime.now()
            ),
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'assistant',
                Content__c = 'Hi there!',
                StepType__c = 'AgentResponse',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        };
        insert messages;

        // When: Getting history
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        Test.startTest();
        List<Map<String, Object>> history = manager.getHistoryPayload(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should return all messages
        System.assertNotEquals(null, history);
        System.assertEquals(2, history.size());
    }

    @IsTest
    static void testBufferWindow_GetHistoryPayload_WithZeroLimit() {
        // Given: Setup with zero limit
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Buffer Window').withHistoryTurnLimit(0).save();

        // Create messages
        List<ExecutionStep__c> messages = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'user',
                Content__c = 'Hello',
                StepType__c = 'UserInput',
                Timestamp__c = Datetime.now()
            )
        };
        insert messages;

        // When: Getting history
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        Test.startTest();
        List<Map<String, Object>> history = manager.getHistoryPayload(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should return no messages
        System.assertNotEquals(null, history);
        System.assertEquals(0, history.size());
    }

    @IsTest
    static void testBufferWindow_OnTurnCompletion_DoesNotThrow() {
        // Given: Setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Buffer Window').save();

        // When: Calling onTurnCompletion
        BufferWindowMemoryManager manager = new BufferWindowMemoryManager();
        Test.startTest();
        manager.onTurnCompletion(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true);
    }

    // ===================================================================================
    // SUMMARY BUFFER MEMORY MANAGER TESTS
    // ===================================================================================

    @IsTest
    static void testSummaryBuffer_GetHistoryPayload_ReturnsMessages() {
        // Given: Setup with summary buffer
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Summary Buffer').save();

        // Create messages
        List<ExecutionStep__c> messages = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'user',
                Content__c = 'Hello',
                StepType__c = 'UserInput',
                Timestamp__c = Datetime.now()
            ),
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'assistant',
                Content__c = 'Hi!',
                StepType__c = 'AgentResponse',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        };
        insert messages;

        // When: Getting history
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        Test.startTest();
        List<Map<String, Object>> history = manager.getHistoryPayload(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should return messages
        System.assertNotEquals(null, history);
        System.assertEquals(2, history.size());
    }

    @IsTest
    static void testSummaryBuffer_OnTurnCompletion_WithTrigger() {
        // Given: Setup with summarization trigger
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Summary Buffer').save();

        setup.agentDefinition.SummarizationTriggerTurnCount__c = 2;
        update setup.agentDefinition;

        // Create messages
        List<ExecutionStep__c> messages = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'user',
                Content__c = 'Hello',
                StepType__c = 'UserInput',
                Timestamp__c = Datetime.now()
            ),
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'assistant',
                Content__c = 'Hi!',
                StepType__c = 'AgentResponse',
                Timestamp__c = Datetime.now().addSeconds(1)
            )
        };
        insert messages;

        // When: Calling onTurnCompletion
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        Test.startTest();
        manager.onTurnCompletion(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true);
    }

    @IsTest
    static void testSummaryBuffer_OnTurnCompletion_WithoutTrigger() {
        // Given: Setup without summarization trigger
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withMemoryStrategy('Summary Buffer').save();

        setup.agentDefinition.SummarizationTriggerTurnCount__c = 5;
        update setup.agentDefinition;

        // Create minimal messages
        List<ExecutionStep__c> messages = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepRole__c = 'user',
                Content__c = 'Hello',
                StepType__c = 'UserInput',
                Timestamp__c = Datetime.now()
            )
        };
        insert messages;

        // When: Calling onTurnCompletion
        SummaryBufferMemoryManager manager = new SummaryBufferMemoryManager();
        Test.startTest();
        manager.onTurnCompletion(setup.agentExecution.Id, setup.agentDefinition, setup.llmConfig, 'Test: ');
        Test.stopTest();

        // Then: Should complete without error
        System.assert(true);
    }
}
