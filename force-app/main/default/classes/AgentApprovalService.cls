/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AgentApprovalService manages the complete lifecycle of human approval for AI agent actions.
 * Consolidated from HumanApprovalRequestTriggerHandler, ResumeApprovedFrameworkAction, and HandleRejectedFrameworkAction
 * to co-locate all approval logic in a single service.
 *
 * Responsibilities:
 *   - Trigger handling: Monitors approval status changes and routes to appropriate handlers
 *   - Approval processing: Executes approved actions and manages notifications
 *   - Rejection processing: Handles rejection workflow and user communication
 *   - Status management: Updates approval request records and maintains audit trail
 *
 * This service ensures consistent, auditable, and robust handling of all human-in-the-loop
 * approval scenarios across the AI agent framework.
 */
public with sharing class AgentApprovalService {
    /**
     * Exception thrown when approval processing fails in a non-recoverable way.
     */
    public class ApprovalProcessingException extends Exception {
    }

    // ===================================================================================
    // TRIGGER HANDLER METHODS
    // ===================================================================================

    /**
     * Handles the after-update trigger event for HumanApprovalRequest__c records.
     * Detects approval status changes and delegates to appropriate processing methods.
     *
     * @param newRecords  List of updated HumanApprovalRequest__c records from Trigger.new
     * @param oldMap      Map of old record versions from Trigger.oldMap
     * @sideeffect May invoke approval/rejection processing that updates records and sends notifications
     */
    public static void handleTrigger(List<HumanApprovalRequest__c> newRecords, Map<Id, HumanApprovalRequest__c> oldMap) {
        List<Id> approvedRequestIds = new List<Id>();
        List<Id> rejectedRequestIds = new List<Id>();

        for (HumanApprovalRequest__c newRecord : newRecords) {
            HumanApprovalRequest__c oldRecord = oldMap.get(newRecord.Id);

            // Only process records where approval status has changed
            if (newRecord.ApprovalStatus__c != oldRecord.ApprovalStatus__c) {
                if (newRecord.ApprovalStatus__c == 'Approved') {
                    System.debug(LoggingLevel.INFO, '[AgentApprovalService] Approval detected for: ' + newRecord.Id);
                    approvedRequestIds.add(newRecord.Id);
                } else if (newRecord.ApprovalStatus__c == 'Rejected') {
                    System.debug(LoggingLevel.INFO, '[AgentApprovalService] Rejection detected for: ' + newRecord.Id);
                    rejectedRequestIds.add(newRecord.Id);
                } else {
                    System.debug(
                        LoggingLevel.DEBUG,
                        '[AgentApprovalService] ApprovalStatus changed to unhandled value: ' + newRecord.ApprovalStatus__c + ' for: ' + newRecord.Id
                    );
                }
            }
        }

        if (!approvedRequestIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AgentApprovalService] Processing ' + approvedRequestIds.size() + ' approved request(s).');
            processApprovedRequests(approvedRequestIds);
        }

        if (!rejectedRequestIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AgentApprovalService] Processing ' + rejectedRequestIds.size() + ' rejected request(s).');
            processRejectedRequests(rejectedRequestIds);
        }
    }

    // ===================================================================================
    // APPROVAL PROCESSING
    // ===================================================================================

    /**
     * Processes approved HumanApprovalRequest__c records by executing the corresponding actions.
     *
     * For each request:
     *   - Validates the record and its AgentExecution__c link
     *   - Resolves the correct AgentCapability__c
     *   - Executes the approved action and manages notifications
     *   - Updates approval request status and logs all outcomes
     *
     * @param humanApprovalRequestIds  List of HumanApprovalRequest__c record IDs to process
     * @sideeffect Sends user notifications, updates records, commits logs
     */
    public static void processApprovedRequests(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AgentApprovalService.processApprovedRequests] No IDs provided. Nothing to process.');
            return;
        }

        List<HumanApprovalRequest__c> harsToProcess = [
            SELECT
                Id,
                AgentExecution__c,
                OriginalAssistantStep__c,
                LLMToolCallId__c,
                ApproverComments__c,
                LLMToolName__c,
                LLMToolArgumentsJSON__c,
                OriginalTurnIdentifier__c,
                OriginalTurnCount__c,
                AgentExecution__r.User__c,
                AgentExecution__r.AIAgentDefinition__c
            FROM HumanApprovalRequest__c
            WHERE Id IN :humanApprovalRequestIds
        ];

        if (harsToProcess.isEmpty()) {
            System.debug(LoggingLevel.ERROR, '[AgentApprovalService.processApprovedRequests] No valid records found. Skipping processing.');
            return;
        }

        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[AgentApprovalService.Approved HAR:' + har.Id + ' Exec:' + har.AgentExecution__c + '] ';
            Id userId = har.AgentExecution__r?.User__c;

            try {
                if (har.AgentExecution__r == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'AgentExecution__r is null. Cannot process.');
                    updateStatus(har, 'Error', 'AgentExecution link is missing.', logPrefix);
                    continue;
                }

                AgentCapability__c capability = AIAgentConfigService.getCapability(har.AgentExecution__r.AIAgentDefinition__c, har.LLMToolName__c);

                if (capability == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'No AgentCapability found for tool: ' + har.LLMToolName__c);
                    throw new ApprovalProcessingException('Active AgentCapability not found for tool: ' + har.LLMToolName__c);
                }

                // Log the approval processing step
                AgentDecisionStepLogger logger = new AgentDecisionStepLogger(har.AgentExecution__c, har.OriginalTurnIdentifier__c);
                String actionDetails = JSON.serialize(
                    new Map<String, Object>{
                        'humanApprovalRequestId' => har.Id,
                        'toolName' => har.LLMToolName__c,
                        'approverComments' => har.ApproverComments__c
                    }
                );
                logger.logResumeApprovedFrameworkAction(
                    'Resume Approved Framework Action',
                    'Resuming approved action for tool: ' + har.LLMToolName__c,
                    actionDetails,
                    0L
                );
                logger.commitSteps();

                executeApprovedAction(har, capability, logPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during approval processing: ' + e.getMessage() + '\n' + e.getStackTraceString());
                if (userId != null) {
                    NotificationService.sendUserNotification(
                        userId,
                        'Error Processing Approved Request',
                        'An error occurred while processing your approved request for "' + har.LLMToolName__c + '".',
                        har.AgentExecution__c
                    );
                }
                updateStatus(har, 'Error', 'Exception during resume: ' + e.getMessage(), logPrefix);
            }
        }
    }

    /**
     * Executes the approved AI capability action and manages the full workflow.
     *
     * @param har         The approved HumanApprovalRequest__c record
     * @param capability  The AgentCapability__c to execute
     * @param logPrefix   Logging prefix for consistent log formatting
     * @sideeffect Sends notifications, updates records
     */
    private static void executeApprovedAction(HumanApprovalRequest__c har, AgentCapability__c capability, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing approved action using Capability: ' + capability.Id);

        CapabilityExecutionService capabilityService = new CapabilityExecutionService();

        // Build action context
        ActionContext actionContext = new ActionContext(
            har.AgentExecution__c,
            har.AgentExecution__r.User__c,
            UserInfo.getUserId(),
            null, // turnRecordContextId - managed through ContextManagerService
            har.AgentExecution__r.AIAgentDefinition__c,
            capability.Id,
            capability.ImplementationDetail__c,
            har.OriginalTurnIdentifier__c,
            har.OriginalTurnCount__c.intValue(),
            'ApprovalResume'
        );

        ActionOutcome actionOutcome = capabilityService.executeSingleAction(capability, har.LLMToolArgumentsJSON__c, actionContext);

        if (actionOutcome.isSuccess) {
            NotificationService.sendUserNotification(
                har.AgentExecution__r.User__c,
                'Request Completed: "' + har.LLMToolName__c + '"',
                'Your approved request has been completed successfully.',
                har.AgentExecution__c
            );
            updateStatus(har, 'Approved', 'Action completed successfully.', logPrefix);
            System.debug(LoggingLevel.INFO, logPrefix + 'Action executed successfully for tool: ' + har.LLMToolName__c);
        } else {
            NotificationService.sendUserNotification(
                har.AgentExecution__r.User__c,
                'Action Failed After Approval: "' + har.LLMToolName__c + '"',
                'Your request was approved, but the action failed to execute. ' + String.valueOf(actionOutcome.errorMessage),
                har.AgentExecution__c
            );
            updateStatus(har, 'Error', 'Action failed post-approval: ' + actionOutcome.errorMessage, logPrefix);
            System.debug(LoggingLevel.WARN, logPrefix + 'Action failed after approval. Details: ' + actionOutcome.errorMessage);
        }
    }

    // ===================================================================================
    // REJECTION PROCESSING
    // ===================================================================================

    /**
     * Processes rejected HumanApprovalRequest__c records.
     *
     * For each request:
     *   - Validates the request and associated execution
     *   - Writes a rejection message to execution history
     *   - Notifies the user of the rejection and any approver comments
     *   - Updates the status of the HumanApprovalRequest__c record
     *
     * @param humanApprovalRequestIds  List of HumanApprovalRequest__c record IDs to process
     * @sideeffect Updates records, sends notifications, and logs actions
     */
    public static void processRejectedRequests(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[AgentApprovalService.processRejectedRequests] No IDs provided. Nothing to process.');
            return;
        }

        List<HumanApprovalRequest__c> harsToProcess = [
            SELECT
                Id,
                AgentExecution__c,
                LLMToolName__c,
                ApproverComments__c,
                OriginalAssistantStep__c,
                LLMToolCallId__c,
                OriginalTurnCount__c,
                OriginalTurnIdentifier__c,
                AgentExecution__r.User__c,
                AgentExecution__r.AIAgentDefinition__c
            FROM HumanApprovalRequest__c
            WHERE Id IN :humanApprovalRequestIds
        ];

        if (harsToProcess.isEmpty()) {
            System.debug(LoggingLevel.ERROR, '[AgentApprovalService.processRejectedRequests] No valid records found. Nothing to process.');
            return;
        }

        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[AgentApprovalService.Rejected HAR:' + har.Id + ' Exec:' + har.AgentExecution__c + '] ';

            try {
                if (har.AgentExecution__r == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Missing AgentExecution relationship. Cannot process rejection.');
                    updateStatus(har, 'Error', 'AgentExecution link is missing.', logPrefix);
                    continue;
                }

                // Log the rejection processing step
                AgentDecisionStepLogger logger = new AgentDecisionStepLogger(har.AgentExecution__c, har.OriginalTurnIdentifier__c);
                String actionDetails = JSON.serialize(
                    new Map<String, Object>{
                        'humanApprovalRequestId' => har.Id,
                        'toolName' => har.LLMToolName__c,
                        'approverComments' => har.ApproverComments__c
                    }
                );
                logger.logHandleRejectedFrameworkAction(
                    'Handle Rejected Framework Action',
                    'Handling rejected action for tool: ' + har.LLMToolName__c,
                    actionDetails,
                    0L
                );
                logger.commitSteps();

                // Compose user-facing rejection reason
                String rejectionReason = 'Your request to "' + har.LLMToolName__c + '" was rejected by an approver.';
                if (String.isNotBlank(har.ApproverComments__c)) {
                    rejectionReason += ' Comments: ' + har.ApproverComments__c;
                }

                String rejectionContentJson = JSON.serialize(new Map<String, String>{ 'status' => 'rejected', 'reason' => rejectionReason });

                // Get the capability ID for the tool
                AgentCapability__c capability = AIAgentConfigService.getCapability(har.AgentExecution__r.AIAgentDefinition__c, har.LLMToolName__c);
                Id capabilityId = capability != null ? capability.Id : null;

                // Write rejection message to execution history
                ExecutionStepService executionStepService = new ExecutionStepService();
                executionStepService.createToolResultStep(
                    har.AgentExecution__c,
                    har.LLMToolCallId__c,
                    har.LLMToolName__c,
                    rejectionContentJson,
                    har.OriginalTurnIdentifier__c,
                    har.OriginalTurnCount__c.intValue(),
                    0L,
                    false,
                    capabilityId
                );

                // Notify the user
                NotificationService.sendUserNotification(
                    har.AgentExecution__r.User__c,
                    'Request Rejected: ' + har.LLMToolName__c,
                    rejectionReason,
                    har.AgentExecution__c
                );

                // Update approval request status
                updateStatus(har, 'Rejected', 'Rejection processed and user notified.', logPrefix);
                System.debug(LoggingLevel.INFO, logPrefix + 'Rejection processed successfully. User notified and history updated.');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during rejection processing: ' + e.getMessage() + '\n' + e.getStackTraceString());
                if (har != null) {
                    updateStatus(har, 'Error', 'Exception during rejection processing: ' + e.getMessage(), logPrefix);
                }
            }
        }
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

    /**
     * Updates the status and comments of a HumanApprovalRequest__c record.
     *
     * @param har        The HumanApprovalRequest__c record to update
     * @param status     The new approval status
     * @param comments   Additional comments to append
     * @param logPrefix  Logging prefix for error messages
     * @sideeffect Updates the record in the database; logs errors if update fails
     */
    private static void updateStatus(HumanApprovalRequest__c har, String status, String comments, String logPrefix) {
        try {
            har.ApprovalStatus__c = status;
            if (String.isNotBlank(comments)) {
                // Abbreviate comments if too long (field limit protection)
                String newComment = comments.abbreviate(131000);
                har.ApproverComments__c = (har.ApproverComments__c != null ? har.ApproverComments__c + '\n' : '') + newComment;
            }
            update har;
            System.debug(LoggingLevel.INFO, logPrefix + 'HumanApprovalRequest ' + har.Id + ' status updated to ' + status);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update status to ' + status + ': ' + e.getMessage());
        }
    }
}
