/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContentResponseHandler processes LLM responses that contain only textual content (no tool calls),
 * orchestrating the full flow from message persistence to context ledger updates and memory management.
 *
 * Responsibilities:
 *   - Persists user and assistant messages for a text-only LLM turn
 *   - Validates LLM response content and handles error/failure scenarios
 *   - Updates the context ledger and invokes memory management hooks
 *   - Invokes completion capabilities via LLM for non-conversational agents
 *   - Ensures robust logging and error handling throughout the response lifecycle
 *
 * This class is not intended for direct use outside the orchestration and response handling subsystems.
 */
public class ContentResponseHandler implements ILLMResponseHandler {
    /**
     * Exception thrown when completion capability invocation fails.
     */
    public class CompletionCapabilityException extends Exception {
    }
    /**
     * Handles an LLM response containing only textual content (no tool calls).
     * Orchestrates message persistence, context ledger update, memory management, and error handling.
     *
     * @param context The orchestration context for the current LLM turn.
     * @return        OUTCOME_COMPLETED if successful, OUTCOME_FAILED if validation or persistence fails.
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ContentHandler] ';
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Handling text-only LLM response for session: ' + context.executionId + ', turn: ' + context.turnIdentifier
        );

        // Use the shared decision step logger from the context
        AgentDecisionStepLogger decisionLogger = context.decisionLogger;

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        // Validate LLM response content before proceeding
        if (String.isBlank(assistantData?.content)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Validation failed: LLM response content is empty.');

            // Log the error step
            decisionLogger.logError(
                'Empty LLM Response',
                'LLM returned empty successful response',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                'LLM returned empty successful response',
                null,
                null
            );

            context.turnLifecycleSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'LLM returned empty successful response.',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        ActionOutcome completionOutcome = null;
        if (shouldInvokeCompletionCapability(context)) {
            completionOutcome = invokeCompletionCapability(context, assistantData.content, logPrefix);
        }

        // Persist the user message as the parent of the assistant's reply using ExecutionStep__c
        Id savedUserMessageId = null;
        if (context.userMessageData != null && String.isNotBlank(context.userMessageData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedUserMessageId = executionStepService.createUserInputStep(
                context.executionId,
                context.userMessageData.content,
                context.turnIdentifier,
                context.currentTurnCount
            );
        }

        // Save assistant message using ExecutionStep__c
        Id savedAssistantMessageId = null;
        if (String.isNotBlank(assistantData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedAssistantMessageId = executionStepService.createAgentResponseStep(
                context.executionId,
                assistantData.content,
                context.turnIdentifier,
                context.currentTurnCount
            );
        }

        // Log completion capability result if it was invoked
        if (completionOutcome != null) {
            logCompletionCapabilityResult(context, completionOutcome, completionOutcome.data, logPrefix);
        }

        // Commit the turn context to the ledger for traceability
        try {
            context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context ledger update failed: ' + e.getMessage());
        }

        // Invoke memory management completion hook if configured
        try {
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (String.isNotBlank(agentConfig.MemoryStrategy__c)) {
                LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentConfig.LLMConfiguration__c);
                IMemoryManager memoryManager = MemoryManagerFactory.getManager(agentConfig.MemoryStrategy__c);
                // Note: Memory manager will need to be updated to handle both execution models
                memoryManager.onTurnCompletion(context.executionId, agentConfig, llmConfig, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Memory management completion hook failed: ' + e.getMessage());
        }

        // Log the final response
        decisionLogger.logFinalResponse(
            'Final Response Generated',
            'The final response from the LLM has been generated and stored',
            assistantData.content,
            assistantData.processingTimeMs
        );

        // Complete the turn successfully
        context.turnLifecycleSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }

    /**
     * Determines if a completion capability should be invoked for this execution.
     * Checks if the agent definition has a completion capability configured and
     * ensures it's not a conversational agent (which displays responses in UI).
     *
     * @param context The orchestration context for the current turn.
     * @return        True if completion capability should be invoked, false otherwise.
     */
    private Boolean shouldInvokeCompletionCapability(OrchestrationContext context) {
        try {
            // Query agent definition to check for completion capability
            AIAgentDefinition__c agentDef = [
                SELECT CompletionCapability__c, AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :context.agentDefinitionId
                LIMIT 1
            ];

            // Don't invoke for conversational agents (they show response in UI)
            if (agentDef.AgentType__c == 'Conversational') {
                System.debug(LoggingLevel.INFO, context.logPrefix + '[CompletionCheck] Skipping completion capability for conversational agent');
                return false;
            }

            // Check if completion capability is configured
            return String.isNotBlank(agentDef.CompletionCapability__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, context.logPrefix + '[CompletionCheck] Error checking completion capability: ' + e.getMessage());
            return false;
        }
    }

