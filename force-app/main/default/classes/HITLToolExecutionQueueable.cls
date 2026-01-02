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
                
                // Notify user of failure
                if (action.RequestingUser__c != null) {
                    NotificationService.sendUserNotification(
                        action.RequestingUser__c,
                        'Tool Execution Failed: ' + action.ToolName__c,
                        'Failed to execute approved action in service user context: ' + errorMsg,
                        action.AgentExecution__c
                    );
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing tool via REST API: ' + 
                e.getMessage() + '\n' + e.getStackTraceString());
            
            // Try to notify user of failure
            try {
                PendingHITLAction__c action = HITLGatewayService.getPendingAction(pendingActionId);
                if (action?.RequestingUser__c != null) {
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
}

