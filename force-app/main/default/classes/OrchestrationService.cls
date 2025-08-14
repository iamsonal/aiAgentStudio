/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * OrchestrationService coordinates the end-to-end flow of AI agent actions following LLM response processing.
 * It applies the Strategy pattern to delegate response handling to the appropriate handler (content-only or tool call),
 * manages turn lifecycle and state transitions, and provides robust error handling with comprehensive logging.
 * The service is designed for extensibility, testability, and operational transparency, serving as the central
 * orchestrator for all LLM-driven agent workflows.
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
    private final TurnLifecycleService turnLifecycleSvc;
    private final ActionExecutionService actionExecSvc;
    private final AgentJobEnqueuer orchestrationDispatchSvc;
    private final ContextManagerService contextManagerSvc;

    /**
     * Default constructor. Initializes all service dependencies with their default implementations.
     *
     * Side effects: Instantiates all required services for orchestration.
     */
    public OrchestrationService() {
        // Initialize with default service implementations
        this(new TurnLifecycleService(), new ActionExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
    }

    /**
     * Constructor with dependency injection for testing and customization.
     *
     * @param turnSvc    TurnLifecycleService instance (required)
     * @param actionSvc  ActionExecutionService instance (required)
     * @param dispatchSvc AgentJobEnqueuer instance (required)
     * @param contextSvc ContextManagerService instance (required)
     * @throws IllegalArgumentException if any dependency is null
     */
    public OrchestrationService(
        TurnLifecycleService turnSvc,
        ActionExecutionService actionSvc,
        AgentJobEnqueuer dispatchSvc,
        ContextManagerService contextSvc
    ) {
        if (turnSvc == null || actionSvc == null || dispatchSvc == null || contextSvc == null) {
            throw new IllegalArgumentException('All service dependencies for OrchestrationService are required.');
        }
        this.turnLifecycleSvc = turnSvc;
        this.actionExecSvc = actionSvc;
        this.orchestrationDispatchSvc = dispatchSvc;
        this.contextManagerSvc = contextSvc;
    }

    /**
     * Processes the LLM interaction result using the appropriate strategy handler based on response type.
     *
     * Selects the correct response handler (content or tool call), manages turn lifecycle, logs all major steps,
     * and returns an outcome constant indicating the result of the orchestration turn.
     *
     * @param llmInteractionResult      Result from LLM interaction containing response content and/or tool calls (required)
     * @param sessionId                 The current session ID (required)
     * @param originalUserId            The original user ID who initiated the session (required)
     * @param executionUserId           The user ID under which execution is performed (required)
     * @param agentDefinitionId         The agent definition ID for this session (required)
     * @param turnIdentifier            Unique identifier for this turn (required)
     * @param currentTurnCount          The current turn count in the session (required)
     * @param userMessageDataForTurn    The user message data for this turn (required)
     * @param currentPageRecordId       The current page record ID, if applicable (optional)
     * @return                          Outcome constant indicating turn completion status and next steps
     * @throws None. All errors are handled internally and surfaced via debug logs and return value.
     *
     * Side effects: Emits debug logs and orchestrates turn state transitions.
     */
    public String processLlmResult(
        LLMInteractionService.LLMInteractionResult llmInteractionResult,
        Id sessionId,
        Id originalUserId,
        Id executionUserId,
        Id agentDefinitionId,
        String turnIdentifier,
        Integer currentTurnCount,
        LLMInteractionService.MessageData userMessageDataForTurn,
        Id currentPageRecordId
    ) {
        String logPrefix = '[OrchSvc Turn:' + turnIdentifier?.left(8) + ' Cycle:' + currentTurnCount + ' Sess:' + sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting orchestration for LLM result. Page context: ' + currentPageRecordId);

        OrchestrationLogger.logStep(
            sessionId,
            turnIdentifier,
            OrchestrationLogger.TYPE_LLM_RESPONSE,
            OrchestrationLogger.STATUS_INIT,
            'Processing LLM response',
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null
        );

        try {
            if (llmInteractionResult == null || !llmInteractionResult.isSuccess) {
                String failureReason = llmInteractionResult?.failureReason ?? 'Unknown LLM interaction error';
                String failureCode = llmInteractionResult?.failureCode ?? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED;
                System.debug(LoggingLevel.ERROR, logPrefix + 'LLM interaction failed. Reason: ' + failureReason + ' (Code: ' + failureCode + ')');

                OrchestrationLogger.logStep(
                    sessionId,
                    turnIdentifier,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_FAILURE,
                    'LLM interaction failed',
                    null,
                    null,
                    failureReason,
                    failureCode,
                    null,
                    null,
                    null,
                    null,
                    null
                );

                this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, failureReason, failureCode, logPrefix);
                return OUTCOME_FAILED;
            }

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                OrchestrationLogger.TYPE_LLM_RESPONSE,
                OrchestrationLogger.STATUS_SUCCESS,
                'LLM response received successfully',
                null,
                llmInteractionResult,
                null,
                null,
                null,
                null,
                null,
                null,
                null
            );

            // Create orchestration context with all required state and dependencies for this turn.
            OrchestrationContext context = new OrchestrationContext(
                llmInteractionResult,
                sessionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                turnIdentifier,
                currentTurnCount,
                userMessageDataForTurn,
                this.turnLifecycleSvc,
                this.actionExecSvc,
                this.orchestrationDispatchSvc,
                this.contextManagerSvc,
                currentPageRecordId
            );

            // Select the appropriate response handler based on LLM response type (tool call or content-only).
            ILLMResponseHandler handler;
            if (llmInteractionResult.providerResult?.requestedActions != null && !llmInteractionResult.providerResult.requestedActions.isEmpty()) {
                handler = new ToolCallResponseHandler();
            } else {
                handler = new ContentResponseHandler();
            }

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_INIT,
                'Dispatching to handler: ' + handler.toString(),
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null
            );

            // Execute the selected response handling strategy.
            String outcome = handler.handle(context);

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_SUCCESS,
                'Orchestration completed: ' + outcome,
                null,
                new Map<String, Object>{ 'outcome' => outcome },
                null,
                null,
                null,
                null,
                null,
                null,
                null
            );

            return outcome;
        } catch (Exception ex) {
            String errorMsg = 'Critical orchestration error: (' + ex.getTypeName() + ') ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration failed with exception. ' + errorMsg + '\nStack: ' + ex.getStackTraceString());

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_FAILURE,
                'Orchestration failed',
                null,
                null,
                errorMsg,
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                null,
                null,
                null,
                null,
                null
            );

            try {
                this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception finalFailEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'FATAL: Could not mark turn as failed. Reason: ' + finalFailEx.getMessage());
            }
            return OUTCOME_FAILED;
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }

    // Static utility methods for use by response handlers

    /**
     * Serializes an ActionResult for LLM consumption, handling nulls and error cases gracefully.
     *
     * If the ActionResult is null or missing output, a synthetic error response is generated. Internal exception details
     * are sanitized for LLM consumption. All serialization errors are logged and surfaced in the output.
     *
     * @param actionResult The ActionResult to serialize (may be null)
     * @param logPrefix    Prefix for debug log output
     * @return             JSON string representing the action result for LLM
     *
     * Side effects: Emits debug logs for null results and serialization errors.
     */
    public static String serializeActionResult(ActionResult actionResult, String logPrefix) {
        try {
            if (actionResult == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Action result is null. Returning error response for LLM.');
                return JSON.serialize(new Map<String, Object>{ 'error' => 'Action execution did not return a result object.' });
            }
            if (actionResult.outputForLlm != null) {
                return JSON.serialize(actionResult.outputForLlm);
            } else {
                Map<String, Object> syntheticOutput = new Map<String, Object>{ 'success' => actionResult.isSuccess };
                if (!actionResult.isSuccess) {
                    syntheticOutput.put('errorCode', actionResult.errorCode);
                    String llmErrorDetail = actionResult.internalDetails != null ? actionResult.internalDetails : 'No details available';
                    // Sanitize internal exception details for LLM consumption
                    if (actionResult.internalDetails != null && actionResult.internalDetails.contains('Exception:')) {
                        llmErrorDetail = 'An internal error occurred executing the action';
                    }
                    syntheticOutput.put('messageForUser', llmErrorDetail);
                }
                syntheticOutput.put('data', new Map<String, Object>());
                return JSON.serialize(syntheticOutput);
            }
        } catch (Exception jsonEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to serialize action result for LLM. Error: ' + jsonEx.getMessage());
            return JSON.serialize(
                new Map<String, Object>{
                    'error' => 'Failed to serialize action result data',
                    'serialization_error_details' => jsonEx.getMessage(),
                    'original_action_success_status' => actionResult?.isSuccess,
                    'original_action_error_code' => actionResult?.errorCode
                }
            );
        }
    }

    /**
     * Extracts a Salesforce record ID from an ActionResult payload for context management.
     *
     * Handles multiple output shapes (direct recordId, single-record list, or single record object).
     *
     * @param actionResult Action execution result containing potential record data (may be null)
     * @return             Salesforce ID if found in result payload, null otherwise
     */
    public static Id extractRecordIdFromResult(ActionResult actionResult) {
        if (
            actionResult == null ||
            !actionResult.isSuccess ||
            actionResult.outputForLlm == null ||
            !(actionResult.outputForLlm instanceof Map<String, Object>)
        ) {
            return null;
        }

        Map<String, Object> outputMap = (Map<String, Object>) actionResult.outputForLlm;
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
     * Clears the PendingConfirmationActionDetails__c field from a ChatMessage__c record.
     *
     * Used to remove pending action details after confirmation or cancellation. Logs all outcomes.
     *
     * @param chatMessageId The ChatMessage__c record ID to update (may be null)
     * @param logPrefix     Prefix for debug log output
     *
     * Side effects: Emits debug logs for null input, success, and failure cases.
     */
    public static void clearPendingDetailsFromMessage(Id chatMessageId, String logPrefix) {
        try {
            if (chatMessageId == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Attempted to clear pending details: ChatMessageId is null. Skipping update.');
                return;
            }
            update new ChatMessage__c(Id = chatMessageId, PendingConfirmationActionDetails__c = null);
            System.debug(LoggingLevel.INFO, logPrefix + 'Pending confirmation details cleared from message: ' + chatMessageId);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'Failed to clear pending details from message ' + chatMessageId + '. Error: ' + e.getMessage()
            );
        }
    }
}
