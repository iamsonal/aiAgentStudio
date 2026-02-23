/**
 * @description Simple custom action for making HTTP callouts to test external API integration.
 * Hardcoded endpoint for basic testing purposes.
 *
 * @extends BaseAgentAction
 */
public class ActionJSONPlaceholder extends BaseAgentAction {
    // Hardcoded endpoint - JSONPlaceholder is a free fake REST API for testing
    private static final String ENDPOINT_URL = 'https://jsonplaceholder.typicode.com/posts';

    /**
     * @description Main entry point for HTTP callout
     * @param params Raw parameters (expects 'data' field with JSON to post)
     * @return ActionOutcome with response data or error
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        try {
            // Get data from params
            String requestData = (String) params.get('data');

            // Make the callout
            HttpRequest req = new HttpRequest();
            req.setEndpoint(ENDPOINT_URL);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(10000);

            // Set body if provided, otherwise use default test data
            if (String.isNotBlank(requestData)) {
                req.setBody(requestData);
            } else {
                // Default test data
                Map<String, Object> defaultData = new Map<String, Object>{
                    'title' => 'Test from Salesforce Agent',
                    'body' => 'This is a test callout from AI Agent Studio',
                    'userId' => 1
                };
                req.setBody(JSON.serialize(defaultData));
            }

            // Make the callout
            Http http = new Http();
            HttpResponse res = http.send(req);

            // Build result
            Map<String, Object> result = new Map<String, Object>{
                'statusCode' => res.getStatusCode(),
                'status' => res.getStatus(),
                'body' => res.getBody(),
                'endpoint' => ENDPOINT_URL
            };

            // Parse JSON response if possible
            if (String.isNotBlank(res.getBody())) {
                try {
                    result.put('parsedBody', JSON.deserializeUntyped(res.getBody()));
                } catch (Exception e) {
                    // Not JSON, keep as string
                }
            }

            // Check for errors
            if (res.getStatusCode() >= 400) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'HTTP ' + res.getStatusCode() + ': ' + res.getStatus());
            }

            return ActionOutcome.success(result);
        } catch (Exception e) {
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description No configuration needed for this simple action
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // No configuration needed - endpoint is hardcoded
    }
}
