/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Centralized service for managing ChatSession__c status updates
 *              during asynchronous agent processing. Enforces locking and consistent state transitions.
 *              Handles preservation and clearing of the CurrentTurnIdentifier__c.
 */
public inherited sharing class ChatSessionStateService {
    /**
     * @description Updates the processing status and related fields on a Chat Session.
     *              Determines whether to clear Job/Turn IDs based on the newStatus being final (Idle/Failed).
     * @param sessionId The ID of the ChatSession__c to update.
     * @param newStatus The target ProcessingStatus__c (use AIAgentConstants).
     * @param nextExpectedStatus The expected status for the *next* step (use AIAgentConstants).
     * @param currentJobId The Apex Job ID of the *next* enqueued job (null if finalizing or transitioning to a state handled by trigger/event). Used ONLY for intermediate states.
     * @param errorDetails Error message to store if newStatus is FAILED, otherwise null/cleared.
     * @param turnIdentifierForLog The Turn Identifier FOR LOGGING CONTEXT only during this update. Does NOT set the CurrentTurnIdentifier__c field.
     * @throws StateUpdateException if the session cannot be locked, DML fails, or critical validation fails.
     */
    public static void updateStatus(
        Id sessionId,
        String newStatus,
        String nextExpectedStatus,
        Id currentJobId,
        String errorDetails,
        String turnIdentifierForLog
    ) {
        Boolean isFinalState = (newStatus == AIAgentConstants.STATUS_IDLE ||
        newStatus == AIAgentConstants.STATUS_FAILED);

        updateStatusInternal(
            sessionId,
            newStatus,
            nextExpectedStatus,
            currentJobId,
            errorDetails,
            turnIdentifierForLog,
            isFinalState
        );
    }

    public static void updateFinalStatus(
        Id sessionId,
        Boolean isSuccess,
        String errorDetails,
        String turnIdentifierForLog
    ) {
        String finalStatus = isSuccess ? AIAgentConstants.STATUS_IDLE : AIAgentConstants.STATUS_FAILED;

        updateStatusInternal(
            sessionId,
            finalStatus,
            AIAgentConstants.NEXT_EXPECTED_NONE,
            null,
            errorDetails,
            turnIdentifierForLog,
            true
        );
    }

    /**
     * @description Internal worker method that performs the actual query and DML.
     * @param isFinalState Flag indicating if this transition moves the session to a terminal state (Idle/Failed).
     */
    @TestVisible
    private static void updateStatusInternal(
        Id sessionId,
        String newStatus,
        String nextExpectedStatus,
        Id currentJobId,
        String errorDetails,
        String turnIdentifierForLog,
        Boolean isFinalState
    ) {
        String logPrefix =
            '[ChatSessionStateSvc TurnLog:' +
            turnIdentifierForLog?.left(8) +
            ' Session:' +
            sessionId +
            '] ';

        if (sessionId == null || String.isBlank(newStatus)) {
            throw new StateUpdateException(logPrefix + 'Session ID and New Status cannot be blank.');
        }

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, CurrentJobId__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty()) {
                throw new StateUpdateException(logPrefix + 'Target session ' + sessionId + ' not found for update.');
            }
            ChatSession__c sessionToUpdate = sessions[0];
            String oldStatus = sessionToUpdate.ProcessingStatus__c;
            String oldTurnId = sessionToUpdate.CurrentTurnIdentifier__c;

            ChatSession__c updateRecord = new ChatSession__c(Id = sessionId);

            updateRecord.ProcessingStatus__c = newStatus;
            updateRecord.NextExpectedStatus__c = nextExpectedStatus;
            updateRecord.LastActivityTime__c = Datetime.now();

            if (isFinalState) {
                updateRecord.CurrentJobId__c = null;
                updateRecord.CurrentTurnIdentifier__c = null;
                updateRecord.LastProcessingError__c = (newStatus == AIAgentConstants.STATUS_FAILED)
                    ? errorDetails?.abbreviate(131072)
                    : null;
            } else {
                updateRecord.CurrentJobId__c = currentJobId;

                updateRecord.LastProcessingError__c = null;
            }

            Database.SaveResult sr = Database.update(updateRecord, false);

            if (!sr.isSuccess()) {
                String dmlErrorMsg =
                    logPrefix +
                    'DML Error updating session status from ' +
                    oldStatus +
                    ' to ' +
                    newStatus +
                    '. Error: ';
                for (Database.Error err : sr.getErrors()) {
                    dmlErrorMsg +=
                        err.getStatusCode() +
                        ': ' +
                        err.getMessage() +
                        ' [' +
                        String.join(err.getFields(), ',') +
                        ']; ';
                }

                throw new StateUpdateException(dmlErrorMsg);
            } else {
            }
        } catch (Exception ex) {
            String errorMsg =
                logPrefix +
                'Exception during session status update to ' +
                newStatus +
                ': ' +
                ex.getMessage();

            if (!(ex instanceof StateUpdateException)) {
                throw new StateUpdateException(errorMsg, ex);
            } else {
                throw ex;
            }
        }
    }

    public class StateUpdateException extends AIAgentException {
    }

    /*
    private static void validateTransition(String currentStatus, String nextStatus) {
        
        if (currentStatus == AIAgentConstants.STATUS_IDLE && nextStatus == AIAgentConstants.STATUS_EXECUTING_ACTIONS) {
            throw new StateUpdateException('Invalid transition: Cannot move directly from Idle to ExecutingActions.');
        }
        
    }
    */
}
