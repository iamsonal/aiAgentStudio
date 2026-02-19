/**
 * @description Comprehensive HTTP mock response handler for AI Agent Framework tests.
 *              Supports multiple LLM providers, response types, error scenarios, and stateful conversations.
 *              Provides realistic mock responses for OpenAI, Anthropic, and other LLM providers.
 *
 * @usage
 *   // Simple success mock
 *   Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());
 *
 *   // Tool call mock
 *   Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCall('find_records'));
 *
 *   // Error mock
 *   Test.setMock(HttpCalloutMock.class, MockHttpResponses.error(429, 'Rate limit exceeded'));
 *
 *   // Stateful conversation mock
 *   MockHttpResponses mock = MockHttpResponses.conversational()
 *       .addResponse(MockHttpResponses.textResponse('Hello!'))
 *       .addResponse(MockHttpResponses.toolCall('find_records'))
 *       .addResponse(MockHttpResponses.textResponse('Found 3 records'));
 *   Test.setMock(HttpCalloutMock.class, mock);
 */
@IsTest
public class MockHttpResponses implements HttpCalloutMock {
    // ===================================================================================
    // INSTANCE VARIABLES
    // ===================================================================================

    private List<ResponseConfig> responseQueue = new List<ResponseConfig>();
    private Integer currentResponseIndex = 0;
    private ResponseMode mode = ResponseMode.SINGLE;
    private ResponseConfig defaultResponse;

    // ===================================================================================
    // BUILDER PATTERN - STATIC FACTORY METHODS
    // ===================================================================================

    /**
     * @description Creates a simple success response mock
     */
    public static MockHttpResponses success() {
        return new MockHttpResponses().withDefaultResponse(textResponse('Hello! How can I assist you today?'));
    }

    /**
     * @description Creates a simple text response mock with custom content
     */
    public static MockHttpResponses text(String content) {
        return new MockHttpResponses().withDefaultResponse(textResponse(content));
    }

    /**
     * @description Creates a tool call response mock
     */
    public static MockHttpResponses toolCall(String toolName) {
        return toolCall(toolName, '{"param":"value"}');
    }

