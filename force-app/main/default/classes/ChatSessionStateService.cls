/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Centralized service for managing ChatSession__c DML status updates using locking
 *              and publishing the final AgentResponse__e Platform Event.
 */
public inherited sharing class ChatSessionStateService {
    public class StateUpdateException extends AIAgentException {
    }

    /**
     * @description Updates the processing status and related fields. Determines field clearing based on final state.
     *              Called by TurnLifecycleService.
     * @param currentJobId Apex Job ID of the *next* async job OR current job that set this state (null if finalizing or sync step).
     */
    public void updateStatus(Id sessionId, String newStatus, Id currentJobId, String errorDetails, String activeTurnIdentifier) {
        Boolean isFinalState = (newStatus == AIAgentConstants.STATUS_IDLE || newStatus == AIAgentConstants.STATUS_FAILED);
        updateStatusInternal(sessionId, newStatus, currentJobId, errorDetails, activeTurnIdentifier, isFinalState);
    }

    /**
     * @description Simplified final update to Idle or Failed status.
     *              Called by TurnLifecycleService.
     */
    public void updateFinalStatus(Id sessionId, Boolean isSuccess, String errorDetails, String activeTurnIdentifier) {
        String finalStatus = isSuccess ? AIAgentConstants.STATUS_IDLE : AIAgentConstants.STATUS_FAILED;
        updateStatusInternal(sessionId, finalStatus, null, errorDetails, activeTurnIdentifier, true);
    }

    @TestVisible
    private static void updateStatusInternal(
        Id sessionId,
        String newStatus,
        Id currentJobId,
        String errorDetails,
        String activeTurnIdentifier,
        Boolean isFinalState
    ) {
        String logPrefix = '[ChatStateSvc Turn:' + activeTurnIdentifier?.left(8) + ' Sess:' + sessionId + '] ';

        if (sessionId == null || String.isBlank(newStatus)) {
            throw new StateUpdateException(logPrefix + 'Session ID and New Status are required.');
        }

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, CurrentJobId__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty())
                throw new StateUpdateException(logPrefix + 'Target session not found for update.');
            ChatSession__c sessionToUpdate = sessions[0];
            String oldStatus = sessionToUpdate.ProcessingStatus__c;
            String oldJobId = sessionToUpdate.CurrentJobId__c;
            String oldTurnId = sessionToUpdate.CurrentTurnIdentifier__c;

            ChatSession__c updateRecord = new ChatSession__c(Id = sessionId);
            updateRecord.ProcessingStatus__c = newStatus;
            updateRecord.LastActivityTime__c = Datetime.now();

            if (isFinalState) {
                updateRecord.CurrentJobId__c = null;
                updateRecord.CurrentTurnIdentifier__c = null;
                updateRecord.LastProcessingError__c = (newStatus == AIAgentConstants.STATUS_FAILED) ? errorDetails : null;
            } else {
                if (String.isBlank(activeTurnIdentifier)) {
                    throw new StateUpdateException('Internal Error: Active Turn Identifier missing for intermediate state update.');
                }

                updateRecord.CurrentJobId__c = currentJobId;
                updateRecord.CurrentTurnIdentifier__c = activeTurnIdentifier;
                updateRecord.LastProcessingError__c = null;
            }

            Database.SaveResult sr = Database.update(updateRecord, false);
            if (!sr.isSuccess()) {
                String dmlErrorMsg = '';
                for (Database.Error err : sr.getErrors()) {
                    dmlErrorMsg += err.getStatusCode() + ': ' + err.getMessage() + '[' + String.join(err.getFields(), ',') + ']; ';
                }

                throw new StateUpdateException(logPrefix + 'DML Error during ChatSession update: ' + dmlErrorMsg);
            }
        } catch (Exception ex) {
            if (!(ex instanceof StateUpdateException)) {
                throw new StateUpdateException(logPrefix + 'Unexpected error during ChatSession update: ' + ex.getMessage(), ex);
            }
            throw ex;
        }
    }

    /**
     * @description Publishes the final AgentResponse__e Platform Event.
     *              This is called by TurnLifecycleService *after* final session status (Idle/Failed) DML is committed.
     * @param finalAssistantMessageId ID of the ChatMessage__c record for the final assistant response (null if none or error).
     */
    @TestVisible
    public void publishFinalResponseEvent(
        Id sessionId,
        Boolean isSuccess,
        Id finalAssistantMessageId,
        String errorDetails,
        String activeTurnIdentifier
    ) {
        String logPrefix = '[ChatStateSvc.Event Turn:' + activeTurnIdentifier?.left(8) + ' Sess:' + sessionId + '] ';

        try {
            AgentResponse__e event = new AgentResponse__e(
                ChatSessionId__c = sessionId,
                IsSuccess__c = isSuccess,
                FinalAssistantMessageId__c = (isSuccess && finalAssistantMessageId != null) ? String.valueOf(finalAssistantMessageId) : null,
                ErrorDetails__c = errorDetails
            );
            Database.SaveResult sr = EventBus.publish(event);

            if (!sr.isSuccess()) {
                String errMsg = logPrefix + 'EventBus.publish errors: ' + JSON.serialize(sr.getErrors());
            } else {
            }
        } catch (Exception e) {
        }
    }
}
