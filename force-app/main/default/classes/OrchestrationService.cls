/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for orchestrating the AI agent's actions
 *              *after* receiving a response from the LLM Interaction Service.
 *              It uses the Strategy pattern (via ResponseHandlerFactory) to delegate
 *              processing to the appropriate handler based on the LLM's response.
 */
public inherited sharing class OrchestrationService {
    public virtual class OrchestrationException extends AIAgentException {
    }
    public class ConfigurationException extends OrchestrationException {
    }

    public static final String OUTCOME_COMPLETED = 'COMPLETED';
    public static final String OUTCOME_FAILED = 'FAILED';
    public static final String OUTCOME_QUEUED_FOLLOWUP = 'QUEUED_FOLLOWUP';
    public static final String OUTCOME_QUEUED_ACTION = 'QUEUED_ACTION';
    public static final String OUTCOME_AWAITING_CONFIRMATION = 'AWAITING_CONFIRMATION';

    private final TurnLifecycleService turnLifecycleSvc;
    private final ActionExecutionService actionExecSvc;
    private final AgentJobEnqueuer orchestrationDispatchSvc;
    private final ContextManagerService contextManagerSvc;

    /**
     * @description Default constructor for ease of use. Instantiates default dependencies.
     */
    public OrchestrationService() {
        this(new TurnLifecycleService(), new ActionExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
    }

    /**
     * @description Main constructor for dependency injection. Allows for test mocking.
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
     * @description Processes the result from an LLM call by delegating to the appropriate strategy handler.
     *              Enhanced with orchestration logging for detailed turn tracking.
     * @param llmInteractionResult The result object from the LLMInteractionService.
     * @return String An outcome constant (e.g., OUTCOME_COMPLETED).
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
                String failureReason = llmInteractionResult?.failureReason ?? 'Unknown LLM Interaction Error';
                String failureCode = llmInteractionResult?.failureCode ?? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED;

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
                'Dispatching to response handler: ' + handler.toString(),
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

            String outcome = handler.handle(context);

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_SUCCESS,
                'Orchestration completed with outcome: ' + outcome,
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
            String errorMsg = 'Critical Orchestration Logic Error: (' + ex.getTypeName() + ') ' + ex.getMessage();

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
            }
            return OUTCOME_FAILED;
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }

    public static String serializeActionResult(ActionResult actionResult, String logPrefix) {
        try {
            if (actionResult == null) {
                return JSON.serialize(new Map<String, Object>{ 'error' => 'Action execution did not return a result object.' });
            }
            if (actionResult.outputForLlm != null) {
                return JSON.serialize(actionResult.outputForLlm);
            } else {
                Map<String, Object> syntheticOutput = new Map<String, Object>{ 'success' => actionResult.isSuccess };
                if (!actionResult.isSuccess) {
                    syntheticOutput.put('errorCode', actionResult.errorCode);
                    String llmErrorDetail = actionResult.internalDetails != null ? actionResult.internalDetails : 'No details available.';
                    if (actionResult.internalDetails != null && actionResult.internalDetails.contains('Exception:')) {
                        llmErrorDetail = 'An internal error occurred executing the action.';
                    }
                    syntheticOutput.put('messageForUser', llmErrorDetail);
                }
                syntheticOutput.put('data', new Map<String, Object>());
                return JSON.serialize(syntheticOutput);
            }
        } catch (Exception jsonEx) {
            return JSON.serialize(
                new Map<String, Object>{
                    'error' => 'Failed to serialize action result data.',
                    'serialization_error_details' => jsonEx.getMessage(),
                    'original_action_success_status' => actionResult?.isSuccess,
                    'original_action_error_code' => actionResult?.errorCode
                }
            );
        }
    }

    /**
     * @description Safely extracts a record ID from a structured ActionResult payload.
     * @param actionResult The result from an action execution.
     * @return The Salesforce ID found in the payload, or null if not found or invalid format.
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

        if (dataMap.get('recordId') instanceof String) {
            try {
                return Id.valueOf((String) dataMap.get('recordId'));
            } catch (Exception e) {
                /* fall through */
            }
        }

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
                            /* fall through */
                        }
                    }
                }
            }
        }

        if (dataMap.get('record') instanceof Map<String, Object>) {
            Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
            if (recordMap.get('Id') instanceof String) {
                try {
                    return Id.valueOf((String) recordMap.get('Id'));
                } catch (Exception e) {
                    /* fall through */
                }
            }
        }

        return null;
    }

    public static void clearPendingDetailsFromMessage(Id chatMessageId, String logPrefix) {
        try {
            if (chatMessageId == null) {
                return;
            }
            update new ChatMessage__c(Id = chatMessageId, PendingConfirmationActionDetails__c = null);
        } catch (Exception e) {
        }
    }
}
