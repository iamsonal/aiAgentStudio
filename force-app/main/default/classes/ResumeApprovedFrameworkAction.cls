/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Invocable Apex called by an Approval Process. Resumes an AI Framework action
 *              post-approval by fetching the correct capability and executing it.
 */
public with sharing class ResumeApprovedFrameworkAction {
    public class ActionResumeException extends Exception {
    }

    @InvocableMethod(
        Label='Resume AI Framework Action on Approval'
        Description='Resumes the AI agent framework action after Salesforce approval and sends a notification.'
    )
    public static void resumeAction(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty())
            return;

        List<HumanApprovalRequest__c> harsToProcess = [
            SELECT
                Id,
                ChatSession__c,
                OriginalAssistantMessage__c,
                LLMToolCallId__c,
                ApproverComments__c,
                LLMToolName__c,
                LLMToolArgumentsJSON__c,
                OriginalTurnIdentifier__c,
                OriginalTurnCount__c,
                ChatSession__r.User__c,
                ChatSession__r.AIAgentDefinition__c
            FROM HumanApprovalRequest__c
            WHERE Id IN :humanApprovalRequestIds
        ];

        if (harsToProcess.isEmpty()) {
            return;
        }

        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[ResumeApprovedAction HAR:' + har.Id + ' Sess:' + har.ChatSession__c + '] ';
            Id userId = har.ChatSession__r?.User__c;

            try {
                if (har.ChatSession__r == null) {
                    updateHARStatus(har, 'Error', 'ChatSession link is missing.', logPrefix);
                    continue;
                }

                AgentCapability__c capability = AIAgentConfigService.getCapability(har.ChatSession__r.AIAgentDefinition__c, har.LLMToolName__c);

                if (capability == null) {
                    throw new ActionResumeException('Active AgentCapability not found for tool: ' + har.LLMToolName__c);
                }

                handleActionResume(har, capability, logPrefix);
            } catch (Exception e) {
                if (userId != null) {
                    NotificationService.sendUserNotification(
                        userId,
                        'Error Processing Approved Request',
                        'An unexpected error occurred while processing your approved request for "' + har.LLMToolName__c + '".',
                        har.ChatSession__c
                    );
                }
                updateHARStatus(har, 'Error', 'Exception during resume: ' + e.getMessage(), logPrefix);
                OrchestrationService.clearPendingDetailsFromMessage(har.OriginalAssistantMessage__c, logPrefix);
            } finally {
                OrchestrationLogger.commitLogs();
            }
        }
    }

    /**
     * @description Handles the resumption of any approved action.
     *              The invocable method context is already asynchronous from the user's perspective,
     *              so we can execute the action directly here.
     */
    private static void handleActionResume(HumanApprovalRequest__c har, AgentCapability__c capability, String logPrefix) {
        ActionExecutionService actionService = new ActionExecutionService();

        Id turnRecordContextId = null;
        if (String.isNotBlank(har.OriginalTurnIdentifier__c)) {
            List<ChatMessage__c> userTurnMessages = [
                SELECT RecordContextId__c
                FROM ChatMessage__c
                WHERE ExternalId__c = :har.OriginalTurnIdentifier__c AND Role__c = 'user'
                LIMIT 1
            ];
            if (!userTurnMessages.isEmpty()) {
                turnRecordContextId = userTurnMessages[0].RecordContextId__c;
            }
        }

        ActionContext actionContext = new ActionContext(
            har.ChatSession__c,
            har.ChatSession__r.User__c,
            turnRecordContextId,
            har.ChatSession__r.AIAgentDefinition__c,
            capability.Id,
            capability.PreExecutionHook__c,
            capability.PostExecutionHook__c,
            capability.ImplementationDetail__c
        );

        ActionResult actionResult = actionService.executeSingleAction(capability, har.LLMToolArgumentsJSON__c, actionContext);

        if (actionResult.isSuccess) {
            NotificationService.sendUserNotification(
                har.ChatSession__r.User__c,
                'Request Completed: "' + har.LLMToolName__c + '"',
                'Your approved request has been completed successfully.',
                har.ChatSession__c
            );
            updateHARStatus(har, 'Approved', 'Action completed successfully.', logPrefix);
        } else {
            NotificationService.sendUserNotification(
                har.ChatSession__r.User__c,
                'Action Failed After Approval: "' + har.LLMToolName__c + '"',
                'Your request was approved, but the action failed to execute. ' + String.valueOf(actionResult.outputForLlm),
                har.ChatSession__c
            );
            updateHARStatus(har, 'Error', 'Action failed post-approval: ' + actionResult.internalDetails, logPrefix);
        }

        OrchestrationService.clearPendingDetailsFromMessage(har.OriginalAssistantMessage__c, logPrefix);
    }

    /**
     * @description Validates if the HAR and its related session are in a state suitable for processing.
     * @return True if valid, False otherwise.
     */
    private static Boolean isValidForProcessing(HumanApprovalRequest__c har, String logPrefix) {
        if (har.ChatSession__r == null) {
            updateHARStatus(har, 'Error', 'ChatSession link is missing.', logPrefix);
            return false;
        }

        return true;
    }

    private static void updateHARStatus(HumanApprovalRequest__c har, String status, String comments, String logPrefix) {
        try {
            har.ApprovalStatus__c = status;
            if (String.isNotBlank(comments)) {
                har.ApproverComments__c = (har.ApproverComments__c != null ? har.ApproverComments__c + '\n' : '') + comments;
            }
            update har;
        } catch (Exception e) {
        }
    }
}
