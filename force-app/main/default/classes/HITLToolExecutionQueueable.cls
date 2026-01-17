/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable job that executes approved HITL tools through REST API for proper user context switching.
 */
public class HITLToolExecutionQueueable implements Queueable, Database.AllowsCallouts {
    private static final String LOG_PREFIX = '[HITLToolExecQueue] ';
    private Id pendingActionId;
    private Boolean needsFollowUp;

    public HITLToolExecutionQueueable(Id pendingActionId, Boolean needsFollowUp) {
        this.pendingActionId = pendingActionId;
        this.needsFollowUp = needsFollowUp != null ? needsFollowUp : true;
    }
    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[JobId:' + context.getJobId() + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting HITL tool execution via REST API for action: ' + pendingActionId);

        try {
            PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
            if (action == null) {
                throw new HITLGatewayService.HITLProcessingException('Pending action not found: ' + pendingActionId);
            }

            HttpRequest httpReq = buildHttpRequest(action, logPrefix);

            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            if (result.response.getStatusCode() == 200) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution successful via REST API');
            } else {
                String errorMsg = 'HTTP ' + result.response.getStatusCode() + ': ' + result.response.getBody();
                System.debug(LoggingLevel.ERROR, logPrefix + 'Tool execution failed: ' + errorMsg);

                try {
                    logHttpError(action, result.response.getStatusCode(), result.response.getBody(), logPrefix);
                } catch (Exception logEx) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log HTTP error to decision steps: ' + logEx.getMessage());
                }

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

            try {
                PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
                if (action != null && action.AgentExecution__c != null && String.isNotBlank(action.TurnIdentifier__c)) {
                    logToolExecutionError(action, e, logPrefix);
                }
            } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log error to decision steps: ' + logEx.getMessage());
            }

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

    private HttpRequest buildHttpRequest(PendingHITLAction__c action, String logPrefix) {
        String namedCredential = AIAgentFrameworkSettings.getHITLApprovalNamedCredential();
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

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for tool execution via Named Credential');
        return httpReq;
    }

    private static Boolean shouldSendNotification(PendingHITLAction__c action, String eventType) {
        String preference = action.AIAgentCapability__r?.HITLNotificationPreference__c;
        return HITLGatewayService.shouldSendHITLNotification(preference, eventType);
    }

    private static void logHttpError(PendingHITLAction__c action, Integer statusCode, String responseBody, String logPrefix) {
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(action.AgentExecution__c, action.TurnIdentifier__c);

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
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log HTTP error to decision steps: ' + logEx.getMessage());
        }
    }

    private static void logToolExecutionError(PendingHITLAction__c action, Exception e, String logPrefix) {
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(action.AgentExecution__c, action.TurnIdentifier__c);

            String errorCode = 'TOOL_EXECUTION_ERROR';
            if (e instanceof AIAgentException.NonRetriableHttpException) {
                errorCode = 'CALLOUT_ERROR';
            } else if (e instanceof System.CalloutException) {
                errorCode = 'CALLOUT_ERROR';
            } else if (e instanceof HITLGatewayService.HITLProcessingException) {
                errorCode = 'HITL_PROCESSING_ERROR';
            }

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
