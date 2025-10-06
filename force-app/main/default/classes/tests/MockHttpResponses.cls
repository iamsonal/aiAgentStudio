@IsTest
public class MockHttpResponses implements HttpCalloutMock {
    // Static variables to control the mock's behavior for each test
    public static Integer statusCode = 200;
    public static String responseBody = '';
    public static Boolean simulateRestError = false;

    // A map to store different predefined responses
    private static Map<String, String> responseTemplates = new Map<String, String>{
        'SUCCESS_CONTENT' => '{"id":"chatcmpl-123","object":"chat.completion","created":1756749197,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"Hello! How can I assist you today?"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1575,"completion_tokens":10,"total_tokens":1585}}',
        'SUCCESS_TOOL_CALL' => '{"id":"chatcmpl-456","object":"chat.completion","created":1756749197,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"I will search for sales records based on your query.","tool_calls":[{"id":"call_123","type":"function","function":{"name":"find_sales_records","arguments":"{\\"sObjectTypes\\":[\\"Account\\"],\\"fieldsToReturn\\":[\\"Name\\",\\"Industry\\"],\\"filters\\":{\\"Name\\":\\"test query\\"}}"}}]}}],"usage":{"prompt_tokens":1575,"completion_tokens":25,"total_tokens":1600}}',
        'SUCCESS_TOOL_CALL_APPROVAL' => '{"id":"chatcmpl-456","object":"chat.completion","created":1756749197,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"I will search for sales records based on your query.","tool_calls":[{"id":"call_123","type":"function","function":{"name":"find_sales_records","arguments":"{\\"searchQuery\\":\\"test query\\",\\"submission_comment\\":\\"User requested sales records search for business analysis\\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1575,"completion_tokens":25,"total_tokens":1600}}',
        'SUCCESS_TOOL_FOLLOWUP' => '{"id":"chatcmpl-789","object":"chat.completion","created":1756749200,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"Based on the search results, I found several sales records that match your query."},"finish_reason":"stop"}],"usage":{"prompt_tokens":1600,"completion_tokens":15,"total_tokens":1615}}',
        'MALFORMED_JSON' => '{"id":"chatcmpl-123", "choices": [ "message": "unclosed bracket..."',
        'MISSING_CHOICES' => '{"id":"chatcmpl-123", "usage":{"total_tokens":10}}'
    };

    // Static method to reset the mock's state before each test
    public static void reset() {
        statusCode = 200;
        responseBody = '';
        simulateRestError = false;
    }

    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setHeader('Content-Type', 'application/json');

        // Route mock response based on the endpoint
        if (req.getEndpoint().contains('/ai/agent/process/')) {
            // This is the INTERNAL REST call for service user context
            if (simulateRestError) {
                res.setStatusCode(500);
                res.setBody('{"success":false, "error":"Simulated internal server error"}');
            } else {
                res.setStatusCode(200);
                // Create a simple response structure that matches AIAgentResponse
                Map<String, Object> restResponse = new Map<String, Object>{
                    'success' => true,
                    'outcome' => 'QUEUED_ACTION',
                    'error' => null,
                    'requestId' => 'mockRequestId'
                };
                res.setBody(JSON.serialize(restResponse));
            }
        } else if (req.getEndpoint().contains('/v1/chat/completions')) {
            // This is the EXTERNAL call to OpenAI (or similar LLM)
            res.setStatusCode(200); // Always return 200 for LLM calls

            // STATELESS LOGIC: Determine response based solely on request content
            String requestBody = req.getBody();
            String responseToUse;

            if (requestBody != null && requestBody.contains('"role":"tool"')) {
                // This is a follow-up call after tool execution - return final response
                responseToUse = responseTemplates.get('SUCCESS_TOOL_FOLLOWUP');
            } else if (requestBody != null && requestBody.contains('Find sales records for approval test query')) {
                // This is the approval test - return tool call with submission_comment
                responseToUse = responseTemplates.get('SUCCESS_TOOL_CALL_APPROVAL');
            } else if (requestBody != null && requestBody.contains('Find sales records')) {
                // This is the initial call for tool capability test - return tool call
                responseToUse = responseTemplates.get('SUCCESS_TOOL_CALL');
            } else {
                // Default response for other tests
                responseToUse = responseTemplates.get('SUCCESS_CONTENT');
            }

            // Handle error simulation
            if (statusCode != 200) {
                res.setStatusCode(statusCode);
                responseToUse = responseBody; // Use the error response set by the test
            }

            res.setBody(responseToUse);
        } else {
            res.setStatusCode(404);
            res.setBody('{"error": "Mock endpoint not found"}');
        }
        return res;
    }
}
