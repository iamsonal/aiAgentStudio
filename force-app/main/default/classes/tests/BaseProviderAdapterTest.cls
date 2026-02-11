/**
 * @description Tests for BaseProviderAdapter through public sendMessage API
 */
@IsTest
private class BaseProviderAdapterTest {
    /**
     * Test adapter implementation for testing base class functionality
     */
    private class TestProviderAdapter extends BaseProviderAdapter {
        public Boolean shouldThrowProviderException = false;
        public Boolean shouldReturnInvalidResponse = false;
        public Boolean shouldTestHelperMethods = false;

        protected override String getLogPrefix() {
            return '[TestAdapter] ';
        }

        protected override HttpRequest buildProviderRequest(
            LLMConfiguration__c llmConfig,
            List<Map<String, Object>> messagesPayload,
            List<Map<String, Object>> toolsPayload,
            AIAgentDefinition__c agentConfig
        ) {
            // Validate config and messages first (same as real implementations)
            validateConfiguration(llmConfig);
            validateMessages(messagesPayload);

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + llmConfig.NamedCredential__c + '/v1/chat/completions');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setBody('{"messages":' + JSON.serialize(messagesPayload) + '}');
            return req;
        }

        protected override ProviderResult parseProviderResponse(String responseBody, String modelIdentifier, Long durationMs) {
            if (shouldThrowProviderException) {
                throw new AIAgentException.ProviderException('Simulated provider error');
            }
            if (shouldReturnInvalidResponse) {
                throw new AIAgentException.ProviderException('Invalid response structure');
            }

            ProviderResult result = new ProviderResult();

            // When testing helper methods, parse the JSON and use getStringValue/getIntegerValue
            if (shouldTestHelperMethods) {
                Map<String, Object> parsed = parseJsonResponse(responseBody, getLogPrefix());

                // Test getStringValue with various scenarios
                result.content = getStringValue(parsed, 'content', 'default_content');
                result.modelIdentifier = getStringValue(parsed, 'model', modelIdentifier);
                String stopReason = getStringValue(parsed, 'stop_reason', 'end_turn');

                // Test getIntegerValue with various scenarios
                Integer promptTokens = getIntegerValue(parsed, 'prompt_tokens', 0);
                Integer completionTokens = getIntegerValue(parsed, 'completion_tokens', 0);
                Integer maxTokens = getIntegerValue(parsed, 'max_tokens', 1000);

                result.promptTokens = promptTokens;
                result.completionTokens = completionTokens;
                result.totalTokens = promptTokens + completionTokens;
                result.llmCalloutDurationMs = durationMs;
            } else {
                result.content = 'Test response';
                result.modelIdentifier = modelIdentifier;
                result.llmCalloutDurationMs = durationMs;
            }

            return result;
        }
    }

    @IsTest
    static void testSendMessage_NullConfig_ThrowsException() {
        TestProviderAdapter adapter = new TestProviderAdapter();
        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, null, null);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('LLM configuration is required'), 'Should indicate config is required');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for null config');
    }

    @IsTest
    static void testSendMessage_MissingNamedCredential_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM').build();
        llm.NamedCredential__c = '';
        llm.DefaultModelIdentifier__c = 'test-model';

        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent').withType('Conversational').withLLM(llm.Id).build();

        TestProviderAdapter adapter = new TestProviderAdapter();
        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('NamedCredential is required'), 'Should indicate named credential is required');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for missing named credential');
    }

    @IsTest
    static void testSendMessage_MissingModelIdentifier_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 2').build();
        llm.NamedCredential__c = 'TestCredential';
        llm.DefaultModelIdentifier__c = '';

        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_2').withType('Conversational').withLLM(llm.Id).build();

        TestProviderAdapter adapter = new TestProviderAdapter();
        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('DefaultModelIdentifier is required'), 'Should indicate model identifier is required');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for missing model identifier');
    }

    @IsTest
    static void testSendMessage_NullMessages_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 3').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_3').withType('Conversational').withLLM(llm.Id).save();

        TestProviderAdapter adapter = new TestProviderAdapter();

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(null, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Messages payload cannot be empty'), 'Should indicate messages required');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for null messages');
    }

    @IsTest
    static void testSendMessage_EmptyMessages_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 4').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_4').withType('Conversational').withLLM(llm.Id).save();

        TestProviderAdapter adapter = new TestProviderAdapter();

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(new List<Map<String, Object>>(), null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Messages payload cannot be empty'), 'Should indicate messages required');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for empty messages');
    }

    @IsTest
    static void testSendMessage_Success_ReturnsProviderResult() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 5').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_5').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Test response'));
        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a provider result');
        System.assertEquals('Test response', result.content, 'Should return expected response content');
    }

    @IsTest
    static void testSendMessage_ProviderException_PropagatesCorrectly() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 6').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_6').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldThrowProviderException = true;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Test'));

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Simulated provider error'), 'Should propagate provider exception');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException');
    }

    @IsTest
    static void testSendMessage_HttpFailure_WrapsAsProviderException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 7').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_7').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();

        Test.setMock(HttpCalloutMock.class, new MockHttpFail());

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('HTTP callout failed'), 'Should wrap as ProviderException');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw wrapped ProviderException');
    }

    @IsTest
    static void testSendMessage_InvalidResponse_HandlesGracefully() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 8').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_8').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldReturnInvalidResponse = true;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Invalid'));

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(messages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Invalid response'), 'Should indicate invalid response');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ProviderException for invalid response');
    }

    @IsTest
    static void testSendMessage_EmptyMessagesList_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Empty').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Empty').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> emptyMessages = new List<Map<String, Object>>();

        TestProviderAdapter adapter = new TestProviderAdapter();
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('test'));

        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            adapter.sendMessage(emptyMessages, null, llm, agent);
        } catch (AIAgentException.ProviderException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().toLowerCase().contains('message'), 'Should mention messages in error');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Empty messages should throw ProviderException');
    }

    @IsTest
    static void testSendMessage_WithToolsPayload_ReturnsResult() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Tools').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Tools').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test with tools' } };

        List<Map<String, Object>> tools = new List<Map<String, Object>>{
            new Map<String, Object>{ 'type' => 'function', 'function' => new Map<String, Object>{ 'name' => 'get_weather', 'description' => 'Get weather' } }
        };

        TestProviderAdapter adapter = new TestProviderAdapter();
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Weather is sunny'));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, tools, llm, agent);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a result with tools payload');
        System.assertNotEquals(null, result.content, 'Result should have content');
    }

    @IsTest
    static void testHelperMethods_GetStringValue_ReturnsCorrectValues() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Helper').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Helper').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with string fields to test getStringValue
        String mockResponse = '{"content":"Hello from LLM","model":"gpt-4","stop_reason":"end_turn"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals('Hello from LLM', result.content, 'Should extract string value from content field');
        System.assertEquals('gpt-4', result.modelIdentifier, 'Should extract string value from model field');
    }

    @IsTest
    static void testHelperMethods_GetStringValue_WithNullValue_ReturnsDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Null').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Null').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with null content to test default value handling
        String mockResponse = '{"content":null,"model":"test-model"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals('default_content', result.content, 'Should return default value when field is null');
    }

    @IsTest
    static void testHelperMethods_GetStringValue_WithMissingKey_ReturnsDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Missing').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Missing').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response without content field to test missing key handling
        String mockResponse = '{"model":"test-model","stop_reason":"end_turn"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals('default_content', result.content, 'Should return default value when key is missing');
    }

    @IsTest
    static void testHelperMethods_GetIntegerValue_ReturnsCorrectValues() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Int').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Int').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with integer fields to test getIntegerValue
        String mockResponse = '{"content":"Response","model":"gpt-4","prompt_tokens":100,"completion_tokens":50}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals(100, result.promptTokens, 'Should extract integer value from prompt_tokens');
        System.assertEquals(50, result.completionTokens, 'Should extract integer value from completion_tokens');
        System.assertEquals(150, result.totalTokens, 'Should calculate total tokens');
    }

    @IsTest
    static void testHelperMethods_GetIntegerValue_WithNullValue_ReturnsDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Int Null').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Int_Null').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with null integer values
        String mockResponse = '{"content":"Response","model":"test","prompt_tokens":null,"completion_tokens":null}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals(0, result.promptTokens, 'Should return default value 0 when integer field is null');
        System.assertEquals(0, result.completionTokens, 'Should return default value 0 when integer field is null');
    }

    @IsTest
    static void testHelperMethods_GetIntegerValue_WithMissingKey_ReturnsDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Int Missing').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Int_Missing').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response without token fields
        String mockResponse = '{"content":"Response","model":"test"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals(0, result.promptTokens, 'Should return default value 0 when key is missing');
        System.assertEquals(0, result.completionTokens, 'Should return default value 0 when key is missing');
    }

    @IsTest
    static void testHelperMethods_GetIntegerValue_WithInvalidType_ReturnsDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Int Invalid').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Int_Invalid').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with string values for integer fields (type mismatch)
        String mockResponse = '{"content":"Response","model":"test","prompt_tokens":"not_a_number","completion_tokens":"invalid"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        // getIntegerValue should catch the cast exception and return default (0)
        System.assertEquals(0, result.promptTokens, 'Should return default value when cast fails');
        System.assertEquals(0, result.completionTokens, 'Should return default value when cast fails');
    }

    @IsTest
    static void testHelperMethods_GetStringValue_WithNonStringValue_ConvertsToString() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM Convert').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_Convert').withType('Conversational').withLLM(llm.Id).save();

        List<Map<String, Object>> messages = new List<Map<String, Object>>{ new Map<String, Object>{ 'role' => 'user', 'content' => 'test' } };

        TestProviderAdapter adapter = new TestProviderAdapter();
        adapter.shouldTestHelperMethods = true;

        // Mock response with numeric value that should be converted to string
        String mockResponse = '{"content":12345,"model":"test-model"}';
        Test.setMock(HttpCalloutMock.class, new MockHttpJsonResponse(mockResponse));

        Test.startTest();
        ProviderResult result = adapter.sendMessage(messages, null, llm, agent);
        Test.stopTest();

        System.assertEquals('12345', result.content, 'Should convert non-string value to string');
    }

    /**
     * Mock HTTP response that simulates a non-2xx status code
     */
    private class MockHttpFail implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setStatus('Internal Server Error');
            res.setBody('{"error": "Server error"}');
            return res;
        }
    }

    /**
     * Mock HTTP response that returns custom JSON body for testing helper methods
     */
    private class MockHttpJsonResponse implements HttpCalloutMock {
        private String jsonBody;

        public MockHttpJsonResponse(String jsonBody) {
            this.jsonBody = jsonBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setStatus('OK');
            res.setHeader('Content-Type', 'application/json');
            res.setBody(this.jsonBody);
            return res;
        }
    }
}
