/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unified queueable job for HITL post-approval operations that must run under the
 * service user identity (elevated permissions) rather than the approver's identity.
 *
 * ── ARCHITECTURAL CONSTRAINT: WHY THIS USES A SELF-CALLOUT ──────────────────────────────────
 * Salesforce Apex has no native "run as <user>" API. The only way to execute code under a
 * different user identity within the same org is to make an HTTP callout back to the org's
 * own REST API using a Named Credential whose authentication is tied to the target user
 * (ServiceUserNamedCredential__c on AIAgentDefinition__c).
 *
 * Pre-requisites that must be in place for this pattern to work:
 *   1. A Connected App with "Run as" or JWT Bearer flow credentials for the service user.
 *   2. A Named Credential (per agent definition) authenticated as the service user.
 *   3. The target REST endpoints (ai/agent/hitl/execute, hitl/followup, ai/agent/resume)
 *      configured in Remote Site Settings / CORS policy for the org's My Domain URL.
 *   4. This class declared `without sharing` — it runs in the approver's Queueable context
 *      but the tool execution is performed by the REST handler in the service user context.
 *
 * Trade-offs:
 *   + Cleanly separates approver identity from execution identity.
 *   + Reuses existing REST handlers — no duplicate logic.
 *   - Consumes one HTTP callout limit (500/tx) per HITL operation.
 *   - Adds ~200–500 ms of network latency for the loopback call.
 *   - Requires Named Credential setup per agent, increasing operational overhead.
 *   - If the Named Credential expires or the connected app is revoked, HITL silently fails.
 *
 * If Salesforce ever provides a first-class "run-as" Apex API this pattern should be removed.
 * ────────────────────────────────────────────────────────────────────────────────────────────
 *
 * Supports three operation modes:
 * - EXECUTE_TOOL:   Execute an approved HITL tool and optionally queue follow-up LLM call.
 * - FOLLOWUP_ONLY: Queue a follow-up LLM call without tool execution (rejection/decline/expiry).
 * - RESUME:        Resume a failed/stuck execution in service user context.
 */
