/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Trigger handler for PendingHITLAction__c records. Handles approval process status changes and automatic execution resumption.
 */
public with sharing class PendingHITLActionTriggerHandler {
    private static final String LOG_PREFIX = '[PendingHITLActionHandler] ';
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

            if (isResolvedStatus(newStatus)) {
                PendingHITLAction__c recordToUpdate = new PendingHITLAction__c(Id = newRecord.Id, ResolvedAt__c = Datetime.now());

                if (newStatus == HITLGatewayService.STATUS_EXPIRED) {
                    recordToUpdate.ResolvedBy__c = null;
                } else {
                    recordToUpdate.ResolvedBy__c = UserInfo.getUserId();
                }

                recordsToUpdate.add(recordToUpdate);

                if (newStatus == HITLGatewayService.STATUS_APPROVED || newStatus == HITLGatewayService.STATUS_REJECTED) {
                    recordsNeedingApprovalComments.add(newRecord.Id);
                }
            }

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

        if (!recordsNeedingApprovalComments.isEmpty()) {
            captureApprovalComments(recordsNeedingApprovalComments, recordsToUpdate);
        }

        if (!recordsToUpdate.isEmpty()) {
            try {
                update recordsToUpdate;
                System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Updated resolution tracking for ' + recordsToUpdate.size() + ' record(s)');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to update resolution tracking: ' + e.getMessage());
            }
        }

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

        approvedActions = mergeRelationshipData(approvedActions, actionsWithRelationships);
        rejectedActions = mergeRelationshipData(rejectedActions, actionsWithRelationships);
        expiredActions = mergeRelationshipData(expiredActions, actionsWithRelationships);

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

    private static Boolean isResolvedStatus(String status) {
        return status == HITLGatewayService.STATUS_CONFIRMED ||
            status == HITLGatewayService.STATUS_DECLINED ||
            status == HITLGatewayService.STATUS_APPROVED ||
            status == HITLGatewayService.STATUS_REJECTED ||
            status == HITLGatewayService.STATUS_EXPIRED;
    }

    private static void captureApprovalComments(Set<Id> recordIds, List<PendingHITLAction__c> recordsToUpdate) {
        String logPrefix = LOG_PREFIX + '[captureApprovalComments] ';

        try {
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

            Map<Id, String> recordIdToComment = new Map<Id, String>();
            Map<Id, Id> recordIdToProcessInstanceId = new Map<Id, Id>();

            for (ProcessInstance pi : processInstances) {
                recordIdToProcessInstanceId.put(pi.TargetObjectId, pi.Id);

                if (pi.StepsAndWorkitems != null && !pi.StepsAndWorkitems.isEmpty()) {
                    for (ProcessInstanceHistory step : pi.StepsAndWorkitems) {
                        if (String.isNotBlank(step.Comments) && !recordIdToComment.containsKey(pi.TargetObjectId)) {
                            recordIdToComment.put(pi.TargetObjectId, step.Comments);
                            break;
                        }
                    }
                }
            }

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
        }
    }

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

    private static void processApprovedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Approved] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' approved action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
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

    private static void processRejectedActions(List<PendingHITLAction__c> actions) {
        String logPrefix = LOG_PREFIX + '[Rejected] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + actions.size() + ' rejected action(s)');

        for (PendingHITLAction__c action : actions) {
            try {
                resumeFlowWithRejection(action, logPrefix);

                if (action.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_REJECTION)) {
                    String message = 'Your requested action "' + action.ToolName__c + '" was rejected.';
                    if (String.isNotBlank(action.ResolutionComment__c)) {
                        message += ' Reason: ' + action.ResolutionComment__c;
                    }
                    HITLGatewayService.sendUserNotification(
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

    private static void executeAndResumeFlow(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing tool and resuming flow for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null) {
            throw new HITLGatewayService.HITLProcessingException('Could not load pending action: ' + action.Id);
        }

        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(fullAction.AgentExecution__c, fullAction.TurnIdentifier__c);
            decisionLogger.log(IDecisionStepLogger.EventType.APPROVAL_RESOLVED, new List<Object>{ fullAction, true });
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log approval decision step: ' + e.getMessage());
        }

        AgentCapability__c capability = AIAgentConfigService.getCapabilityById(fullAction.AIAgentCapability__c);
        if (capability == null) {
            throw new HITLGatewayService.HITLProcessingException('Capability not found: ' + fullAction.AIAgentCapability__c);
        }

        AgentExecution__c execution = [
            SELECT Id, AIAgentDefinition__r.AgentType__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        // HITL approved tools execute via Named Credential which handles service user authentication
        Boolean needsFollowUp = (execution.AIAgentDefinition__r.AgentType__c != 'Conversational');

        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueueing tool execution via REST API (Named Credential handles auth)');
        System.debug(
            LoggingLevel.DEBUG,
            logPrefix + 'Follow-up LLM call needed: ' + needsFollowUp + ' (AgentType: ' + execution.AIAgentDefinition__r.AgentType__c + ')'
        );

        System.enqueueJob(new HITLServiceQueueable(fullAction.Id, needsFollowUp));

        System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution queued via HITLServiceQueueable');
    }

    private static void resumeFlowWithDecline(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with decline for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        String declineMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'declined' => true,
                'message' => 'User declined to execute this action.',
                'comment' => fullAction.ResolutionComment__c
            }
        );

        ExecutionStepService stepService = new ExecutionStepService();
        // IMPORTANT: Decline is NOT an error - it's a valid user decision
        // The LLM should adapt rather than retry
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, declineMessage, 0L, false);

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
                false // IsError = false: decline is a valid outcome, not an error
            );
        }

        AgentExecution__c execution = [
            SELECT Id, User__c, ServiceUser__c, AIAgentDefinition__c, SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    private static void resumeFlowWithRejection(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with rejection for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(fullAction.AgentExecution__c, fullAction.TurnIdentifier__c);
            decisionLogger.log(IDecisionStepLogger.EventType.APPROVAL_RESOLVED, new List<Object>{ fullAction, false });
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log rejection decision step: ' + e.getMessage());
        }

        String rejectionMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'rejected' => true,
                'message' => 'Action was rejected by approver.',
                'approverComment' => fullAction.ResolutionComment__c
            }
        );

        ExecutionStepService stepService = new ExecutionStepService();
        // IMPORTANT: Rejection is NOT an error - it's a valid user decision
        // The LLM should adapt (e.g., choose a different action) rather than retry
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, rejectionMessage, 0L, false);

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
                false // IsError = false: rejection is a valid outcome, not an error
            );
        }

        AgentExecution__c execution = [
            SELECT Id, User__c, ServiceUser__c, AIAgentDefinition__c, SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    private static void resumeFlowWithExpiration(PendingHITLAction__c action, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming flow with expiration for action: ' + action.Id);

        PendingHITLAction__c fullAction = HITLGatewayService.getPendingAction(action.Id);
        if (fullAction == null)
            return;

        String expirationMessage = JSON.serialize(
            new Map<String, Object>{
                'success' => false,
                'expired' => true,
                'message' => 'Confirmation request expired without user response. The user may have been away or busy.'
            }
        );

        ExecutionStepService stepService = new ExecutionStepService();
        // IMPORTANT: Expiration is NOT an error - it's a timeout, a valid outcome
        // The LLM should handle this gracefully and adapt
        Id updatedStepId = stepService.updateToolResultStep(fullAction.AgentExecution__c, fullAction.ToolCallId__c, expirationMessage, 0L, false);

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
                false // IsError = false: expiration is a timeout, not an error
            );
        }

        AgentExecution__c execution = [
            SELECT Id, User__c, ServiceUser__c, AIAgentDefinition__c, SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :fullAction.AgentExecution__c
            LIMIT 1
        ];

        queueFollowUpLLMCall(fullAction, execution, logPrefix);
    }

    private static void queueFollowUpLLMCall(PendingHITLAction__c action, AgentExecution__c execution, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Checking if follow-up LLM call needed for execution: ' + execution.Id);

        try {
            // Check for pending async tools - if any are still running, defer LLM call to async completion
            AgentExecution__c execWithAsyncCount = [
                SELECT Id, PendingAsyncToolCount__c
                FROM AgentExecution__c
                WHERE Id = :execution.Id
                LIMIT 1
            ];

            Integer pendingAsyncCount = execWithAsyncCount.PendingAsyncToolCount__c != null ? execWithAsyncCount.PendingAsyncToolCount__c.intValue() : 0;

            if (pendingAsyncCount > 0) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'HITL resolved but ' + pendingAsyncCount + ' async tool(s) still pending. Deferring LLM call to async completion.'
                );
                return;
            }

            AIAgentDefinition__c agentDef = [
                SELECT AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :execution.AIAgentDefinition__c
                LIMIT 1
            ];

            if (agentDef.AgentType__c == 'Conversational') {
                System.debug(LoggingLevel.INFO, logPrefix + 'Conversational agent - no follow-up needed, turn already completed');
                return;
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Queueing follow-up LLM call for ' + agentDef.AgentType__c + ' agent');

            // IMPORTANT: Always route follow-up LLM through REST API (via HITLServiceQueueable)
            // to maintain consistency with approval flow which always uses REST API for tool execution.
            // This ensures the Named Credential authenticates as the service user, providing
            // proper context for any subsequent tool calls the LLM may request.
            System.debug(LoggingLevel.INFO, logPrefix + 'Using HITLServiceQueueable to route follow-up LLM via REST API');
            System.enqueueJob(
                new HITLServiceQueueable(
                    execution.Id,
                    action.TurnIdentifier__c,
                    action.TurnCount__c != null ? action.TurnCount__c.intValue() : 1,
                    execution.SourceRecordId__c
                )
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM call queued successfully');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue follow-up LLM call: ' + e.getMessage());
            throw e;
        }
    }

    private static void notifyUserOfError(PendingHITLAction__c action, String errorMessage) {
        if (action.RequestingUser__c != null && shouldSendNotification(action, HITLGatewayService.NOTIFICATION_TYPE_ERROR)) {
            try {
                HITLGatewayService.sendUserNotification(
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

    private static Set<Id> getActionIds(List<PendingHITLAction__c> actions) {
        Set<Id> ids = new Set<Id>();
        for (PendingHITLAction__c action : actions) {
            ids.add(action.Id);
        }
        return ids;
    }

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

    private static Boolean shouldSendNotification(PendingHITLAction__c action, String eventType) {
        String preference = action.AIAgentCapability__r?.HITLNotificationPreference__c;
        return HITLGatewayService.shouldSendHITLNotification(preference, eventType);
    }
}
