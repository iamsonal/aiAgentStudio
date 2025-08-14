/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * HandleRejectedFrameworkAction manages the full rejection lifecycle for AI agent framework actions
 * that are denied via Salesforce approval workflows. Its responsibilities include:
 *   - Updating chat history to reflect the rejection and provide user-facing feedback
 *   - Notifying the user of the rejection and any approver comments
 *   - Updating the status and comments of the HumanApprovalRequest__c record
 *   - Cleaning up any pending approval details from the original assistant message
 *   - Logging all relevant actions and errors for traceability
 *
 * This class is invoked automatically by Salesforce approval processes and is designed to be robust
 * against missing or invalid data, ensuring that user experience and auditability are preserved even in error scenarios.
 */
public class HandleRejectedFrameworkAction {
    /**
     * Invocable entry point for handling AI agent framework action rejections from approval workflows.
     *
     * For each provided HumanApprovalRequest__c Id:
     *   - Validates the request and associated session
     *   - Writes a rejection message to chat history
     *   - Notifies the user of the rejection and any approver comments
     *   - Updates the approval request status and comments
     *   - Cleans up any pending approval details from the original assistant message
     *   - Logs all actions and errors for traceability
     *
     * @param humanApprovalRequestIds  List of HumanApprovalRequest__c record Ids to process
     * @sideeffect Updates records, sends notifications, and logs actions/errors
     */
    @InvocableMethod
    public static void handleRejection(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[HandleRejectedFrameworkAction] No approval request IDs provided. Exiting without processing.');
            return;
        }
        List<HumanApprovalRequest__c> harsToProcess = [
            SELECT
                Id,
                ChatSession__c,
                LLMToolName__c,
                ApproverComments__c,
                OriginalAssistantMessage__c,
                LLMToolCallId__c,
                OriginalTurnIdentifier__c,
                ChatSession__r.User__c
            FROM HumanApprovalRequest__c
            WHERE Id IN :humanApprovalRequestIds
        ];
        if (harsToProcess.isEmpty()) {
            System.debug(
                LoggingLevel.ERROR,
                '[HandleRejectedFrameworkAction] No valid approval request records found for provided IDs. Nothing to process.'
            );
            return;
        }
        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[HandleRejectedAction HAR:' + har.Id + ' Sess:' + har.ChatSession__c + '] ';
            try {
                // Validate that the approval request is linked to a chat session
                if (har.ChatSession__r == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Missing ChatSession relationship. Cannot process rejection.');
                    updateHARStatus(har, 'Error', 'ChatSession link is missing.', logPrefix);
                    continue;
                }
                // Compose a user-facing rejection reason, including approver comments if present
                String rejectionReason = 'Your request to "' + har.LLMToolName__c + '" was rejected by an approver.';
                if (String.isNotBlank(har.ApproverComments__c)) {
                    rejectionReason += ' Comments: ' + har.ApproverComments__c;
                }
                String rejectionContentJson = JSON.serialize(new Map<String, String>{ 'status' => 'rejected', 'reason' => rejectionReason });
                // Write a rejection message to chat history for traceability and user feedback
                ChatMessageService.saveToolResultMessage(
                    har.ChatSession__c,
                    har.OriginalTurnIdentifier__c,
                    har.OriginalAssistantMessage__c,
                    har.LLMToolCallId__c,
                    rejectionContentJson,
                    rejectionReason, // internalDetails
                    AIAgentConstants.ERR_CODE_USER_REJECTED, // errorCode
                    0L, // actionDuration
                    null, // recordContextId (not applicable here)
                    null, // recordContextDataJson (not applicable here)
                    har.LLMToolName__c,
                    logPrefix
                );
                // Notify the user of the rejection
                NotificationService.sendUserNotification(
                    har.ChatSession__r.User__c,
                    'Request Rejected: ' + har.LLMToolName__c,
                    rejectionReason,
                    har.ChatSession__c
                );
                // Update the approval request status and comments
                updateHARStatus(har, 'Rejected', 'Rejection processed and user notified.', logPrefix);
                // Remove any pending approval details from the original assistant message
                OrchestrationService.clearPendingDetailsFromMessage(har.OriginalAssistantMessage__c, logPrefix);
                System.debug(LoggingLevel.INFO, logPrefix + 'Rejection processed successfully. User notified and chat history updated.');
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Exception during rejection processing: (' + e.getTypeName() + ') ' + e.getMessage() + '\n' + e.getStackTraceString()
                );
                if (har != null) {
                    updateHARStatus(har, 'Error', 'Exception during rejection processing: ' + e.getMessage(), logPrefix);
                }
            } finally {
                OrchestrationLogger.commitLogs();
            }
        }
    }

    /**
     * Updates the status and approver comments of a HumanApprovalRequest__c record.
     *
     * @param har        The approval request record to update.
     * @param status     The new approval status to set.
     * @param comments   Additional comments to append (abbreviated if too long).
     * @param logPrefix  Prefix for debug/error logging.
     * @sideeffect Updates the HAR record in the database; logs errors if update fails.
     */
    private static void updateHARStatus(HumanApprovalRequest__c har, String status, String comments, String logPrefix) {
        try {
            har.ApprovalStatus__c = status;
            if (String.isNotBlank(comments)) {
                har.ApproverComments__c = (har.ApproverComments__c != null ? har.ApproverComments__c + '\n' : '') + comments.abbreviate(131000);
            }
            update har;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update approval request status to ' + status + ': ' + e.getMessage());
        }
    }
}
