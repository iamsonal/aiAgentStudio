/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Queueable job that executes approved HITL tools through REST API for proper user context switching.
 *
 * When an agent requires specific execution context (service user or per-user), tool execution
 * after approval must run in the correct user's context, not the approver's context. This Queueable
 * routes the tool execution through the internal REST API using Named Credential authentication,
 * which switches execution to the configured user.
 *
 * The Named Credential used is configurable via AIAgentFrameworkSettings__c.HITLApprovalNamedCredential__c
 *
 * Flow:
 * 1. Approval trigger detects approved status
 * 2. Enqueues this Queueable instead of executing directly
 * 3. Queueable makes HTTP callout to AIAgentRestService.executeApprovedHITLTool()
 * 4. REST API executes in the Named Credential's authenticated user context
 * 5. Tool executes with that user's permissions
 *
 * @author Sonal
 * @since 2025
 */
public class HITLToolExecutionQueueable implements Queueable, Database.AllowsCallouts {
    private static final String LOG_PREFIX = '[HITLToolExecQueue] ';

    private Id pendingActionId;
    private Boolean needsFollowUp;

    /**
     * @description Constructs a new HITL tool execution queueable job.
     * @param pendingActionId The PendingHITLAction__c record ID to execute
     * @param needsFollowUp Whether a follow-up LLM call will be needed (false for Conversational agents)
     */
    public HITLToolExecutionQueueable(Id pendingActionId, Boolean needsFollowUp) {
        this.pendingActionId = pendingActionId;
        this.needsFollowUp = needsFollowUp != null ? needsFollowUp : true; // Default to true if null
    }

    /**
     * @description Executes the queueable job - routes tool execution through REST API.
     * @param context The queueable context
     */
    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[JobId:' + context.getJobId() + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting HITL tool execution via REST API for action: ' + pendingActionId);

        try {
            // Load the pending action
            PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
            if (action == null) {
                throw new HITLGatewayService.HITLProcessingException('Pending action not found: ' + pendingActionId);
            }

            // Build HTTP request
            HttpRequest httpReq = buildHttpRequest(action, logPrefix);

            // Execute callout
            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            // Parse response
            if (result.response.getStatusCode() == 200) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution successful via REST API');
            } else {
                String errorMsg = 'HTTP ' + result.response.getStatusCode() + ': ' + result.response.getBody();
                System.debug(LoggingLevel.ERROR, logPrefix + 'Tool execution failed: ' + errorMsg);

                // Log HTTP error to decision steps
                try {
                    logHttpError(action, result.response.getStatusCode(), result.response.getBody(), logPrefix);
                } catch (Exception logEx) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log HTTP error to decision steps: ' + logEx.getMessage());
                }

