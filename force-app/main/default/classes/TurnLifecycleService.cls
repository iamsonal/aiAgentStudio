/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Manages the lifecycle and state transitions of a chat session turn.
 *              Uses ChatSessionStateService for actual DML and event publishing.
 */
public inherited sharing class TurnLifecycleService {
    public class LifecycleException extends AIAgentException {
    }

    private ChatSessionStateService stateService;

    public TurnLifecycleService() {
        this.stateService = new ChatSessionStateService();
    }

    @TestVisible
    private TurnLifecycleService(ChatSessionStateService mockStateService) {
        this.stateService = mockStateService;
    }

    /** Called when a turn begins any form of active processing (LLM call, action exec) */
    public void startTurnProcessing(Id sessionId, String turnIdentifier, Id jobIdIfAny, String logPrefix) {
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_PROCESSING, jobIdIfAny, null, turnIdentifier);
    }

    /** Called when pausing for user confirmation before an action. */
    public void pauseForUserConfirmation(Id sessionId, String turnIdentifier, String logPrefix) {
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_USER_CONFIRMATION, null, null, turnIdentifier);
    }

    /** Called when an asynchronous action is queued, and we are waiting for its completion. */
    public void pauseForAsyncAction(Id sessionId, String turnIdentifier, Id jobId, String logPrefix) {
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_ACTION, jobId, null, turnIdentifier);
    }

    /** Called after a tool/action completes and the system needs another LLM call to continue the turn. */
    public void resumeForFollowUpLlmCall(Id sessionId, String turnIdentifier, Id nextJobId, String logPrefix) {
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_FOLLOWUP, nextJobId, null, turnIdentifier);
    }

    /**
     * @description Call when a turn completes successfully with a final assistant message.
     * @param finalAssistantMessageId ID of the last ChatMessage__c from the assistant for this turn.
     */
    public void completeTurnSuccessfully(Id sessionId, String turnIdentifier, Id finalAssistantMessageId, String logPrefix) {
        this.stateService.updateFinalStatus(sessionId, true, null, turnIdentifier);
        this.stateService.publishFinalResponseEvent(sessionId, true, finalAssistantMessageId, null, turnIdentifier);
    }

    /** Call when a turn fails unrecoverably. */
    public void failTurn(Id sessionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        String errorDetailForState = String.isNotBlank(errorCode) ? '[' + errorCode + '] ' + errorMessage : errorMessage;

        this.stateService.updateFinalStatus(sessionId, false, errorDetailForState?.abbreviate(131072), turnIdentifier);

        this.stateService.publishFinalResponseEvent(sessionId, false, null, errorMessage?.abbreviate(255), turnIdentifier);
    }
}
