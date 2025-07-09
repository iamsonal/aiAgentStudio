/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Invocable Apex called by an Approval Process. Handles the rejection of an
 *              AI agent framework action, saves a rejection message to the chat history,
 *              and sends a notification to the user.
 */
public class HandleRejectedFrameworkAction {
    @InvocableMethod(
        label='Handle AI Framework Action Rejection'
        description='Handles the rejection of an AI agent framework action and sends a notification.'
    )
    public static void handleRejection(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty()) {
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
            return;
        }

        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[HandleRejectedAction HAR:' + har.Id + ' Sess:' + har.ChatSession__c + '] ';

            try {
                if (har.ChatSession__r == null) {
                    updateHARStatus(har, 'Error', 'ChatSession link is missing.', logPrefix);
                    continue;
                }

                String rejectionReason = 'Your request to "' + har.LLMToolName__c + '" was rejected by an approver.';
                if (String.isNotBlank(har.ApproverComments__c)) {
                    rejectionReason += ' Comments: ' + har.ApproverComments__c;
                }
                String rejectionContentJson = JSON.serialize(new Map<String, String>{ 'status' => 'rejected', 'reason' => rejectionReason });

                ChatMessageService.saveToolResultMessage(
                    har.ChatSession__c,
                    har.OriginalTurnIdentifier__c,
                    har.OriginalAssistantMessage__c,
                    har.LLMToolCallId__c,
                    rejectionContentJson,
                    rejectionReason,
                    AIAgentConstants.ERR_CODE_USER_REJECTED,
                    0L,
                    null,
                    null,
                    har.LLMToolName__c,
                    logPrefix
                );

                NotificationService.sendUserNotification(
                    har.ChatSession__r.User__c,
                    'Request Rejected: ' + har.LLMToolName__c,
                    rejectionReason,
                    har.ChatSession__c
                );

                updateHARStatus(har, 'Rejected', 'Rejection processed and user notified.', logPrefix);

                OrchestrationService.clearPendingDetailsFromMessage(har.OriginalAssistantMessage__c, logPrefix);
            } catch (Exception e) {
                if (har != null) {
                    updateHARStatus(har, 'Error', 'Exception during rejection processing: ' + e.getMessage(), logPrefix);
                }
            } finally {
                OrchestrationLogger.commitLogs();
            }
        }
    }

    private static void updateHARStatus(HumanApprovalRequest__c har, String status, String comments, String logPrefix) {
        try {
            har.ApprovalStatus__c = status;
            if (String.isNotBlank(comments)) {
                har.ApproverComments__c = (har.ApproverComments__c != null ? har.ApproverComments__c + '\n' : '') + comments.abbreviate(131000);
            }
            update har;
        } catch (Exception e) {
        }
    }
}
