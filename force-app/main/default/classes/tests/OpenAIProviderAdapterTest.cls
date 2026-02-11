/**
 * @description Tests for OpenAIProviderAdapter request/response handling.
 */
@IsTest
private class OpenAIProviderAdapterTest {
    private static HttpRequest lastRequest;

    private class CapturingMock implements HttpCalloutMock {
        private final Integer statusCode;
        private final String responseBody;

        public CapturingMock(Integer statusCode, String responseBody) {
            this.statusCode = statusCode;
            this.responseBody = responseBody;
        }

        public HttpResponse respond(HttpRequest req) {
            OpenAIProviderAdapterTest.lastRequest = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(responseBody);
            return res;
        }
    }

    @IsTest
    static void testSendMessage_BuildsRequestWithToolsParallelFlag() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().build();
        llm.TimeoutMs__c = 30000;
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();
        agent.EnableParallelToolCalling__c = true;

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Hello' } };
        List<Map<String, Object>> tools = new List<Map<String, Object>>{
            new Map<String, Object>{
                'type' => 'function',
                'function' => new Map<String, Object>{
                    'name' => 'find_records',
                    'description' => 'Find records',
                    'parameters' => new Map<String, Object>{ 'type' => 'object', 'properties' => new Map<String, Object>() }
                }
            }
        };

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'));

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        ProviderResult result = adapter.sendMessage(messages, tools, llm, agent);

        System.assertNotEquals(null, result, 'Should return provider result');
        System.assertNotEquals(null, lastRequest, 'Request should be captured');

        HttpRequest req = lastRequest;
        System.assertEquals('POST', req.getMethod(), 'Request method should be POST');
        System.assertEquals('application/json; charset=utf-8', req.getHeader('Content-Type'), 'Content-Type should be JSON');
        System.assert(req.getEndpoint().contains('/v1/chat/completions'), 'Endpoint should target chat completions');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
        System.assertEquals(llm.DefaultModelIdentifier__c, body.get('model'), 'Model should come from config');
        System.assertEquals('auto', body.get('tool_choice'), 'Tool choice should be auto when tools provided');
        System.assertEquals(true, body.get('parallel_tool_calls'), 'Parallel tool calls should be enabled');

        List<Object> bodyTools = (List<Object>) body.get('tools');
        System.assertEquals(1, bodyTools.size(), 'Tools should be included');
    }

    @IsTest
    static void testSendMessage_ParsesTextAndUsage() {
        String responseBody =
            '{"choices":[{"message":{"role":"assistant","content":"Hello there"}}],' + '"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}';

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, responseBody));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().build();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Hello' } };

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);

        System.assertEquals('Hello there', result.content, 'Should parse assistant content');
        System.assertEquals(10, result.promptTokens, 'Should parse prompt tokens');
        System.assertEquals(20, result.completionTokens, 'Should parse completion tokens');
        System.assertEquals(30, result.totalTokens, 'Should parse total tokens');
        System.assertEquals(llm.DefaultModelIdentifier__c, result.modelIdentifier, 'Should set model identifier');
        System.assertNotEquals(null, result.rawAssistantMessageWithActionsJson, 'Raw assistant message should be captured');
    }

    @IsTest
    static void testSendMessage_ParsesToolCalls() {
        String responseBody =
            '{"choices":[{"message":{"role":"assistant","content":null,' +
            '"tool_calls":[{"id":"call_1","type":"function","function":{"name":"find_records","arguments":"{\\"q\\":\\"test\\"}"}}]}}]}';

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, responseBody));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().build();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Find records' } };

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);

        System.assertEquals(1, result.requestedActions.size(), 'Should parse tool calls');
        System.assertEquals('find_records', result.requestedActions[0].get('name'), 'Tool name should be parsed');
        System.assertNotEquals(null, result.rawToolCallsJson, 'Raw tool calls JSON should be captured');
    }

    @IsTest
    static void testSendMessage_MissingChoicesThrows() {
        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, '{"id":"no-choices"}'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().build();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Hello' } };

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        Boolean exceptionThrown = false;
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Failed to parse OpenAI response'), 'Should throw provider exception');
        }
        System.assert(exceptionThrown, 'Expected ProviderException for missing choices');
    }
}
