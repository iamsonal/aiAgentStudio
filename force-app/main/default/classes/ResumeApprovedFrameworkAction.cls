/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ResumeApprovedFrameworkAction is an invocable Apex class that orchestrates the resumption of AI agent framework actions
 * after human approval via Salesforce approval processes. It validates and processes approved HumanApprovalRequest__c records,
 * executes the corresponding AI agent capability, manages error handling, and notifies users of outcomes. The class ensures
 * robust, auditable, and user-friendly handling of post-approval agent actions, including logging and cleanup.
 *
 * Responsibilities:
 *   - Validate and process approved HumanApprovalRequest__c records
 *   - Resolve and execute the correct AgentCapability__c for each request
 *   - Manage user notifications for both success and failure scenarios
 *   - Update approval request status and comments
 *   - Ensure all orchestration logs are committed and pending details are cleared
 */
public with sharing class ResumeApprovedFrameworkAction {
    /**
     * Exception thrown when action resumption fails in a non-recoverable way.
     */
    public class ActionResumeException extends Exception {
    }

    /**
     * Invocable entry point: Processes a list of approved HumanApprovalRequest__c records.
     *
     * For each request:
     *   - Validates the record and its AgentExecution__c link
     *   - Resolves the correct AgentCapability__c
     *   - Executes the approved action and manages notifications
     *   - Updates approval request status and logs all outcomes
     *
     * @param humanApprovalRequestIds  List of HumanApprovalRequest__c record IDs to process
     * @sideeffect                     Sends user notifications, updates records, commits logs
     */
    @InvocableMethod(
        Label='Resume AI Framework Action on Approval'
        Description='Resumes the AI agent framework action after Salesforce approval and sends a notification.'
    )
    public static void resumeAction(List<Id> humanApprovalRequestIds) {
        if (humanApprovalRequestIds == null || humanApprovalRequestIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[ResumeApprovedFrameworkAction] No HumanApprovalRequest IDs provided. Nothing to process.');
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
            System.debug(
                LoggingLevel.ERROR,
                '[ResumeApprovedFrameworkAction] No valid HumanApprovalRequest__c records found for the provided IDs. Skipping processing.'
            );
            return;
        }

        for (HumanApprovalRequest__c har : harsToProcess) {
            String logPrefix = '[ResumeApprovedAction HAR:' + har.Id + ' Exec:' + har.AgentExecution__c + '] ';
            Id userId = har.AgentExecution__r?.User__c;

            try {
                if (har.AgentExecution__r == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Cannot process: AgentExecution__r is null on HumanApprovalRequest.');
                    updateHARStatus(har, 'Error', 'AgentExecution link is missing.', logPrefix);
                    continue;
                }

                AgentCapability__c capability = AIAgentConfigService.getCapability(har.AgentExecution__r.AIAgentDefinition__c, har.LLMToolName__c);

                if (capability == null) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'No AgentCapability found for tool: ' + har.LLMToolName__c + '.');
                    throw new ActionResumeException('Active AgentCapability not found for tool: ' + har.LLMToolName__c);
                }

                // Log the step
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

                handleActionResume(har, capability, logPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during action resume: ' + e.getMessage() + '\n' + e.getStackTraceString());
                if (userId != null) {
                    NotificationService.sendUserNotification(
                        userId,
                        'Error Processing Approved Request',
                        'An error occurred while processing your approved request for "' + har.LLMToolName__c + '".',
                        har.AgentExecution__c
                    );
                }
                updateHARStatus(har, 'Error', 'Exception during resume: ' + e.getMessage(), logPrefix);
                // Note: Pending approval details cleanup handled by ExecutionStepService
            } finally {
            }
        }
    }

    /**
     * Executes the approved AI capability action and manages the full workflow for a single request.
     *
     * Steps:
     *   - Resolves turn context and builds ActionContext
     *   - Executes the capability with provided arguments
     *   - Notifies user of success or failure
     *   - Updates approval status and clears pending details
     *
     * @param har         The approved HumanApprovalRequest__c record
     * @param capability  The AgentCapability__c to execute
     * @param logPrefix   Logging prefix for consistent log formatting
     * @sideeffect        Sends notifications, updates records, clears pending details
     */
    private static void handleActionResume(HumanApprovalRequest__c har, AgentCapability__c capability, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming approved action using Capability: ' + capability.Id);

        CapabilityExecutionRouter capabilityRouter = new CapabilityExecutionRouter();

        // In the unified model, record context is managed through ContextManagerService
        // and doesn't need to be retrieved from ExecutionStep__c records
        Id turnRecordContextId = null;
        System.debug(LoggingLevel.INFO, logPrefix + 'Turn context resolved to RecordContextId: ' + turnRecordContextId);
        ActionContext actionContext = new ActionContext(
            har.AgentExecution__c,
            har.AgentExecution__r.User__c,
            UserInfo.getUserId(),
            turnRecordContextId,
            har.AgentExecution__r.AIAgentDefinition__c,
            capability.Id,
            capability.ImplementationDetail__c,
            har.OriginalTurnIdentifier__c,
            har.OriginalTurnCount__c.intValue(),
            'API'
        );

        ActionOutcome actionOutcome = capabilityRouter.executeSingleAction(capability, har.LLMToolArgumentsJSON__c, actionContext);
        if (actionOutcome.isSuccess) {
            NotificationService.sendUserNotification(
                har.AgentExecution__r.User__c,
                'Request Completed: "' + har.LLMToolName__c + '"',
                'Your approved request has been completed successfully.',
                har.AgentExecution__c
            );
            updateHARStatus(har, 'Approved', 'Action completed successfully.', logPrefix);
            System.debug(LoggingLevel.INFO, logPrefix + 'Action executed successfully for tool: ' + har.LLMToolName__c);
        } else {
            NotificationService.sendUserNotification(
                har.AgentExecution__r.User__c,
                'Action Failed After Approval: "' + har.LLMToolName__c + '"',
                'Your request was approved, but the action failed to execute. ' + String.valueOf(actionOutcome.errorMessage),
                har.AgentExecution__c
            );
            updateHARStatus(har, 'Error', 'Action failed post-approval: ' + actionOutcome.errorMessage, logPrefix);
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'Action failed after approval for tool: ' + har.LLMToolName__c + '. Details: ' + actionOutcome.errorMessage
            );
        }

        // Note: Pending approval details cleanup handled by ExecutionStepService
    }

    /**
     * Updates the status and comments of a HumanApprovalRequest__c record.
     *
     * @param har        The HumanApprovalRequest__c record to update
     * @param status     The new approval status
     * @param comments   Additional comments to append
     * @param logPrefix  Logging prefix for error messages
     * @sideeffect       Updates the record in the database; logs errors if update fails
     */

    private static void updateHARStatus(HumanApprovalRequest__c har, String status, String comments, String logPrefix) {
        try {
            har.ApprovalStatus__c = status;
            if (String.isNotBlank(comments)) {
                har.ApproverComments__c = (har.ApproverComments__c != null ? har.ApproverComments__c + '\n' : '') + comments;
            }
            update har;
            System.debug(LoggingLevel.INFO, logPrefix + 'HumanApprovalRequest ' + har.Id + ' status updated to ' + status + '.');
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Failed to update HumanApprovalRequest ' + har.Id + ' status to ' + status + ': ' + e.getMessage()
            );
        }
    }
}
