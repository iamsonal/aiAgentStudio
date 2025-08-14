/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ChatSessionStateService is the authoritative service for managing the lifecycle and state transitions
 * of chat sessions in the AI Agent Framework.
 *
 * Responsibilities:
 *   - Provides atomic, lock-protected updates to session status and processing fields
 *   - Ensures concurrent access safety and prevents race conditions via FOR UPDATE locking
 *   - Handles all state transitions, including finalization and error handling, with robust logging
 *   - Publishes event-driven notifications for downstream consumers on session completion
 *
 * This class is not intended for direct use outside the session management and orchestration subsystems.
 */
public inherited sharing class ChatSessionStateService {
    public class StateUpdateException extends AIAgentException {
    }

    /**
     * Updates the chat session's processing status, managing all relevant fields based on the new state.
     * Ensures atomic updates with record locking to prevent concurrent modification issues.
     *
     * @param sessionId            The session to update.
     * @param newStatus            The new processing status value.
     * @param currentJobId         The active async job identifier for tracking processing chain.
     * @param errorDetails         Error details to record if transitioning to a failed state.
     * @param activeTurnIdentifier The current turn identifier (required for intermediate states).
     * @param currentStepDescription Description of the current processing step (optional).
     * @throws StateUpdateException if required parameters are missing or DML fails.
     */
    public void updateStatus(
        Id sessionId,
        String newStatus,
        Id currentJobId,
        String errorDetails,
        String activeTurnIdentifier,
        String currentStepDescription
    ) {
        Boolean isFinalState = (newStatus == AIAgentConstants.STATUS_IDLE || newStatus == AIAgentConstants.STATUS_FAILED);
        updateStatusInternal(sessionId, newStatus, currentJobId, errorDetails, activeTurnIdentifier, isFinalState, currentStepDescription);
    }

    /**
     * Finalizes the session state to either successful completion or failure, performing all necessary cleanup.
     * Clears all temporary processing fields to ensure a clean final state.
     *
     * @param sessionId            The session to finalize.
     * @param isSuccess            True if the session completed successfully, false if failed.
     * @param errorDetails         Error details to record if failed.
     * @param activeTurnIdentifier The current turn identifier.
     * @throws StateUpdateException if DML fails.
     */
    public void updateFinalStatus(Id sessionId, Boolean isSuccess, String errorDetails, String activeTurnIdentifier) {
        String finalStatus = isSuccess ? AIAgentConstants.STATUS_IDLE : AIAgentConstants.STATUS_FAILED;
        // The user-visible status should be cleared in the final state.
        updateStatusInternal(sessionId, finalStatus, null, errorDetails, activeTurnIdentifier, true, null);
    }

    /**
     * Internal implementation for updating session state, with full field management and error handling.
     * Uses FOR UPDATE locking to ensure atomicity and prevent race conditions.
     *
     * @param sessionId            The session to update.
     * @param newStatus            The new processing status value.
     * @param currentJobId         The active async job identifier.
     * @param errorDetails         Error details to record if failed.
     * @param activeTurnIdentifier The current turn identifier (required for intermediate states).
     * @param isFinalState         True if this is a final state transition (idle/failed), false otherwise.
     * @param currentStepDescription Description of the current processing step (optional).
     * @throws StateUpdateException if required parameters are missing or DML fails.
     */
    @TestVisible
    private static void updateStatusInternal(
        Id sessionId,
        String newStatus,
        Id currentJobId,
        String errorDetails,
        String activeTurnIdentifier,
        Boolean isFinalState,
        String currentStepDescription
    ) {
        String logPrefix = '[ChatStateSvc Turn:' + activeTurnIdentifier?.left(8) + ' Sess:' + sessionId + '] ';
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'Session state update: newStatus=' +
                newStatus +
                (currentJobId != null ? ' (Job: ' + currentJobId + ')' : '') +
                (isFinalState ? ' [FINAL]' : '') +
                (currentStepDescription != null ? ' - ' + currentStepDescription : '')
        );

        if (sessionId == null || String.isBlank(newStatus)) {
            throw new StateUpdateException(logPrefix + 'Session ID and New Status are required.');
        }

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, CurrentJobId__c, CurrentStepDescription__c
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
            String oldStepDesc = sessionToUpdate.CurrentStepDescription__c;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Current session state: status=' + oldStatus + ', turn=' + oldTurnId + ', job=' + oldJobId);

            ChatSession__c updateRecord = new ChatSession__c(Id = sessionId);
            updateRecord.ProcessingStatus__c = newStatus;
            updateRecord.LastActivityTime__c = Datetime.now();
            updateRecord.CurrentStepDescription__c = currentStepDescription;

            if (isFinalState) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Final state cleanup: clearing processing fields');
                updateRecord.CurrentJobId__c = null;
                updateRecord.CurrentTurnIdentifier__c = null;
                updateRecord.CurrentStepDescription__c = null;
                updateRecord.LastProcessingError__c = (newStatus == AIAgentConstants.STATUS_FAILED) ? errorDetails : null;
            } else {
                if (String.isBlank(activeTurnIdentifier)) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: Turn identifier required for intermediate state transition to ' + newStatus);
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
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'DML error during state transition ' + oldStatus + ' -> ' + newStatus + ': ' + dmlErrorMsg
                );
                throw new StateUpdateException(logPrefix + 'DML Error during ChatSession update: ' + dmlErrorMsg);
            }
            System.debug(LoggingLevel.INFO, logPrefix + 'Session state transition complete: ' + oldStatus + ' -> ' + newStatus);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during state update to ' + newStatus + ': ' + ex.getMessage());
            if (!(ex instanceof StateUpdateException)) {
                throw new StateUpdateException(logPrefix + 'Unexpected error during ChatSession update: ' + ex.getMessage(), ex);
            }
            throw ex;
        }
    }

    /**
     * Publishes a completion event to notify subscribers of conversation turn completion.
     * Includes response content and success status for downstream processing and UI updates.
     *
     * @param sessionId               The session for which the event is published.
     * @param isSuccess               True if the turn completed successfully, false if failed.
     * @param finalAssistantMessageId Identifier of the final assistant response message.
     * @param errorDetails            Error details to include in the event.
     * @param activeTurnIdentifier    The current turn identifier.
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
        System.debug(LoggingLevel.INFO, logPrefix + 'Publishing completion event: success=' + isSuccess + ', messageId=' + finalAssistantMessageId);

        String finalMessageContent = null;
        if (isSuccess && finalAssistantMessageId != null) {
            try {
                // Query for the message content to include in the event payload
                List<ChatMessage__c> messages = [SELECT Content__c FROM ChatMessage__c WHERE Id = :finalAssistantMessageId LIMIT 1];
                if (!messages.isEmpty()) {
                    finalMessageContent = messages[0].Content__c;
                }
            } catch (Exception qe) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Warning: Unable to retrieve message content for event: ' + qe.getMessage());
            }
        }

        try {
            AgentResponse__e event = new AgentResponse__e(
                ChatSessionId__c = sessionId,
                IsSuccess__c = isSuccess,
                FinalAssistantMessageId__c = (isSuccess && finalAssistantMessageId != null) ? String.valueOf(finalAssistantMessageId) : null,
                ErrorDetails__c = errorDetails,
                FinalMessageContent__c = finalMessageContent // Populate the new field
            );
            Database.SaveResult sr = EventBus.publish(event);

            if (!sr.isSuccess()) {
                String errMsg = logPrefix + 'EventBus.publish errors: ' + JSON.serialize(sr.getErrors());
                System.debug(LoggingLevel.ERROR, errMsg);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Completion event published successfully');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Event publishing failed: ' + e.getMessage());
        }
    }
}
