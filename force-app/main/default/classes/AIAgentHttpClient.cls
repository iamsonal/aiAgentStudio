/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentHttpClient is a fail-fast, internal HTTP client service for AI Agent REST API communications.
 * Responsibilities:
 *   - Provides secure, authenticated callouts via Named Credentials
 *   - Implements comprehensive error handling with single-attempt execution
 *   - Enables reliable, auditable communication between different execution contexts within the framework
 *   - Surfaces callout and parsing issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended.
 */
public class AIAgentHttpClient {
    private static final String LOG_PREFIX = '[AIAgentHttpClient] ';
    private static final String NAMED_CREDENTIAL_NAME = 'AgentStudioInternalAPI';

    /**
     * Processes an AI agent message by making a secure, authenticated REST callout to the internal API.
     * Executes a single attempt - callers should handle retries if needed.
     *
     * @param requestData The message request data to send to the internal API.
     * @return           The parsed HTTP response as an AIAgentHttpResponse.
     */
    public static AIAgentHttpResponse processMessage(AIAgentMessageRequest requestData) {
        String logPrefix = LOG_PREFIX + '[Turn:' + requestData.turnIdentifier?.left(8) + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting secure REST callout for AI agent message processing via Named Credential.');

        try {
            HttpRequest httpReq = buildHttpRequest(requestData, logPrefix);

            // Configure callout
            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);

            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            return parseResponse(result.response, logPrefix);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'HTTP client encountered unexpected error: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString()
            );
            return new AIAgentHttpResponse(false, null, 'HTTP client error: ' + e.getMessage(), null);
        }
    }

    /**
     * Builds an authenticated HttpRequest for the internal AI Agent REST API using Named Credentials.
     *
     * @param requestData The message request data to send.
     * @param logPrefix   The logging prefix for debug output.
     * @return            The configured HttpRequest instance.
     */
    private static HttpRequest buildHttpRequest(AIAgentMessageRequest requestData, String logPrefix) {
        // Use Named Credential endpoint for secure authentication and URL management
        String endpoint = 'callout:' + NAMED_CREDENTIAL_NAME + '/services/apexrest/ai/agent/process/';

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');

        Map<String, Object> requestBody = new Map<String, Object>{
            'sessionId' => requestData.sessionId,
            'originalUserId' => requestData.originalUserId,
            'agentDefinitionId' => requestData.agentDefinitionId,
            'turnIdentifier' => requestData.turnIdentifier,
            'userMessage' => requestData.userMessage,
            'currentRecordId' => requestData.currentRecordId
        };

        httpReq.setBody(JSON.serialize(requestBody));

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for Named Credential: ' + NAMED_CREDENTIAL_NAME);
        return httpReq;
    }

    /**
     * Parses the HTTP response and creates an AIAgentHttpResponse.
     * Handles both success and error responses, with robust error parsing and debug output.
     *
     * @param httpRes   The HttpResponse returned from the callout.
     * @param logPrefix The logging prefix for debug output.
     * @return          The parsed AIAgentHttpResponse.
     */
    private static AIAgentHttpResponse parseResponse(HttpResponse httpRes, String logPrefix) {
        Integer statusCode = httpRes.getStatusCode();
        String responseBody = httpRes.getBody();

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP response received. Status=' + statusCode + ', BodyLength=' + (responseBody?.length() ?? 0));

        try {
            if (statusCode == 200) {
                // Parse successful response
                AIAgentRestService.AIAgentResponse restResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                    responseBody,
                    AIAgentRestService.AIAgentResponse.class
                );

                return new AIAgentHttpResponse(restResponse.success, restResponse.outcome, restResponse.error, restResponse.requestId);
            } else {
                // Handle error responses
                String errorMessage = 'HTTP ' + statusCode;

                if (String.isNotBlank(responseBody)) {
                    try {
                        AIAgentRestService.AIAgentResponse errorResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                            responseBody,
                            AIAgentRestService.AIAgentResponse.class
                        );
                        errorMessage = errorResponse.error ?? errorMessage;
                    } catch (Exception parseEx) {
                        // If unable to parse error response, use the raw body (truncated if necessary)
                        errorMessage = responseBody.length() > 200 ? responseBody.substring(0, 200) + '...' : responseBody;
                    }
                }

                System.debug(LoggingLevel.ERROR, logPrefix + 'HTTP error response: ' + errorMessage);
                return new AIAgentHttpResponse(false, null, errorMessage, null);
            }
        } catch (JSONException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to parse JSON response: ' + e.getMessage());
            return new AIAgentHttpResponse(false, null, 'Response parsing error: ' + e.getMessage(), null);
        }
    }

    /**
     * Request data structure for the AI Agent HTTP client.
     */
    public class AIAgentMessageRequest {
        public String sessionId { get; set; }
        public String originalUserId { get; set; }
        public String agentDefinitionId { get; set; }
        public String turnIdentifier { get; set; }
        public String userMessage { get; set; }
        public String currentRecordId { get; set; }

        public AIAgentMessageRequest(
            String sessionId,
            String originalUserId,
            String agentDefinitionId,
            String turnIdentifier,
            String userMessage,
            String currentRecordId
        ) {
            this.sessionId = sessionId;
            this.originalUserId = originalUserId;
            this.agentDefinitionId = agentDefinitionId;
            this.turnIdentifier = turnIdentifier;
            this.userMessage = userMessage;
            this.currentRecordId = currentRecordId;
        }
    }

    /**
     * Response data structure for the AI Agent HTTP client.
     */
    public class AIAgentHttpResponse {
        public Boolean success { get; set; }
        public String outcome { get; set; }
        public String error { get; set; }
        public String requestId { get; set; }

        public AIAgentHttpResponse(Boolean success, String outcome, String error, String requestId) {
            this.success = success;
            this.outcome = outcome;
            this.error = error;
            this.requestId = requestId;
        }
    }
}