    /**
     * @description Creates a tool call response with specific arguments
     */
    public static MockHttpResponses toolCall(String toolName, String arguments) {
        Map<String, Object> response = createToolCallResponse(toolName, arguments, null);
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, JSON.serialize(response)));
    }

    /**
     * @description Creates a tool call response with custom assistant content
     */
    public static MockHttpResponses toolCall(String toolName, String arguments, String content) {
        Map<String, Object> response = createToolCallResponse(toolName, arguments, content);
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, JSON.serialize(response)));
    }

    /**
     * @description Creates a multi-tool call response
     * @param actions List of maps with keys: id (optional), name, arguments
     */
    public static MockHttpResponses toolCalls(List<Map<String, String>> actions, String content) {
        Map<String, Object> response = createToolCallsResponse(actions, content);
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, JSON.serialize(response)));
    }

    /**
     * @description Creates an error response mock
     */
    public static MockHttpResponses error(Integer statusCode, String errorMessage) {
        Map<String, Object> errorResponse = new Map<String, Object>{
            'error' => new Map<String, Object>{ 'message' => errorMessage, 'type' => 'invalid_request_error', 'code' => String.valueOf(statusCode) }
        };
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(statusCode, JSON.serialize(errorResponse)));
    }

    /**
     * @description Creates a conversational mock that responds based on request sequence
     */
    public static MockHttpResponses conversational() {
        MockHttpResponses mock = new MockHttpResponses();
        mock.mode = ResponseMode.SEQUENTIAL;
        return mock;
    }

    /**
     * @description Creates a context-aware mock that examines request content
     */
    public static MockHttpResponses contextAware() {
        MockHttpResponses mock = new MockHttpResponses();
        mock.mode = ResponseMode.CONTEXT_AWARE;
        mock.withDefaultResponse(textResponse('I can help you with that.'));
        return mock;
    }

    // ===================================================================================
    // FLUENT BUILDER METHODS
    // ===================================================================================

    public MockHttpResponses withDefaultResponse(ResponseConfig config) {
        this.defaultResponse = config;
        return this;
    }

    public MockHttpResponses addResponse(ResponseConfig config) {
        this.responseQueue.add(config);
        return this;
    }

    public MockHttpResponses addTextResponse(String content) {
        return addResponse(textResponse(content));
    }

    public MockHttpResponses addToolCallResponse(String toolName, String arguments) {
        Map<String, Object> response = createToolCallResponse(toolName, arguments, null);
        return addResponse(new ResponseConfig(200, JSON.serialize(response)));
    }

    public MockHttpResponses addError(Integer statusCode, String message) {
        return addResponse(error(statusCode, message).defaultResponse);
    }

    // ===================================================================================
    // HTTPCALLOUTMOCK IMPLEMENTATION
    // ===================================================================================

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        // Route based on endpoint
        String endpoint = req.getEndpoint();

        if (endpoint.contains('/ai/agent/process/')) {
            // Internal REST API mock (agent processing)
            return createInternalApiResponse(req);
        } else if (endpoint.contains('/ai/agent/hitl/execute')) {
            // HITL REST API mock (tool execution after approval)
            return createHITLExecuteResponse(req);
        } else if (endpoint.contains('/ai/agent/hitl/followup')) {
            // HITL follow-up REST API mock
            return createResumeOrFollowUpResponse(req);
        } else if (endpoint.contains('/ai/agent/resume') || endpoint.contains('/ai/agent/followup')) {
            // Agent resume/follow-up REST API mock
            return createResumeOrFollowUpResponse(req);
        } else if (endpoint.contains('/v1/chat/completions')) {
            // LLM API mock (OpenAI-compatible)
            return createLLMResponse(req);
        } else if (endpoint.contains('/v1/embeddings')) {
            // Embeddings API mock
            return createEmbeddingsResponse();
        } else {
            // Unknown endpoint
            res.setStatusCode(404);
            res.setBody('{"error":"Mock endpoint not found: ' + endpoint + '"}');
            return res;
        }
    }

    // ===================================================================================
    // RESPONSE CREATION - INTERNAL API
    // ===================================================================================

    private HttpResponse createInternalApiResponse(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(200);

        Map<String, Object> response = new Map<String, Object>{
            'success' => true,
            'outcome' => 'QUEUED_ACTION',
            'error' => null,
            'requestId' => 'mock_request_' + generateRandomId()
        };

        res.setBody(JSON.serialize(response));
        return res;
    }

    private HttpResponse createHITLExecuteResponse(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        // Use defaultResponse if configured (including error scenarios)
        if (defaultResponse != null) {
            res.setStatusCode(defaultResponse.statusCode);
            res.setBody(defaultResponse.body);
            return res;
        }

        // Default success response
        res.setStatusCode(200);
        Map<String, Object> response = new Map<String, Object>{ 'success' => true, 'outcome' => 'Tool executed successfully', 'error' => null };
        res.setBody(JSON.serialize(response));
        return res;
    }

    private HttpResponse createResumeOrFollowUpResponse(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        // Use defaultResponse if configured (including error scenarios)
        if (defaultResponse != null) {
            res.setStatusCode(defaultResponse.statusCode);
            res.setBody(defaultResponse.body);
            return res;
        }

        // Default success response
        res.setStatusCode(200);
        Map<String, Object> response = new Map<String, Object>{ 'success' => true, 'outcome' => 'QUEUED_FOLLOWUP', 'message' => 'Agent resumed successfully' };
        res.setBody(JSON.serialize(response));
        return res;
    }

    // ===================================================================================
    // RESPONSE CREATION - LLM API
    // ===================================================================================

    private HttpResponse createLLMResponse(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        ResponseConfig config = selectResponse(req);
        res.setStatusCode(config.statusCode);
        res.setBody(config.body);

        return res;
    }

    private ResponseConfig selectResponse(HttpRequest req) {
        if (mode == ResponseMode.SINGLE) {
            return defaultResponse != null ? defaultResponse : textResponse('Default response');
        } else if (mode == ResponseMode.SEQUENTIAL) {
            if (currentResponseIndex < responseQueue.size()) {
                return responseQueue[currentResponseIndex++];
            } else {
                return defaultResponse != null ? defaultResponse : textResponse('End of sequence');
            }
        } else if (mode == ResponseMode.CONTEXT_AWARE) {
            return selectContextAwareResponse(req);
        }

        return textResponse('Fallback response');
    }

    private ResponseConfig selectContextAwareResponse(HttpRequest req) {
        String requestBody = req.getBody();

        if (String.isBlank(requestBody)) {
            return defaultResponse;
        }

        // Check if this is a follow-up after tool execution
        if (requestBody.contains('"role":"tool"')) {
            return textResponse('Based on the tool results, here is the answer.');
        }

        // Parse request to identify intent
        if (requestBody.contains('find') || requestBody.contains('search')) {
            return new ResponseConfig(200, JSON.serialize(createToolCallResponse('find_records', '{"searchQuery":"test"}', null)));
        }

        if (requestBody.contains('create') || requestBody.contains('new')) {
            return new ResponseConfig(200, JSON.serialize(createToolCallResponse('create_record', '{"objectType":"Account"}', null)));
        }

        if (requestBody.contains('update') || requestBody.contains('change')) {
            return new ResponseConfig(200, JSON.serialize(createToolCallResponse('update_record', '{"recordId":"001xx000003DHP0"}', null)));
        }

        // Default text response
        return defaultResponse != null ? defaultResponse : textResponse('I can help with that.');
    }

    // ===================================================================================
    // RESPONSE CREATION - EMBEDDINGS
    // ===================================================================================

    private HttpResponse createEmbeddingsResponse() {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');
        res.setStatusCode(200);

        // Create mock embedding vector (typically 1536 dimensions for OpenAI)
        List<Decimal> embedding = new List<Decimal>();
        for (Integer i = 0; i < 1536; i++) {
            embedding.add(Math.random() * 2 - 1); // Random values between -1 and 1
        }

        Map<String, Object> response = new Map<String, Object>{
            'object' => 'list',
            'data' => new List<Object>{ new Map<String, Object>{ 'object' => 'embedding', 'embedding' => embedding, 'index' => 0 } },
            'model' => 'text-embedding-ada-002',
            'usage' => new Map<String, Object>{ 'prompt_tokens' => 8, 'total_tokens' => 8 }
        };

        res.setBody(JSON.serialize(response));
        return res;
    }

    // ===================================================================================
    // STATIC RESPONSE TEMPLATES
    // ===================================================================================

    /**
     * @description Creates a simple text response configuration
     */
    public static ResponseConfig textResponse(String content) {
        Map<String, Object> response = createTextResponse(content);
        return new ResponseConfig(200, JSON.serialize(response));
    }

    /**
     * @description Creates a tool call response configuration with optional content
     */
    public static ResponseConfig toolCallResponse(String toolName, String arguments, String content) {
        Map<String, Object> response = createToolCallResponse(toolName, arguments, content);
        return new ResponseConfig(200, JSON.serialize(response));
    }

    /**
     * @description Creates an OpenAI-style text response
     */
    private static Map<String, Object> createTextResponse(String content) {
        return new Map<String, Object>{
            'id' => 'chatcmpl-' + generateRandomId(),
            'object' => 'chat.completion',
            'created' => Datetime.now().getTime() / 1000,
            'model' => 'gpt-4o-mini',
            'choices' => new List<Object>{
                new Map<String, Object>{
                    'index' => 0,
                    'message' => new Map<String, Object>{ 'role' => 'assistant', 'content' => content },
                    'finish_reason' => 'stop'
                }
            },
            'usage' => new Map<String, Object>{ 'prompt_tokens' => 100, 'completion_tokens' => 50, 'total_tokens' => 150 }
        };
    }

    /**
     * @description Creates an OpenAI-style tool call response
     */
    private static Map<String, Object> createToolCallResponse(String toolName, String arguments, String content) {
        return new Map<String, Object>{
            'id' => 'chatcmpl-' + generateRandomId(),
            'object' => 'chat.completion',
            'created' => Datetime.now().getTime() / 1000,
            'model' => 'gpt-4o-mini',
            'choices' => new List<Object>{
                new Map<String, Object>{
                    'index' => 0,
                    'message' => new Map<String, Object>{
                        'role' => 'assistant',
                        'content' => content != null ? content : 'Calling tool: ' + toolName,
                        'tool_calls' => new List<Object>{
                            new Map<String, Object>{
                                'id' => 'call_' + generateRandomId(),
                                'type' => 'function',
                                'function' => new Map<String, Object>{ 'name' => toolName, 'arguments' => arguments }
                            }
                        }
                    },
                    'finish_reason' => 'tool_calls'
                }
            },
            'usage' => new Map<String, Object>{ 'prompt_tokens' => 150, 'completion_tokens' => 75, 'total_tokens' => 225 }
        };
    }

    /**
     * @description Creates an OpenAI-style multi tool call response
     */
    private static Map<String, Object> createToolCallsResponse(List<Map<String, String>> actions, String content) {
        List<Object> toolCalls = new List<Object>();
        if (actions != null) {
            for (Map<String, String> action : actions) {
                String toolName = action.get('name');
                String arguments = action.get('arguments');
                String toolCallId = action.get('id');

                toolCalls.add(
                    new Map<String, Object>{
                        'id' => String.isNotBlank(toolCallId) ? toolCallId : ('call_' + generateRandomId()),
                        'type' => 'function',
                        'function' => new Map<String, Object>{ 'name' => toolName, 'arguments' => String.isNotBlank(arguments) ? arguments : '{}' }
                    }
                );
            }
        }

        return new Map<String, Object>{
            'id' => 'chatcmpl-' + generateRandomId(),
            'object' => 'chat.completion',
            'created' => Datetime.now().getTime() / 1000,
            'model' => 'gpt-4o-mini',
            'choices' => new List<Object>{
                new Map<String, Object>{
                    'index' => 0,
                    'message' => new Map<String, Object>{ 'role' => 'assistant', 'content' => content, 'tool_calls' => toolCalls },
                    'finish_reason' => 'tool_calls'
                }
            },
            'usage' => new Map<String, Object>{ 'prompt_tokens' => 150, 'completion_tokens' => 75, 'total_tokens' => 225 }
        };
    }

    // ===================================================================================
    // COMMON ERROR RESPONSES
    // ===================================================================================

    /**
     * @description Rate limit error (429)
     */
    public static MockHttpResponses rateLimitError() {
        return error(429, 'Rate limit exceeded. Please try again later.');
    }

    /**
     * @description Invalid API key error (401)
     */
    public static MockHttpResponses authError() {
        return error(401, 'Invalid API key provided.');
    }

    /**
     * @description Invalid request error (400)
     */
    public static MockHttpResponses badRequest(String message) {
        return error(400, message);
    }

    /**
     * @description Server error (500)
     */
    public static MockHttpResponses serverError() {
        return error(500, 'Internal server error occurred.');
    }

    /**
     * @description Timeout simulation (408)
     */
    public static MockHttpResponses timeout() {
        return error(408, 'Request timeout.');
    }

    /**
     * @description Malformed JSON response
     */
    public static MockHttpResponses malformedJson() {
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, '{"incomplete": "json", "missing":'));
    }

    /**
     * @description Missing required fields
     */
    public static MockHttpResponses missingFields() {
        Map<String, Object> incomplete = new Map<String, Object>{
            'id' => 'chatcmpl-123',
            'object' => 'chat.completion'
            // Missing 'choices' field
        };
        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, JSON.serialize(incomplete)));
    }

    // ===================================================================================
    // SPECIFIC TEST SCENARIOS
    // ===================================================================================

    /**
     * @description Mock for approval flow testing
     */
    public static MockHttpResponses approvalFlow() {
        return new MockHttpResponses()
            .withDefaultResponse(
                new ResponseConfig(
                    200,
                    JSON.serialize(
                        createToolCallResponse(
                            'find_records',
                            '{"searchQuery":"test","submission_comment":"Needs approval"}',
                            'I need to search records, requesting approval.'
                        )
                    )
                )
            );
    }

    /**
     * @description Mock for parallel tool calling
     */
    public static MockHttpResponses parallelToolCalls() {
        Map<String, Object> response = new Map<String, Object>{
            'id' => 'chatcmpl-' + generateRandomId(),
            'object' => 'chat.completion',
            'created' => Datetime.now().getTime() / 1000,
            'model' => 'gpt-4o-mini',
            'choices' => new List<Object>{
                new Map<String, Object>{
                    'index' => 0,
                    'message' => new Map<String, Object>{
                        'role' => 'assistant',
                        'content' => null,
                        'tool_calls' => new List<Object>{
                            new Map<String, Object>{
                                'id' => 'call_1',
                                'type' => 'function',
                                'function' => new Map<String, Object>{ 'name' => 'find_records', 'arguments' => '{"searchQuery":"accounts"}' }
                            },
                            new Map<String, Object>{
                                'id' => 'call_2',
                                'type' => 'function',
                                'function' => new Map<String, Object>{ 'name' => 'find_records', 'arguments' => '{"searchQuery":"contacts"}' }
                            }
                        }
                    },
                    'finish_reason' => 'tool_calls'
                }
            },
            'usage' => new Map<String, Object>{ 'prompt_tokens' => 200, 'completion_tokens' => 100, 'total_tokens' => 300 }
        };

        return new MockHttpResponses().withDefaultResponse(new ResponseConfig(200, JSON.serialize(response)));
    }

    /**
     * @description Mock for streaming responses (simulated with final response)
     */
    public static MockHttpResponses streaming() {
        // Note: Apex doesn't support true streaming, so we return complete response
        return new MockHttpResponses().withDefaultResponse(textResponse('This is a simulated streaming response that would normally arrive in chunks.'));
    }

    /**
     * @description Mock for multi-turn conversation
     */
    public static MockHttpResponses multiTurnConversation() {
        return conversational()
            .addTextResponse('Hello! How can I help you today?')
            .addToolCallResponse('find_records', '{"searchQuery":"accounts"}')
            .addTextResponse('I found 5 accounts matching your criteria.')
            .addToolCallResponse('get_details', '{"recordId":"001xx000003DHP0"}')
            .addTextResponse('Here are the details for that account.');
    }

    // ===================================================================================
    // REALISTIC TOOL CALL HELPERS (WITH recordData WRAPPER)
    // ===================================================================================

    /**
     * @description Creates a realistic create_follow_up_task tool call with proper recordData structure
     * Tests the CORRECT format that LLMs should use (with recordData wrapper)
     */
    public static MockHttpResponses createTaskWithRecordData(String subject, String whatId, String activityDate) {
        Map<String, Object> recordData = new Map<String, Object>{
            'Subject' => subject,
            'WhatId' => whatId,
            'ActivityDate' => activityDate,
            'Description' => 'Test task description'
        };
        String args = JSON.serialize(new Map<String, Object>{ 'recordData' => recordData });
        return toolCall('create_follow_up_task', args);
    }

    /**
     * @description Creates a realistic create_follow_up_task tool call WITHOUT recordData wrapper
     * Tests the FLATTENED format that LLMs sometimes incorrectly use (fields passed directly)
     * Our fix in ActionCreateRecord should handle this gracefully
     */
    public static MockHttpResponses createTaskWithoutRecordData(String subject, String whatId, String activityDate) {
        Map<String, Object> directFields = new Map<String, Object>{
            'Subject' => subject,
            'WhatId' => whatId,
            'ActivityDate' => activityDate,
            'Description' => 'Test task description'
        };
        String args = JSON.serialize(directFields);
        return toolCall('create_follow_up_task', args);
    }

    /**
     * @description Creates a realistic update_record tool call with proper recordData structure
     */
    public static MockHttpResponses updateRecordWithRecordData(String recordId, Map<String, Object> fields) {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => recordId, 'recordData' => fields };
        String args = JSON.serialize(params);
        return toolCall('update_record', args);
    }

    /**
     * @description Creates a realistic create_record tool call with proper recordData structure
     * @param objectType The SObject type (e.g., 'Account', 'Task')
     * @param fields Map of field names to values
     */
    public static MockHttpResponses createRecordWithRecordData(String objectType, Map<String, Object> fields) {
        Map<String, Object> params = new Map<String, Object>{ 'recordData' => fields };
        String args = JSON.serialize(params);
        return toolCall('create_record', args);
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

    private static String generateRandomId() {
        String chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        String result = '';
        for (Integer i = 0; i < 12; i++) {
            Integer index = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            result += chars.substring(index, index + 1);
        }
        return result;
    }

    /**
     * @description Resets the mock to initial state
     */
    public MockHttpResponses reset() {
        currentResponseIndex = 0;
        return this;
    }

    // ===================================================================================
    // INNER CLASSES
    // ===================================================================================

    /**
     * @description Response configuration
     */
    public class ResponseConfig {
        public Integer statusCode { get; set; }
        public String body { get; set; }

        public ResponseConfig(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
    }

    /**
     * @description Response mode enumeration
     */
    private enum ResponseMode {
        SINGLE, // Always return the same response
        SEQUENTIAL, // Return responses in sequence
        CONTEXT_AWARE // Examine request and return appropriate response
    }
}
