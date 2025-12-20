/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * REST API endpoint for AI agent message processing with user context management.
 * Provides secure message processing and asynchronous handling via platform events.
 */
@RestResource(urlMapping='/ai/agent/process/*')
global with sharing class AIAgentRestService {
    private static final String LOG_PREFIX = '[AIAgentRestService] ';

    /**
     * Processes AI agent messages with user context management.
     *
     * @return AIAgentResponse with processing outcome
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
     * Parses and validates incoming request data.
     *
     * @param requestBody Raw JSON request body
     * @param logPrefix   Logging prefix
     * @return            Parsed and validated request
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
     * Processes the message in the execution user context (SERVICE USER after Named Credential switch).
     * This method now delegates to the unified AgentExecutionService, which will call the appropriate
     * orchestrator. The orchestrator executes with the service user's permissions because we're already
     * in the service user context after the Named Credential switch.
     *
     * CRITICAL: Sets isInServiceUserContext=true to prevent AgentExecutionService from attempting
     * another context switch (which would cause infinite recursion).
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
            // Get the agent definition to use its developer name
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDefinition == null) {
                throw new AIAgentRestException('Agent definition not found: ' + agentDefinitionId);
            }

            // Build execution payload for unified service
            // Note: We're now running as the service user after the Named Credential context switch
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.userId = originalUserId; // Original user who initiated the request
            payload.serviceUserId = UserInfo.getUserId(); // Current user (service user after context switch)
            payload.triggerSource = 'Chat';
            payload.userMessage = requestData.userMessage;
            payload.currentRecordId = currentRecordId;
            payload.turnIdentifier = requestData.turnIdentifier;
            payload.existingExecutionId = sessionId; // Continue existing execution
            payload.isInServiceUserContext = true; // CRITICAL: Prevent infinite recursion

            System.debug(LoggingLevel.INFO, logPrefix + 'Delegating to AgentExecutionService as service user: ' + UserInfo.getUserName());

            // Use unified AgentExecutionService to initiate/continue execution
            // The orchestrator will now execute with service user permissions
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agentDefinition.DeveloperName__c, payload);

            if (result.success) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Message processing initiated successfully via service user context');
                return result.status;
            } else {
                throw new AIAgentRestException('Execution failed: ' + result.errorMessage);
            }
        } catch (AIAgentConfigService.ConfigurationException e) {
            throw new AIAgentRestException('Configuration error: ' + e.getMessage());
        } catch (AgentOrchestratorException e) {
            throw new AIAgentRestException('Orchestration error: ' + e.getMessage());
        } catch (Exception e) {
            // Mark the turn as failed before re-throwing
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(
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
