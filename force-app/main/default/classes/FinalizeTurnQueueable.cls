/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Queueable Job: FINAL step (Event Publishing Only).
 *              Sole responsibility is to publish the final AgentResponse__e Platform Event
 *              indicating the success/failure status determined by the *calling* queueable.
 *              Does NOT perform DML or session state updates.
 */
public class FinalizeTurnQueueable implements Queueable {
    private Id chatSessionId;
    private Boolean finalIsSuccess;
    private Id finalAssistantMsgId;
    private String finalErrorDetails;
    private String turnIdentifier;

    public FinalizeTurnQueueable(Id sessionId, Boolean isSuccess, Id messageId, String errorDetails, String turnId) {
        if (sessionId == null || String.isBlank(turnId)) {
            throw new IllegalArgumentException('FinalizeTurnQueueable requires SessionId and TurnIdentifier.');
        }
        this.chatSessionId = sessionId;
        this.finalIsSuccess = isSuccess;
        this.finalAssistantMsgId = isSuccess ? messageId : null;
        this.finalErrorDetails = isSuccess ? null : errorDetails;
        this.turnIdentifier = turnId;
    }

    public void execute(QueueableContext context) {
        Integer seq = 0;
        String logPrefix = '[FinalizeTurn:' + this.turnIdentifier?.left(8) + ' Session:' + this.chatSessionId + '] ';

        try {
            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                this.finalIsSuccess ? OrchestrationLogger.TYPE_TURN_COMPLETE : OrchestrationLogger.TYPE_TURN_FAIL,
                OrchestrationLogger.STATUS_INIT,
                'Publishing final agent response event.',
                new Map<String, Object>{ 'success' => this.finalIsSuccess },
                null,
                this.finalErrorDetails,
                null,
                null,
                this.finalAssistantMsgId,
                null,
                null,
                null,
                null
            );
            publishResponseEvent(
                this.chatSessionId,
                this.finalIsSuccess,
                this.finalAssistantMsgId,
                this.finalErrorDetails
            );
        } catch (Exception eventEx) {
            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                this.finalIsSuccess ? OrchestrationLogger.TYPE_TURN_COMPLETE : OrchestrationLogger.TYPE_TURN_FAIL,
                OrchestrationLogger.STATUS_FAILURE,
                'Failed to publish final agent response event.',
                null,
                null,
                eventEx.getMessage(),
                eventEx.getTypeName(),
                null,
                this.finalAssistantMsgId,
                null,
                null,
                null,
                null
            );
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }

    /**
     * @description Helper method to encapsulate event publishing logic.
     * @param sessionId The chat session ID.
     * @param isSuccess The final success status of the turn.
     * @param messageId The final assistant message ID (null if !isSuccess).
     * @param errorDetails The error details (null if isSuccess).
     */
    @TestVisible
    private static void publishResponseEvent(Id sessionId, Boolean isSuccess, Id messageId, String errorDetails) {
        String logPrefix = '[FinalizeTurnQueueable.publish] ';

        try {
            AgentResponse__e event = new AgentResponse__e(
                ChatSessionId__c = sessionId,
                IsSuccess__c = isSuccess,
                FinalAssistantMessageId__c = messageId,
                ErrorDetails__c = errorDetails?.abbreviate(255)
            );
            Database.SaveResult sr = EventBus.publish(event);

            if (!sr.isSuccess()) {
            } else {
            }
        } catch (Exception e) {
        }
    }

    public class IllegalArgumentException extends AIAgentException {
    }
}
