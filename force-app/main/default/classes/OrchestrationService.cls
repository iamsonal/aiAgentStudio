/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Coordinates AI agent action flow after LLM response processing. Manages turn lifecycle.
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
    public static final String OUTCOME_IMMEDIATE_FOLLOWUP = 'IMMEDIATE_FOLLOWUP';
    private final AgentStateService agentStateSvc;
    private final CapabilityExecutionService actionExecSvc;
    private final AgentJobEnqueuer orchestrationDispatchSvc;
    private final ContextManagerService contextManagerSvc;

    public OrchestrationService() {
        this(new AgentStateService(), new CapabilityExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
    }
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
        IDecisionStepLogger.ILogger decisionLogger
    ) {
        String logPrefix = '[OrchSvc Turn:' + turnIdentifier?.left(8) + ' Cycle:' + currentTurnCount + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting orchestration for LLM result. Page context: ' + currentPageRecordId);

        try {
            if (llmInteractionResult == null || !llmInteractionResult.isSuccess) {
                String failureReason = llmInteractionResult == null ? 'Unknown LLM interaction error' : llmInteractionResult.failureReason;
                String failureCode = llmInteractionResult == null ? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED : llmInteractionResult.failureCode;
                System.debug(LoggingLevel.ERROR, logPrefix + failureReason + ' (Code: ' + failureCode + ')');

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

            ILLMResponseHandler handler;
            if (llmInteractionResult.providerResult?.requestedActions != null && !llmInteractionResult.providerResult.requestedActions.isEmpty()) {
                handler = new ToolCallResponseHandler();
            } else {
                handler = new ContentResponseHandler();
            }

            String outcome = handler.handle(context);

            return outcome;
        } catch (Exception ex) {
            String errorMsg = ex.getTypeName() + ': ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + ex.getStackTraceString());

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
            } catch (Exception failTurnEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state during error handling: ' + failTurnEx.getMessage());
            }
            return OUTCOME_FAILED;
        } finally {
            if (!TransactionContext.getInstance().isDeferredDMLMode()) {
                decisionLogger.commitSteps();
            }
        }
    }

    public static String serializeActionOutcome(ActionOutcome actionOutcome, String logPrefix) {
        try {
            if (actionOutcome == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Action outcome is null. Returning error response for LLM.');
                return JSON.serialize(new Map<String, Object>{ 'isSuccess' => false, 'error' => 'Action execution did not return an outcome object.' });
            }

            if (actionOutcome.isSuccess) {
                Map<String, Object> successOutput = new Map<String, Object>{ 'isSuccess' => true };

                if (actionOutcome.data != null) {
                    successOutput.put('data', actionOutcome.data);
                } else {
                    successOutput.put('data', new Map<String, Object>());
                }

                return JSON.serialize(successOutput);
            } else {
                Map<String, Object> errorOutput = new Map<String, Object>{
                    'isSuccess' => false,
                    'errorCode' => actionOutcome.errorCode,
                    'messageForUser' => actionOutcome.llmFriendlyMessage != null ? actionOutcome.llmFriendlyMessage : actionOutcome.errorMessage,
                    'data' => new Map<String, Object>()
                };

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

    public static Id extractRecordIdFromOutcome(ActionOutcome actionOutcome) {
        if (actionOutcome == null || !actionOutcome.isSuccess || actionOutcome.data == null || !(actionOutcome.data instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> outputMap = (Map<String, Object>) actionOutcome.data;
        if (!'SUCCESS'.equalsIgnoreCase(String.valueOf(outputMap.get('status'))) || !(outputMap.get('data') instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        if (dataMap.get('recordId') instanceof String) {
            try {
                return Id.valueOf((String) dataMap.get('recordId'));
            } catch (Exception e) {
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
                }
            }
        }

        return null;
    }

    private static String serializeLlmInteractionResultForLogging(LLMInteractionService.LLMInteractionResult result) {
        if (result == null) {
            return null;
        }

        try {
            Map<String, Object> serializableResult = new Map<String, Object>();
            serializableResult.put('isSuccess', result.isSuccess);
            serializableResult.put('providerResult', result.providerResult);
            serializableResult.put('assistantMessageData', result.assistantMessageData);
            serializableResult.put('failureReason', result.failureReason);
            serializableResult.put('failureCode', result.failureCode);

            if (result.failureException != null) {
                serializableResult.put('failureExceptionMessage', result.failureException.getMessage());
                serializableResult.put('failureExceptionType', result.failureException.getTypeName());
            }

            return JSON.serialize(serializableResult);
        } catch (Exception e) {
            return '{"isSuccess": ' + result.isSuccess + ', "serializationError": "Failed to serialize LLMInteractionResult: ' + e.getMessage() + '"}';
        }
    }

    /**
     * @description Determines if execution should fail immediately on tool error. Three-tier hierarchy: Capability.FailFastOnError__c, MaxToolRetries__c, or autonomous recovery.
     */
    public static Boolean shouldFailFast(
        AgentCapability__c capability,
        AIAgentDefinition__c agentDefinition,
        ActionOutcome toolOutcome,
        Id executionId,
        String logPrefix
    ) {
        if (toolOutcome == null || toolOutcome.isSuccess) {
            return false;
        }

        if (capability.FailFastOnError__c == true) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + '⚠️ FAIL-FAST (Tier 1): Capability "' + capability.CapabilityName__c + '" has FailFastOnError=true. Halting execution immediately.'
            );
            return true;
        }

        if (executionId != null && agentDefinition.AgentType__c != 'Conversational') {
            Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
            Integer failureCount = countSuccessiveToolFailures(executionId, capability.CapabilityName__c, logPrefix);

            if (failureCount >= maxRetries) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        '⚠️ FAIL-FAST (Tier 3): Tool "' +
                        capability.CapabilityName__c +
                        '" exceeded MaxToolRetries__c (' +
                        maxRetries +
                        '). ' +
                        'Successive failures: ' +
                        failureCount +
                        '. Halting execution. ' +
                        '(AgentType: ' +
                        agentDefinition.AgentType__c +
                        ')'
                );
                return true;
            }
        }

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '✓ AUTONOMOUS RECOVERY (Tier 3): Passing error to LLM for handling. ' +
                'Capability: ' +
                capability.CapabilityName__c +
                ', AgentType: ' +
                agentDefinition.AgentType__c
        );
        return false;
    }

    public static Boolean shouldFailFast(AgentCapability__c capability, AIAgentDefinition__c agentDefinition, ActionOutcome toolOutcome, String logPrefix) {
        return shouldFailFast(capability, agentDefinition, toolOutcome, null, logPrefix);
    }

    public static Integer countSuccessiveToolFailures(Id executionId, String toolName, String logPrefix) {
        if (executionId == null || String.isBlank(toolName)) {
            return 0;
        }

        try {
            List<ExecutionStep__c> steps = [
                SELECT Id, StepType__c, ToolName__c, IsError__c, Timestamp__c, ToolCallId__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND StepType__c IN ('ToolCall', 'ToolResult') AND ToolName__c = :toolName
                ORDER BY Timestamp__c DESC, Id DESC
                LIMIT 100
            ];

            if (steps.isEmpty()) {
                return 0;
            }

            Integer failureCount = 0;

            for (ExecutionStep__c step : steps) {
                if (step.StepType__c == 'ToolResult') {
                    if (step.IsError__c == true) {
                        failureCount++;
                    } else {
                        break;
                    }
                }
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Tool "' + toolName + '" has ' + failureCount + ' successive failure(s) in execution ' + executionId);

            return failureCount;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error counting tool failures: ' + e.getMessage());
            return 0;
        }
    }

    /**
     * @description Called by AsyncActionEngine after an async tool completes to atomically decrement the pending counter and trigger follow-up when all tools complete.
     */
    public static void onAsyncToolCompleted(Id executionId, String turnIdentifier, Integer currentTurnCount, String completedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool completed: ' + completedToolCallId + '. Atomically decrementing counter.');

            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

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

            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool counter decremented: ' + currentCount + ' -> ' + newCount);

            if (newCount == 0 && currentCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
            } else if (newCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Still waiting for ' + newCount + ' more async tool(s) to complete.');
            }
        } catch (QueryException qe) {
            if (qe.getMessage().contains('UNABLE_TO_LOCK_ROW')) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Record locked by concurrent transaction. Will retry via platform retry mechanism.');
                throw qe;
            }
            System.debug(LoggingLevel.ERROR, logPrefix + 'Query error in async tool completion: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in async tool completion check: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    /**
     * @description Decrements the async tool counter when a tool fails to queue, preventing execution hangs.
     */
    public static void decrementAsyncToolCounter(Id executionId, String turnIdentifier, Integer currentTurnCount, String failedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Decrementing counter for failed queue: ' + failedToolCallId);

            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            if (String.isNotBlank(execution.AsyncToolTurnIdentifier__c) && !turnIdentifier.equals(execution.AsyncToolTurnIdentifier__c)) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Turn identifier mismatch. Skipping decrement.');
                return;
            }

            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Counter decremented for queue failure: ' + currentCount + ' -> ' + newCount);

            if (newCount == 0 && currentCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools failed to queue. Triggering follow-up for error handling.');
                triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error decrementing counter: ' + e.getMessage());
        }
    }

    private static void triggerFinalFollowUpLLMCallInternal(AgentExecution__c execution, String turnIdentifier, Integer currentTurnCount, String logPrefix) {
        try {
            execution.AsyncToolTurnIdentifier__c = null;
            update execution;

            AgentStateService agentStateSvcLocal = new AgentStateService();
            agentStateSvcLocal.resumeForFollowUpLlmCall(execution.Id, turnIdentifier, null, logPrefix);

            AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(agentStateSvcLocal);
            orchestrationDispatchSvc.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                turnIdentifier,
                currentTurnCount + 1,
                logPrefix,
                false,
                execution.SourceRecordId__c
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Final follow-up LLM call queued for parallel execution completion');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error triggering final follow-up LLM call: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
