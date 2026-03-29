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
    static void testSendMessage_ParallelSuppressedWithSingleTool() {
        // Even when EnableParallelToolCalling__c = true, parallel_tool_calls must be false
        // when only one tool is available — prevents models like gpt-4o-mini from
        // hallucinating duplicate calls to fill parallel slots.
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
        HttpRequest req = lastRequest;
        System.assertEquals('POST', req.getMethod(), 'Request method should be POST');
        System.assertEquals('application/json; charset=utf-8', req.getHeader('Content-Type'), 'Content-Type should be JSON');
        System.assert(req.getEndpoint().contains('/v1/chat/completions'), 'Endpoint should target chat completions');

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
        System.assertEquals('gpt-4o-mini', body.get('model'), 'Model should come from the selected catalog metadata');
        System.assertEquals('auto', body.get('tool_choice'), 'Tool choice should be auto when tools provided');
        System.assertEquals(false, body.get('parallel_tool_calls'), 'Parallel tool calls must be false with a single tool');

        List<Object> bodyTools = (List<Object>) body.get('tools');
        System.assertEquals(1, bodyTools.size(), 'Single tool should be included');
    }

    @IsTest
    static void testSendMessage_UsesConfiguredMaxTokensParameterFromModelCatalog() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withModel('gpt-5-mini').build();
        llm.TimeoutMs__c = 30000;
        llm.MaxResponseTokens__c = 512;
        llm.DefaultTemperature__c = 0.10;
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Hello' } };

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'));

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        adapter.sendMessage(messages, null, llm, agent);

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(lastRequest.getBody());
        System.assertEquals(512, body.get('max_completion_tokens'), 'Model catalog should drive max_completion_tokens for GPT-5 mini');
        System.assertEquals(null, body.get('max_tokens'), 'Configured token parameter should replace the default token field');
        System.assertEquals(0.10, body.get('temperature'), 'Temperature should now come directly from the LLM configuration');
    }

    @IsTest
    static void testSendMessage_UsesConfiguredMaxTokensParameterForGpt4oMini() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withModel('gpt-4o-mini').build();
        llm.TimeoutMs__c = 30000;
        llm.MaxResponseTokens__c = 256;
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'Hello' } };

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'));

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        adapter.sendMessage(messages, null, llm, agent);

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(lastRequest.getBody());
        System.assertEquals(256, body.get('max_tokens'), 'GPT-4o mini should explicitly use the configured max_tokens parameter');
        System.assertEquals(null, body.get('max_completion_tokens'), 'Only the configured token parameter should be sent');
    }

    @IsTest
    static void testNormalizePromptSafetyPreset_BlankDefaultsToStandard() {
        System.assertEquals(BaseProviderAdapter.PRESET_STANDARD, BaseProviderAdapter.normalizePromptSafetyPreset(null));
        System.assertEquals(BaseProviderAdapter.PRESET_STANDARD, BaseProviderAdapter.normalizePromptSafetyPreset(''));
        System.assertEquals(BaseProviderAdapter.PRESET_OFF, BaseProviderAdapter.normalizePromptSafetyPreset('Off'));
        System.assertEquals(BaseProviderAdapter.FAILURE_MODE_FAIL_OPEN, BaseProviderAdapter.normalizePromptSafetyFailureMode(null));
        System.assertEquals(BaseProviderAdapter.FAILURE_MODE_FAIL_CLOSED, BaseProviderAdapter.normalizePromptSafetyFailureMode('Fail Closed'));
    }

    @IsTest
    static void testCheckMessageSafety_FailClosedBlocksOnModerationOutage() {
        Test.setMock(HttpCalloutMock.class, new CapturingMock(500, '{"error":"temporarily unavailable"}'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().build();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();
        agent.PromptSafetyPreset__c = 'Standard';
        agent.PromptSafetyFailureMode__c = 'Fail Closed';

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        ThreatAssessment assessment = adapter.checkMessageSafety('Review this prompt', llm, agent);

        System.assertNotEquals(null, assessment, 'Moderation outage should still return an assessment');
        System.assertEquals(true, assessment.shouldBlock(), 'Fail Closed should block when moderation cannot be completed');
    }

    @IsTest
    static void testSendMessage_ParallelEnabledWithMultipleTools() {
        // parallel_tool_calls should be true only when the agent setting is on AND 2+ tools are present.
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
            },
            new Map<String, Object>{
                'type' => 'function',
                'function' => new Map<String, Object>{
                    'name' => 'update_record',
                    'description' => 'Update a record',
                    'parameters' => new Map<String, Object>{ 'type' => 'object', 'properties' => new Map<String, Object>() }
                }
            }
        };

        Test.setMock(HttpCalloutMock.class, new CapturingMock(200, '{"choices":[{"message":{"role":"assistant","content":"ok"}}]}'));

        OpenAIProviderAdapter adapter = new OpenAIProviderAdapter();
        adapter.sendMessage(messages, tools, llm, agent);

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(lastRequest.getBody());
        System.assertEquals(true, body.get('parallel_tool_calls'), 'Parallel tool calls should be enabled with 2+ tools');
        System.assertEquals(2, ((List<Object>) body.get('tools')).size(), 'Both tools should be included');
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
        System.assertEquals('gpt-4o-mini', result.modelIdentifier, 'Should set model identifier from catalog metadata');
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