    /**
     * Invokes the configured completion capability using declarative mapping.
     *
     * Strategy:
     * 1. Check if CompletionParameterMapping__c is configured (custom admin mapping)
     * 2. If not, check for hardcoded default mapping by AgentType__c
     * 3. If neither exists, throw an error (no LLM fallback)
     *
     * This approach provides:
     * - Performance: Declarative mapping is instant (no API calls)
     * - Cost: Declarative mapping is free
     * - Reliability: 100% deterministic, no hallucination risk
     * - Maintainability: Clear, testable transformation logic
     *
     * @param context      The orchestration context for the current turn.
     * @param summary      The final LLM-generated summary to pass to the completion capability.
     * @param logPrefix    Logging prefix for debug output.
     * @return             ActionOutcome representing the result of the completion capability execution.
     */
    private ActionOutcome invokeCompletionCapability(OrchestrationContext context, String summary, String logPrefix) {
        String completionLogPrefix = logPrefix + '[CompletionCapability] ';

        try {
            // 1. Query agent definition with completion configuration
            AIAgentDefinition__c agentDef = [
                SELECT CompletionCapability__c, CompletionParameterMapping__c, AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :context.agentDefinitionId
                LIMIT 1
            ];

            // 2. Query the completion capability record
            AgentCapability__c capability = [
                SELECT
                    Id,
                    CapabilityName__c,
                    Description__c,
                    Parameters__c,
                    ImplementationType__c,
                    ImplementationDetail__c,
                    StandardActionType__c,
                    BackendConfiguration__c,
                    ExecutionContext__c,
                    HaltAndReportError__c,
                    RunAsynchronously__c,
                    RequiresConfirmation__c,
                    RequiresApproval__c,
                    ExposureLevel__c
                FROM AgentCapability__c
                WHERE Id = :agentDef.CompletionCapability__c
                LIMIT 1
            ];

            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Invoking completion capability: ' + capability.CapabilityName__c);

            // 3. Determine execution strategy: Custom Mapping → Default Mapping → Error
            String toolArgs;
            String mappingTemplate = null;

            // Check for custom admin-provided mapping
            if (String.isNotBlank(agentDef.CompletionParameterMapping__c)) {
                mappingTemplate = agentDef.CompletionParameterMapping__c;
                System.debug(LoggingLevel.INFO, completionLogPrefix + 'Using custom declarative mapping');
            } else {
                // Check for hardcoded default mapping by agent type
                mappingTemplate = CompletionParameterMapper.getDefaultMapping(agentDef.AgentType__c);
                if (String.isNotBlank(mappingTemplate)) {
                    System.debug(
                        LoggingLevel.INFO,
                        completionLogPrefix + 'Using default declarative mapping for agent type: ' + agentDef.AgentType__c
                    );
                } else {
                    // No mapping available - this is a configuration error
                    String errorMsg =
                        'No completion parameter mapping found. ' +
                        'Either configure CompletionParameterMapping__c or add a default mapping for agent type: ' +
                        agentDef.AgentType__c;
                    System.debug(LoggingLevel.ERROR, completionLogPrefix + errorMsg);
                    throw new CompletionCapabilityException(errorMsg);
                }
            }

            // Execute declarative mapping
            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Executing declarative parameter mapping');
            toolArgs = executeDeclarativeMapping(context, summary, mappingTemplate, completionLogPrefix);

            // 4. Build ActionContext for capability execution
            ActionContext actionContext = new ActionContext(
                context.executionId,
                context.originalUserId,
                context.executionUserId,
                context.currentPageRecordId, // relatedRecordId
                context.agentDefinitionId,
                capability.Id, // capabilityId
                null, // implementationDetail
                context.turnIdentifier,
                context.currentTurnCount,
                'Completion' // executionType
            );

            // 5. Execute capability using existing CapabilityExecutionRouter
            ActionOutcome outcome = context.actionExecSvc.executeSingleAction(capability, toolArgs, actionContext);

            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Completion capability executed. Success: ' + outcome.isSuccess);
            return outcome;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                completionLogPrefix + 'Completion capability failed: ' + e.getMessage() + '\n' + e.getStackTraceString()
            );

            // Don't let completion failure crash the main flow
            ActionOutcome errorOutcome = ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_COMPLETION_CAPABILITY_FAILED,
                'Completion capability execution failed: ' + e.getMessage()
            );
            return errorOutcome;
        }
    }

    /**
     * Executes declarative parameter mapping using CompletionParameterMapper.
     * Fast, deterministic, and cost-free.
     *
     * @param context         The orchestration context
     * @param summary         The LLM summary
     * @param mappingTemplate The JSON template with {{variable}} placeholders
     * @param logPrefix       Logging prefix
     * @return                JSON string with mapped parameters
     */
    private String executeDeclarativeMapping(OrchestrationContext context, String summary, String mappingTemplate, String logPrefix) {
        String mapLogPrefix = logPrefix + '[DeclarativeMapping] ';

        try {
            // Query execution for trigger payload (contains email metadata, etc.)
            AgentExecution__c execution = [
                SELECT TriggerPayload__c, ExecutionType__c, TriggerSource__c
                FROM AgentExecution__c
                WHERE Id = :context.executionId
                LIMIT 1
            ];

            // Build completion context
            Map<String, Object> completionContext = CompletionParameterMapper.buildCompletionContext(summary, execution);

            // Apply mapping template
            String mappedJson = CompletionParameterMapper.applyMapping(mappingTemplate, completionContext);

            System.debug(LoggingLevel.INFO, mapLogPrefix + 'Declarative mapping completed successfully');
            return mappedJson;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, mapLogPrefix + 'Declarative mapping failed: ' + e.getMessage());
            throw new CompletionCapabilityException('Declarative mapping failed: ' + e.getMessage());
        }
    }

    /**
     * Logs the result of the completion capability execution as an ExecutionStep__c record.
     *
     * @param context        The orchestration context for the current turn.
     * @param outcome        The ActionOutcome from the completion capability execution.
     * @param outcomeData    The outcome data that may contain capability details.
     * @param logPrefix      Logging prefix for debug output.
     */
    private void logCompletionCapabilityResult(OrchestrationContext context, ActionOutcome outcome, Object outcomeData, String logPrefix) {
        String resultLogPrefix = logPrefix + '[LogCompletion] ';

        try {
            ExecutionStepService executionStepService = new ExecutionStepService();

            String resultContent = outcome.isSuccess
                ? 'Completion capability executed successfully'
                : 'Completion capability failed: ' + outcome.errorMessage;

            // Build metadata for the completion step
            Map<String, Object> stepMetadata = new Map<String, Object>{ 'success' => outcome.isSuccess, 'errorCode' => outcome.errorCode };

            executionStepService.createStep(
                context.executionId,
                'ToolResult',
                'Tool',
                resultContent,
                'Text',
                context.turnIdentifier,
                context.currentTurnCount,
                null,
                null,
                null,
                outcome.data != null ? JSON.serialize(outcome.data) : null,
                JSON.serialize(stepMetadata),
                false
            );

            System.debug(LoggingLevel.INFO, resultLogPrefix + 'Logged completion capability result');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, resultLogPrefix + 'Failed to log completion result: ' + e.getMessage());
        }
    }
}
