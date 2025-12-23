/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Coordinates end-to-end flow of AI agent actions following LLM response processing.
 * Applies Strategy pattern for response handling and manages turn lifecycle.
 */
public inherited sharing class OrchestrationService {
    public virtual class OrchestrationException extends AIAgentException {
    }
    public class ConfigurationException extends OrchestrationException {
    }

    // Turn outcome constants for orchestration flow control
    public static final String OUTCOME_COMPLETED = 'COMPLETED';
    public static final String OUTCOME_FAILED = 'FAILED';
    public static final String OUTCOME_QUEUED_FOLLOWUP = 'QUEUED_FOLLOWUP';
    public static final String OUTCOME_QUEUED_ACTION = 'QUEUED_ACTION';
    public static final String OUTCOME_AWAITING_CONFIRMATION = 'AWAITING_CONFIRMATION';

    // Injected service dependencies
    private final AgentStateService agentStateSvc;
    private final CapabilityExecutionService actionExecSvc;
    private final AgentJobEnqueuer orchestrationDispatchSvc;
    private final ContextManagerService contextManagerSvc;

    /**
     * Default constructor with default service dependencies.
     */
    public OrchestrationService() {
        // Initialize with default service implementations
        this(new AgentStateService(), new CapabilityExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
    }

    /**
     * Constructor with dependency injection for testing and customization.
     *
     * @param stateSvc   AgentStateService instance
     * @param actionSvc  CapabilityExecutionService instance
     * @param dispatchSvc AgentJobEnqueuer instance
     * @param contextSvc ContextManagerService instance
     */
    public OrchestrationService(
        AgentStateService stateSvc,
        CapabilityExecutionService actionSvc,
        AgentJobEnqueuer dispatchSvc,
        ContextManagerService contextSvc
    ) {
        if (stateSvc == null || actionSvc == null || dispatchSvc == null || contextSvc == null) {
            throw new IllegalArgumentException('All service dependencies for OrchestrationService are required.');
        }
        this.agentStateSvc = stateSvc;
        this.actionExecSvc = actionSvc;
        this.orchestrationDispatchSvc = dispatchSvc;
        this.contextManagerSvc = contextSvc;
    }

    /**
     * Processes the LLM interaction result for AgentExecution__c records.
     * Main method that supports the unified agentic framework.
     *
     * @param llmInteractionResult      Result from LLM interaction containing response content and/or tool calls (required)
     * @param executionId               The AgentExecution__c ID (required)
     * @param originalUserId            The original user ID who initiated the execution (required)
     * @param executionUserId           The user ID under which execution is performed (required)
     * @param agentDefinitionId         The agent definition ID for this execution (required)
     * @param turnIdentifier            Unique identifier for this turn (required)
     * @param currentTurnCount          The current turn count in the execution (required)
     * @param userMessageDataForTurn    The user message data for this turn (optional for non-conversational)
     * @param currentPageRecordId       The current page record ID, if applicable (optional)
     * @param decisionLogger            The decision step logger to use (required)
     * @return                          Outcome constant indicating turn completion status and next steps
     * @throws None. All errors are handled internally and surfaced via debug logs and return value.
     *
     * Side effects: Emits debug logs and orchestrates turn state transitions.
     */
    public String processLlmResult(
        LLMInteractionService.LLMInteractionResult llmInteractionResult,
        Id executionId,
        Id originalUserId,
        Id executionUserId,
        Id agentDefinitionId,
        String turnIdentifier,
        Integer currentTurnCount,
        LLMInteractionService.MessageData userMessageDataForTurn,
        Id currentPageRecordId,
        AgentDecisionStepLogger decisionLogger
    ) {
        String logPrefix = '[OrchSvc Turn:' + turnIdentifier?.left(8) + ' Cycle:' + currentTurnCount + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting orchestration for LLM result. Page context: ' + currentPageRecordId);

        try {
            if (llmInteractionResult == null || !llmInteractionResult.isSuccess) {
                String failureReason = llmInteractionResult?.failureReason ?? 'Unknown LLM interaction error';
                String failureCode = llmInteractionResult?.failureCode ?? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED;
                System.debug(LoggingLevel.ERROR, logPrefix + 'LLM interaction failed. Reason: ' + failureReason + ' (Code: ' + failureCode + ')');

                // Log the error step using the safe serialization method
                decisionLogger.logError(
                    'LLM Interaction Failed',
                    'The LLM interaction failed during processing',
                    failureCode,
                    failureReason,
                    serializeLlmInteractionResultForLogging(llmInteractionResult),
                    null
                );

                this.agentStateSvc.failTurn(executionId, turnIdentifier, failureReason, failureCode, logPrefix);
                return OUTCOME_FAILED;
            }

            // Create orchestration context with all required state and dependencies for this turn.
            OrchestrationContext context = new OrchestrationContext(
                llmInteractionResult,
                executionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                turnIdentifier,
                currentTurnCount,
                userMessageDataForTurn,
                this.agentStateSvc,
                this.actionExecSvc,
                this.orchestrationDispatchSvc,
                this.contextManagerSvc,
                currentPageRecordId,
                decisionLogger
            );

            // Select the appropriate response handler based on LLM response type (tool call or content-only).
            ILLMResponseHandler handler;
            if (llmInteractionResult.providerResult?.requestedActions != null && !llmInteractionResult.providerResult.requestedActions.isEmpty()) {
                handler = new ToolCallResponseHandler();
            } else {
                handler = new ContentResponseHandler();
            }

            // Execute the selected response handling strategy.
            String outcome = handler.handle(context);

            return outcome;
        } catch (Exception ex) {
            String errorMsg = 'Critical orchestration error: (' + ex.getTypeName() + ') ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration failed with exception. ' + errorMsg + '\nStack: ' + ex.getStackTraceString());

            // Log the error step
            decisionLogger.logError(
                'Orchestration Failed',
                'A critical error occurred during orchestration',
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                errorMsg,
                ex.getStackTraceString(),
                null
            );

            try {
                this.agentStateSvc.failTurn(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception finalFailEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'FATAL: Could not mark turn as failed. Reason: ' + finalFailEx.getMessage());
            }
            return OUTCOME_FAILED;
        } finally {
            // Commit all decision steps at the end of the transaction
            // This ensures all logs are persisted in one transaction after all business logic and potential callouts are complete
            decisionLogger.commitSteps();
        }
    }

    // Static utility methods for use by response handlers

    /**
     * Serializes an ActionOutcome for LLM consumption, handling nulls and error cases gracefully.
     *
     * If the ActionOutcome is null or missing data, a synthetic error response is generated.
     * For failures, the LLM-friendly message with emojis and suggestions is used. All serialization
     * errors are logged and surfaced in the output.
     *
     * @param actionOutcome The ActionOutcome to serialize (may be null)
     * @param logPrefix     Prefix for debug log output
     * @return              JSON string representing the action outcome for LLM
     *
     * Side effects: Emits debug logs for null outcomes and serialization errors.
     */
    public static String serializeActionOutcome(ActionOutcome actionOutcome, String logPrefix) {
        try {
            if (actionOutcome == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Action outcome is null. Returning error response for LLM.');
                return JSON.serialize(new Map<String, Object>{ 'isSuccess' => false, 'error' => 'Action execution did not return an outcome object.' });
            }

            if (actionOutcome.isSuccess) {
                // ✅ CRITICAL FIX: ALWAYS include isSuccess flag for standardized resume logic
                // This enables WorkflowOrchestrator.buildResumeContext() to reliably identify successful tools
                Map<String, Object> successOutput = new Map<String, Object>{ 'isSuccess' => true };

                // Include the actual data payload if present
                if (actionOutcome.data != null) {
                    successOutput.put('data', actionOutcome.data);
                } else {
                    successOutput.put('data', new Map<String, Object>());
                }

                return JSON.serialize(successOutput);
            } else {
                // For failure, create structured error output with LLM-friendly message
                // Note: Using 'isSuccess' for consistency (was 'success' before)
                Map<String, Object> errorOutput = new Map<String, Object>{
                    'isSuccess' => false,
                    'errorCode' => actionOutcome.errorCode,
                    'messageForUser' => actionOutcome.llmFriendlyMessage != null ? actionOutcome.llmFriendlyMessage : actionOutcome.errorMessage,
                    'data' => new Map<String, Object>()
                };

                // Include correction guidance if provided (format requirements and examples)
                if (String.isNotBlank(actionOutcome.correctionGuidance)) {
                    errorOutput.put('correctionGuidance', actionOutcome.correctionGuidance);
                }

                return JSON.serialize(errorOutput);
            }
        } catch (Exception jsonEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to serialize action outcome for LLM. Error: ' + jsonEx.getMessage());
            return JSON.serialize(
                new Map<String, Object>{
                    'isSuccess' => false,
                    'error' => 'Failed to serialize action outcome data',
                    'serialization_error_details' => jsonEx.getMessage(),
                    'original_action_success_status' => actionOutcome?.isSuccess,
                    'original_action_error_code' => actionOutcome?.errorCode
                }
            );
        }
    }

    /**
     * Extracts a Salesforce record ID from an ActionOutcome payload for context management.
     *
     * Handles multiple output shapes (direct recordId, single-record list, or single record object).
     *
     * @param actionOutcome Action execution outcome containing potential record data (may be null)
     * @return              Salesforce ID if found in outcome payload, null otherwise
     */
    public static Id extractRecordIdFromOutcome(ActionOutcome actionOutcome) {
        if (actionOutcome == null || !actionOutcome.isSuccess || actionOutcome.data == null || !(actionOutcome.data instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> outputMap = (Map<String, Object>) actionOutcome.data;
        if (!'SUCCESS'.equalsIgnoreCase(String.valueOf(outputMap.get('status'))) || !(outputMap.get('data') instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        // Direct recordId field (Create/Update actions)
        if (dataMap.get('recordId') instanceof String) {
            try {
                return Id.valueOf((String) dataMap.get('recordId'));
            } catch (Exception e) {
                // Invalid ID format, continue to other cases
            }
        }

        // Records list with single record (GetRecords actions)
        if (dataMap.get('records') instanceof List<Object>) {
            List<Object> recordsList = (List<Object>) dataMap.get('records');
            if (recordsList.size() == 1) {
                Object firstRecord = recordsList[0];

                if (firstRecord instanceof SObject) {
                    return (Id) ((SObject) firstRecord).get('Id');
                } else if (firstRecord instanceof Map<String, Object>) {
                    Map<String, Object> recordMap = (Map<String, Object>) firstRecord;
                    if (recordMap.get('Id') instanceof String) {
                        try {
                            return Id.valueOf((String) recordMap.get('Id'));
                        } catch (Exception e) {
                            // Invalid ID format, continue
                        }
                    }
                }
            }
        }

        // Single record object (FindEntities actions)
        if (dataMap.get('record') instanceof Map<String, Object>) {
            Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
            if (recordMap.get('Id') instanceof String) {
                try {
                    return Id.valueOf((String) recordMap.get('Id'));
                } catch (Exception e) {
                    // Invalid ID format
                }
            }
        }

        return null;
    }

    /**
     * Serializes an LLMInteractionResult for logging purposes, excluding non-serializable Exception objects.
     *
     * @param result The LLMInteractionResult to serialize
     * @return JSON string representation of the result, safe for logging
     */
    private static String serializeLlmInteractionResultForLogging(LLMInteractionService.LLMInteractionResult result) {
        if (result == null) {
            return null;
        }

        try {
            // Create a map with only the serializable fields
            Map<String, Object> serializableResult = new Map<String, Object>();
            serializableResult.put('isSuccess', result.isSuccess);
            serializableResult.put('providerResult', result.providerResult);
            serializableResult.put('assistantMessageData', result.assistantMessageData);
            serializableResult.put('failureReason', result.failureReason);
            serializableResult.put('failureCode', result.failureCode);

            // Instead of including the Exception object, include its message if it exists
            if (result.failureException != null) {
                serializableResult.put('failureExceptionMessage', result.failureException.getMessage());
                serializableResult.put('failureExceptionType', result.failureException.getTypeName());
            }

            return JSON.serialize(serializableResult);
        } catch (Exception e) {
            // If serialization still fails, return a basic representation
            return '{"isSuccess": ' + result.isSuccess + ', "serializationError": "Failed to serialize LLMInteractionResult: ' + e.getMessage() + '"}';
        }
    }

    /**
     * @description Determines if agent execution should fail immediately on tool error.
     *
     * Implements Three-Tier Hierarchy for Error Handling:
     * Priority 1 (Highest): Capability.FailFastOnError__c = true → FAIL
     * Priority 2: Agent.ErrorHandlingPolicy__c = 'Fail-Fast' → FAIL
     * Priority 3 (Default): 'Autonomous Recovery' → CONTINUE
     *
     * This method centralizes error handling policy for all orchestrators (Function, Conversational, Workflow).
     *
     * @param capability The capability that was executed
     * @param agentDefinition The agent definition configuration
     * @param toolOutcome The outcome of the tool execution
     * @param logPrefix Logging prefix for debug output
     * @return true if execution should fail immediately, false to allow LLM recovery
     */
    public static Boolean shouldFailFast(AgentCapability__c capability, AIAgentDefinition__c agentDefinition, ActionOutcome toolOutcome, String logPrefix) {
        // Only applies to tool failures
        if (toolOutcome == null || toolOutcome.isSuccess) {
            return false;
        }

        // Tier 1: Capability-level override (highest priority)
        // If this specific tool is marked as critical, always fail fast
        if (capability.FailFastOnError__c == true) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + '⚠️ FAIL-FAST (Tier 1): Capability "' + capability.CapabilityName__c + '" has FailFastOnError=true. Halting execution immediately.'
            );
            return true;
        }

        // Tier 2: Agent-level policy
        // Check if agent is configured for fail-fast behavior
        if (agentDefinition.ErrorHandlingPolicy__c == 'Fail-Fast') {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + '⚠️ FAIL-FAST (Tier 2): Agent "' + agentDefinition.DeveloperName__c + '" has ErrorHandlingPolicy=Fail-Fast. Halting execution.'
            );
            return true;
        }

        // Tier 3: Default behavior (autonomous recovery)
        // Let LLM see the error and attempt to handle it
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '✓ AUTONOMOUS RECOVERY (Tier 3): Passing error to LLM for handling. ' +
                'Capability: ' +
                capability.CapabilityName__c +
                ', ' +
                'Agent Policy: ' +
                (agentDefinition.ErrorHandlingPolicy__c != null ? agentDefinition.ErrorHandlingPolicy__c : 'Not Set (Default)')
        );
        return false;
    }

    // ===================================================================================
    // PARALLEL TOOL COMPLETION TRACKING (Consolidated from ParallelToolCallHandler)
    // ===================================================================================

    /**
     * @description
     * Initializes the async tool tracking counter on the execution record.
     * Must be called BEFORE queuing async tools to set up the atomic counter.
     * Uses FOR UPDATE to ensure exclusive access during initialization.
     *
     * @param executionId The execution ID
     * @param turnIdentifier The turn identifier for this batch of async tools
     * @param asyncToolCount The number of async tools being queued
     * @param logPrefix Logging prefix
     */
    public static void initializeAsyncToolTracking(Id executionId, String turnIdentifier, Integer asyncToolCount, String logPrefix) {
        if (asyncToolCount <= 0) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'No async tools to track, skipping initialization.');
            return;
        }

        try {
            // Use FOR UPDATE to lock the record and prevent concurrent modifications
            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            execution.PendingAsyncToolCount__c = asyncToolCount;
            execution.AsyncToolTurnIdentifier__c = turnIdentifier;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Initialized async tool tracking: count=' + asyncToolCount + ', turnId=' + turnIdentifier);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to initialize async tool tracking: ' + e.getMessage());
            throw new OrchestrationException('Failed to initialize async tool tracking: ' + e.getMessage());
        }
    }

    /**
     * @description
     * Called by AsyncActionEngine after an async tool completes to atomically decrement
     * the pending counter and trigger the final follow-up LLM call when all tools complete.
     *
     * Uses FOR UPDATE row locking to prevent race conditions when multiple async tools
     * complete simultaneously. Only the last completing tool (the one that decrements
     * the counter to zero) will trigger the follow-up call.
     *
     * @param executionId The execution ID
     * @param turnIdentifier The turn identifier
     * @param currentTurnCount The current turn count
     * @param completedToolCallId The tool call ID that just completed
     * @param logPrefix Logging prefix
     */
    public static void onAsyncToolCompleted(Id executionId, String turnIdentifier, Integer currentTurnCount, String completedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool completed: ' + completedToolCallId + '. Atomically decrementing counter.');

            // Use FOR UPDATE to acquire exclusive lock on the execution record
            // This prevents race conditions when multiple async tools complete simultaneously
            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            // Validate turn identifier to prevent stale async completions from affecting current turn
            if (String.isNotBlank(execution.AsyncToolTurnIdentifier__c) && !turnIdentifier.equals(execution.AsyncToolTurnIdentifier__c)) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Stale async tool completion detected. Expected turn: ' +
                        execution.AsyncToolTurnIdentifier__c +
                        ', Received: ' +
                        turnIdentifier +
                        '. Ignoring completion.'
                );
                return;
            }

            // Atomically decrement the counter
            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool counter decremented: ' + currentCount + ' -> ' + newCount);

            // Only the last completing tool (counter reaches zero) triggers the follow-up
            if (newCount == 0 && currentCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
            } else if (newCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Still waiting for ' + newCount + ' more async tool(s) to complete.');
            }
        } catch (QueryException qe) {
            // Handle case where record is locked by another transaction
            if (qe.getMessage().contains('UNABLE_TO_LOCK_ROW')) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Record locked by concurrent transaction. Will retry via platform retry mechanism.');
                // The platform will retry the queueable job, or we can implement explicit retry
                throw qe;
            }
            System.debug(LoggingLevel.ERROR, logPrefix + 'Query error in async tool completion: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in async tool completion check: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    /**
     * @description
     * Decrements the async tool counter without triggering follow-up.
     * Used when an async tool fails to queue, to keep the counter accurate.
     * This prevents execution hangs when some tools fail to queue.
     *
     * @param executionId The execution ID
     * @param turnIdentifier The turn identifier
     * @param currentTurnCount The current turn count
     * @param failedToolCallId The tool call ID that failed to queue
     * @param logPrefix Logging prefix
     */
    public static void decrementAsyncToolCounter(Id executionId, String turnIdentifier, Integer currentTurnCount, String failedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Decrementing counter for failed queue: ' + failedToolCallId);

            // Use FOR UPDATE to acquire exclusive lock
            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            // Validate turn identifier
            if (String.isNotBlank(execution.AsyncToolTurnIdentifier__c) && !turnIdentifier.equals(execution.AsyncToolTurnIdentifier__c)) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Turn identifier mismatch. Skipping decrement.');
                return;
            }

            // Atomically decrement the counter
            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Counter decremented for queue failure: ' + currentCount + ' -> ' + newCount);

            // If this was the last tool (all others also failed to queue), trigger follow-up
            // so the LLM can see the error results and respond appropriately
            if (newCount == 0 && currentCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools failed to queue. Triggering follow-up for error handling.');
                triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error decrementing counter: ' + e.getMessage());
            // Don't rethrow - this is a recovery operation, we don't want to cascade failures
        }
    }

    /**
     * @description
     * Internal method to trigger the final follow-up LLM call using an already-queried execution record.
     * Called from onAsyncToolCompleted after atomically determining all async tools have finished.
     *
     * @param execution The execution record (already queried with FOR UPDATE)
     * @param turnIdentifier The turn identifier
     * @param currentTurnCount The current turn count
     * @param logPrefix Logging prefix
     */
    private static void triggerFinalFollowUpLLMCallInternal(AgentExecution__c execution, String turnIdentifier, Integer currentTurnCount, String logPrefix) {
        try {
            // Clear the async tracking fields now that all tools are complete
            execution.AsyncToolTurnIdentifier__c = null;
            // Note: PendingAsyncToolCount__c is already 0 from the decrement
            update execution;

            // Update execution status to indicate we're ready for final follow-up
            AgentStateService agentStateSvcLocal = new AgentStateService();
            agentStateSvcLocal.resumeForFollowUpLlmCall(execution.Id, turnIdentifier, null, logPrefix);

            // Enqueue the final follow-up LLM call
            AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(agentStateSvcLocal);
            orchestrationDispatchSvc.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                turnIdentifier,
                currentTurnCount + 1,
                logPrefix,
                false // isFinalErrorTurn
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Final follow-up LLM call queued for parallel execution completion');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error triggering final follow-up LLM call: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
