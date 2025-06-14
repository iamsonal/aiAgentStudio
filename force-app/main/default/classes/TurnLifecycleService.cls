/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Manages the lifecycle and state transitions of a chat session turn.
 *              Uses ChatSessionStateService for actual DML and event publishing.
 */
public inherited sharing class TurnLifecycleService {
    public class LifecycleException extends AIAgentException {
    }

    private final ChatSessionStateService stateService;

    /**
     * @description Default constructor for ease of use.
     */
    public TurnLifecycleService() {
        this(new ChatSessionStateService());
    }

    /**
     * @description Main constructor for dependency injection.
     * @param stateService The state service implementation to use.
     */
    public TurnLifecycleService(ChatSessionStateService stateService) {
        if (stateService == null) {
            throw new IllegalArgumentException('ChatSessionStateService cannot be null.');
        }
        this.stateService = stateService;
    }

    /** Called when a turn begins any form of active processing (LLM call, action exec) */
    public void startTurnProcessing(Id sessionId, String turnIdentifier, Id jobIdIfAny, String logPrefix) {
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_PROCESSING, null);
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_PROCESSING, jobIdIfAny, null, turnIdentifier, stepDesc);
    }

    /** Called when an asynchronous action is queued, and we are waiting for its completion. */
    public void pauseForAsyncAction(Id sessionId, String turnIdentifier, Id jobId, String toolName, String logPrefix) {
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_ACTION, toolName);
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_ACTION, jobId, null, turnIdentifier, stepDesc);
    }

    /** Called after a tool/action completes and the system needs another LLM call to continue the turn. */
    public void resumeForFollowUpLlmCall(Id sessionId, String turnIdentifier, Id nextJobId, String logPrefix) {
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, null);
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_FOLLOWUP, nextJobId, null, turnIdentifier, stepDesc);
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

    /**
     * @description Generates a user-friendly status message based on the new state and optional context.
     * @param newStatus The technical status from AIAgentConstants.
     * @param contextName Optional context, like a Tool Name.
     * @return A user-friendly string for display.
     */
    @TestVisible
    private String generateStepDescription(String newStatus, String contextName) {
        if (String.isBlank(newStatus))
            return null;

        switch on newStatus {
            when 'Processing' {
                return 'Thinking...';
            }
            when 'AwaitingAction' {
                return 'Executing: ' + (String.isNotBlank(contextName) ? contextName.abbreviate(50) : 'Action');
            }
            when 'AwaitingFollowup' {
                return 'Processing results...';
            }
            when 'AwaitingUserConfirmation' {
                return 'Waiting for your confirmation...';
            }
            when 'Failed' {
                return 'An error occurred.';
            }
            when 'Idle' {
                return 'Done.';
            }
            when else {
                return 'Processing...';
            }
        }
    }
}
