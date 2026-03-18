/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Asynchronous direct runtime for agents with 2+ capabilities using the iterative agentic pattern.
 * Handles complex multi-tool workflows with async queueable chain execution using the same follow-up engines as iterative chat/email runtimes.
 *
 * **Key Characteristics:**
 * - **Conversational Execution**: Multi-turn LLM calls with tool execution
 * - **Async Queueable Chain**: Uses FollowUpLLMEngine, AsyncActionEngine
 * - **2+ Tools**: Supports agents with multiple capabilities
 * - **Pipeline/Sub-Agent Support**: Can reuse existing execution records
 *
 * **Execution Flow:**
 * 1. Call LLM synchronously (no execution record yet)
 * 2. If text response: return immediately
 * 3. If tool call(s):
 *    a. Create execution record + steps
 *    b. Check if sync or async tool
 *    c. Sync: execute now, enqueue follow-up LLM
 *    d. Async: enqueue tool execution
 * 4. Return executionId + "Processing" status
 * 5. Queueable chain continues through the shared follow-up engines
 *
 * **Use Cases:**
 * - Complex research workflows (search → analyze → summarize → report)
 * - Multi-step data processing (validate → transform → enrich → store)
 * - Pipeline step agents and agent-as-capability child executions
 *
 * This class was extracted from DirectRuntimeService to separate concerns and
 * reduce complexity in the main runtime router.
 */
