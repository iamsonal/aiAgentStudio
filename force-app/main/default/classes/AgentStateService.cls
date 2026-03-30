/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unified service for managing AgentExecution__c lifecycle and state transitions.
 */
public inherited sharing class AgentStateService {
    private static final String LOG_PREFIX = '[AgentStateService] ';

    // Cache for execution type to avoid repeated queries
    private Map<Id, String> executionTypeCache = new Map<Id, String>();

    public virtual class AgentStateException extends AIAgentException {
    }

    /**
     * @description Specialized exception used when an async job detects its turn identifier is stale.
     * Callers should treat this as a no-op (skip processing) rather than a terminal failure.
     */
    public class StaleExecutionException extends AgentStateException {
        public String expectedTurnIdentifier { get; private set; }
        public String actualTurnIdentifier { get; private set; }

        public StaleExecutionException(String message, String expectedTurnIdentifier, String actualTurnIdentifier) {
            super(message);
            this.expectedTurnIdentifier = expectedTurnIdentifier;
            this.actualTurnIdentifier = actualTurnIdentifier;
        }
    }

    /**
     * @description Returns the execution type for a given execution ID.
     * Caches the result to avoid repeated SOQL queries within the same transaction.
     *
     * @param executionId The AgentExecution__c ID
     * @return String execution strategy key stored on ExecutionType__c
     */
    public String getExecutionType(Id executionId) {
        if (executionId == null) {
            return null;
        }

        // Return from cache if available
        if (executionTypeCache.containsKey(executionId)) {
            return executionTypeCache.get(executionId);
        }

        // Query and cache
        try {
            List<AgentExecution__c> executions = [
                SELECT ExecutionType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (!executions.isEmpty()) {
                String execType = executions[0].ExecutionType__c;
                executionTypeCache.put(executionId, execType);
                return execType;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to get execution type: ' + e.getMessage());
        }

        return null;
    }

    /**
     * @description Checks if context tracking should be enabled for the given execution.
     * Context tracking is enabled for runtimes whose resolved strategy/channel traits support it.
     *
     * @param executionId The AgentExecution__c ID
     * @return Boolean true if context tracking should be enabled
     */
    public Boolean isContextTrackingEnabled(Id executionId) {
        return RuntimeRegistryService.getTraits(executionId).supportsContextLedger == true;
    }
    public Id createExecution(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        Id serviceUserId
    ) {
        return createExecution(executionType, agentDefinitionId, triggerSource, triggerPayload, sourceRecordId, userId, serviceUserId, null, null, null, null);
    }

    /**
     * Creates an AgentExecution__c record with an optional parent link and pre-set turn identifier,
     * allowing child executions to be created in a single DML operation rather than insert + update.
     *
     * @param executionType      The execution strategy key (e.g. 'Direct', 'Conversational', 'Pipeline')
     * @param agentDefinitionId  The AIAgentDefinition__c record ID
     * @param triggerSource      The trigger source label
     * @param triggerPayload     Optional trigger payload text
     * @param sourceRecordId     The source record being processed
     * @param userId             The acting user ID
     * @param serviceUserId      Optional service user ID
     * @param parentExecutionId  Optional parent AgentExecution__c ID (for child executions)
     * @param turnIdentifier     Optional pre-computed turn identifier; generated if null
     * @return The Id of the newly inserted AgentExecution__c record
     */
    public Id createExecution(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        Id serviceUserId,
        Id parentExecutionId,
        String turnIdentifier
    ) {
        return createExecution(
            executionType,
            agentDefinitionId,
            triggerSource,
            triggerPayload,
            sourceRecordId,
            userId,
            serviceUserId,
            parentExecutionId,
            turnIdentifier,
            null,
            null
        );
    }

    public Id createExecution(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        Id serviceUserId,
        Id parentExecutionId,
        String turnIdentifier,
        String executionIdentityProfileDeveloperName,
        String executionIdentityNamedCredential
    ) {
        String logPrefix = LOG_PREFIX + '[createExecution] ';

        try {
            if (String.isBlank(turnIdentifier)) {
                turnIdentifier = generateTurnIdentifier();
            }

            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = executionType,
                InteractionChannel__c = mapExecutionTypeToChannel(executionType),
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
                ServiceUser__c = serviceUserId,
                ParentExecution__c = parentExecutionId,
                ExecutionIdentityProfileDeveloperName__c = executionIdentityProfileDeveloperName,
                ExecutionIdentityNamedCredential__c = executionIdentityNamedCredential
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

    private static String mapExecutionTypeToChannel(String executionType) {
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Direct).equalsIgnoreCase(executionType)) {
            return RuntimeRegistryService.CHANNEL_DIRECT;
        }
        return RuntimeRegistryService.CHANNEL_CHAT;
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

            // Cache the execution type to avoid future queries
            if (String.isNotBlank(execution.ExecutionType__c)) {
                executionTypeCache.put(executionId, execution.ExecutionType__c);
            }

            // Check for stale execution if turn identifier provided
            if (String.isNotBlank(expectedTurnIdentifier) && !expectedTurnIdentifier.equals(execution.CurrentTurnIdentifier__c)) {
                throw new StaleExecutionException(
                    'Stale execution detected. Expected turn: ' + expectedTurnIdentifier + ', Actual: ' + execution.CurrentTurnIdentifier__c,
                    expectedTurnIdentifier,
                    execution.CurrentTurnIdentifier__c
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Validated execution: ' + executionId);
            return execution;
        } catch (AgentStateException ase) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to validate execution: ' + ase.getMessage());
            throw ase;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to validate execution: ' + e.getMessage());
            throw new AgentStateException('Failed to validate execution: ' + e.getMessage());
        }
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
                ', AsyncToolCount=' +
                asyncToolCount +
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

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Batched update: status=AWAITING_ACTION, asyncToolCount=' + asyncToolCount + ', turnId=' + turnIdentifier
            );
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
    public Boolean completeTurnSuccessfully(Id executionId, String turnIdentifier, Id finalAssistantMessageId, String logPrefix) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'AgentStateService: IDLE (Turn Complete) state for Turn=' +
                turnIdentifier +
                (finalAssistantMessageId != null ? (', FinalMsg=' + finalAssistantMessageId) : '')
        );

        Boolean statusApplied = updateStatus(
            executionId,
            'Completed',
            AIAgentConstants.STATUS_IDLE,
            turnIdentifier,
            null // No specific status message for successful completion
        );

        if (!statusApplied) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Skipped completion side effects because the turn no longer owns execution ' + executionId);
            return false;
        }

        // Publish AgentResponse__e event for UI notification
        publishAgentResponseEvent(executionId, true, finalAssistantMessageId, null, turnIdentifier, logPrefix);

        return true;
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
    public Boolean failTurn(Id executionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        String errorDetailForState = String.isNotBlank(errorCode) ? '[' + errorCode + '] ' + errorMessage : errorMessage;
        System.debug(LoggingLevel.ERROR, logPrefix + 'AgentStateService: FAILED state for Turn=' + turnIdentifier + '. Error=' + errorDetailForState);

        Boolean statusApplied = updateStatus(executionId, 'Failed', AIAgentConstants.STATUS_FAILED, turnIdentifier, errorDetailForState);

        if (!statusApplied) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Skipped failure side effects because the turn no longer owns execution ' + executionId);
            return false;
        }

        // Publish AgentResponse__e event for UI notification of failure
        publishAgentResponseEvent(executionId, false, null, errorMessage, turnIdentifier, logPrefix);

        return true;
    }

    /**
     * @description Pauses an execution with an explicit operational-state marker so operators can
     * inspect recoverable runtime problems without relying on debug logs.
     */
    public Boolean pauseForOperationalIssue(Id executionId, String turnIdentifier, String operationalState, String detailMessage, String logPrefix) {
        String stateMessage = buildOperationalStateMessage(operationalState, detailMessage);
        System.debug(
            LoggingLevel.WARN,
            logPrefix +
                'AgentStateService: PAUSED state for execution=' +
                executionId +
                (String.isNotBlank(turnIdentifier) ? (', Turn=' + turnIdentifier) : '') +
                '. Operational=' +
                stateMessage
        );

        return updateStatus(executionId, AIAgentConstants.EXECUTION_STATUS_PAUSED, AIAgentConstants.STATUS_FAILED, turnIdentifier, stateMessage);
    }

    public static String buildOperationalStateMessage(String operationalState, String detailMessage) {
        String normalizedState = String.isNotBlank(operationalState) ? operationalState : 'UNKNOWN_OPERATIONAL_STATE';
        return '[' + normalizedState + '] ' + (String.isNotBlank(detailMessage) ? detailMessage : 'No additional details provided.');
    }

    /**
     * @description Finalizes execution status after a synchronous turn completes.
     *
     * In the synchronous execution path, Apex's DML-before-callout restriction prevents
     * pre-stamping the turn identifier before the LLM call. This means
     * completeTurnSuccessfully() inside the sync loop may silently skip its update due
     * to the stale-turn check. This method recovers by force-updating the execution
     * only if the turn has not already been correctly stamped.
     *
     * Safe to call unconditionally - uses FOR UPDATE to guard against concurrent writes
     * and is a no-op when the turn was already correctly stamped.
     *
     * @param executionId The AgentExecution__c ID
     * @param newTurnIdentifier The turn identifier used by the sync execution
     * @param processingStatus The ProcessingStatus__c value returned by the execution (e.g. Idle, Failed)
     * @param logPrefix Log prefix for debug output
     */
    @TestVisible
    private static Boolean forceSyncFinalizeExecutionFailure = false;

    public Boolean syncFinalizeExecution(Id executionId, String newTurnIdentifier, String processingStatus, String statusMessage, String logPrefix) {
        try {
            TransactionContext txnCtx = TransactionContext.getInstance();
            if (forceSyncFinalizeExecutionFailure) {
                throw new AgentStateException('Forced sync finalization failure for test coverage');
            }
            if (txnCtx.isDeferredDMLMode()) {
                txnCtx.commitBuffer();
                txnCtx.disableDeferredDMLMode();
            }

            List<AgentExecution__c> stale = [
                SELECT Id, CurrentTurnIdentifier__c
                FROM AgentExecution__c
                WHERE Id = :executionId AND CurrentTurnIdentifier__c != :newTurnIdentifier
                LIMIT 1
                FOR UPDATE
            ];

            if (stale.isEmpty()) {
                return true; // Already stamped correctly by completeTurnSuccessfully()
            }

            AgentExecution__c exec = new AgentExecution__c(
                Id = executionId,
                CurrentTurnIdentifier__c = newTurnIdentifier,
                LastActivityTime__c = Datetime.now()
            );

            if (processingStatus == AIAgentConstants.STATUS_FAILED) {
                exec.ExecutionStatus__c = 'Failed';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_FAILED;
                exec.EndTime__c = Datetime.now();
            } else if (processingStatus == AIAgentConstants.STATUS_AWAITING_FOLLOWUP) {
                exec.ExecutionStatus__c = 'Processing';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_AWAITING_FOLLOWUP;
            } else if (processingStatus == AIAgentConstants.STATUS_AWAITING_ACTION) {
                exec.ExecutionStatus__c = 'Processing';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_AWAITING_ACTION;
            } else if (processingStatus == AIAgentConstants.STATUS_PROCESSING) {
                exec.ExecutionStatus__c = 'Processing';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING;
            } else {
                exec.ExecutionStatus__c = 'Completed';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_IDLE;
                exec.EndTime__c = Datetime.now();
            }

            update exec;
            if (exec.ExecutionStatus__c == 'Completed') {
                publishAgentResponseEvent(executionId, true, null, null, newTurnIdentifier, logPrefix);
            } else if (exec.ExecutionStatus__c == 'Failed') {
                publishAgentResponseEvent(executionId, false, null, statusMessage, newTurnIdentifier, logPrefix);
            }
            System.debug(
                LoggingLevel.INFO,
                logPrefix + '[AgentStateService] syncFinalizeExecution stamped turn=' + newTurnIdentifier + ' status=' + exec.ExecutionStatus__c
            );
            return true;
        } catch (Exception e) {
            String detailMessage = 'Synchronous turn finalization recovery failed: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + '[AgentStateService] ' + detailMessage);

            TransactionContext txnCtx = TransactionContext.getInstance();
            if (txnCtx.isDeferredDMLMode()) {
                txnCtx.discardBufferedRecordsForExecution(executionId);
                txnCtx.disableDeferredDMLMode();
            }

            try {
                Boolean paused = pauseForOperationalIssue(executionId, null, AIAgentConstants.OP_STATE_SYNC_FINALIZATION_FAILED, detailMessage, logPrefix);
                if (paused) {
                    update new AgentExecution__c(Id = executionId, EndTime__c = Datetime.now());
                }
            } catch (Exception pauseEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + '[AgentStateService] Failed to persist sync finalization recovery issue: ' + pauseEx.getMessage());
            }
            return false;
        } finally {
            TransactionContext.getInstance().clearSyncFinalizationRecovery();
        }
    }

    public Boolean syncFinalizeExecution(Id executionId, String newTurnIdentifier, String processingStatus, String logPrefix) {
        return syncFinalizeExecution(executionId, newTurnIdentifier, processingStatus, null, logPrefix);
    }

    // STATUS UPDATE (Public for direct callers)

    /**
     * Updates the status of an AgentExecution__c record.
     *
     * @param executionId The execution to update
     * @param executionStatus The new execution status
     * @param processingStatus The new processing status (optional)
     * @param turnIdentifier The current turn identifier (optional)
     * @param statusMessage Additional status message (optional)
     */
    public Boolean updateStatus(Id executionId, String executionStatus, String processingStatus, String turnIdentifier, String statusMessage) {
        String logPrefix = LOG_PREFIX + '[updateStatus] ';

        try {
            Boolean isTerminalState = (executionStatus == 'Completed' || executionStatus == 'Failed' || executionStatus == 'Cancelled');
            List<AgentExecution__c> currentExecutions = null;

            // Guard against stale workers overwriting newer turns.
            // This must happen before committing buffered DML so stale workers cannot flush
            // old-turn execution steps or emit completion signals for the wrong owner.
            if (String.isNotBlank(turnIdentifier)) {
                currentExecutions = [
                    SELECT Id, CurrentTurnIdentifier__c
                    FROM AgentExecution__c
                    WHERE Id = :executionId AND (CurrentTurnIdentifier__c = :turnIdentifier OR CurrentTurnIdentifier__c = NULL)
                    LIMIT 1
                    FOR UPDATE
                ];

                if (currentExecutions.isEmpty()) {
                    String currentTurn = null;
                    try {
                        List<AgentExecution__c> lookup = [
                            SELECT Id, CurrentTurnIdentifier__c
                            FROM AgentExecution__c
                            WHERE Id = :executionId
                            LIMIT 1
                        ];
                        if (!lookup.isEmpty()) {
                            currentTurn = lookup[0].CurrentTurnIdentifier__c;
                        }
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, logPrefix + 'Unable to read current turn for debug: ' + e.getMessage());
                    }
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Stale status update skipped for execution ' +
                            executionId +
                            '. Turn mismatch for provided turn=' +
                            turnIdentifier +
                            (currentTurn != null ? (', current turn=' + currentTurn) : '') +
                            '. Expected for sync execution path — syncFinalizeExecution handles recovery.'
                    );
                    if (isTerminalState && TransactionContext.getInstance().isDeferredDMLMode()) {
                        if (TransactionContext.getInstance().isSyncFinalizationRecovery(executionId, turnIdentifier)) {
                            System.debug(
                                LoggingLevel.INFO,
                                logPrefix + 'Preserving buffered records for synchronous finalization recovery on execution ' + executionId
                            );
                        } else {
                            TransactionContext.getInstance().discardBufferedRecordsForExecution(executionId);
                            TransactionContext.getInstance().disableDeferredDMLMode();
                        }
                    }
                    return false;
                }
            }

            // Multi-LLM optimization: For terminal states, commit any buffered DML only
            // after the stale-turn guard has confirmed this worker still owns the turn.
            if (isTerminalState && TransactionContext.getInstance().isDeferredDMLMode()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Terminal state update - committing buffered DML before state change');
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }

            AgentExecution__c execution = new AgentExecution__c(Id = executionId, ExecutionStatus__c = executionStatus, LastActivityTime__c = Datetime.now());

            if (String.isNotBlank(processingStatus)) {
                execution.ProcessingStatus__c = processingStatus;
            }

            if (String.isNotBlank(turnIdentifier)) {
                execution.CurrentTurnIdentifier__c = turnIdentifier;
            }

            // Set end time for terminal states
            if (isTerminalState) {
                execution.EndTime__c = Datetime.now();
            }

            // Set error message when execution fails
            if ((executionStatus == 'Failed' || executionStatus == AIAgentConstants.EXECUTION_STATUS_PAUSED) && String.isNotBlank(statusMessage)) {
                execution.ErrorMessage__c = statusMessage;
            }

            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Updated execution ' + executionId + ' to status: ' + executionStatus);
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + e.getMessage());
            throw new AgentStateException('Failed to update execution status: ' + e.getMessage());
        }
    }

    /**
     * Publishes AgentResponse__e event for AgentExecution__c records to notify UI of completion.
     * Only publishes events for iterative chat executions. Direct/API
     * executions are backend operations that don't need UI notifications.
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
            System.debug(LoggingLevel.INFO, logPrefix + 'Skipping AgentResponse__e event (non-UI execution channel)');
            return;
        }

        // If stepId is null (due to deferred DML mode), query for it using turnIdentifier
        // This ensures the platform event contains the correct step ID for UI retrieval
        if (isSuccess && finalAssistantMessageId == null && String.isNotBlank(turnIdentifier)) {
            try {
                List<ExecutionStep__c> steps = [
                    SELECT Id
                    FROM ExecutionStep__c
                    WHERE
                        AgentExecution__c = :executionId
                        AND TurnIdentifier__c = :turnIdentifier
                        AND StepType__c = 'AgentResponse'
                        AND StepRole__c = 'Assistant'
                    ORDER BY CreatedDate DESC
                    LIMIT 1
                ];
                if (!steps.isEmpty()) {
                    finalAssistantMessageId = steps[0].Id;
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'Resolved stepId from deferred DML: ' + finalAssistantMessageId);
                }
            } catch (Exception qe) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Warning: Unable to resolve step ID for deferred DML: ' + qe.getMessage());
            }
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
     * Only iterative chat executions need UI notification events. Direct
     * and backend/API executions should not trigger UI events.
     *
     * @param executionId The execution ID to check
     * @param logPrefix String prefix for log output
     * @return true if events should be published for the execution traits, false otherwise
     */
    @TestVisible
    private Boolean shouldPublishEventsForExecution(Id executionId, String logPrefix) {
        Boolean shouldPublish = RuntimeRegistryService.getTraits(executionId).publishesUiEvents == true;
        System.debug(LoggingLevel.INFO, logPrefix + 'Event publishing decision: ShouldPublish=' + shouldPublish);
        return shouldPublish;
    }

    // UTILITY METHODS

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
