/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description HTTP client service for making internal REST calls to AI Agent processing endpoints.
 *              Handles authentication, error handling, and retry logic.
 */
public class AIAgentHttpClient {
    private static final String LOG_PREFIX = '[AIAgentHttpClient] ';
    private static final String NAMED_CREDENTIAL_NAME = 'AgentStudioInternalAPI';

    public static AIAgentHttpResponse processMessage(AIAgentMessageRequest requestData) {
        String logPrefix = LOG_PREFIX + '[Turn:' + requestData.turnIdentifier?.left(8) + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Initiating REST callout via Named Credential for message processing');

        try {
            HttpRequest httpReq = buildHttpRequest(requestData, logPrefix);

            // USE THE ROBUST, CENTRALIZED RETRY SERVICE
            HttpRetryService.RetryConfig config = new HttpRetryService.RetryConfig(
                    2, // maxAttempts
                    1000, // initialDelayMs
                    new Set<Integer>{ 408, 429, 500, 502, 503, 504 }
                )
                .withLogPrefix(logPrefix);

            HttpRetryService.HttpRetryResult result = HttpRetryService.executeWithRetry(httpReq, config);

            return parseResponse(result.response, logPrefix);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'HTTP client error: ' + e.getMessage());
            return new AIAgentHttpResponse(false, null, 'HTTP client error: ' + e.getMessage(), null);
        }
    }

    private static HttpRequest buildHttpRequest(AIAgentMessageRequest requestData, String logPrefix) {
        // The endpoint now uses the Named Credential syntax.
        // Salesforce handles replacing the URL and adding the Authorization header automatically.
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

        System.debug(LoggingLevel.DEBUG, logPrefix + 'HTTP request prepared for Named Credential: ' + NAMED_CREDENTIAL_NAME);
        return httpReq;
    }

    /**
     * @description Parses the HTTP response and creates an AIAgentHttpResponse
     */
    private static AIAgentHttpResponse parseResponse(HttpResponse httpRes, String logPrefix) {
        Integer statusCode = httpRes.getStatusCode();
        String responseBody = httpRes.getBody();

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Parsing response. Status: ' + statusCode + ', Body length: ' + (responseBody?.length() ?? 0));

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
                        // If we can't parse the error response, use the raw body
                        errorMessage = responseBody.length() > 200 ? responseBody.substring(0, 200) + '...' : responseBody;
                    }
                }

                System.debug(LoggingLevel.ERROR, logPrefix + 'HTTP error response: ' + errorMessage);
                return new AIAgentHttpResponse(false, null, errorMessage, null);
            }
        } catch (JSONException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'JSON parsing error: ' + e.getMessage());
            return new AIAgentHttpResponse(false, null, 'Response parsing error: ' + e.getMessage(), null);
        }
    }

    /**
     * @description Request data structure for HTTP client
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
     * @description Response structure for HTTP client
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

    /**
     * @description Custom exception for HTTP client errors
     */
    public class AIAgentHttpClientException extends Exception {
    }
}