public with sharing class DirectAsyncRuntimeService {
    private static final String LOG_PREFIX = '[DirectAsyncRuntime] ';

    private AIAgentDefinition__c agentDefinition;
    private LLMConfiguration__c llmConfig;
    private String triggerPayload;

    public void setTriggerPayload(String value) {
        this.triggerPayload = value;
    }
    private Map<String, AgentCapability__c> capabilityCache = new Map<String, AgentCapability__c>();
    private Map<Id, String> userNameCache = new Map<Id, String>();

    /**
     * @description Constructor
     * @param agentDef The agent definition
     * @param llmConfig The LLM configuration
     */
    public DirectAsyncRuntimeService(AIAgentDefinition__c agentDef, LLMConfiguration__c llmConfig) {
        this.agentDefinition = agentDef;
        this.llmConfig = llmConfig;
    }

    // ===================================================================================
    // HELPER METHODS - DEFINED FIRST TO AVOID COMPILATION ERRORS
    // ===================================================================================

    /**
     * @description Factory method for creating a successful result
     */
    private DirectExecutionResult createSuccessResult(String response, Id executionId, Integer tokens, Long timeMs) {
        DirectExecutionResult result = new DirectExecutionResult();
        result.success = true;
        result.response = response;
        result.executionId = executionId;
        result.status = 'Completed';
        result.requiresPolling = false;
        result.tokensUsed = tokens;
        result.processingTimeMs = timeMs;
        return result;
    }

    /**
     * @description Factory method for creating a processing result (async execution)
     */
    private DirectExecutionResult createProcessingResult(Id executionId, String executionUrl, String statusMessage) {
        DirectExecutionResult result = new DirectExecutionResult();
        result.success = true;
        result.status = 'Processing';
        result.requiresPolling = true;
        result.executionId = executionId;
        result.executionUrl = executionUrl;
        result.response = statusMessage;
        return result;
    }

    /**
     * @description Factory method for creating a failure result
     */
    private DirectExecutionResult createFailureResult(String errorCode, String errorMessage) {
        DirectExecutionResult result = new DirectExecutionResult();
        result.success = false;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.status = 'Failed';
        result.requiresPolling = false;
        return result;
    }

    private AgentCapability__c getCachedCapability(String toolName) {
        if (String.isBlank(toolName)) {
            return null;
        }
        String key = toolName.toLowerCase();
        if (!capabilityCache.containsKey(key)) {
            capabilityCache.put(key, AIAgentConfigService.getCapability(agentDefinition.Id, toolName));
        }
        return capabilityCache.get(key);
    }

    /**
     * @description Marks an execution as failed
     */
    private void markExecutionFailed(Id executionId, String turnIdentifier, String errorMessage, String errorCode, String logPrefix) {
        try {
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.failTurn(executionId, turnIdentifier, errorMessage, errorCode, logPrefix);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + e.getMessage());
        }
    }

    /**
     * @description
     * Handles sync tool result by creating steps and enqueuing follow-up LLM call.
     */
    private DirectExecutionResult handleSyncToolResult(
        Id executionId,
        Id userId,
        Id recordId,
        String turnIdentifier,
        String toolCallId,
        String toolName,
        String toolArgs,
        AgentCapability__c capability,
        ActionOutcome toolOutcome,
        Long toolExecutionTime,
        LLMInteractionService.LLMInteractionResult llmResult,
        String executionUrl,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing sync tool result for: ' + toolName);

        try {
            ExecutionStepService stepSvc = new ExecutionStepService();

            // Create tool call step
            stepSvc.createToolCallStep(
                executionId,
                toolCallId,
                toolName,
                toolArgs,
                turnIdentifier,
                1, // turnCount
                llmResult.providerResult.promptTokens,
                llmResult.providerResult.completionTokens,
                llmResult.providerResult.totalTokens,
                llmResult.providerResult.modelIdentifier,
                llmResult.providerResult.llmCalloutDurationMs,
                capability.Id,
                null,
                null,
                null,
                false
            );

            // Log tool execution result - pass domain objects
            if (decisionLogger != null) {
                decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, toolOutcome, toolExecutionTime });
            }

            // Create tool result step
            String toolResultJson = OrchestrationService.serializeActionOutcome(toolOutcome, logPrefix);
            stepSvc.createToolResultStep(
                executionId,
                toolCallId,
                toolName,
                toolResultJson,
                turnIdentifier,
                1,
                toolExecutionTime,
                false, // isAsyncToolExecution - synchronous execution
                capability.Id,
                !toolOutcome.isSuccess, // isError = !isSuccess
                false
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Created tool call and result steps (ExecutionSteps and DecisionSteps)');

            // Commit page context references BEFORE queuing follow-up LLM call
            // This ensures context persistence across async boundaries
            if (recordId != null) {
                try {
                    ContextManagerService contextMgr = new ContextManagerService();
                    contextMgr.commitContextDelta(executionId, 1, contextMgr.buildTurnContextDelta(executionId, recordId, null));
                    System.debug(LoggingLevel.INFO, logPrefix + 'Committed page context references: ' + recordId);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit page context references: ' + e.getMessage());
                }
            }

            // Enqueue follow-up LLM call
            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            AgentStateService turnLifecycleSvc = new AgentStateService();

            turnLifecycleSvc.resumeForFollowUpLlmCall(executionId, turnIdentifier, null, logPrefix);

            enqueuer.enqueueFollowUp(
                executionId,
                userId,
                agentDefinition.Id,
                turnIdentifier,
                2, // Next turn count
                logPrefix,
                false, // not final error turn
                recordId
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued follow-up LLM call');

            // Commit decision steps
            decisionLogger.commitSteps();

            return createProcessingResult(executionId, executionUrl, 'Processing tool results');
        } catch (Exception e) {
            String errorMsg = 'Failed to process sync tool result: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + e.getStackTraceString());
            markExecutionFailed(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMsg);
        }
    }
    /**
     * @description
     * Handles async tool calls by delegating to existing orchestration infrastructure.
     */
    private DirectExecutionResult handleAsyncToolCalls(
        Id executionId,
        Id userId,
        Id recordId,
        String turnIdentifier,
        LLMInteractionService.LLMInteractionResult llmResult,
        IDecisionStepLogger.ILogger decisionLogger,
        String executionUrl,
        String logPrefix,
        TransactionContext txnCtx
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Handling async tool calls or multiple tools');

        try {
            List<Map<String, String>> requestedActions = llmResult.providerResult.requestedActions;
            Integer toolCount = requestedActions.size();

            // Check if parallel tool calling is enabled
            Boolean parallelEnabled = (agentDefinition.EnableParallelToolCalling__c == true);

            System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + toolCount + ' tool call(s). Parallel enabled: ' + parallelEnabled);

            // Parse first tool call (for sequential or single tool)
            Map<String, String> firstToolCall = requestedActions[0];
            String toolCallId = firstToolCall.get('id');
            String toolName = firstToolCall.get('name');
            String toolArgs = firstToolCall.get('arguments');

            // Lookup capability
            AgentCapability__c capability = getCachedCapability(toolName);

            if (capability == null) {
                // Commit buffer and disable deferred mode before returning
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();
                String errorMsg = 'Tool "' + toolName + '" is not configured for this agent.';
                markExecutionFailed(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_CONFIG_ERROR, logPrefix);
                return createFailureResult(AIAgentConstants.ERR_CODE_CONFIG_ERROR, errorMsg);
            }

            // Create tool call step(s)
            ExecutionStepService stepSvc = new ExecutionStepService();

            Boolean isAgentCapability = 'Agent'.equalsIgnoreCase(capability.ImplementationType__c);

            if ((toolCount == 1 || !parallelEnabled) && !isAgentCapability) {
                // Single non-Agent tool or sequential execution - commit buffer first
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();

                stepSvc.createToolCallStep(
                    executionId,
                    toolCallId,
                    toolName,
                    toolArgs,
                    turnIdentifier,
                    1, // turnCount
                    llmResult.providerResult.promptTokens,
                    llmResult.providerResult.completionTokens,
                    llmResult.providerResult.totalTokens,
                    llmResult.providerResult.modelIdentifier,
                    llmResult.providerResult.llmCalloutDurationMs,
                    null, // capabilityId - not available for function calls
                    null,
                    null,
                    null,
                    false
                );

                // Use async infrastructure to avoid callout-after-DML
                System.debug(LoggingLevel.INFO, logPrefix + 'Tool call after DML - using async infrastructure');

                return handleAsyncToolInIterativePattern(
                    executionId,
                    userId,
                    recordId,
                    turnIdentifier,
                    toolCallId,
                    toolArgs,
                    capability,
                    executionUrl,
                    decisionLogger,
                    logPrefix
                );
            } else {
                // PARALLEL EXECUTION: Multiple tools with parallel enabled
                // Keep deferred mode for multi-LLM optimization - ToolCallResponseHandler will check
                System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + toolCount + ' tools in parallel');
                return handleParallelToolsInIterativePattern(
                    executionId,
                    userId,
                    recordId,
                    turnIdentifier,
                    requestedActions,
                    llmResult,
                    executionUrl,
                    decisionLogger,
                    logPrefix,
                    txnCtx
                );
            }
        } catch (Exception e) {
            // Ensure buffer is committed on error
            try {
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();
            } catch (Exception bufferEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to commit buffer on exception: ' + bufferEx.getMessage());
            }
            String errorMsg = 'Failed to process tool calls: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + e.getStackTraceString());
            markExecutionFailed(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMsg);
        }
    }
    /**
     * @description
     * Handles asynchronous tool execution in iterative pattern.
     */
    private DirectExecutionResult handleAsyncToolInIterativePattern(
        Id executionId,
        Id userId,
        Id recordId,
        String turnIdentifier,
        String toolCallId,
        String toolArgs,
        AgentCapability__c capability,
        String executionUrl,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Async tool detected: ' + capability.CapabilityName__c);

        try {
            // Enqueue async action execution
            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            AgentStateService turnLifecycleSvc = new AgentStateService();

            // Mark as awaiting action with proper tracking
            turnLifecycleSvc.pauseForAsyncActionWithTracking(executionId, turnIdentifier, 1, capability.CapabilityName__c, logPrefix);

            enqueuer.enqueueAsyncAction(
                executionId,
                userId,
                agentDefinition.Id,
                null, // savedAssistantMessageId
                toolCallId,
                toolArgs,
                capability,
                recordId,
                turnIdentifier,
                1, // turnCount
                logPrefix
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued async tool execution');

            // Commit decision steps to persist audit trail
            if (decisionLogger != null) {
                decisionLogger.commitSteps();
            }

            return createProcessingResult(executionId, executionUrl, 'Processing asynchronous tool');
        } catch (Exception e) {
            String errorMsg = 'Failed to handle async tool: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + e.getStackTraceString());
            markExecutionFailed(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMsg);
        }
    }
    /**
     * @description
     * Handles parallel tool execution in iterative pattern.
     */
    private DirectExecutionResult handleParallelToolsInIterativePattern(
        Id executionId,
        Id userId,
        Id recordId,
        String turnIdentifier,
        List<Map<String, String>> requestedActions,
        LLMInteractionService.LLMInteractionResult llmResult,
        String executionUrl,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix,
        TransactionContext txnCtx
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Handling parallel tool execution');

        try {
            // Build orchestration context using the shared runtime model
            AgentStateService turnLifecycleSvc = new AgentStateService();
            CapabilityExecutionService actionExecSvc = new CapabilityExecutionService();
            AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer();
            ContextManagerService contextManagerSvc = new ContextManagerService();

            OrchestrationContext context = new OrchestrationContext(
                llmResult,
                executionId,
                userId, // originalUserId
                userId, // executionUserId (same for direct agents)
                agentDefinition.Id,
                turnIdentifier,
                1, // currentTurnCount
                null, // userMessageDataForTurn (already persisted)
                turnLifecycleSvc,
                actionExecSvc,
                orchestrationDispatchSvc,
                contextManagerSvc,
                recordId,
                decisionLogger
            );

            // Delegate to unified ToolCallResponseHandler (handles single or multiple tools)
            ToolCallResponseHandler handler = new ToolCallResponseHandler();
            String outcome = handler.handle(context);

            System.debug(LoggingLevel.INFO, logPrefix + 'ToolCallResponseHandler returned outcome: ' + outcome);

            // Multi-LLM optimization: If handler returns IMMEDIATE_FOLLOWUP, continue in same transaction
            if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Handler signaled immediate follow-up, entering multi-LLM loop');

                // Enter multi-LLM loop (starting at turn 2 since turn 1 was the initial parallel tools)
                return executeMultiLLMLoop(
                    executionId,
                    userId,
                    recordId,
                    turnIdentifier,
                    2, // Start at turn 2
                    decisionLogger,
                    txnCtx,
                    logPrefix
                );
            }

            // Not continuing with immediate follow-up - commit buffer and decision steps
            if (txnCtx.isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();
            }
            decisionLogger.commitSteps();

            if (outcome == OrchestrationService.OUTCOME_QUEUED_ACTION || outcome == OrchestrationService.OUTCOME_QUEUED_FOLLOWUP) {
                return createProcessingResult(executionId, executionUrl, 'Processing tools');
            } else if (outcome == OrchestrationService.OUTCOME_COMPLETED) {
                return createProcessingResult(executionId, executionUrl, 'Completed');
            } else {
                return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Parallel tool execution failed with outcome: ' + outcome);
            }
        } catch (Exception e) {
            // Ensure buffer is committed on error
            try {
                if (txnCtx.isDeferredDMLMode()) {
                    TransactionContext.getInstance().commitBuffer();
                    txnCtx.disableDeferredDMLMode();
                }
            } catch (Exception bufferEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to commit buffer on exception: ' + bufferEx.getMessage());
            }
            String errorMsg = 'Failed to handle parallel tools: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + e.getStackTraceString());
            markExecutionFailed(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMsg);
        }
    }
    // ===================================================================================
    // MAIN EXECUTION METHOD
    // ===================================================================================

    /**
     * @description
     * Executes the iterative agentic pattern for agents with 2+ capabilities.
     *
     * Note: Pre-existing DML detection is handled centrally by DirectRuntimeService
     * before routing to this specialized runtime.
     *
     * @param input The primary text input for the task
     * @param recordId The record context for the task (can be null)
     * @param userId The user ID
     * @param turnIdentifier The turn identifier
     * @param capabilities List of capabilities (passed from DirectRuntimeService)
     * @param existingExecutionId Optional execution ID to reuse (for pipeline step agents or bulk context)
     * @return DirectExecutionResult with executionId and Processing status
     */
    public DirectExecutionResult execute(
        String input,
        Id recordId,
        Id userId,
        String turnIdentifier,
        List<AgentCapability__c> capabilities,
        Id existingExecutionId
    ) {
        Long startTime = System.currentTimeMillis();
        String logPrefix = '[AsyncFunctionOrch Agent:' + agentDefinition.DeveloperName__c + ' Turn:' + turnIdentifier.left(8) + '] ';

        // --- MULTI-LLM OPTIMIZATION TRACKING ---
        // Deferred DML mode is enabled only if we actually enter the multi-LLM loop.
        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.incrementLLMCallCount();
        txnCtx.resetTurnSafetyTracking();

        // Track whether a pre-existing execution record was provided (pipeline/bulk context)
        // If true, multi-LLM optimization can proceed. If false, follow-up LLM calls must use new transaction.
        txnCtx.setHasPreExistingExecution(existingExecutionId != null);

        try {
            // --- 1. PREPARE FOR INITIAL LLM CALL (NO DML YET) ---
            System.debug(LoggingLevel.INFO, logPrefix + 'Starting iterative agentic execution');

            // Enable deferred DML mode for multi-LLM optimization
            // This allows the first LLM call to cache its system prompt and context
            // for reuse in subsequent LLM calls within the same transaction
            if (existingExecutionId != null) {
                txnCtx.enableDeferredDMLMode();
                System.debug(LoggingLevel.DEBUG, logPrefix + 'Enabled deferred DML mode for multi-LLM optimization');
            }

            LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
            userMessageData.role = AIAgentConstants.ROLE_USER;
            userMessageData.content = input;

            // Use existing execution ID if provided, otherwise temporary ID for read-only context gathering
            Id executionIdForContext = (existingExecutionId != null) ? existingExecutionId : '000000000000AAA';

            // Buffer storyboard events before the real execution exists, then rebind later.
            IDecisionStepLogger.ILogger decisionLogger = existingExecutionId != null
                ? IDecisionStepLogger.create(executionIdForContext, turnIdentifier, userId)
                : IDecisionStepLogger.createForAgent(agentDefinition.Id, turnIdentifier, userId);

            // Get user and agent names for dynamic description
            String userName = getUserName(userId);
            String agentDisplayName = getAgentName(agentDefinition.Id); // Use actual agent name instead of developer name
            if (String.isNotBlank(input)) {
                decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ input, userName, agentDisplayName });
            }

            LLMInteractionService interactionService = new LLMInteractionService(
                executionIdForContext,
                userId,
                agentDefinition.Id,
                llmConfig.Id,
                turnIdentifier,
                1,
                recordId,
                false,
                decisionLogger
            );

            // --- 2. PERFORM INITIAL LLM CALLOUT (NO DML YET) ---
            System.debug(LoggingLevel.INFO, logPrefix + 'Calling LLM for initial turn');
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(userMessageData);

            // Validate LLM result
            Boolean hasContent = String.isNotBlank(llmResult?.providerResult?.content);
            Boolean hasToolCalls = (llmResult?.providerResult?.requestedActions != null && !llmResult.providerResult.requestedActions.isEmpty());

            if (llmResult == null || !llmResult.isSuccess || (!hasContent && !hasToolCalls)) {
                // Commit decision steps if we have a real execution ID (e.g., from pipeline or bulk context)
                commitBufferedDataOnFailure(existingExecutionId, decisionLogger, logPrefix);
                return createFailureResult(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, llmResult?.failureReason ?? 'LLM returned an empty or failed response.');
            }

            Long llmProcessingTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'LLM call succeeded in ' + llmProcessingTime + 'ms.');

            // --- 3. CHECK RESPONSE TYPE ---
            if (!hasToolCalls) {
                // Text response - handle based on execution context
                System.debug(LoggingLevel.INFO, logPrefix + 'Text response received');

                // Commit buffered DML before final processing
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();

                if (existingExecutionId != null) {
                    // BULK/PIPELINE CONTEXT: Must update execution record to trigger chaining
                    System.debug(LoggingLevel.INFO, logPrefix + 'Bulk/pipeline context - updating execution record to Completed');

                    try {
                        // Update decision logger with real execution ID
                        decisionLogger.updateExecutionId(existingExecutionId);

                        // Create user input step for audit trail
                        ExecutionStepService stepSvc = new ExecutionStepService();
                        stepSvc.createUserInputStep(existingExecutionId, input, turnIdentifier, 1);

                        // Create LLM response step
                        stepSvc.createAgentResponseStepWithTokens(
                            existingExecutionId,
                            llmResult.providerResult.content,
                            turnIdentifier,
                            1, // turnCount
                            llmResult.providerResult.promptTokens,
                            llmResult.providerResult.completionTokens,
                            llmResult.providerResult.totalTokens,
                            llmResult.providerResult.modelIdentifier,
                            llmResult.providerResult.llmCalloutDurationMs
                        );

                        // Log final response - pass response content
                        decisionLogger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ llmResult.providerResult.content });
                        decisionLogger.commitSteps();

                        // Mark execution as completed - CRITICAL for trigger chaining
                        AgentStateService agentStateSvc = new AgentStateService();
                        agentStateSvc.completeTurnSuccessfully(existingExecutionId, turnIdentifier, null, logPrefix);

                        System.debug(LoggingLevel.INFO, logPrefix + 'Execution marked as Completed - trigger will handle chaining');

                        return createSuccessResult(
                            llmResult.providerResult.content,
                            existingExecutionId,
                            llmResult.providerResult.totalTokens,
                            llmProcessingTime
                        );
                    } catch (Exception e) {
                        System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution record: ' + e.getMessage());
                        // Mark execution as failed so it doesn't remain stuck
                        markExecutionFailed(
                            existingExecutionId,
                            turnIdentifier,
                            'Failed to complete text response: ' + e.getMessage(),
                            AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                            logPrefix
                        );
                        return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Failed to complete text response: ' + e.getMessage());
                    }
                } else {
                    // STANDALONE CONTEXT: Return immediately without creating execution record (performance optimization)
                    System.debug(LoggingLevel.INFO, logPrefix + 'Standalone context - returning immediately without execution record');
                    return createSuccessResult(
                        llmResult.providerResult.content,
                        null, // no execution record for immediate text responses
                        llmResult.providerResult.totalTokens,
                        llmProcessingTime
                    );
                }
            }

            // --- 4. TOOL CALL(S) DETECTED - CHECK IF WE CAN EXECUTE SYNC TOOLS NOW ---
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool call(s) detected (' + llmResult.providerResult.requestedActions.size() + ').');

            // Parse first tool call
            Map<String, String> firstToolCall = llmResult.providerResult.requestedActions[0];
            String toolCallId = firstToolCall.get('id');
            String toolName = firstToolCall.get('name');
            String toolArgs = firstToolCall.get('arguments');

            // Lookup capability
            AgentCapability__c capability = getCachedCapability(toolName);

            if (capability == null) {
                commitBufferedDataOnFailure(existingExecutionId, decisionLogger, logPrefix);
                return createFailureResult(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Tool "' + toolName + '" is not configured for this agent.');
            }

            Boolean isAsyncTool = capability.RunAsynchronously__c == true || 'Agent'.equalsIgnoreCase(capability.ImplementationType__c);
            Boolean isSingleTool = (llmResult.providerResult.requestedActions.size() == 1);

            // For SYNC tools, execute NOW (before any DML) to avoid callout-after-DML
            ActionOutcome toolOutcome = null;
            Long toolExecutionTime = 0;

            if (!isAsyncTool && isSingleTool) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Sync tool detected. Executing before DML to avoid governor limits.');

                // Capture pre-tool limits for multi-LLM optimization safety check
                txnCtx.capturePreToolLimits();

                ActionContext actionContext = new ActionContext(
                    null, // executionId not created yet
                    userId,
                    userId,
                    recordId,
                    agentDefinition.Id,
                    capability.Id,
                    capability.ImplementationDetail__c,
                    turnIdentifier,
                    1,
                    'DirectAsyncRuntimeService'
                );

                Long toolStartTime = System.currentTimeMillis();
                try {
                    toolOutcome = new CapabilityExecutionService().executeSingleAction(capability, toolArgs, actionContext);
                    toolExecutionTime = System.currentTimeMillis() - toolStartTime;
                    System.debug(LoggingLevel.INFO, logPrefix + 'Sync tool executed in ' + toolExecutionTime + 'ms. Success: ' + toolOutcome.isSuccess);
                } catch (Exception toolEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Tool execution failed: ' + toolEx.getMessage());
                    toolOutcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, 'Tool execution failed: ' + toolEx.getMessage());
                    toolExecutionTime = System.currentTimeMillis() - toolStartTime;
                }

                // Log tool safety check result for observability
                Boolean toolPerformedDMLOrCallout = txnCtx.toolPerformedDMLOrCallout();
                System.debug(LoggingLevel.INFO, logPrefix + 'Tool safety check: performedDMLOrCallout=' + toolPerformedDMLOrCallout);

                // FAIL-FAST CHECK: If tool failed and should fail-fast, halt execution immediately
                if (OrchestrationService.shouldFailFast(capability, agentDefinition, toolOutcome, existingExecutionId, logPrefix)) {
                    // Commit buffered DML before fail-fast handling
                    TransactionContext.getInstance().commitBuffer();
                    txnCtx.disableDeferredDMLMode();

                    // Get or create execution record for audit trail
                    Id failedExecutionId;

                    if (existingExecutionId != null) {
                        // CRITICAL: Reuse existing execution (pipeline step or sub-agent scenario)
                        // Don't create duplicate execution records!
                        failedExecutionId = existingExecutionId;
                        System.debug(LoggingLevel.WARN, logPrefix + 'Fail-fast triggered - reusing existing execution: ' + failedExecutionId);
                    } else {
                        // Create new execution record for standalone execution
                        AgentStateService execSvc = new AgentStateService();
                        String executionLabel = 'Function - ' + Datetime.now().format('MM/dd HH:mm:ss');
                        failedExecutionId = execSvc.createExecution(
                            RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                            agentDefinition.Id,
                            'API', // TriggerSource - valid picklist value (function called programmatically)
                            'Conversational Function: ' +
                            executionLabel, // TriggerPayload - descriptive info
                            recordId,
                            userId,
                            null
                        );
                        System.debug(LoggingLevel.WARN, logPrefix + 'Fail-fast triggered - created new execution: ' + failedExecutionId);
                    }

                    // Update decision logger with real execution ID before logging error
                    decisionLogger.updateExecutionId(failedExecutionId);

                    // Log the failure decision
                    ExecutionStepService stepSvc = new ExecutionStepService();
                    stepSvc.createErrorStep(
                        failedExecutionId,
                        'Tool execution failed (fail-fast triggered): ' + toolOutcome.errorMessage,
                        toolOutcome.errorCode,
                        turnIdentifier,
                        1
                    );

                    // Commit decision steps collected so far
                    if (decisionLogger != null) {
                        decisionLogger.commitSteps();
                    }

                    // Mark execution as failed
                    markExecutionFailed(failedExecutionId, turnIdentifier, toolOutcome.errorMessage, toolOutcome.errorCode, logPrefix);

                    // Return failure result (don't continue to follow-up LLM)
                    return createFailureResult(toolOutcome.errorCode, toolOutcome.errorMessage);
                }

                // =====================================================================================
                // MULTI-LLM OPTIMIZATION: Check if we can continue with immediate follow-up
                // =====================================================================================
                Boolean canContinueImmediateFollowUp = false;
                if (existingExecutionId != null) {
                    txnCtx.enableDeferredDMLMode();
                    canContinueImmediateFollowUp = txnCtx.canContinueWithImmediateFollowUp();
                    if (!canContinueImmediateFollowUp) {
                        txnCtx.disableDeferredDMLMode();
                    }
                }

                if (canContinueImmediateFollowUp) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Tool is safe, can make another LLM call in same transaction');

                    // Get or create execution record NOW (before multi-LLM loop)
                    // We need the execution ID to create tool steps
                    Id executionId = getOrCreateExecutionRecord(existingExecutionId, capabilities, recordId, userId, turnIdentifier, logPrefix);

                    // Update decision logger with real execution ID
                    decisionLogger.updateExecutionId(executionId);

                    // Create user input step (buffered)
                    ExecutionStepService stepSvc = new ExecutionStepService();
                    stepSvc.createUserInputStep(executionId, input, turnIdentifier, 1);

                    // Create tool call and result steps (buffered) for the first tool
                    stepSvc.createToolCallStep(
                        executionId,
                        toolCallId,
                        toolName,
                        toolArgs,
                        turnIdentifier,
                        1, // turnCount
                        llmResult.providerResult.promptTokens,
                        llmResult.providerResult.completionTokens,
                        llmResult.providerResult.totalTokens,
                        llmResult.providerResult.modelIdentifier,
                        llmResult.providerResult.llmCalloutDurationMs,
                        null, // capabilityId
                        null,
                        null,
                        null,
                        false
                    );

                    // Log tool execution result - pass domain objects
                    decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, toolOutcome, toolExecutionTime });

                    String toolResultJson = OrchestrationService.serializeActionOutcome(toolOutcome, logPrefix);
                    stepSvc.createToolResultStep(
                        executionId,
                        toolCallId,
                        toolName,
                        toolResultJson,
                        turnIdentifier,
                        1,
                        toolExecutionTime,
                        false, // isAsyncToolExecution
                        null, // capabilityId
                        !toolOutcome.isSuccess, // isError
                        false
                    );

                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Created buffered tool steps, entering multi-LLM loop');

                    // Enter multi-LLM loop (similar to FollowUpLLMEngine)
                    return executeMultiLLMLoop(
                        executionId,
                        userId,
                        recordId,
                        turnIdentifier,
                        2, // Start at turn 2 (turn 1 was the initial LLM call)
                        decisionLogger,
                        txnCtx,
                        logPrefix
                    );
                }
            }

            // --- 5. GET OR CREATE EXECUTION RECORD (AFTER ALL CALLOUTS) ---
            Id executionId = getOrCreateExecutionRecord(existingExecutionId, capabilities, recordId, userId, turnIdentifier, logPrefix);

            // Update decision logger with real execution ID
            decisionLogger.updateExecutionId(executionId);

            // If we started with a placeholder ID (no pre-existing execution), patch every
            // buffered SObject that still references it so commitBuffer() succeeds.
            if (existingExecutionId == null && executionIdForContext != executionId) {
                TransactionContext.getInstance().replaceExecutionId(executionIdForContext, executionId);
            }

            // Create user input step
            ExecutionStepService stepSvc = new ExecutionStepService();
            stepSvc.createUserInputStep(executionId, input, turnIdentifier, 1);

            // Build execution URL
            String executionUrl = '/lightning/r/AgentExecution__c/' + executionId + '/view';

            // --- 6. HANDLE TOOL EXECUTION RESULTS ---
            if (!isAsyncTool && isSingleTool && toolOutcome != null) {
                // Single sync tool already executed - commit and enqueue follow-up
                // (Multi-LLM optimization was already checked above and didn't apply)
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();

                return handleSyncToolResult(
                    executionId,
                    userId,
                    recordId,
                    turnIdentifier,
                    toolCallId,
                    toolName,
                    toolArgs,
                    capability,
                    toolOutcome,
                    toolExecutionTime,
                    llmResult,
                    executionUrl,
                    decisionLogger,
                    logPrefix
                );
            } else {
                // Async tool or multiple tools - keep deferred mode for multi-LLM optimization
                // ToolCallResponseHandler will check canContinueWithImmediateFollowUp() after tool execution
                return handleAsyncToolCalls(executionId, userId, recordId, turnIdentifier, llmResult, decisionLogger, executionUrl, logPrefix, txnCtx);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in iterative pattern: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Ensure buffer is committed even on exception
            try {
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();
            } catch (Exception bufferEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to commit buffer on exception: ' + bufferEx.getMessage());
            }

            // Mark execution as failed if we have an existing execution ID (pipeline/bulk scenarios)
            // This ensures proper status for resume functionality and error visibility
            if (existingExecutionId != null) {
                try {
                    markExecutionFailed(
                        existingExecutionId,
                        turnIdentifier,
                        'Unexpected error: ' + e.getMessage(),
                        AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                        logPrefix
                    );
                } catch (Exception failEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + failEx.getMessage());
                }
            }

            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, e.getMessage());
        }
    }

    /**
     * @description Gets or creates an execution record for the agent run.
     * Handles both existing execution (pipeline/bulk) and new execution scenarios.
     */
    private Id getOrCreateExecutionRecord(
        Id existingExecutionId,
        List<AgentCapability__c> capabilities,
        Id recordId,
        Id userId,
        String turnIdentifier,
        String logPrefix
    ) {
        Id executionId;

        if (existingExecutionId != null) {
            // Reuse existing execution ID (pipeline step, sub-agent, or bulk execution)
            executionId = existingExecutionId;
            System.debug(LoggingLevel.INFO, logPrefix + 'Reusing existing execution record: ' + executionId);

            if (capabilities.size() <= 1) {
                update new AgentExecution__c(Id = executionId, IsToolTerminatingMode__c = true);
                System.debug(LoggingLevel.INFO, logPrefix + 'Set IsToolTerminatingMode=true for existing execution');
            }
        } else {
            // Create new execution record
            System.debug(LoggingLevel.INFO, logPrefix + 'Creating new execution record.');
            AgentStateService execSvc = new AgentStateService();
            String executionLabel = 'Function - ' + Datetime.now().format('MM/dd HH:mm:ss');
            String execTriggerPayload = String.isNotBlank(this.triggerPayload) ? this.triggerPayload : 'Conversational Function: ' + executionLabel;

            executionId = execSvc.createExecution(
                RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                agentDefinition.Id,
                'API',
                execTriggerPayload,
                recordId,
                userId,
                null
            );
            System.debug(LoggingLevel.INFO, logPrefix + 'Created execution record: ' + executionId);

            // Merge the optional turn-identifier and tool-terminating-mode updates into a
            // single DML statement to reduce from up to 3 operations down to 2 (INSERT + UPDATE).
            AgentExecution__c postCreate = new AgentExecution__c(Id = executionId);
            Boolean needsUpdate = false;
            if (String.isNotBlank(turnIdentifier)) {
                postCreate.CurrentTurnIdentifier__c = turnIdentifier;
                needsUpdate = true;
            }
            if (capabilities.size() <= 1) {
                postCreate.IsToolTerminatingMode__c = true;
                needsUpdate = true;
                System.debug(LoggingLevel.INFO, logPrefix + 'Set IsToolTerminatingMode=true');
            }
            if (needsUpdate) {
                update postCreate;
            }
        }

        return executionId;
    }

    /**
     * @description Executes the multi-LLM optimization loop.
     * Similar to FollowUpLLMEngine but starting after the first tool execution.
     * Continues making LLM calls while tools are safe and under the call limit.
     */
    private DirectExecutionResult executeMultiLLMLoop(
        Id executionId,
        Id userId,
        Id recordId,
        String turnIdentifier,
        Integer startTurnCount,
        IDecisionStepLogger.ILogger decisionLogger,
        TransactionContext txnCtx,
        String logPrefix
    ) {
        String executionUrl = '/lightning/r/AgentExecution__c/' + executionId + '/view';
        OrchestrationService orchestrationSvc = new OrchestrationService();
        Integer currentTurnCount = startTurnCount;
        String outcome;

        try {
            // Multi-LLM loop: Continue making LLM calls while conditions allow
            do {
                // Prepare for next LLM call
                txnCtx.incrementLLMCallCount();
                txnCtx.resetTurnSafetyTracking();

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Multi-LLM optimization: Making LLM call ' + txnCtx.getLLMCallCount() + ' (turn ' + currentTurnCount + ')'
                );

                // Create LLM interaction service for this turn
                LLMInteractionService interactionService = new LLMInteractionService(
                    executionId,
                    userId,
                    agentDefinition.Id,
                    llmConfig.Id,
                    turnIdentifier,
                    currentTurnCount,
                    recordId,
                    false, // isFinalErrorTurn
                    decisionLogger
                );

                // Make LLM call (tool results are in history via buffered steps)
                LLMInteractionService.LLMInteractionResult llmInteractionResult = interactionService.prepareAndCallLLM(null);

                // Process the LLM result using OrchestrationService (handles tool execution, HITL, etc.)
                outcome = orchestrationSvc.processLlmResult(
                    llmInteractionResult,
                    executionId,
                    userId,
                    userId, // executionUserId
                    agentDefinition.Id,
                    turnIdentifier,
                    currentTurnCount,
                    null, // userMessageDataForTurn - null for follow-up calls
                    recordId, // currentPageRecordId
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                // If immediate follow-up is needed, prepare for next iteration
                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Continuing with immediate follow-up (turn ' + currentTurnCount + ')');
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Multi-LLM loop completed. Final outcome: ' + outcome + ', Total LLM calls: ' + txnCtx.getLLMCallCount()
            );

            // Determine result based on final outcome
            if (outcome == OrchestrationService.OUTCOME_COMPLETED) {
                // Execution completed successfully
                return createProcessingResult(executionId, executionUrl, 'Completed');
            } else {
                // Execution still in progress (queued for async processing)
                return createProcessingResult(executionId, executionUrl, 'Processing');
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Multi-LLM loop error: ' + ex.getMessage() + '\n' + ex.getStackTraceString());

            // Mark execution as failed
            try {
                markExecutionFailed(executionId, turnIdentifier, ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + failEx.getMessage());
            }

            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex.getMessage());
        } finally {
            // Ensure buffer is committed and deferred mode is disabled
            if (txnCtx.isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                txnCtx.disableDeferredDMLMode();
            }

            // Commit decision steps
            if (decisionLogger != null) {
                decisionLogger.commitSteps();
            }

            // Clear LLM request cache for this execution
            LLMInteractionService.clearRequestCache(executionId);

            System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM loop cleanup complete.');
        }
    }

    /**
     * @description Helper to commit buffered data on failure scenarios
     */
    private void commitBufferedDataOnFailure(Id existingExecutionId, IDecisionStepLogger.ILogger decisionLogger, String logPrefix) {
        try {
            TransactionContext.getInstance().commitBuffer();
            TransactionContext.getInstance().disableDeferredDMLMode();

            if (existingExecutionId != null && decisionLogger != null) {
                decisionLogger.commitSteps();
                System.debug(LoggingLevel.INFO, logPrefix + 'Committed decision steps for failed LLM call');
            }
        } catch (Exception commitEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to commit buffered data: ' + commitEx.getMessage());
        }
    }

    /**
     * Helper method to get user name for dynamic descriptions
     *
     * @param userId The user ID
     * @return User name or fallback
     */
    private String getUserName(Id userId) {
        if (userId == null) {
            return 'User';
        }
        if (userNameCache.containsKey(userId)) {
            return userNameCache.get(userId);
        }
        try {
            User user = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
            userNameCache.put(userId, user.Name);
            return user.Name;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not retrieve user name for ID: ' + userId + '. Error: ' + e.getMessage());
        }
        return 'User';
    }

    /**
     * Helper method to get agent name for dynamic descriptions
     *
     * @param agentDefinitionId The agent definition ID
     * @return Agent name or fallback
     */
    private String getAgentName(Id agentDefinitionId) {
        return AIAgentConfigService.getAgentName(agentDefinitionId);
    }
}
