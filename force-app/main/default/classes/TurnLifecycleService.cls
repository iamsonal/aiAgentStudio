/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * TurnLifecycleService manages the state transitions and lifecycle events for chat session turns
 * within the agent orchestration framework.
 *
 * Responsibilities:
 *   - Coordinates turn state changes (processing, awaiting action, follow-up, completion, failure).
 *   - Delegates persistence and event publication to ChatSessionStateService.
 *   - Integrates with orchestration logging for traceability and audit.
 *   - Provides user-friendly status descriptions for UI and debugging.
 *
 * This class is the central point for all turn-level state management, ensuring robust, auditable,
 * and maintainable orchestration of agent conversations.
 */
public inherited sharing class TurnLifecycleService {
    private final ChatSessionStateService stateService;

    /**
     * Constructs a TurnLifecycleService with the default ChatSessionStateService dependency.
     */
    public TurnLifecycleService() {
        this(new ChatSessionStateService());
    }

    /**
     * Constructs a TurnLifecycleService with an injected ChatSessionStateService dependency.
     *
     * @param stateService The ChatSessionStateService implementation to use for persistence and events.
     * @throws IllegalArgumentException if stateService is null.
     */
    public TurnLifecycleService(ChatSessionStateService stateService) {
        if (stateService == null) {
            throw new IllegalArgumentException('ChatSessionStateService cannot be null.');
        }
        this.stateService = stateService;
    }

    /**
     * Transitions the turn to the active processing state for LLM calls or action execution.
     *
     * @param sessionId The chat session Id.
     * @param turnIdentifier The unique identifier for the turn.
     * @param jobIdIfAny Optional job Id associated with the turn.
     * @param logPrefix String prefix for log output.
     */
    public void startTurnProcessing(Id sessionId, String turnIdentifier, Id jobIdIfAny, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'TurnLifecycleService: PROCESSING state for Turn=' + turnIdentifier + (jobIdIfAny != null ? (', Job=' + jobIdIfAny) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_PROCESSING, null);
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_PROCESSING, jobIdIfAny, null, turnIdentifier, stepDesc);
    }

    /**
     * Transitions the turn to the awaiting state while an asynchronous action executes.
     *
     * @param sessionId The chat session Id.
     * @param turnIdentifier The unique identifier for the turn.
     * @param jobId The job Id for the async action.
     * @param toolName The name of the tool being executed (for context).
     * @param logPrefix String prefix for log output.
     */
    public void pauseForAsyncAction(Id sessionId, String turnIdentifier, Id jobId, String toolName, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: AWAITING_ACTION state for Turn=' +
                turnIdentifier +
                (jobId != null ? (', Job=' + jobId) : '') +
                (String.isNotBlank(toolName) ? (', Tool=' + toolName) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_ACTION, toolName);
        // Context will be updated by async job when it completes
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_ACTION, jobId, null, turnIdentifier, stepDesc);
    }

    /**
     * Transitions the turn to the follow-up state after action completion, preparing for the next LLM call.
     *
     * @param sessionId The chat session Id.
     * @param turnIdentifier The unique identifier for the turn.
     * @param nextJobId The job Id for the next step, if any.
     * @param logPrefix String prefix for log output.
     */
    public void resumeForFollowUpLlmCall(Id sessionId, String turnIdentifier, Id nextJobId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: AWAITING_FOLLOWUP state for Turn=' +
                turnIdentifier +
                (nextJobId != null ? (', NextJob=' + nextJobId) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, null);
        // Context already updated by action handler
        this.stateService.updateStatus(sessionId, AIAgentConstants.STATUS_AWAITING_FOLLOWUP, nextJobId, null, turnIdentifier, stepDesc);
    }

    /**
     * Completes the turn successfully and publishes the final response event.
     * Includes orchestration logging and cleanup of turn-specific resources.
     *
     * @param sessionId The chat session Id.
     * @param turnIdentifier The unique identifier for the turn.
     * @param finalAssistantMessageId The Id of the final assistant message for this turn.
     * @param logPrefix String prefix for log output.
     */
    public void completeTurnSuccessfully(Id sessionId, String turnIdentifier, Id finalAssistantMessageId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: IDLE (Turn Complete) state for Turn=' +
                turnIdentifier +
                (finalAssistantMessageId != null ? (', FinalMsg=' + finalAssistantMessageId) : '')
        );

        this.stateService.updateFinalStatus(sessionId, true, null, turnIdentifier);
        this.stateService.publishFinalResponseEvent(sessionId, true, finalAssistantMessageId, null, turnIdentifier);
    }

    /**
     * Marks the turn as failed and publishes an error event, including orchestration logging.
     *
     * @param sessionId The chat session Id.
     * @param turnIdentifier The unique identifier for the turn.
     * @param errorMessage The error message to record.
     * @param errorCode The error code to record.
     * @param logPrefix String prefix for log output.
     */
    public void failTurn(Id sessionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        String errorDetailForState = String.isNotBlank(errorCode) ? '[' + errorCode + '] ' + errorMessage : errorMessage;
        System.debug(
            LoggingLevel.ERROR,
            logPrefix + 'TurnLifecycleService: FAILED state for Turn=' + turnIdentifier + '. Error=' + errorDetailForState
        );

        this.stateService.updateFinalStatus(sessionId, false, errorDetailForState?.abbreviate(131072), turnIdentifier);
        this.stateService.publishFinalResponseEvent(sessionId, false, null, errorMessage?.abbreviate(255), turnIdentifier);
    }

    /**
     * Generates user-friendly status descriptions for UI display based on technical status codes.
     *
     * @param newStatus Technical status constant from AIAgentConstants.
     * @param contextName Optional context (e.g., tool name) for enhanced messaging.
     * @return String user-friendly status description for UI.
     */
    @TestVisible
    private String generateStepDescription(String newStatus, String contextName) {
        if (String.isBlank(newStatus))
            return null;

        switch on newStatus {
            when 'Processing' {
                return 'Thinking...';
            }
            when 'Awaiting Action' {
                // Include tool name for more informative user feedback
                return 'Executing: ' + (String.isNotBlank(contextName) ? contextName.abbreviate(50) : 'Action');
            }
            when 'Awaiting Followup' {
                return 'Processing results...';
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
