/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Trigger handler for PendingHITLAction__c records. Handles:
 * - Approval process status changes (Approved/Rejected)
 * - Automatic execution resumption after HITL resolution
 * - Notification to users about HITL status changes
 *
 * This handler bridges the gap between Salesforce Approval Process and the
 * AI Agent Framework's execution flow.
 */
public with sharing class PendingHITLActionTriggerHandler {
    private static final String LOG_PREFIX = '[PendingHITLActionHandler] ';

    /**
     * @description Main entry point for after update trigger.
     * Detects status changes and routes to appropriate handlers.
     *
     * @param newRecords List of updated PendingHITLAction__c records
     * @param oldMap Map of old record versions
     */
    public static void handleAfterUpdate(List<PendingHITLAction__c> newRecords, Map<Id, PendingHITLAction__c> oldMap) {
        List<PendingHITLAction__c> confirmedActions = new List<PendingHITLAction__c>();
        List<PendingHITLAction__c> declinedActions = new List<PendingHITLAction__c>();
        List<PendingHITLAction__c> approvedActions = new List<PendingHITLAction__c>();
        List<PendingHITLAction__c> rejectedActions = new List<PendingHITLAction__c>();
        List<PendingHITLAction__c> expiredActions = new List<PendingHITLAction__c>();
        List<PendingHITLAction__c> recordsToUpdate = new List<PendingHITLAction__c>();
        Set<Id> recordsNeedingApprovalComments = new Set<Id>();

        for (PendingHITLAction__c newRecord : newRecords) {
            PendingHITLAction__c oldRecord = oldMap.get(newRecord.Id);

            // Only process if status changed
            if (newRecord.Status__c == oldRecord.Status__c) {
                continue;
            }

            String newStatus = newRecord.Status__c;
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Status changed for ' + newRecord.Id + ': ' + oldRecord.Status__c + ' → ' + newStatus);

            // Populate ResolvedAt__c and ResolvedBy__c for all resolved statuses
            if (isResolvedStatus(newStatus)) {
                PendingHITLAction__c recordToUpdate = new PendingHITLAction__c(Id = newRecord.Id, ResolvedAt__c = Datetime.now());

                // Set ResolvedBy__c based on resolution type
                if (newStatus == HITLGatewayService.STATUS_EXPIRED) {
                    // For expired actions, leave ResolvedBy__c null (system resolution)
                    recordToUpdate.ResolvedBy__c = null;
                } else {
                    // For manual resolutions (Confirmed, Declined, Approved, Rejected)
                    recordToUpdate.ResolvedBy__c = UserInfo.getUserId();
                }

                recordsToUpdate.add(recordToUpdate);

                // For Approved/Rejected, we need to capture approval comments
                if (newStatus == HITLGatewayService.STATUS_APPROVED || newStatus == HITLGatewayService.STATUS_REJECTED) {
                    recordsNeedingApprovalComments.add(newRecord.Id);
                }
            }

            // Route to appropriate handler based on new status
            if (newStatus == HITLGatewayService.STATUS_CONFIRMED) {
                confirmedActions.add(newRecord);
            } else if (newStatus == HITLGatewayService.STATUS_DECLINED) {
                declinedActions.add(newRecord);
            } else if (newStatus == HITLGatewayService.STATUS_APPROVED) {
                approvedActions.add(newRecord);
            } else if (newStatus == HITLGatewayService.STATUS_REJECTED) {
                rejectedActions.add(newRecord);
            } else if (newStatus == HITLGatewayService.STATUS_EXPIRED) {
                expiredActions.add(newRecord);
            }
        }

        // Capture approval comments for approved/rejected records
        if (!recordsNeedingApprovalComments.isEmpty()) {
            captureApprovalComments(recordsNeedingApprovalComments, recordsToUpdate);
        }

        // Update ResolvedAt__c and ResolvedBy__c fields
        if (!recordsToUpdate.isEmpty()) {
            try {
                update recordsToUpdate;
                System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Updated resolution tracking for ' + recordsToUpdate.size() + ' record(s)');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to update resolution tracking: ' + e.getMessage());
                // Don't throw - this is audit data, shouldn't block the main flow
            }
        }

        // Query relationship fields for actions that need notification preference checks
        Set<Id> actionIdsNeedingNotificationCheck = new Set<Id>();
        actionIdsNeedingNotificationCheck.addAll(getActionIds(approvedActions));
        actionIdsNeedingNotificationCheck.addAll(getActionIds(rejectedActions));
        actionIdsNeedingNotificationCheck.addAll(getActionIds(expiredActions));

        Map<Id, PendingHITLAction__c> actionsWithRelationships = new Map<Id, PendingHITLAction__c>();
        if (!actionIdsNeedingNotificationCheck.isEmpty()) {
            actionsWithRelationships = new Map<Id, PendingHITLAction__c>(
                [
                    SELECT
                        Id,
                        RequestingUser__c,
                        ToolName__c,
                        AgentExecution__c,
                        TurnIdentifier__c,
                        TurnCount__c,
                        ResolutionComment__c,
                        AIAgentCapability__r.HITLNotificationPreference__c
                    FROM PendingHITLAction__c
                    WHERE Id IN :actionIdsNeedingNotificationCheck
                ]
            );
        }

        // Replace action lists with queried records that include relationship data
        approvedActions = mergeRelationshipData(approvedActions, actionsWithRelationships);
        rejectedActions = mergeRelationshipData(rejectedActions, actionsWithRelationships);
        expiredActions = mergeRelationshipData(expiredActions, actionsWithRelationships);

        // Process each category
        if (!confirmedActions.isEmpty()) {
            processConfirmedActions(confirmedActions);
        }
        if (!declinedActions.isEmpty()) {
            processDeclinedActions(declinedActions);
        }
        if (!approvedActions.isEmpty()) {
            processApprovedActions(approvedActions);
        }
        if (!rejectedActions.isEmpty()) {
            processRejectedActions(rejectedActions);
        }
        if (!expiredActions.isEmpty()) {
            processExpiredActions(expiredActions);
        }
    }

    /**
     * @description Determines if a status represents a resolved state.
     * @param status The status to check
     * @return true if the status is a resolved state
     */
    private static Boolean isResolvedStatus(String status) {
        return status == HITLGatewayService.STATUS_CONFIRMED ||
            status == HITLGatewayService.STATUS_DECLINED ||
            status == HITLGatewayService.STATUS_APPROVED ||
            status == HITLGatewayService.STATUS_REJECTED ||
            status == HITLGatewayService.STATUS_EXPIRED;
    }

    /**
     * @description Captures approval comments and ProcessInstance ID from ProcessInstanceStep and updates PendingHITLAction records.
     * When an approver approves/rejects a record, they can add comments. These comments are stored in
     * ProcessInstanceStep.Comments, and we need to copy them to PendingHITLAction__c.ResolutionComment__c.
     * Also populates ApprovalProcessInstanceId__c if not already set.
     *
     * @param recordIds Set of PendingHITLAction__c IDs that need approval comments
     * @param recordsToUpdate List of records being updated (to add ResolutionComment__c updates)
     */
    private static void captureApprovalComments(Set<Id> recordIds, List<PendingHITLAction__c> recordsToUpdate) {
        String logPrefix = LOG_PREFIX + '[captureApprovalComments] ';

        try {
            // Query ProcessInstance records for our target objects, then get the steps with comments
            // ProcessInstanceStep contains the approval/rejection comments
            List<ProcessInstance> processInstances = [
                SELECT
                    Id,
                    TargetObjectId,
                    (
                        SELECT Id, Comments, StepStatus, ActorId, CreatedDate
                        FROM StepsAndWorkitems
                        WHERE StepStatus IN ('Approved', 'Rejected')
                        ORDER BY CreatedDate DESC
                    )
                FROM ProcessInstance
                WHERE TargetObjectId IN :recordIds AND Status IN ('Approved', 'Rejected')
            ];

            // Build maps for record ID to comment and ProcessInstance ID
            Map<Id, String> recordIdToComment = new Map<Id, String>();
            Map<Id, Id> recordIdToProcessInstanceId = new Map<Id, Id>();

            for (ProcessInstance pi : processInstances) {
                // Always capture the ProcessInstance ID
                recordIdToProcessInstanceId.put(pi.TargetObjectId, pi.Id);

                if (pi.StepsAndWorkitems != null && !pi.StepsAndWorkitems.isEmpty()) {
                    for (ProcessInstanceHistory step : pi.StepsAndWorkitems) {
                        // Only capture if there's a comment and we haven't captured one for this record yet
                        if (String.isNotBlank(step.Comments) && !recordIdToComment.containsKey(pi.TargetObjectId)) {
                            recordIdToComment.put(pi.TargetObjectId, step.Comments);
                            break; // Got the most recent comment, move to next process instance
                        }
                    }
                }
            }

            // Update the recordsToUpdate list with resolution comments and ProcessInstance ID
            for (PendingHITLAction__c record : recordsToUpdate) {
                if (recordIdToComment.containsKey(record.Id)) {
                    record.ResolutionComment__c = recordIdToComment.get(record.Id);
                }
                if (recordIdToProcessInstanceId.containsKey(record.Id)) {
                    record.ApprovalProcessInstanceId__c = recordIdToProcessInstanceId.get(record.Id);
                }
            }

            if (!recordIdToComment.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Captured approval comments for ' + recordIdToComment.size() + ' record(s)');
            }
            if (!recordIdToProcessInstanceId.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Captured ProcessInstance IDs for ' + recordIdToProcessInstanceId.size() + ' record(s)');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error capturing approval data: ' + e.getMessage());
            // Don't throw - this is non-critical, shouldn't block approval processing
        }
    }

    /**
     * @description Processes confirmed actions - executes the tool and resumes agent flow.
     */
    private static void processConfirmedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Confirmed] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' confirmed action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                executeAndResumeFlow(action, logPrefix);
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Error processing confirmed action ' + action.Id + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
                );
                notifyUserOfError(action, 'Error executing confirmed action: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Processes declined actions - notifies LLM and user.
     */
    private static void processDeclinedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Declined] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' declined action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                resumeFlowWithDecline(action, logPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing declined action ' + action.Id + ': ' + e.getMessage());
            }
        }
    }

    /**
     * @description Processes approved actions - executes the tool and resumes agent flow.
     */
    private static void processApprovedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Approved] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' approved action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                // Execute tool via REST API (async via Queueable)
                // Note: User notification will be sent by the REST API after actual execution
                executeAndResumeFlow(action, logPrefix);
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Error processing approved action ' + action.Id + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
                );
                notifyUserOfError(action, 'Error executing approved action: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Processes rejected actions - notifies user and updates execution.
     */
    private static void processRejectedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Rejected] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' rejected action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                resumeFlowWithRejection(action, logPrefix);

                // Notify requesting user (check notification preference)
                if (action.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_REJECTION)) {
                    String message = 'Your requested action "' + action.ToolName__c + '" was rejected.';
                    if (String.isNotBlank(action.ResolutionComment__c)) {
                        message += ' Reason: ' + action.ResolutionComment__c;
                    }
                    NotificationService.sendUserNotification(
                        action.RequestingUser__c,
                        'Action Rejected: ' + action.ToolName__c,
                        message,
                        action.AgentExecution__c
                    );
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing rejected action ' + action.Id + ': ' + e.getMessage());
            }
        }
    }

    /**
     * @description Processes expired actions - notifies user and updates execution.
     */
    private static void processExpiredActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Expired] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' expired action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                resumeFlowWithExpiration(action, logPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing expired action ' + action.Id + ': ' + e.getMessage());
            }
        }
    }

    // =============================================================================
    // EXECUTION AND FLOW RESUMPTION
    // =============================================================================

    /**
     * @description Executes the approved/confirmed tool and resumes the agent flow.
     */
    private static void executeAndResumeFlow(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing tool and resuming flow for action: ' + action.Id);

        // Load full action details if needed
        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null) {
            throw new HITLGatewayService.HITLProcessingException('Could not load pending action: ' + action.Id);
        }

        // Log decision step for approved action
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(fullAction.AgentExecution__c, fullAction.TurnIdentifier__c);
            decisionLogger.logResumeApprovedFrameworkAction(
                'Resume Approved Framework Action',
                'Tool "' + fullAction.ToolName__c + '" was approved and will now be executed',
                JSON.serialize(
                    new Map<String, Object>{
                        'toolName' => fullAction.ToolName__c,
                        'pendingActionId' => fullAction.Id,
                        'approvedBy' => fullAction.ResolvedBy__c,
                        'approvedAt' => fullAction.ResolvedAt__c,
                        'requestedAt' => fullAction.RequestedAt__c,
                        'resolutionComment' => fullAction.ResolutionComment__c
                    }
                ),
                0L
            );
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log approval decision step: ' + e.getMessage());
        }

        // Load the capability
        AgentCapability__c capability = AIAgentConfigService.getCapabilityById(fullAction.AIAgentCapability__c);
        if (capability == null) {
            throw new HITLGatewayService.HITLProcessingException('Capability not found: ' + fullAction.AIAgentCapability__c);
        }

        // Load execution to get user context and agent definition
        AgentExecution__c execution = [
            SELECT
                Id,
                User__c,
                ServiceUser__c,
                AIAgentDefinition__c,
                CurrentTurnIdentifier__c,
                AIAgentDefinition__r.RequiresServiceUserContext__c,
                AIAgentDefinition__r.DeveloperName__c,
                AIAgentDefinition__r.AgentType__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        // IMPORTANT: After HITL approval, we ALWAYS route through REST API to execute in the correct user context
        // This ensures the tool never executes in the approver's context
        // - If RequiresServiceUserContext__c = true: Execute as service user
        // - If RequiresServiceUserContext__c = false: Execute as original requesting user

        Boolean requiresServiceUserContext = execution.AIAgentDefinition__r.RequiresServiceUserContext__c == true;
        Id targetUserId = requiresServiceUserContext ? execution.ServiceUser__c : execution.User__c;

        if (targetUserId == null) {
            // No target user available - this shouldn't happen, but handle gracefully
            String userType = requiresServiceUserContext ? 'service user' : 'original user';
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: No ' + userType + ' available for tool execution. Cannot proceed.');

            // Notify requesting user of the failure
            if (execution.User__c != null) {
                NotificationService.sendUserNotification(
                    execution.User__c,
                    'Action Failed: ' + fullAction.ToolName__c,
                    'Tool execution failed because no ' + userType + ' context is available.',
                    fullAction.AgentExecution__c
                );
            }
            return;
        }

        // Check if follow-up LLM call will be needed (to optimize REST API execution)
        Boolean needsFollowUp = (execution.AIAgentDefinition__r.AgentType__c != 'Conversational');

        // Enqueue Queueable to execute tool via REST API in the correct user context
        String contextType = requiresServiceUserContext ? 'service user' : 'original user';
        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueueing tool execution via REST API as ' + contextType + ': ' + targetUserId);
        System.debug(
            LoggingLevel.DEBUG,
            logPrefix + 'Follow-up LLM call needed: ' + needsFollowUp + ' (AgentType: ' + execution.AIAgentDefinition__r.AgentType__c + ')'
        );

        System.enqueueJob(new HITLToolExecutionQueueable(fullAction.Id, needsFollowUp));

        System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution queued. Queueable will route through REST API to execute as ' + contextType + '.');
        // Exit - Queueable will handle execution, step updates, and follow-up LLM calls (if needed)
    }

    /**
     * @description Resumes flow with a decline message to the LLM.
     */
    private static void resumeFlowWithDecline(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with decline for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        // Create a tool result indicating the decline
        String declineMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'declined' => true,
                'message' => 'User declined to execute this action.',
                'comment' => fullAction.ResolutionComment__c
            }
        );

        // Update the existing placeholder tool result step with decline message
        ExecutionStepService stepService = new ExecutionStepService();
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, declineMessage, 0L, true);

        // Fallback: create new step if update failed
        if (updatedStepId == null) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Could not find existing tool result step to update, creating new one');
            stepService.createToolResultStep(
                fullAction.AgentExecution__c,
                fullAction.ToolCallId__c,
                fullAction.ToolName__c,
                declineMessage,
                fullAction.TurnIdentifier__c,
                fullAction.TurnCount__c != null ? fullAction.TurnCount__c.intValue() : 1,
                0L,
                false,
                fullAction.AIAgentCapability__c,
                true // isError - declined action is an error
            );
        }

        // Load execution for follow-up
        AgentExecution__c execution = [
            SELECT Id, User__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        // Queue follow-up LLM call
        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    /**
     * @description Resumes flow with a rejection message to the LLM.
     */
    private static void resumeFlowWithRejection(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with rejection for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        // Log decision step for rejected action
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(fullAction.AgentExecution__c, fullAction.TurnIdentifier__c);
            decisionLogger.logHandleRejectedFrameworkAction(
                'Handle Rejected Framework Action',
                'Tool "' + fullAction.ToolName__c + '" was rejected by approver',
                JSON.serialize(
                    new Map<String, Object>{
                        'toolName' => fullAction.ToolName__c,
                        'pendingActionId' => fullAction.Id,
                        'rejectedBy' => fullAction.ResolvedBy__c,
                        'rejectedAt' => fullAction.ResolvedAt__c,
                        'requestedAt' => fullAction.RequestedAt__c,
                        'resolutionComment' => fullAction.ResolutionComment__c
                    }
                ),
                0L
            );
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log rejection decision step: ' + e.getMessage());
        }

        // Create a tool result indicating the rejection
        String rejectionMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'rejected' => true,
                'message' => 'Action was rejected by approver.',
                'approverComment' => fullAction.ResolutionComment__c
            }
        );

        // Update the existing placeholder tool result step with rejection message
        ExecutionStepService stepService = new ExecutionStepService();
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, rejectionMessage, 0L, true);

        // Fallback: create new step if update failed
        if (updatedStepId == null) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Could not find existing tool result step to update, creating new one');
            stepService.createToolResultStep(
                fullAction.AgentExecution__c,
                fullAction.ToolCallId__c,
                fullAction.ToolName__c,
                rejectionMessage,
                fullAction.TurnIdentifier__c,
                fullAction.TurnCount__c != null ? fullAction.TurnCount__c.intValue() : 1,
                0L,
                false,
                fullAction.AIAgentCapability__c,
                true // isError - rejected action is an error
            );
        }

        // Load execution for follow-up
        AgentExecution__c execution = [
            SELECT Id, User__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        // Queue follow-up LLM call
        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    /**
     * @description Resumes flow with an expiration message to the LLM.
     */
    private static void resumeFlowWithExpiration(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with expiration for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        // Create a tool result indicating the expiration
        String expirationMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'expired' => true,
                'message' => 'Confirmation request expired without user response. The user may have been away or busy.'
            }
        );

        // Update the existing placeholder tool result step with expiration message
        ExecutionStepService stepService = new ExecutionStepService();
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, expirationMessage, 0L, true);

        // Fallback: create new step if update failed
        if (updatedStepId == null) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Could not find existing tool result step to update, creating new one');
            stepService.createToolResultStep(
                fullAction.AgentExecution__c,
                fullAction.ToolCallId__c,
                fullAction.ToolName__c,
                expirationMessage,
                fullAction.TurnIdentifier__c,
                fullAction.TurnCount__c != null ? fullAction.TurnCount__c.intValue() : 1,
                0L,
                false,
                fullAction.AIAgentCapability__c,
                true // isError - expired action is an error
            );
        }

        // Load execution for follow-up
        AgentExecution__c execution = [
            SELECT Id, User__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        // Queue follow-up LLM call
        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    // =============================================================================
    // HELPER METHODS
    // =============================================================================

    /**
     * @description Queues a follow-up LLM call to continue the agent flow.
     * Only needed for Function/Workflow agents. Conversational agents already completed their turn.
     */
    private static void queueFollowUpLLMCall(PendingHITLAction__c action, AgentExecution__c execution, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Checking if follow-up LLM call needed for execution: ' + execution.Id);

        try {
            // Load agent definition to check type
            AIAgentDefinition__c agentDef = [
                SELECT AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :execution.AIAgentDefinition__c
                LIMIT 1
            ];

            if (agentDef.AgentType__c == 'Conversational') {
                // Conversational agents already completed their turn with programmatic response
                // No follow-up needed - user can start new conversation turns
                System.debug(LoggingLevel.INFO, logPrefix + 'Conversational agent - no follow-up needed, turn already completed');
                return;
            }

            // For Function/Workflow agents: queue follow-up to continue processing
            System.debug(LoggingLevel.INFO, logPrefix + 'Queueing follow-up LLM call for ' + agentDef.AgentType__c + ' agent');

            // Update execution state to resume processing
            AgentStateService stateService = new AgentStateService();
            stateService.resumeForFollowUpLlmCall(execution.Id, action.TurnIdentifier__c, null, logPrefix);

            // Enqueue the follow-up
            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            enqueuer.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                action.TurnIdentifier__c,
                (action.TurnCount__c != null ? action.TurnCount__c.intValue() : 1) + 1,
                logPrefix,
                false // not final error turn
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM call queued successfully');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue follow-up LLM call: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * @description Notifies the user of an error during HITL processing.
     */
    private static void notifyUserOfError(PendingHITLAction__c action, String errorMessage) {
        if (action.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_ERROR)) {
            try {
                NotificationService.sendUserNotification(
                    action.RequestingUser__c,
                    'Error Processing Action: ' + action.ToolName__c,
                    errorMessage,
                    action.AgentExecution__c
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to send error notification: ' + e.getMessage());
            }
        }
    }

    /**
     * @description Helper method to extract IDs from a list of actions.
     * @param actions List of PendingHITLAction__c records
     * @return Set of action IDs
     */
    private static Set<Id> getActionIds(List<PendingHITLAction__c> actions) {
        Set<Id> ids = new Set<Id>();
        for (PendingHITLAction__c action : actions) {
            ids.add(action.Id);
        }
        return ids;
    }

    /**
     * @description Helper method to merge relationship data into action records.
     * @param actions List of PendingHITLAction__c records to update
     * @param actionsWithRelationships Map of actions with relationship data
     * @return List of actions with relationship data merged
     */
    private static List<PendingHITLAction__c> mergeRelationshipData(
        List<PendingHITLAction__c> actions,
        Map<Id, PendingHITLAction__c> actionsWithRelationships
    ) {
        List<PendingHITLAction__c> mergedActions = new List<PendingHITLAction__c>();
        for (PendingHITLAction__c action : actions) {
            PendingHITLAction__c actionWithRelationship = actionsWithRelationships.get(action.Id);
            if (actionWithRelationship != null) {
                mergedActions.add(actionWithRelationship);
            } else {
                mergedActions.add(action);
            }
        }
        return mergedActions;
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
}