public without sharing class HITLServiceQueueable implements Queueable, Database.AllowsCallouts {
    private static final String LOG_PREFIX = '[HITLServiceQueue] ';

    public enum OperationType {
        EXECUTE_TOOL,
        FOLLOWUP_ONLY,
        RESUME
    }

    private OperationType operationType;

    // For EXECUTE_TOOL mode
    private Id pendingActionId;
    private Boolean needsFollowUp;

    // For FOLLOWUP_ONLY mode
    private Id executionId;
    private String turnIdentifier;
    private Integer turnCount;
    private Id sourceRecordId;

    // For RESUME mode
    private String resumeReason;
    private Boolean retryFailedTool;

    /**
     * Constructor for EXECUTE_TOOL mode - executes approved tool via REST API
     * @param pendingActionId The ID of the pending HITL action to execute
     * @param needsFollowUp Whether to queue a follow-up LLM call after tool execution
     */
    public HITLServiceQueueable(Id pendingActionId, Boolean needsFollowUp) {
        this.operationType = HITLServiceQueueable.OperationType.EXECUTE_TOOL;
        this.pendingActionId = pendingActionId;
        this.needsFollowUp = needsFollowUp != null ? needsFollowUp : true;
    }

    /**
     * Constructor for FOLLOWUP_ONLY mode - queues follow-up LLM without tool execution
     * Used when HITL requests are rejected/declined/expired
     * @param executionId The agent execution ID
     * @param turnIdentifier The current turn identifier
     * @param turnCount The current turn count
     * @param sourceRecordId The source record ID for context
     */
    public HITLServiceQueueable(Id executionId, String turnIdentifier, Integer turnCount, Id sourceRecordId) {
        this.operationType = HITLServiceQueueable.OperationType.FOLLOWUP_ONLY;
        this.executionId = executionId;
        this.turnIdentifier = turnIdentifier;
        this.turnCount = turnCount;
        this.sourceRecordId = sourceRecordId;
    }

    /**
     * Constructor for RESUME mode - resumes execution in service user context
     * Used when manual resume is triggered and agent requires service user context
     * @param executionId The agent execution ID to resume
     * @param resumeReason The reason for resuming (for logging)
     * @param retryFailedTool Whether to retry the last failed tool (null = auto-detect)
     */
    public HITLServiceQueueable(Id executionId, String resumeReason, Boolean retryFailedTool) {
        this.operationType = HITLServiceQueueable.OperationType.RESUME;
        this.executionId = executionId;
        this.resumeReason = resumeReason;
        this.retryFailedTool = retryFailedTool;
    }

    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[JobId:' + context.getJobId() + '] ';

        if (operationType == HITLServiceQueueable.OperationType.EXECUTE_TOOL) {
            executeToolViaRestApi(logPrefix);
        } else if (operationType == HITLServiceQueueable.OperationType.FOLLOWUP_ONLY) {
            executeFollowUpViaRestApi(logPrefix);
        } else if (operationType == HITLServiceQueueable.OperationType.RESUME) {
            executeResumeViaRestApi(logPrefix);
        }
    }

    // ==================================================================================
    // EXECUTE_TOOL MODE
    // ==================================================================================

    private void executeToolViaRestApi(String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting HITL tool execution via REST API for action: ' + pendingActionId);

        try {
            PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
            if (action == null) {
                throw new HITLGatewayService.HITLProcessingException('Pending action not found: ' + pendingActionId);
            }

            HttpRequest httpReq = buildToolExecutionRequest(action, logPrefix);
            HttpCalloutService.CalloutResult result = executeHttpRequest(httpReq, logPrefix);

            // HttpCalloutService throws exception for non-200, so reaching here means success
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution successful via REST API');
        } catch (Exception e) {
            handleToolExecutionError(e, logPrefix);
        }
    }

    private HttpRequest buildToolExecutionRequest(PendingHITLAction__c action, String logPrefix) {
        String namedCredential = getServiceUserNamedCredential(action.AgentExecution__c, logPrefix);
        String endpoint = 'callout:' + namedCredential + '/services/apexrest/ai/agent/hitl/execute';

        System.debug(LoggingLevel.INFO, logPrefix + 'Using Named Credential for HITL execution: ' + namedCredential);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setTimeout(120000);

        Map<String, Object> requestBody = new Map<String, Object>{
            'pendingActionId' => String.valueOf(action.Id),
            'executionId' => String.valueOf(action.AgentExecution__c),
            'capabilityId' => String.valueOf(action.AIAgentCapability__c),
            'toolCallId' => action.ToolCallId__c,
            'toolName' => action.ToolName__c,
            'toolArguments' => action.ToolArgumentsJSON__c,
            'turnIdentifier' => action.TurnIdentifier__c,
            'turnCount' => action.TurnCount__c,
            'sourceRecordId' => action.SourceRecordId__c,
            'requestingUserId' => String.valueOf(action.RequestingUser__c),
            'needsFollowUp' => this.needsFollowUp
        };

        httpReq.setBody(JSON.serialize(requestBody));
        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for tool execution');
        return httpReq;
    }

    private void handleToolExecutionError(Exception e, String logPrefix) {
        System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing tool via REST API: ' + e.getMessage() + '\n' + e.getStackTraceString());

        try {
            PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
            if (action != null && action.AgentExecution__c != null && String.isNotBlank(action.TurnIdentifier__c)) {
                logExecutionError(action.AgentExecution__c, action.TurnIdentifier__c, action.ToolName__c, e, logPrefix);
            }
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log error to decision steps: ' + logEx.getMessage());
        }

        try {
            PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
            if (action?.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_ERROR)) {
                HITLGatewayService.sendUserNotification(
                    action.RequestingUser__c,
                    'Tool Execution Error: ' + (action.ToolName__c ?? 'Unknown'),
                    'Error executing approved action: ' + e.getMessage(),
                    action.AgentExecution__c
                );
            }
        } catch (Exception notifyEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to notify user: ' + notifyEx.getMessage());
        }
    }

    // ==================================================================================
    // FOLLOWUP_ONLY MODE
    // ==================================================================================

    private void executeFollowUpViaRestApi(String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting follow-up LLM call via REST API for execution: ' + executionId);

        try {
            HttpRequest httpReq = buildFollowUpRequest(logPrefix);
            HttpCalloutService.CalloutResult result = executeHttpRequest(httpReq, logPrefix);

            // HttpCalloutService throws exception for non-200, so reaching here means success
            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM call queued successfully via REST API');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error triggering follow-up LLM via REST API: ' + e.getMessage() + '\n' + e.getStackTraceString());
            logExecutionError(executionId, turnIdentifier, null, e, logPrefix);
        }
    }

    private HttpRequest buildFollowUpRequest(String logPrefix) {
        String namedCredential = getServiceUserNamedCredential(this.executionId, logPrefix);
        String endpoint = 'callout:' + namedCredential + '/services/apexrest/ai/agent/hitl/followup';

        System.debug(LoggingLevel.INFO, logPrefix + 'Using Named Credential for follow-up LLM: ' + namedCredential);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setTimeout(120000);

        Map<String, Object> requestBody = new Map<String, Object>{
            'executionId' => String.valueOf(this.executionId),
            'turnIdentifier' => this.turnIdentifier,
            'turnCount' => this.turnCount,
            'sourceRecordId' => this.sourceRecordId != null ? String.valueOf(this.sourceRecordId) : null
        };

        httpReq.setBody(JSON.serialize(requestBody));
        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for follow-up LLM');
        return httpReq;
    }

    // ==================================================================================
    // RESUME MODE
    // ==================================================================================

    private void executeResumeViaRestApi(String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting resume via REST API for execution: ' + executionId);

        try {
            HttpRequest httpReq = buildResumeRequest(logPrefix);
            HttpCalloutService.CalloutResult result = executeHttpRequest(httpReq, logPrefix);

            // HttpCalloutService throws exception for non-200, so reaching here means success
            System.debug(LoggingLevel.INFO, logPrefix + 'Resume completed successfully via REST API');

            // Parse response to log result
            Map<String, Object> responseData = (Map<String, Object>) JSON.deserializeUntyped(result.response.getBody());
            Boolean success = (Boolean) responseData.get('success');
            String message = (String) responseData.get('message');

            if (success == true) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Resume result: ' + message);
            } else {
                System.debug(LoggingLevel.WARN, logPrefix + 'Resume completed with warning: ' + message);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing resume via REST API: ' + e.getMessage() + '\n' + e.getStackTraceString());
            logExecutionError(executionId, null, null, e, logPrefix);
        }
    }

    private HttpRequest buildResumeRequest(String logPrefix) {
        String namedCredential = getServiceUserNamedCredential(this.executionId, logPrefix);
        String endpoint = 'callout:' + namedCredential + '/services/apexrest/ai/agent/resume';

        System.debug(LoggingLevel.INFO, logPrefix + 'Using Named Credential for resume: ' + namedCredential);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setTimeout(120000);

        Map<String, Object> requestBody = new Map<String, Object>{
            'executionId' => String.valueOf(this.executionId),
            'resumeReason' => this.resumeReason,
            'retryFailedTool' => this.retryFailedTool
        };

        httpReq.setBody(JSON.serialize(requestBody));
        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for resume');
        return httpReq;
    }

    // ==================================================================================
    // SHARED UTILITIES
    // ==================================================================================

    private HttpCalloutService.CalloutResult executeHttpRequest(HttpRequest httpReq, String logPrefix) {
        HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
        return HttpCalloutService.execute(httpReq, config);
    }

    private String getServiceUserNamedCredential(Id execId, String logPrefix) {
        if (execId == null) {
            throw new AIAgentException.OrchestrationException('Execution ID is required to resolve service user Named Credential');
        }

        List<AgentExecution__c> execs = [
            SELECT AIAgentDefinition__r.ServiceUserNamedCredential__c
            FROM AgentExecution__c
            WHERE Id = :execId
            LIMIT 1
        ];
        if (execs.isEmpty() || String.isBlank(execs[0].AIAgentDefinition__r.ServiceUserNamedCredential__c)) {
            throw new AIAgentException.OrchestrationException(
                'ServiceUserNamedCredential__c is not configured on AIAgentDefinition__c for execution: ' + execId
            );
        }

        String namedCredential = execs[0].AIAgentDefinition__r.ServiceUserNamedCredential__c;
        System.debug(LoggingLevel.INFO, logPrefix + 'Using service user Named Credential: ' + namedCredential);
        return namedCredential;
    }

    private static Boolean shouldSendNotification(PendingHITLAction__c action, String eventType) {
        String preference = action.AIAgentCapability__r?.HITLNotificationPreference__c;
        return HITLGatewayService.shouldSendHITLNotification(preference, eventType);
    }

    private void logExecutionError(Id execId, String turnId, String toolName, Exception e, String logPrefix) {
        try {
            if (String.isBlank(turnId) && execId != null) {
                List<AgentExecution__c> execs = [
                    SELECT CurrentTurnIdentifier__c
                    FROM AgentExecution__c
                    WHERE Id = :execId
                    LIMIT 1
                ];
                if (!execs.isEmpty()) {
                    turnId = execs[0].CurrentTurnIdentifier__c;
                }
            }
            if (String.isBlank(turnId)) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Skipping decision step logging (missing turn identifier)');
                return;
            }
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(execId, turnId);
            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ e, toolName });
            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Error logged to decision steps');
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log error to decision steps: ' + logEx.getMessage());
        }
    }
}
