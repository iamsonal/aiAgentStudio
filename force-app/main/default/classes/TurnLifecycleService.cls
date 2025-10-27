/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Manages state transitions and lifecycle events for execution turns.
 * Coordinates turn state changes and integrates with orchestration logging.
 */
public inherited sharing class TurnLifecycleService {
    private final ExecutionContextService executionContextService;

    /**
     * Default constructor with default service dependencies.
     */
    public TurnLifecycleService() {
        this(new ExecutionContextService());
    }

    /**
     * Constructor with injected service dependencies.
     *
     * @param executionContextService ExecutionContextService implementation
     */
    public TurnLifecycleService(ExecutionContextService executionContextService) {
        if (executionContextService == null) {
            throw new IllegalArgumentException('ExecutionContextService cannot be null.');
        }
        this.executionContextService = executionContextService;
    }

    /**
     * Transitions the turn to the active processing state for LLM calls or action execution.
     *
     * @param executionId The execution Id (AgentExecution__c).
     * @param turnIdentifier The unique identifier for the turn.
     * @param jobIdIfAny Optional job Id associated with the turn.
     * @param logPrefix String prefix for log output.
     */
    public void startTurnProcessing(Id executionId, String turnIdentifier, Id jobIdIfAny, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'TurnLifecycleService: PROCESSING state for Turn=' + turnIdentifier + (jobIdIfAny != null ? (', Job=' + jobIdIfAny) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_PROCESSING, null);

        this.executionContextService.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_PROCESSING, turnIdentifier, stepDesc);
    }

    /**
     * Transitions the turn to the awaiting state while an asynchronous action executes.
     *
     * @param executionId The execution Id (AgentExecution__c).
     * @param turnIdentifier The unique identifier for the turn.
     * @param jobId The job Id for the async action.
     * @param toolName The name of the tool being executed (for context).
     * @param logPrefix String prefix for log output.
     */
    public void pauseForAsyncAction(Id executionId, String turnIdentifier, Id jobId, String toolName, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: AWAITING_ACTION state for Turn=' +
                turnIdentifier +
                (jobId != null ? (', Job=' + jobId) : '') +
                (String.isNotBlank(toolName) ? (', Tool=' + toolName) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_ACTION, toolName);

        this.executionContextService.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_AWAITING_ACTION, turnIdentifier, stepDesc);
    }

    /**
     * Transitions the turn to the follow-up state after action completion, preparing for the next LLM call.
     *
     * @param executionId The execution Id (AgentExecution__c).
     * @param turnIdentifier The unique identifier for the turn.
     * @param nextJobId The job Id for the next step, if any.
     * @param logPrefix String prefix for log output.
     */
    public void resumeForFollowUpLlmCall(Id executionId, String turnIdentifier, Id nextJobId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: AWAITING_FOLLOWUP state for Turn=' +
                turnIdentifier +
                (nextJobId != null ? (', NextJob=' + nextJobId) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, null);

        this.executionContextService.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_AWAITING_FOLLOWUP, turnIdentifier, stepDesc);
    }

    /**
     * Completes the turn successfully and publishes the final response event.
     *
     * @param executionId The execution Id (AgentExecution__c).
     * @param turnIdentifier The unique identifier for the turn.
     * @param finalAssistantMessageId The Id of the final assistant message for this turn.
     * @param logPrefix String prefix for log output.
     */
    public void completeTurnSuccessfully(Id executionId, String turnIdentifier, Id finalAssistantMessageId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TurnLifecycleService: IDLE (Turn Complete) state for Turn=' +
                turnIdentifier +
                (finalAssistantMessageId != null ? (', FinalMsg=' + finalAssistantMessageId) : '')
        );

        this.executionContextService.updateStatus(
            executionId,
            'Completed',
            AIAgentConstants.STATUS_IDLE,
            turnIdentifier,
            null // No specific status message for successful completion
        );

        // Publish AgentResponse__e event for UI notification
        publishAgentResponseEvent(executionId, true, finalAssistantMessageId, null, turnIdentifier, logPrefix);
    }

    /**
     * Marks the turn as failed and publishes an error event, including orchestration logging.
     *
     * @param executionId The execution Id (AgentExecution__c).
     * @param turnIdentifier The unique identifier for the turn.
     * @param errorMessage The error message to record.
     * @param errorCode The error code to record.
     * @param logPrefix String prefix for log output.
     */
    public void failTurn(Id executionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        String errorDetailForState = String.isNotBlank(errorCode) ? '[' + errorCode + '] ' + errorMessage : errorMessage;
        System.debug(
            LoggingLevel.ERROR,
            logPrefix + 'TurnLifecycleService: FAILED state for Turn=' + turnIdentifier + '. Error=' + errorDetailForState
        );

        this.executionContextService.updateStatus(
            executionId,
            'Failed',
            AIAgentConstants.STATUS_FAILED,
            turnIdentifier,
            errorDetailForState?.abbreviate(255)
        );

        // Publish AgentResponse__e event for UI notification of failure
        publishAgentResponseEvent(executionId, false, null, errorMessage?.abbreviate(255), turnIdentifier, logPrefix);
    }

    /**
     * Publishes AgentResponse__e event for AgentExecution__c records to notify UI of completion.
     *
     * @param executionId The AgentExecution__c ID
     * @param isSuccess Whether the turn completed successfully
     * @param finalAssistantMessageId The ID of the final assistant ExecutionStep__c (if success)
     * @param errorDetails Error details (if failure)
     * @param turnIdentifier The turn identifier
     * @param logPrefix String prefix for log output
     */
    private void publishAgentResponseEvent(
        Id executionId,
        Boolean isSuccess,
        Id finalAssistantMessageId,
        String errorDetails,
        String turnIdentifier,
        String logPrefix
    ) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Publishing AgentResponse__e event: success=' + isSuccess + ', stepId=' + finalAssistantMessageId
        );

        String finalMessageContent = null;
        if (isSuccess && finalAssistantMessageId != null) {
            try {
                // Query for the step content to include in the event payload
                List<ExecutionStep__c> steps = [SELECT Content__c FROM ExecutionStep__c WHERE Id = :finalAssistantMessageId LIMIT 1];
                if (!steps.isEmpty()) {
                    finalMessageContent = steps[0].Content__c;
                }
            } catch (Exception qe) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Warning: Unable to retrieve step content for event: ' + qe.getMessage());
            }
        }

        try {
            AgentResponse__e event = new AgentResponse__e(
                AgentExecutionId__c = executionId,
                IsSuccess__c = isSuccess,
                FinalAssistantMessageId__c = (isSuccess && finalAssistantMessageId != null) ? String.valueOf(finalAssistantMessageId) : null,
                ErrorDetails__c = errorDetails,
                FinalMessageContent__c = finalMessageContent
            );
            Database.SaveResult sr = EventBus.publish(event);

            if (!sr.isSuccess()) {
                String errMsg = logPrefix + 'EventBus.publish errors: ' + JSON.serialize(sr.getErrors());
                System.debug(LoggingLevel.ERROR, errMsg);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'AgentResponse__e event published successfully for AgentExecution: ' + executionId);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'AgentResponse__e event publishing failed: ' + e.getMessage());
        }
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