                // Notify user of failure (check notification preference)
                if (action.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_ERROR)) {
                    NotificationService.sendUserNotification(
                        action.RequestingUser__c,
                        'Tool Execution Failed: ' + action.ToolName__c,
                        'Failed to execute approved action in service user context: ' + errorMsg,
                        action.AgentExecution__c
                    );
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing tool via REST API: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Log error to decision steps for visibility in storyboard
            try {
                PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
                if (action != null && action.AgentExecution__c != null && String.isNotBlank(action.TurnIdentifier__c)) {
                    logToolExecutionError(action, e, logPrefix);
                }
            } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log error to decision steps: ' + logEx.getMessage());
            }

            // Try to notify user of failure (check notification preference)
            try {
                PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
                if (action?.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_ERROR)) {
                    NotificationService.sendUserNotification(
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
    }

    /**
     * @description Builds the HTTP request for tool execution via REST API.
     * Uses the Named Credential configured in AIAgentFrameworkSettings__c.
     * @param action The pending HITL action
     * @param logPrefix Logging prefix
     * @return Configured HttpRequest
     */
    private HttpRequest buildHttpRequest(PendingHITLAction__c action, String logPrefix) {
        // Get Named Credential from custom setting
        String namedCredential = AIAgentFrameworkSettings.getHITLApprovalNamedCredential();
        String endpoint = 'callout:' + namedCredential + '/services/apexrest/ai/agent/hitl/execute';

        System.debug(LoggingLevel.INFO, logPrefix + 'Using Named Credential for HITL execution: ' + namedCredential);

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');
        httpReq.setTimeout(120000); // 2 minutes

        // Build request payload
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
            'needsFollowUp' => this.needsFollowUp // Pass follow-up flag to REST API
        };

        httpReq.setBody(JSON.serialize(requestBody));

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for tool execution via Named Credential');
        return httpReq;
    }

    /**
     * @description Determines if a notification should be sent based on the capability's notification preference.
     * @param action The PendingHITLAction__c record (must have AIAgentCapability__r.HITLNotificationPreference__c populated)
     * @param eventType The type of event: HITLGatewayService.NOTIFICATION_TYPE_APPROVAL, NOTIFICATION_TYPE_REJECTION, or NOTIFICATION_TYPE_ERROR
     * @return True if notification should be sent, false otherwise
     */
    private static Boolean shouldSendNotification(PendingHITLAction__c action, String eventType) {
        String preference = action.AIAgentCapability__r?.HITLNotificationPreference__c;
        return HITLGatewayService.shouldSendHITLNotification(preference, eventType);
    }

    /**
     * @description Logs HTTP error responses for visibility in storyboard.
     * @param action The PendingHITLAction__c record with execution context
     * @param statusCode The HTTP status code
     * @param responseBody The HTTP response body
     * @param logPrefix Logging prefix
     */
    private static void logHttpError(PendingHITLAction__c action, Integer statusCode, String responseBody, String logPrefix) {
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(action.AgentExecution__c, action.TurnIdentifier__c);

            // Build error details
            Map<String, Object> errorDetails = new Map<String, Object>{
                'errorCode' => 'HTTP_ERROR',
                'httpStatusCode' => statusCode,
                'responseBody' => responseBody,
                'toolName' => action.ToolName__c,
                'capabilityId' => action.AIAgentCapability__c,
                'pendingActionId' => action.Id,
                'toolCallId' => action.ToolCallId__c
            };

            decisionLogger.logError(
                'Tool Execution HTTP Error',
                'HTTP ' + statusCode + ' error executing tool "' + (action.ToolName__c ?? 'Unknown') + '" after approval',
                'HTTP_ERROR',
                'HTTP ' + statusCode + ': ' + responseBody,
                JSON.serialize(errorDetails),
                0L
            );

            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'HTTP error logged to decision steps for storyboard visibility');
        } catch (Exception logEx) {
            // Best effort - don't let logging errors break the error handling
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log HTTP error to decision steps: ' + logEx.getMessage());
        }
    }

    /**
     * @description Logs tool execution errors for visibility in storyboard.
     * @param action The PendingHITLAction__c record with execution context
     * @param e The exception that occurred
     * @param logPrefix Logging prefix
     */
    private static void logToolExecutionError(PendingHITLAction__c action, Exception e, String logPrefix) {
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(action.AgentExecution__c, action.TurnIdentifier__c);

            // Determine error category
            String errorCode = 'TOOL_EXECUTION_ERROR';
            if (e instanceof AIAgentException.NonRetriableHttpException) {
                errorCode = 'CALLOUT_ERROR';
            } else if (e instanceof System.CalloutException) {
                errorCode = 'CALLOUT_ERROR';
            } else if (e instanceof HITLGatewayService.HITLProcessingException) {
                errorCode = 'HITL_PROCESSING_ERROR';
            }

            // Build error details
            Map<String, Object> errorDetails = new Map<String, Object>{
                'errorCode' => errorCode,
                'errorMessage' => e.getMessage(),
                'errorType' => e.getTypeName(),
                'stackTrace' => e.getStackTraceString(),
                'toolName' => action.ToolName__c,
                'capabilityId' => action.AIAgentCapability__c,
                'pendingActionId' => action.Id,
                'toolCallId' => action.ToolCallId__c
            };

            decisionLogger.logError(
                'Tool Execution Error',
                'Error executing tool "' + (action.ToolName__c ?? 'Unknown') + '" after approval',
                errorCode,
                e.getMessage(),
                JSON.serialize(errorDetails),
                0L
            );

            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Error logged to decision steps for storyboard visibility');
        } catch (Exception logEx) {
            // Best effort - don't let logging errors break the error handling
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log error to decision steps: ' + logEx.getMessage());
        }
    }
}
