/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentRestService is the enterprise-grade REST API endpoint for AI agent message processing.
 * Responsibilities:
 *   - Provides secure, scalable message processing with advanced user context management
 *   - Implements comprehensive error handling, request validation, and proper HTTP status code responses
 *   - Eliminates concurrency bottlenecks by directly queueing asynchronous processing jobs
 *   - Surfaces operational and validation issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended.
 */
@RestResource(urlMapping='/ai/agent/process/*')
global with sharing class AIAgentRestService {
    private static final String LOG_PREFIX = '[AIAgentRestService] ';

    /**
     * Processes AI agent messages in the context of the specified execution user.
     * Supports HTTP callouts and eliminates queueable job limitations by directly enqueuing asynchronous jobs.
     *
     * @return AIAgentResponse containing the processing outcome and any errors.
     */
    @HttpPost
    global static AIAgentResponse processMessage() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String requestId = generateRequestId();
        String logPrefix = LOG_PREFIX + '[ReqId:' + requestId + '] ';

        System.debug(LoggingLevel.INFO, logPrefix + 'Processing incoming AI agent message request');

        try {
            // Validate request
            if (req.requestBody == null || req.requestBody.size() == 0) {
                throw new AIAgentRestException('Request body is required');
            }

            // Parse and validate request data
            AIAgentRequest requestData = parseAndValidateRequest(req.requestBody.toString(), logPrefix);

            // Process the message in the execution user context
            String outcome = processMessageInContext(requestData, logPrefix);

            System.debug(LoggingLevel.INFO, logPrefix + 'AI agent message processed successfully with outcome: ' + outcome);

            // Set success response
            res.statusCode = 200;
            return new AIAgentResponse(true, outcome, null, requestId);
        } catch (AIAgentRestException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Request validation or business logic error: ' + e.getMessage());
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (System.SecurityException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Security violation detected: ' + e.getMessage());
            res.statusCode = 403;
            return new AIAgentResponse(false, null, 'Access denied: ' + e.getMessage(), requestId);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Unexpected system error during request processing: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString()
            );
            res.statusCode = 500;
            return new AIAgentResponse(false, null, 'Internal server error: ' + e.getMessage(), requestId);
        }
    }

    /**
     * Parses and validates the incoming request data from the REST request body.
     *
     * @param requestBody The raw JSON request body as a string.
     * @param logPrefix   The logging prefix for debug output.
     * @return            The parsed and validated AIAgentRequest.
     * @throws AIAgentRestException if validation fails or required fields are missing/invalid.
     */
    private static AIAgentRequest parseAndValidateRequest(String requestBody, String logPrefix) {
        try {
            AIAgentRequest requestData = (AIAgentRequest) JSON.deserialize(requestBody, AIAgentRequest.class);

            // Validate required fields
            if (String.isBlank(requestData.sessionId)) {
                throw new AIAgentRestException('sessionId is required');
            }
            if (String.isBlank(requestData.originalUserId)) {
                throw new AIAgentRestException('originalUserId is required');
            }
            if (String.isBlank(requestData.agentDefinitionId)) {
                throw new AIAgentRestException('agentDefinitionId is required');
            }
            if (String.isBlank(requestData.turnIdentifier)) {
                throw new AIAgentRestException('turnIdentifier is required');
            }
            if (String.isBlank(requestData.userMessage)) {
                throw new AIAgentRestException('userMessage is required');
            }

            // Validate ID formats
            validateId(requestData.sessionId, 'sessionId');
            validateId(requestData.originalUserId, 'originalUserId');
            validateId(requestData.agentDefinitionId, 'agentDefinitionId');

            if (String.isNotBlank(requestData.currentRecordId)) {
                validateId(requestData.currentRecordId, 'currentRecordId');
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Request validation completed successfully');
            return requestData;
        } catch (JSONException e) {
            throw new AIAgentRestException('Invalid JSON format: ' + e.getMessage());
        }
    }

    /**
     * Validates that a string is a proper Salesforce ID format.
     *
     * @param idValue   The string value to validate as an ID.
     * @param fieldName The name of the field being validated (for error reporting).
     * @throws AIAgentRestException if the ID is not valid.
     */
    private static void validateId(String idValue, String fieldName) {
        try {
            Id.valueOf(idValue);
        } catch (Exception e) {
            throw new AIAgentRestException('Invalid ' + fieldName + ' format: ' + idValue);
        }
    }

    /**
     * Processes the message in the execution user context, updating session state and enqueuing async processing.
     *
     * @param requestData The parsed and validated AIAgentRequest.
     * @param logPrefix   The logging prefix for debug output.
     * @return            The processing status string (e.g., 'Processing').
     * @throws AIAgentRestException for configuration or business logic errors.
     * @throws Exception for unexpected system errors (will be caught by the main handler).
     */
    private static String processMessageInContext(AIAgentRequest requestData, String logPrefix) {
        Id sessionId = Id.valueOf(requestData.sessionId);
        Id originalUserId = Id.valueOf(requestData.originalUserId);
        Id agentDefinitionId = Id.valueOf(requestData.agentDefinitionId);
        Id currentRecordId = String.isNotBlank(requestData.currentRecordId) ? Id.valueOf(requestData.currentRecordId) : null;

        try {
            // Get the agent definition to retrieve LLM configuration
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDefinition == null) {
                throw new AIAgentRestException('Agent definition not found: ' + agentDefinitionId);
            }

            // Update session status to processing
            ChatSessionStateService chatStateSvc = new ChatSessionStateService();
            chatStateSvc.updateStatus(
                sessionId,
                AIAgentConstants.STATUS_PROCESSING,
                null,
                null,
                requestData.turnIdentifier,
                'Processing message asynchronously'
            );

            // Queue the LLM processing asynchronously to avoid callout loop
            System.enqueueJob(
                new AIAgentAsyncProcessor(
                    sessionId,
                    originalUserId,
                    agentDefinitionId,
                    agentDefinition.LLMConfiguration__c,
                    requestData.turnIdentifier,
                    requestData.userMessage,
                    currentRecordId,
                    logPrefix
                )
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Message successfully queued for asynchronous processing');
            return AIAgentConstants.STATUS_PROCESSING;
        } catch (AIAgentConfigService.ConfigurationException e) {
            throw new AIAgentRestException('Configuration error: ' + e.getMessage());
        } catch (Exception e) {
            // Mark the turn as failed before re-throwing
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    sessionId,
                    requestData.turnIdentifier,
                    'REST processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'CRITICAL: Failed to update session state after processing failure: ' + failEx.getMessage()
                );
            }

            throw e; // Re-throw the original exception
        }
    }

    /**
     * Generates a unique request ID for tracking and debugging.
     *
     * @return A unique request ID string.
     */
    private static String generateRequestId() {
        return String.valueOf(Crypto.getRandomLong()).substring(1, 9);
    }

    /**
     * Request data structure for AI agent processing.
     */
    global class AIAgentRequest {
        public String sessionId { get; set; }
        public String originalUserId { get; set; }
        public String agentDefinitionId { get; set; }
        public String turnIdentifier { get; set; }
        public String userMessage { get; set; }
        public String currentRecordId { get; set; }
    }

    /**
     * Response data structure for AI agent processing.
     */
    global class AIAgentResponse {
        public Boolean success { get; set; }
        public String outcome { get; set; }
        public String error { get; set; }
        public String requestId { get; set; }

        public AIAgentResponse(Boolean success, String outcome, String error, String requestId) {
            this.success = success;
            this.outcome = outcome;
            this.error = error;
            this.requestId = requestId;
        }
    }

    /**
     * Exception for REST service business logic errors (e.g., validation, configuration, or user errors).
     */
    public class AIAgentRestException extends Exception {
    }
}
