/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description REST API endpoint for AI agent message processing with user context management.
 */
@RestResource(urlMapping='/ai/agent/*')
global with sharing class AIAgentRestService {
    private static final String LOG_PREFIX = '[AIAgentRestService] ';
    @HttpPost
    global static AIAgentResponse processMessage() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        String requestId = generateRequestId();
        String logPrefix = LOG_PREFIX + '[ReqId:' + requestId + '] ';

        String requestUri = req.requestURI;
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing request: ' + requestUri);

        if (String.isNotBlank(requestUri) && requestUri.endsWith('/hitl/execute')) {
            return executeApprovedHITLTool(req, res, requestId, logPrefix);
        } else if (String.isNotBlank(requestUri) && requestUri.endsWith('/hitl/followup')) {
            return executeFollowUpLLMCall(req, res, requestId, logPrefix);
        } else if (String.isNotBlank(requestUri) && requestUri.endsWith('/resume')) {
            return executeResumeInServiceContext(req, res, requestId, logPrefix);
        } else {
            return processChatMessage(req, res, requestId, logPrefix);
        }
    }
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

    private static AIAgentRequest parseAndValidateRequest(String requestBody, String logPrefix) {
        try {
            AIAgentRequest requestData = (AIAgentRequest) JSON.deserialize(requestBody, AIAgentRequest.class);

            // sessionId is now OPTIONAL - allows creating new executions in service user context
            // When blank, a new execution will be created by the service user
            if (String.isBlank(requestData.originalUserId)) {
                throw new AIAgentRestException('originalUserId is required');
            }
            if (String.isBlank(requestData.agentDefinitionId)) {
                throw new AIAgentRestException('agentDefinitionId is required');
            }
            if (String.isBlank(requestData.turnIdentifier)) {
                throw new AIAgentRestException('turnIdentifier is required');
            }
            // userMessage is now optional for non-conversational agents
            // (Function/Workflow agents may not need a user message)

            // Validate ID formats
            if (String.isNotBlank(requestData.sessionId)) {
                validateId(requestData.sessionId, 'sessionId');
            }
            validateId(requestData.originalUserId, 'originalUserId');
            validateId(requestData.agentDefinitionId, 'agentDefinitionId');

            if (String.isNotBlank(requestData.currentRecordId)) {
                validateId(requestData.currentRecordId, 'currentRecordId');
            }
            if (String.isNotBlank(requestData.sourceRecordId)) {
                validateId(requestData.sourceRecordId, 'sourceRecordId');
            }
            // Validate sourceRecordIds if provided
            if (requestData.sourceRecordIds != null) {
                for (Integer i = 0; i < requestData.sourceRecordIds.size(); i++) {
                    if (String.isNotBlank(requestData.sourceRecordIds[i])) {
                        validateId(requestData.sourceRecordIds[i], 'sourceRecordIds[' + i + ']');
                    }
                }
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Request validation completed successfully. New execution: ' + String.isBlank(requestData.sessionId));
            return requestData;
        } catch (JSONException e) {
            throw new AIAgentRestException('Invalid JSON format: ' + e.getMessage());
        }
    }

    private static void validateId(String idValue, String fieldName) {
        try {
            Id.valueOf(idValue);
        } catch (Exception e) {
            throw new AIAgentRestException('Invalid ' + fieldName + ' format: ' + idValue);
        }
    }

    private static String processMessageInContext(AIAgentRequest requestData, String logPrefix) {
        // sessionId is now optional - null means create new execution
        Id sessionId = String.isNotBlank(requestData.sessionId) ? Id.valueOf(requestData.sessionId) : null;
        Id originalUserId = Id.valueOf(requestData.originalUserId);
        Id agentDefinitionId = Id.valueOf(requestData.agentDefinitionId);
        Id currentRecordId = String.isNotBlank(requestData.currentRecordId) ? Id.valueOf(requestData.currentRecordId) : null;
        Id sourceRecordId = String.isNotBlank(requestData.sourceRecordId) ? Id.valueOf(requestData.sourceRecordId) : null;

        try {
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDefinition == null) {
                throw new AIAgentRestException('Agent definition not found: ' + agentDefinitionId);
            }

            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.userId = originalUserId;
            payload.serviceUserId = UserInfo.getUserId();
            payload.triggerSource = String.isNotBlank(requestData.triggerSource) ? requestData.triggerSource : 'API';
            payload.userMessage = requestData.userMessage;
            payload.currentRecordId = currentRecordId;
            payload.turnIdentifier = requestData.turnIdentifier;
            payload.existingExecutionId = sessionId; // May be null for new executions
            payload.isInServiceUserContext = true;
            payload.sourceRecordId = sourceRecordId;
            payload.batchId = requestData.batchId;
            payload.priority = requestData.priority;

            // Handle sourceRecordIds array
            if (requestData.sourceRecordIds != null && !requestData.sourceRecordIds.isEmpty()) {
                payload.sourceRecordIds = new List<Id>();
                for (String idStr : requestData.sourceRecordIds) {
                    if (String.isNotBlank(idStr)) {
                        payload.sourceRecordIds.add(Id.valueOf(idStr));
                    }
                }
            }

            payload.triggerPayload = requestData.triggerPayload;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Delegating to AgentExecutionService as service user: ' + UserInfo.getUserName() + '. New execution: ' + (sessionId == null)
            );

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
            // Only try to fail the turn if we have an existing execution
            if (sessionId != null) {
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
            }

            throw e;
        }
    }

    private static AIAgentResponse executeApprovedHITLTool(RestRequest req, RestResponse res, String requestId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing HITL tool execution request');

        HITLToolRequest toolRequest = null;
        try {
            if (req.requestBody == null || req.requestBody.size() == 0) {
                throw new AIAgentRestException('Request body is required');
            }

            toolRequest = (HITLToolRequest) JSON.deserialize(req.requestBody.toString(), HITLToolRequest.class);

            if (String.isBlank(toolRequest.pendingActionId)) {
                throw new AIAgentRestException('pendingActionId is required');
            }
            if (String.isBlank(toolRequest.executionId)) {
                throw new AIAgentRestException('executionId is required');
            }
            if (String.isBlank(toolRequest.capabilityId)) {
                throw new AIAgentRestException('capabilityId is required');
            }

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Executing tool as authenticated user: ' + UserInfo.getUserName() + ' (UserId: ' + UserInfo.getUserId() + ')'
            );

            AgentCapability__c capability = AIAgentConfigService.getCapabilityById(Id.valueOf(toolRequest.capabilityId));
            if (capability == null) {
                throw new AIAgentRestException('Capability not found: ' + toolRequest.capabilityId);
            }

            AgentExecution__c execution = [
                SELECT Id, User__c, ServiceUser__c, AIAgentDefinition__c, SourceRecordId__c
                FROM AgentExecution__c
                WHERE Id = :toolRequest.executionId
                LIMIT 1
            ];

            ActionContext actionContext = new ActionContext(
                execution.Id,
                execution.User__c,
                UserInfo.getUserId(),
                String.isNotBlank(toolRequest.sourceRecordId) ? Id.valueOf(toolRequest.sourceRecordId) : null,
                execution.AIAgentDefinition__c,
                capability.Id,
                capability.ImplementationDetail__c,
                toolRequest.turnIdentifier,
                toolRequest.turnCount != null ? Integer.valueOf(toolRequest.turnCount) : 1,
                'HITLResume'
            );

            CapabilityExecutionService capabilityService = new CapabilityExecutionService();
            ActionOutcome outcome = capabilityService.executeSingleAction(capability, toolRequest.toolArguments, actionContext);

            try {
                IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(execution.Id, toolRequest.turnIdentifier);
                decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, outcome });
                decisionLogger.commitSteps();
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log tool result decision step: ' + e.getMessage());
            }

            ExecutionStepService stepService = new ExecutionStepService();
            String resultJson = OrchestrationService.serializeActionOutcome(outcome, logPrefix);

            Id updatedStepId = stepService.updateToolResultStep(execution.Id, toolRequest.toolCallId, resultJson, 0L, !outcome.isSuccess);

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
                    capability.Id,
                    !outcome.isSuccess
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Tool executed successfully. Success: ' + outcome.isSuccess);

            if (toolRequest.needsFollowUp == true) {
                queueFollowUpLLMCall(execution, toolRequest, logPrefix);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Conversational agent - no follow-up needed (pre-determined)');
            }

            if (
                String.isNotBlank(toolRequest.requestingUserId) &&
                shouldSendNotification(
                    capability,
                    outcome.isSuccess ? HITLGatewayService.NOTIFICATION_TYPE_APPROVAL : HITLGatewayService.NOTIFICATION_TYPE_ERROR
                )
            ) {
                String approverComment = null;
                if (String.isNotBlank(toolRequest.pendingActionId)) {
                    try {
                        List<PendingHITLAction__c> pendingActions = [
                            SELECT ResolutionComment__c
                            FROM PendingHITLAction__c
                            WHERE Id = :toolRequest.pendingActionId
                            LIMIT 1
                        ];
                        if (!pendingActions.isEmpty() && String.isNotBlank(pendingActions[0].ResolutionComment__c)) {
                            approverComment = pendingActions[0].ResolutionComment__c;
                        }
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, logPrefix + 'Could not retrieve approver comment: ' + e.getMessage());
                    }
                }

                String title = outcome.isSuccess ? 'Action Executed: ' + toolRequest.toolName : 'Action Failed: ' + toolRequest.toolName;

                String body = outcome.isSuccess
                    ? 'Your requested action "' + toolRequest.toolName + '" has been approved and executed successfully.'
                    : 'Your requested action "' + toolRequest.toolName + '" was approved but execution failed: ' + outcome.errorMessage;

                if (String.isNotBlank(approverComment)) {
                    body += '\n\nApprover comment: ' + approverComment;
                }

                HITLGatewayService.sendUserNotification(Id.valueOf(toolRequest.requestingUserId), title, body, execution.Id);
            }

            res.statusCode = 200;
            return new AIAgentResponse(true, 'Tool executed successfully', null, requestId);
        } catch (AIAgentRestException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            logResumeError(toolRequest, e.getMessage(), 'VALIDATION_ERROR');
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (AIAgentConfigService.ConfigurationException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            logResumeError(toolRequest, e.getMessage(), 'CONFIGURATION_ERROR');
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage() + '\n' + e.getStackTraceString());
            logResumeError(toolRequest, e.getMessage() + '\n' + e.getStackTraceString(), 'UNEXPECTED_ERROR');
            res.statusCode = 500;
            return new AIAgentResponse(false, null, 'Internal server error: ' + e.getMessage(), requestId);
        }
    }

    private static void logResumeError(HITLToolRequest toolRequest, String errorMessage, String errorCode) {
        if (toolRequest == null || String.isBlank(toolRequest.executionId) || String.isBlank(toolRequest.turnIdentifier)) {
            return;
        }

        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(Id.valueOf(toolRequest.executionId), toolRequest.turnIdentifier);
            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ toolRequest, errorCode, errorMessage });
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[AIAgentRestService] Failed to log resume error to decision steps: ' + e.getMessage());
        }
    }

    private static void queueFollowUpLLMCall(AgentExecution__c execution, HITLToolRequest toolRequest, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Queueing follow-up LLM call');

            AgentStateService stateService = new AgentStateService();
            stateService.resumeForFollowUpLlmCall(execution.Id, toolRequest.turnIdentifier, null, logPrefix);

            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            enqueuer.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                toolRequest.turnIdentifier,
                (toolRequest.turnCount != null ? Integer.valueOf(toolRequest.turnCount) : 1) + 1,
                logPrefix,
                false,
                execution.SourceRecordId__c
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue follow-up: ' + e.getMessage());
        }
    }

    /**
     * @description Handles follow-up LLM calls after HITL rejection/decline/expiration.
     * This endpoint is called via Named Credential to ensure the follow-up runs in service user context.
     */
    private static AIAgentResponse executeFollowUpLLMCall(RestRequest req, RestResponse res, String requestId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing HITL follow-up LLM request');

        try {
            if (req.requestBody == null || req.requestBody.size() == 0) {
                throw new AIAgentRestException('Request body is required');
            }

            HITLFollowUpRequest followUpRequest = (HITLFollowUpRequest) JSON.deserialize(req.requestBody.toString(), HITLFollowUpRequest.class);

            if (String.isBlank(followUpRequest.executionId)) {
                throw new AIAgentRestException('executionId is required');
            }
            if (String.isBlank(followUpRequest.turnIdentifier)) {
                throw new AIAgentRestException('turnIdentifier is required');
            }

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Queueing follow-up LLM as authenticated user: ' + UserInfo.getUserName() + ' (UserId: ' + UserInfo.getUserId() + ')'
            );

            AgentExecution__c execution = [
                SELECT Id, User__c, AIAgentDefinition__c, SourceRecordId__c
                FROM AgentExecution__c
                WHERE Id = :followUpRequest.executionId
                LIMIT 1
            ];

            // Queue the follow-up LLM call - it will run as the current user (service user via Named Credential)
            AgentStateService stateService = new AgentStateService();
            stateService.resumeForFollowUpLlmCall(execution.Id, followUpRequest.turnIdentifier, null, logPrefix);

            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            enqueuer.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                followUpRequest.turnIdentifier,
                (followUpRequest.turnCount != null ? Integer.valueOf(followUpRequest.turnCount) : 1) + 1,
                logPrefix,
                false,
                execution.SourceRecordId__c
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM call queued successfully');

            res.statusCode = 200;
            return new AIAgentResponse(true, 'QUEUED_FOLLOWUP', null, requestId);
        } catch (AIAgentRestException e) {
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
     * @description Handles execution resume in service user context.
     * This endpoint is called via Named Credential when an agent requires service user context
     * and a manual resume is triggered from the UI.
     */
    private static AIAgentResponse executeResumeInServiceContext(RestRequest req, RestResponse res, String requestId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing resume request in service user context');

        try {
            if (req.requestBody == null || req.requestBody.size() == 0) {
                throw new AIAgentRestException('Request body is required');
            }

            ResumeRequest resumeRequest = (ResumeRequest) JSON.deserialize(req.requestBody.toString(), ResumeRequest.class);

            if (String.isBlank(resumeRequest.executionId)) {
                throw new AIAgentRestException('executionId is required');
            }

            Id executionId = Id.valueOf(resumeRequest.executionId);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Resuming execution as authenticated user: ' + UserInfo.getUserName() + ' (UserId: ' + UserInfo.getUserId() + ')'
            );

            // Load execution and validate
            AgentExecution__c exec = [
                SELECT Id, ExecutionStatus__c, ExecutionType__c, AIAgentDefinition__c, AIAgentDefinition__r.DeveloperName__c, AIAgentDefinition__r.AgentType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (exec.ExecutionStatus__c == 'Completed') {
                throw new AIAgentRestException('Execution is already completed. Nothing to resume.');
            }

            // Load agent definition
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(exec.AIAgentDefinition__c);
            if (agentDef == null) {
                throw new AIAgentRestException('Agent definition not found for execution: ' + executionId);
            }

            // Get orchestrator for this agent
            IAgentOrchestrator orchestrator = AgentExecutionService.getOrchestrator(agentDef);

            // Check if execution can be resumed
            if (!orchestrator.canResume(executionId)) {
                throw new AIAgentRestException('Execution cannot be resumed from its current state.');
            }

            // Build resume options
            BaseAgentOrchestrator.ResumeOptions options = new BaseAgentOrchestrator.ResumeOptions()
                .withReason(String.isNotBlank(resumeRequest.resumeReason) ? resumeRequest.resumeReason : 'Resume via service user context');

            if (resumeRequest.retryFailedTool != null) {
                options.withRetryFailedTool(resumeRequest.retryFailedTool);
            }

            // Execute resume
            AgentExecutionService.ExecutionResult result = orchestrator.resume(executionId, options);

            System.debug(LoggingLevel.INFO, logPrefix + 'Resume completed. Success: ' + result.success + ', Message: ' + result.message);

            res.statusCode = 200;
            return new AIAgentResponse(result.success, result.message, result.errorMessage, requestId);
        } catch (AIAgentRestException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage());
            res.statusCode = 400;
            return new AIAgentResponse(false, null, e.getMessage(), requestId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage() + '\n' + e.getStackTraceString());
            res.statusCode = 500;
            return new AIAgentResponse(false, null, 'Internal server error: ' + e.getMessage(), requestId);
        }
    }

    private static String generateRequestId() {
        return String.valueOf(Crypto.getRandomLong()).substring(1, 9);
    }

    public class AIAgentRequest {
        public String sessionId { get; set; } // Optional for new executions
        public String originalUserId { get; set; }
        public String agentDefinitionId { get; set; }
        public String turnIdentifier { get; set; }
        public String userMessage { get; set; }
        public String currentRecordId { get; set; }
        // Additional fields for full context support (new in service user routing)
        public String sourceRecordId { get; set; }
        public List<String> sourceRecordIds { get; set; }
        public String triggerPayload { get; set; }
        public String triggerSource { get; set; }
        public String batchId { get; set; }
        public Integer priority { get; set; }
    }

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

    public class HITLToolRequest {
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
        public Boolean needsFollowUp { get; set; }
    }

    public class HITLFollowUpRequest {
        public String executionId { get; set; }
        public String turnIdentifier { get; set; }
        public Decimal turnCount { get; set; }
        public String sourceRecordId { get; set; }
    }

    public class ResumeRequest {
        public String executionId { get; set; }
        public String resumeReason { get; set; }
        public Boolean retryFailedTool { get; set; }
    }

    public class AIAgentRestException extends Exception {
    }

    private static Boolean shouldSendNotification(AgentCapability__c capability, String eventType) {
        return HITLGatewayService.shouldSendHITLNotification(capability.HITLNotificationPreference__c, eventType);
    }
}
