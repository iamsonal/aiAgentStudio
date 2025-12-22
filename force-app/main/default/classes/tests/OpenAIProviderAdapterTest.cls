/**
 * @description Tests for OpenAIProviderAdapter
 */
@IsTest
private class OpenAIProviderAdapterTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
    }

    // ===================================================================================
    // SEND MESSAGE - SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSendMessage_TextResponse_Success() {
        // Given: Mock HTTP response for text
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        TestFactory.AgentSetup setup = getTestSetup();
        List<Map<String, Object>> messages = createMessages('Hello!');

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();

        // When: Sending message
        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, setup.llmConfig, setup.agentDefinition);
        Test.stopTest();

        // Then: Should return success result
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.content);
    }

    @IsTest
    static void testSendMessage_ToolCallResponse_Success() {
        // Given: Mock HTTP response for tool call
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCall('find_records'));

        TestFactory.AgentSetup setup = getTestSetup();
        List<Map<String, Object>> messages = createMessages('Find my accounts');
        List<Map<String, Object>> tools = createTools();

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();

        // When: Sending message with tools
        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, tools, setup.llmConfig, setup.agentDefinition);
        Test.stopTest();

        // Then: Should return tool call result
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.requestedActions);
        System.assert(!result.requestedActions.isEmpty(), 'Should have requested actions');
    }

    @IsTest
    static void testSendMessage_WithParallelToolsEnabled_Success() {
        // Given: Agent with parallel tools enabled
        TestFactory.AgentSetup setup = getTestSetup();
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, EnableParallelToolCalling__c = true);

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.parallelToolCalls());

        AIAgentDefinition__c agent = [
            SELECT Id, EnableParallelToolCalling__c
            FROM AIAgentDefinition__c
            WHERE Id = :setup.agentDefinition.Id
        ];

        List<Map<String, Object>> messages = createMessages('Find accounts and contacts');
        List<Map<String, Object>> tools = createTools();

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();

        // When: Sending message
        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, tools, setup.llmConfig, agent);
        Test.stopTest();

        // Then: Should return result
        System.assertNotEquals(null, result);
    }

    // ===================================================================================
    // SEND MESSAGE - FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSendMessage_RateLimitError_ThrowsException() {
        // Given: Mock rate limit error
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.rateLimitError());

        TestFactory.AgentSetup setup = getTestSetup();
        List<Map<String, Object>> messages = createMessages('Test');

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        Boolean exceptionThrown = false;

        // When: Sending message with rate limit
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, setup.llmConfig, setup.agentDefinition);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw AIAgentException.ProviderException');
    }

    @IsTest
    static void testSendMessage_AuthError_ThrowsException() {
        // Given: Mock auth error
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.authError());

        TestFactory.AgentSetup setup = getTestSetup();
        List<Map<String, Object>> messages = createMessages('Test');

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        Boolean exceptionThrown = false;

        // When: Sending message with auth error
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, setup.llmConfig, setup.agentDefinition);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw AIAgentException.ProviderException');
    }

    @IsTest
    static void testSendMessage_MalformedJson_ThrowsException() {
        // Given: Mock malformed JSON response
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.malformedJson());

        TestFactory.AgentSetup setup = getTestSetup();
        List<Map<String, Object>> messages = createMessages('Test');

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        Boolean exceptionThrown = false;

        // When: Sending message with malformed response
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, setup.llmConfig, setup.agentDefinition);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        // Then: Should throw exception
        System.assert(exceptionThrown, 'Should throw AIAgentException.ProviderException');
    }

    // ===================================================================================
    // ADDITIONAL SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSendMessage_WithTemperature_Success() {
        // Given: LLM config with temperature setting
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        TestFactory.AgentSetup setup = getTestSetup();

        // Update LLM config with specific temperature
        update new LLMConfiguration__c(Id = setup.llmConfig.Id, DefaultTemperature__c = 0.5);

        LLMConfiguration__c llmConfig = [
            SELECT Id, NamedCredential__c, DefaultModelIdentifier__c, DefaultTemperature__c
            FROM LLMConfiguration__c
            WHERE Id = :setup.llmConfig.Id
        ];

        List<Map<String, Object>> messages = createMessages('Test with temperature');

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();

        // When: Sending message with temperature
        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llmConfig, setup.agentDefinition);
        Test.stopTest();

        // Then: Should return result
        System.assertNotEquals(null, result);
        System.assertNotEquals(null, result.content);
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testOpenAIParseException_CanBeThrown() {
        Test.startTest();
        try {
            throw new OpenAIProviderAdapter.OpenAIParseException('Test parse exception');
        } catch (OpenAIProviderAdapter.OpenAIParseException e) {
            System.assertEquals('Test parse exception', e.getMessage());
        }
        Test.stopTest();
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    private static TestFactory.AgentSetup getTestSetup() {
        AIAgentDefinition__c agent = [SELECT Id, EnableParallelToolCalling__c FROM AIAgentDefinition__c LIMIT 1];
        LLMConfiguration__c llm = [
            SELECT Id, NamedCredential__c, DefaultModelIdentifier__c, DefaultTemperature__c
            FROM LLMConfiguration__c
            LIMIT 1
        ];

        TestFactory.AgentSetup setup = new TestFactory.AgentSetup();
        setup.agentDefinition = agent;
        setup.llmConfig = llm;

        return setup;
    }

    private static List<Map<String, Object>> createMessages(String content) {
        return new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => content } };
    }

    private static List<Map<String, Object>> createTools() {
        return new List<Map<String, Object>>{
            new Map<String, Object>{
                'type' => 'function',
                'function' => new Map<String, Object>{
                    'name' => 'find_records',
                    'description' => 'Find records',
                    'parameters' => new Map<String, Object>{
                        'type' => 'object',
                        'properties' => new Map<String, Object>{ 'searchQuery' => new Map<String, Object>{ 'type' => 'string' } }
                    }
                }
            }
        };
    }
}
