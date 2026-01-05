/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Unified service for managing AgentExecution__c lifecycle and state transitions.
 * Consolidated from TurnLifecycleService and ExecutionContextService to eliminate
 * pass-through logic and centralize all state management in one place.
 *
 * Responsibilities:
 *   - Creation and validation of AgentExecution__c records
 *   - State transition orchestration (start, pause, resume, complete, fail)
 *   - Status updates and persistence
 *   - Platform event publishing for UI notifications
 *   - Stale execution detection and validation
 */
public inherited sharing class AgentStateService {
    // --- CONSTANTS ---
    private static final String LOG_PREFIX = '[AgentStateService] ';

    // --- EXCEPTIONS ---
    public class AgentStateException extends AIAgentException {
    }

    // ===================================================================================
    // EXECUTION CREATION AND VALIDATION
    // ===================================================================================

    /**
     * Creates a new AgentExecution__c record for any execution type.
     *
     * @param executionType     Execution type (Conversational, Function, Workflow)
     * @param agentDefinitionId Agent definition ID
     * @param triggerSource     Trigger source
     * @param triggerPayload    Trigger payload JSON
     * @param sourceRecordId    Source record ID
     * @param userId            User ID
     * @param serviceUserId     Service user ID
     * @return                  Created execution ID
     * @throws AgentStateException if creation fails
     */
    public Id createExecution(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        Id serviceUserId
    ) {
        String logPrefix = LOG_PREFIX + '[createExecution] ';

        try {
            String turnIdentifier = generateTurnIdentifier();

            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = executionType,
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = triggerSource,
                TriggerPayload__c = triggerPayload,
                ExecutionStatus__c = 'Pending',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                SourceRecordId__c = sourceRecordId,
                CurrentTurnIdentifier__c = turnIdentifier,
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                User__c = userId,
                ServiceUser__c = serviceUserId
            );

            insert execution;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Created AgentExecution__c: ' + execution.Id + ' Type: ' + executionType + ' Agent: ' + agentDefinitionId
            );

            return execution.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution: ' + e.getMessage());
            throw new AgentStateException('Failed to create agent execution: ' + e.getMessage());
        }
    }

    /**
     * Validates and retrieves an execution record, checking for stale state.
     * Use this to validate the execution state matches the expected turn identifier
     * before processing to prevent race conditions from stale async jobs.
     *
     * @param executionId The execution to validate and retrieve
     * @param expectedTurnIdentifier Expected turn identifier for stale check
     * @return AgentExecution__c record
     * @throws AgentStateException if execution is stale or not found
     */
    public AgentExecution__c validateAndGetExecution(Id executionId, String expectedTurnIdentifier) {
        String logPrefix = LOG_PREFIX + '[validateAndGetExecution] ';

        try {
            List<AgentExecution__c> executions = [
                SELECT Id, ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, LastActivityTime__c, ExecutionType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                throw new AgentStateException('Execution not found: ' + executionId);
            }

            AgentExecution__c execution = executions[0];

            // Check for stale execution if turn identifier provided
            if (String.isNotBlank(expectedTurnIdentifier) && !expectedTurnIdentifier.equals(execution.CurrentTurnIdentifier__c)) {
                throw new AgentStateException(
                    'Stale execution detected. Expected turn: ' + expectedTurnIdentifier + ', Actual: ' + execution.CurrentTurnIdentifier__c
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Validated execution: ' + executionId);
            return execution;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to validate execution: ' + e.getMessage());
            throw new AgentStateException('Failed to validate execution: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // STATE TRANSITION METHODS
    // ===================================================================================

    /**
     * Transitions the turn to the awaiting state while an asynchronous action executes.
     *
     * @param executionId The execution Id (AgentExecution__c)
     * @param turnIdentifier The unique identifier for the turn
     * @param jobId The job Id for the async action
     * @param toolName The name of the tool being executed (for context)
     * @param logPrefix String prefix for log output
     */
    public void pauseForAsyncAction(Id executionId, String turnIdentifier, Id jobId, String toolName, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'AgentStateService: AWAITING_ACTION state for Turn=' +
                turnIdentifier +
                (jobId != null ? (', Job=' + jobId) : '') +
                (String.isNotBlank(toolName) ? (', Tool=' + toolName) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_ACTION, toolName);

        updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_AWAITING_ACTION, turnIdentifier, stepDesc);
    }

    /**
     * Optimized method that combines async tool tracking initialization with status update.
     * This reduces DML operations from 2 to 1 by batching the updates.
     *
     * @param executionId The execution Id (AgentExecution__c)
     * @param turnIdentifier The unique identifier for the turn
     * @param asyncToolCount Number of async tools being queued
     * @param toolName The name of the tool being executed (for context)
     * @param logPrefix String prefix for log output
     */
    public void pauseForAsyncActionWithTracking(Id executionId, String turnIdentifier, Integer asyncToolCount, String toolName, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'AgentStateService: AWAITING_ACTION state for Turn=' +
                turnIdentifier +
                ', AsyncToolCount=' + asyncToolCount +
                (String.isNotBlank(toolName) ? (', Tool=' + toolName) : '')
        );

        try {
            // Use FOR UPDATE to lock the record and prevent concurrent modifications
            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            // Batch all updates in a single DML operation
            execution.ExecutionStatus__c = 'Processing';
            execution.ProcessingStatus__c = AIAgentConstants.STATUS_AWAITING_ACTION;
            execution.CurrentTurnIdentifier__c = turnIdentifier;
            execution.LastActivityTime__c = Datetime.now();
            execution.PendingAsyncToolCount__c = asyncToolCount;
            execution.AsyncToolTurnIdentifier__c = turnIdentifier;

            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Batched update: status=AWAITING_ACTION, asyncToolCount=' + asyncToolCount + ', turnId=' + turnIdentifier);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution with async tracking: ' + e.getMessage());
            throw new AgentStateException('Failed to update execution with async tracking: ' + e.getMessage());
        }
    }

    /**
     * Transitions the turn to the follow-up state after action completion, preparing for the next LLM call.
     *
     * @param executionId The execution Id (AgentExecution__c)
     * @param turnIdentifier The unique identifier for the turn
     * @param nextJobId The job Id for the next step, if any
     * @param logPrefix String prefix for log output
     */
    public void resumeForFollowUpLlmCall(Id executionId, String turnIdentifier, Id nextJobId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'AgentStateService: AWAITING_FOLLOWUP state for Turn=' + turnIdentifier + (nextJobId != null ? (', NextJob=' + nextJobId) : '')
        );
        String stepDesc = generateStepDescription(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, null);

        updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_AWAITING_FOLLOWUP, turnIdentifier, stepDesc);
    }

    /**
     * Completes the turn successfully and publishes the final response event.
     *
     * @param executionId The execution Id (AgentExecution__c)
     * @param turnIdentifier The unique identifier for the turn
     * @param finalAssistantMessageId The Id of the final assistant message for this turn
     * @param logPrefix String prefix for log output
     */
    public void completeTurnSuccessfully(Id executionId, String turnIdentifier, Id finalAssistantMessageId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'AgentStateService: IDLE (Turn Complete) state for Turn=' +
                turnIdentifier +
                (finalAssistantMessageId != null ? (', FinalMsg=' + finalAssistantMessageId) : '')
        );

        updateStatus(
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
     * Marks the turn as failed and publishes an error event.
     *
     * @param executionId The execution Id (AgentExecution__c)
     * @param turnIdentifier The unique identifier for the turn
     * @param errorMessage The error message to record
     * @param errorCode The error code to record
     * @param logPrefix String prefix for log output
     */
    public void failTurn(Id executionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        String errorDetailForState = String.isNotBlank(errorCode) ? '[' + errorCode + '] ' + errorMessage : errorMessage;
        System.debug(LoggingLevel.ERROR, logPrefix + 'AgentStateService: FAILED state for Turn=' + turnIdentifier + '. Error=' + errorDetailForState);

        updateStatus(executionId, 'Failed', AIAgentConstants.STATUS_FAILED, turnIdentifier, errorDetailForState?.abbreviate(255));

        // Publish AgentResponse__e event for UI notification of failure
        publishAgentResponseEvent(executionId, false, null, errorMessage?.abbreviate(255), turnIdentifier, logPrefix);
    }

    // ===================================================================================
    // STATUS UPDATE (Public for direct callers)
    // ===================================================================================

    /**
     * Updates the status of an AgentExecution__c record.
     *
     * @param executionId The execution to update
     * @param executionStatus The new execution status
     * @param processingStatus The new processing status (optional)
     * @param turnIdentifier The current turn identifier (optional)
     * @param statusMessage Additional status message (optional)
     */
    public void updateStatus(Id executionId, String executionStatus, String processingStatus, String turnIdentifier, String statusMessage) {
        String logPrefix = LOG_PREFIX + '[updateStatus] ';

        try {
            AgentExecution__c execution = new AgentExecution__c(Id = executionId, ExecutionStatus__c = executionStatus, LastActivityTime__c = Datetime.now());

            if (String.isNotBlank(processingStatus)) {
                execution.ProcessingStatus__c = processingStatus;
            }

            if (String.isNotBlank(turnIdentifier)) {
                execution.CurrentTurnIdentifier__c = turnIdentifier;
            }

            // Set end time for terminal states
            if (executionStatus == 'Completed' || executionStatus == 'Failed' || executionStatus == 'Cancelled') {
                execution.EndTime__c = Datetime.now();
            }

            // Set error message when execution fails
            if (executionStatus == 'Failed' && String.isNotBlank(statusMessage)) {
                execution.ErrorMessage__c = statusMessage.abbreviate(255);
            }

            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Updated execution ' + executionId + ' to status: ' + executionStatus);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + e.getMessage());
            throw new AgentStateException('Failed to update execution status: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // PLATFORM EVENT PUBLISHING
    // ===================================================================================

    /**
     * Publishes AgentResponse__e event for AgentExecution__c records to notify UI of completion.
     * Only publishes events for Conversational executions (chat UI). Function and Workflow
     * executions are background/API operations that don't need UI notifications.
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
        // Check if we should publish events based on execution type
        if (!shouldPublishEventsForExecution(executionId, logPrefix)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Skipping AgentResponse__e event (non-conversational execution type)');
            return;
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Publishing AgentResponse__e event: success=' + isSuccess + ', stepId=' + finalAssistantMessageId);

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
     * Determines if platform events should be published for this execution.
     * Only conversational agents need UI notification events. Function and Workflow
     * executions are backend/API operations that should not trigger UI events.
     *
     * @param executionId The execution ID to check
     * @param logPrefix String prefix for log output
     * @return true if events should be published (Conversational type), false otherwise
     */
    @TestVisible
    private Boolean shouldPublishEventsForExecution(Id executionId, String logPrefix) {
        try {
            List<AgentExecution__c> executions = [
                SELECT ExecutionType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Execution record not found for event publishing check, defaulting to no event');
                return false;
            }

            String executionType = executions[0].ExecutionType__c;
            Boolean shouldPublish = (executionType == 'Conversational');

            System.debug(LoggingLevel.INFO, logPrefix + 'Event publishing decision: ExecutionType=' + executionType + ', ShouldPublish=' + shouldPublish);

            return shouldPublish;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error checking execution type for event publishing: ' + e.getMessage());
            // Fail-safe: don't publish if we can't determine type
            return false;
        }
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

    /**
     * Generates user-friendly status descriptions for UI display based on technical status codes.
     *
     * @param newStatus Technical status constant from AIAgentConstants
     * @param contextName Optional context (e.g., tool name) for enhanced messaging
     * @return String user-friendly status description for UI
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

    /**
     * Generates a unique turn identifier for execution tracking.
     *
     * @return String unique turn identifier
     */
    private String generateTurnIdentifier() {
        return 'turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
