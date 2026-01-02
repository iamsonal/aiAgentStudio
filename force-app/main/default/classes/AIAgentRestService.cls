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
 * 
 * Endpoints:
 * - POST /ai/agent/process/* - Process chat messages (existing)
 * - POST /ai/agent/hitl/execute - Execute approved HITL tools in service user context (new)
 */
@RestResource(urlMapping='/ai/agent/*')
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

        // Route based on URL path
        String requestUri = req.requestURI;
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing request: ' + requestUri);

        if (String.isNotBlank(requestUri) && requestUri.endsWith('/hitl/execute')) {
            // HITL tool execution endpoint
            return executeApprovedHITLTool(req, res, requestId, logPrefix);
        } else {
            // Default chat message processing endpoint
            return processChatMessage(req, res, requestId, logPrefix);
        }
    }

    /**
     * Processes chat messages (original functionality).
     */
    private static AIAgentResponse processChatMessage(RestRequest req, RestResponse res, String requestId, String logPrefix) {
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
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (System.SecurityException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            res.statusCode = 403;
            return new AIAgentResponse(false, null, 'Access denied: ' + e.getMessage(), requestId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage() + '\n' + e.getStackTraceString());
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
        } catch (AIAgentException.OrchestrationException e) {
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
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update session state after processing failure: ' + failEx.getMessage());
            }

            throw e; // Re-throw the original exception
        }
    }

    /**
     * Executes approved HITL tools in the authenticated user's context.
     * The authenticated user is determined by the Named Credential configured in
     * AIAgentFrameworkSettings__c.HITLApprovalNamedCredential__c:
     * - JWT Bearer Flow → Service user (dedicated account with elevated permissions)
     * - Per-User OAuth → Original requesting user (user-specific permissions)
     * Called by HITLToolExecutionQueueable after approval.
     */
    private static AIAgentResponse executeApprovedHITLTool(RestRequest req, RestResponse res, String requestId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing HITL tool execution request');

        try {
            // Validate request
            if (req.requestBody == null || req.requestBody.size() == 0) {
                throw new AIAgentRestException('Request body is required');
            }

            // Parse request
            HITLToolRequest toolRequest = (HITLToolRequest) JSON.deserialize(
                req.requestBody.toString(), 
                HITLToolRequest.class
            );

            // Validate required fields
            if (String.isBlank(toolRequest.pendingActionId)) {
                throw new AIAgentRestException('pendingActionId is required');
            }
            if (String.isBlank(toolRequest.executionId)) {
                throw new AIAgentRestException('executionId is required');
            }
            if (String.isBlank(toolRequest.capabilityId)) {
                throw new AIAgentRestException('capabilityId is required');
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Executing tool as authenticated user: ' + UserInfo.getUserName() + 
                ' (UserId: ' + UserInfo.getUserId() + ')');

            // Load capability
            AgentCapability__c capability = AIAgentConfigService.getCapabilityById(Id.valueOf(toolRequest.capabilityId));
            if (capability == null) {
                throw new AIAgentRestException('Capability not found: ' + toolRequest.capabilityId);
            }

            // Load execution
            AgentExecution__c execution = [
                SELECT Id, User__c, ServiceUser__c, AIAgentDefinition__c
                FROM AgentExecution__c
                WHERE Id = :toolRequest.executionId
                LIMIT 1
            ];

            // Build action context
            // - originalUserId: The user who originally requested the action
            // - executionUserId: The authenticated user executing the tool (current user via Named Credential)
            ActionContext actionContext = new ActionContext(
                execution.Id,
                execution.User__c, // Original user
                UserInfo.getUserId(), // Authenticated user (service user or original user)
                String.isNotBlank(toolRequest.sourceRecordId) ? Id.valueOf(toolRequest.sourceRecordId) : null,
                execution.AIAgentDefinition__c,
                capability.Id,
                capability.ImplementationDetail__c,
                toolRequest.turnIdentifier,
                toolRequest.turnCount != null ? Integer.valueOf(toolRequest.turnCount) : 1,
                'HITLResume'
            );

            // Execute the tool
            CapabilityExecutionService capabilityService = new CapabilityExecutionService();
            ActionOutcome outcome = capabilityService.executeSingleAction(
                capability,
                toolRequest.toolArguments,
                actionContext
            );

            // Update the existing placeholder tool result step
            ExecutionStepService stepService = new ExecutionStepService();
            String resultJson = OrchestrationService.serializeActionOutcome(outcome, logPrefix);

            Id updatedStepId = stepService.updateToolResultStep(
                execution.Id,
                toolRequest.toolCallId,
                resultJson,
                0L
            );

            // Fallback: create new step if update failed
            if (updatedStepId == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not find existing tool result step, creating new one');
                stepService.createToolResultStep(
                    execution.Id,
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    resultJson,
                    toolRequest.turnIdentifier,
                    toolRequest.turnCount != null ? Integer.valueOf(toolRequest.turnCount) : 1,
                    0L,
                    false,
                    capability.Id
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Tool executed successfully. Success: ' + outcome.isSuccess);

            // Queue follow-up LLM call if needed (optimization: use pre-determined flag)
            if (toolRequest.needsFollowUp == true) {
                queueFollowUpLLMCall(execution, toolRequest, logPrefix);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Conversational agent - no follow-up needed (pre-determined)');
            }

            // Notify requesting user about execution result
            if (String.isNotBlank(toolRequest.requestingUserId)) {
                String title = outcome.isSuccess ? 
                    'Action Executed: ' + toolRequest.toolName :
                    'Action Failed: ' + toolRequest.toolName;
                    
                String body = outcome.isSuccess ?
                    'Your requested action "' + toolRequest.toolName + '" has been approved and executed successfully.' :
                    'Your requested action "' + toolRequest.toolName + '" was approved but execution failed: ' + outcome.errorMessage;
                    
                NotificationService.sendUserNotification(
                    Id.valueOf(toolRequest.requestingUserId),
                    title,
                    body,
                    execution.Id
                );
            }

            res.statusCode = 200;
            return new AIAgentResponse(true, 'Tool executed successfully', null, requestId);

        } catch (AIAgentRestException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (AIAgentConfigService.ConfigurationException e) {
            // Configuration errors (capability not found, etc.) are client errors
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage() + '\n' + e.getStackTraceString());
            res.statusCode = 500;
            return new AIAgentResponse(false, null, 'Internal server error: ' + e.getMessage(), requestId);
        }
    }

    /**
     * Queues follow-up LLM call for Function/Workflow agents.
     * Note: This method assumes the caller has already determined that a follow-up is needed.
     */
    private static void queueFollowUpLLMCall(AgentExecution__c execution, HITLToolRequest toolRequest, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Queueing follow-up LLM call');

            AgentStateService stateService = new AgentStateService();
            stateService.resumeForFollowUpLlmCall(
                execution.Id,
                toolRequest.turnIdentifier,
                null,
                logPrefix
            );

            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            enqueuer.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                toolRequest.turnIdentifier,
                (toolRequest.turnCount != null ? Integer.valueOf(toolRequest.turnCount) : 1) + 1,
                logPrefix,
                false
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue follow-up: ' + e.getMessage());
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
     * Request data structure for HITL tool execution.
     */
    global class HITLToolRequest {
        public String pendingActionId { get; set; }
        public String executionId { get; set; }
        public String capabilityId { get; set; }
        public String toolCallId { get; set; }
        public String toolName { get; set; }
        public String toolArguments { get; set; }
        public String turnIdentifier { get; set; }
        public Decimal turnCount { get; set; }
        public String sourceRecordId { get; set; }
        public String requestingUserId { get; set; }
        public Boolean needsFollowUp { get; set; } // Whether follow-up LLM call is needed
    }

    /**
     * Exception for REST service business logic errors (e.g., validation, configuration, or user errors).
     */
    public class AIAgentRestException extends Exception {
    }
}
