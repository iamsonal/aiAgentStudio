/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ParallelToolCallHandler manages the execution of multiple tool calls from an LLM response
 * and coordinates result gathering for parallel execution.
 * 
 * It handles the complex orchestration of:
 * 1. Executing synchronous tools immediately in the same transaction
 * 2. Creating execution step records for all tool calls
 * 3. Queuing asynchronous tools for separate transaction execution
 * 4. Tracking completion of async tools and triggering follow-up LLM calls
 * 5. Determining when all async tools have completed
 *
 * This class ensures proper transaction boundaries and maintains execution order
 * while maximizing parallel execution where possible.
 */
public class ParallelToolCallHandler {
    /**
     * @description
     * Data structure to hold information about a tool call request
     */
    public class ToolCallRequest {
        public String toolCallId;
        public String toolName;
        public String toolArguments;
        public AgentCapability__c capability;
        public Boolean isAsync;
        public Integer executionOrder;

        public ToolCallRequest(
            String toolCallId,
            String toolName,
            String toolArguments,
            AgentCapability__c capability,
            Boolean isAsync,
            Integer executionOrder
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.toolArguments = toolArguments;
            this.capability = capability;
            this.isAsync = isAsync;
            this.executionOrder = executionOrder;
        }
    }

    /**
     * @description
     * Data structure to hold the result of a tool execution
     */
    public class ToolExecutionResult {
        public String toolCallId;
        public String toolName;
        public ActionOutcome outcome;
        public Long processingTime;
        public Boolean isAsync;
        public Integer executionOrder;

        public ToolExecutionResult(
            String toolCallId,
            String toolName,
            ActionOutcome outcome,
            Long processingTime,
            Boolean isAsync,
            Integer executionOrder
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.outcome = outcome;
            this.processingTime = processingTime;
            this.isAsync = isAsync;
            this.executionOrder = executionOrder;
        }
    }

    /**
     * @description
     * Main entry point for handling multiple tool calls from an LLM response.
     *
     * @param context The orchestration context
     * @param requestedActions List of tool call requests from LLM
     * @param decisionLogger The decision logger for tracking
     * @return String outcome constant for orchestration flow
     */
    public static String handleParallelToolCalls(
        OrchestrationContext context,
        List<Map<String, String>> requestedActions,
        AgentDecisionStepLogger decisionLogger
    ) {
        String logPrefix = context.logPrefix + '[ParallelToolHandler] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting parallel tool call handling for ' + requestedActions.size() + ' tools');

        try {
            // Step 1: Parse and validate all tool calls
            List<ToolCallRequest> toolRequests = parseAndValidateToolCalls(context, requestedActions, decisionLogger, logPrefix);

            if (toolRequests.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'No valid tool calls found after parsing');
                return OrchestrationService.OUTCOME_FAILED;
            }

            // Step 2: Create execution step records for all tool calls
            createToolCallExecutionSteps(context, toolRequests, decisionLogger, logPrefix);

            // Step 3: Execute synchronous tools immediately in same transaction
            List<ToolExecutionResult> syncResults = executeSynchronousTools(context, toolRequests, decisionLogger, logPrefix);

            // Step 4: Create execution step records for sync tool results
            createToolResultExecutionSteps(context, syncResults, decisionLogger, logPrefix);

            // Step 5: Queue asynchronous tools for separate transaction execution
            List<ToolCallRequest> asyncTools = getAsyncTools(toolRequests);
            if (!asyncTools.isEmpty()) {
                queueAsyncTools(context, asyncTools, decisionLogger, logPrefix);
            }

            // Step 6: Determine next orchestration step
            return determineNextOrchestrationStep(context, syncResults, asyncTools, logPrefix);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in parallel tool call handling: ' + e.getMessage() + '\n' + e.getStackTraceString());
            context.turnLifecycleSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Parallel tool call handling failed: ' + e.getMessage(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }
    }

    /**
     * @description
     * Parses and validates all tool call requests from the LLM response
     */
    private static List<ToolCallRequest> parseAndValidateToolCalls(
        OrchestrationContext context,
        List<Map<String, String>> requestedActions,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        List<ToolCallRequest> toolRequests = new List<ToolCallRequest>();

        for (Integer i = 0; i < requestedActions.size(); i++) {
            Map<String, String> actionMap = requestedActions[i];

            try {
                // Parse tool call details
                String toolCallId = actionMap.get('id');
                String toolName = actionMap.get('name');
                String toolArguments = actionMap.get('arguments');

                if (String.isBlank(toolCallId) || String.isBlank(toolName)) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping malformed tool call at index ' + i + ': missing id or name');
                    continue;
                }

                // Lookup and validate capability
                AgentCapability__c capability = AIAgentConfigService.getCapability(context.agentDefinitionId, toolName);
                if (capability == null) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping tool call ' + toolName + ': capability not found');
                    continue;
                }

                // Determine if tool should run asynchronously
                Boolean isAsync = capability.RunAsynchronously__c == true;

                ToolCallRequest toolRequest = new ToolCallRequest(toolCallId, toolName, toolArguments, capability, isAsync, i + 1);
                toolRequests.add(toolRequest);

                System.debug(LoggingLevel.INFO, logPrefix + 'Parsed tool call ' + (i + 1) + ': ' + toolName + ' (async=' + isAsync + ')');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error parsing tool call at index ' + i + ': ' + e.getMessage());
                continue;
            }
        }

        // Log the parallel tool execution plan
        if (decisionLogger != null) {
            Map<String, Object> planData = new Map<String, Object>{
                'totalTools' => toolRequests.size(),
                'syncTools' => getSyncTools(toolRequests).size(),
                'asyncTools' => getAsyncTools(toolRequests).size(),
                'tools' => new List<Map<String, Object>>()
            };

            for (ToolCallRequest req : toolRequests) {
                ((List<Map<String, Object>>) planData.get('tools'))
                    .add(
                        new Map<String, Object>{
                            'name' => req.toolName,
                            'id' => req.toolCallId,
                            'isAsync' => req.isAsync,
                            'order' => req.executionOrder
                        }
                    );
            }

            decisionLogger.logToolExecution(
                'Parallel Tool Execution Plan',
                'LLM requested ' + toolRequests.size() + ' tools for parallel execution',
                JSON.serialize(planData),
                null,
                true,
                null,
                null
            );
        }

        return toolRequests;
    }

    /**
     * @description
     * Creates execution step records for all tool calls
     */
    private static void createToolCallExecutionSteps(
        OrchestrationContext context,
        List<ToolCallRequest> toolRequests,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        ExecutionStepService executionStepService = new ExecutionStepService();

        for (ToolCallRequest toolRequest : toolRequests) {
            try {
                executionStepService.createToolCallStep(
                    context.executionId,
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    toolRequest.toolArguments,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    context.llmResult.providerResult.promptTokens,
                    context.llmResult.providerResult.completionTokens,
                    context.llmResult.providerResult.totalTokens,
                    context.llmResult.providerResult.modelIdentifier,
                    context.llmResult.providerResult.llmCalloutDurationMs
                );

                System.debug(LoggingLevel.DEBUG, logPrefix + 'Created execution step for tool call: ' + toolRequest.toolName);
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Failed to create execution step for tool ' + toolRequest.toolName + ': ' + e.getMessage()
                );
                // Continue with other tools even if one fails
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Created execution steps for ' + toolRequests.size() + ' tool calls');
    }

    /**
     * @description
     * Executes all synchronous tools immediately in the same transaction
     */
    private static List<ToolExecutionResult> executeSynchronousTools(
        OrchestrationContext context,
        List<ToolCallRequest> toolRequests,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        List<ToolCallRequest> syncTools = getSyncTools(toolRequests);
        List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();

        if (syncTools.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No synchronous tools to execute');
            return syncResults;
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' synchronous tools');

        for (ToolCallRequest toolRequest : syncTools) {
            try {
                Long startTime = System.currentTimeMillis();

                // Build action execution context
                ActionContext actionContext = new ActionContext(
                    context.executionId,
                    context.originalUserId,
                    context.executionUserId,
                    context.currentPageRecordId,
                    context.agentDefinitionId,
                    toolRequest.capability.Id,
                    toolRequest.capability.ImplementationDetail__c,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    'ParallelSync'
                );

                // Execute the tool
                ActionOutcome outcome = context.actionExecSvc.executeSingleAction(toolRequest.capability, toolRequest.toolArguments, actionContext);

                Long processingTime = System.currentTimeMillis() - startTime;

                ToolExecutionResult result = new ToolExecutionResult(
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    outcome,
                    processingTime,
                    false, // isAsync
                    toolRequest.executionOrder
                );

                syncResults.add(result);

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Executed sync tool ' + toolRequest.toolName + ' in ' + processingTime + 'ms (success=' + outcome.isSuccess + ')'
                );

                // Log the tool execution result
                if (decisionLogger != null) {
                    decisionLogger.logToolResult(
                        'Synchronous Tool Executed',
                        'Tool ' + toolRequest.toolName + ' executed synchronously',
                        JSON.serialize(outcome),
                        processingTime,
                        outcome.isSuccess,
                        outcome.errorCode,
                        outcome.errorMessage
                    );
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing sync tool ' + toolRequest.toolName + ': ' + e.getMessage());

                // Create failure result
                ActionOutcome failureOutcome = ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    'Synchronous tool execution failed: ' + e.getMessage()
                );

                ToolExecutionResult failureResult = new ToolExecutionResult(
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    failureOutcome,
                    System.currentTimeMillis() - System.currentTimeMillis(),
                    false,
                    toolRequest.executionOrder
                );

                syncResults.add(failureResult);
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Completed execution of ' + syncResults.size() + ' synchronous tools');
        return syncResults;
    }

    /**
     * @description
     * Creates execution step records for synchronous tool results
     */
    private static void createToolResultExecutionSteps(
        OrchestrationContext context,
        List<ToolExecutionResult> syncResults,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        ExecutionStepService executionStepService = new ExecutionStepService();

        for (ToolExecutionResult result : syncResults) {
            try {
                String resultJsonForStorage = OrchestrationService.serializeActionOutcome(result.outcome, logPrefix);

                executionStepService.createToolResultStep(
                    context.executionId,
                    result.toolCallId,
                    result.toolName,
                    resultJsonForStorage,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    result.processingTime,
                    false // isAsyncToolExecution - synchronous execution
                );

                System.debug(LoggingLevel.DEBUG, logPrefix + 'Created execution step for sync tool result: ' + result.toolName);
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Failed to create execution step for sync tool result ' + result.toolName + ': ' + e.getMessage()
                );
                // Continue with other results even if one fails
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Created execution steps for ' + syncResults.size() + ' sync tool results');
    }

    /**
     * @description
     * Queues asynchronous tools for separate transaction execution
     */
    private static void queueAsyncTools(
        OrchestrationContext context,
        List<ToolCallRequest> asyncTools,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Queuing ' + asyncTools.size() + ' asynchronous tools');

        // Pause the turn for async action processing
        context.turnLifecycleSvc.pauseForAsyncAction(context.executionId, context.turnIdentifier, null, 'Multiple Async Tools', logPrefix);

        // Queue each async tool individually
        for (ToolCallRequest toolRequest : asyncTools) {
            try {
                context.dispatchSvc.enqueueAsyncAction(
                    context.executionId,
                    context.originalUserId,
                    context.agentDefinitionId,
                    null, // savedAssistantMessageId - not needed for parallel execution
                    toolRequest.toolCallId,
                    toolRequest.toolArguments,
                    toolRequest.capability,
                    context.currentPageRecordId,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    logPrefix
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'Queued async tool: ' + toolRequest.toolName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue async tool ' + toolRequest.toolName + ': ' + e.getMessage());
                // Continue with other tools even if one fails to queue
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Queued ' + asyncTools.size() + ' asynchronous tools for execution');
    }

    /**
     * @description
     * Determines the next orchestration step based on execution results
     */
    private static String determineNextOrchestrationStep(
        OrchestrationContext context,
        List<ToolExecutionResult> syncResults,
        List<ToolCallRequest> asyncTools,
        String logPrefix
    ) {
        // If there are async tools, we need to wait for them to complete
        if (!asyncTools.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tools queued, returning QUEUED_ACTION outcome');
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }

        // All tools were synchronous, check results and continue
        Boolean hasFailures = false;
        for (ToolExecutionResult result : syncResults) {
            if (!result.outcome.isSuccess) {
                hasFailures = true;
                break;
            }
        }

        if (hasFailures) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Some sync tools failed, continuing with follow-up LLM call for error handling');
        } else {
            System.debug(LoggingLevel.INFO, logPrefix + 'All sync tools succeeded, continuing with follow-up LLM call');
        }

        // Commit the page context to the ledger BEFORE queuing follow-up LLM call
        // This ensures the initial record context (e.g., Case ID) is persisted across async boundaries
        if (context.currentPageRecordId != null) {
            try {
                context.contextManagerSvc.commitExecutionTurnContext(
                    context.executionId,
                    context.currentTurnCount,
                    context.currentPageRecordId,
                    null // no new record created by action
                );
                System.debug(LoggingLevel.INFO, logPrefix + 'Committed initial page context to ledger: ' + context.currentPageRecordId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit page context to ledger: ' + e.getMessage());
            }
        }

        // Queue follow-up LLM call to process results
        context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.executionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.executionId,
            context.originalUserId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false // isFinalErrorTurn
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    /**
     * @description
     * Helper method to get synchronous tools from the list
     */
    private static List<ToolCallRequest> getSyncTools(List<ToolCallRequest> toolRequests) {
        List<ToolCallRequest> syncTools = new List<ToolCallRequest>();
        for (ToolCallRequest tool : toolRequests) {
            if (!tool.isAsync) {
                syncTools.add(tool);
            }
        }
        return syncTools;
    }

    /**
     * @description
     * Helper method to get asynchronous tools from the list
     */
    private static List<ToolCallRequest> getAsyncTools(List<ToolCallRequest> toolRequests) {
        List<ToolCallRequest> asyncTools = new List<ToolCallRequest>();
        for (ToolCallRequest tool : toolRequests) {
            if (tool.isAsync) {
                asyncTools.add(tool);
            }
        }
        return asyncTools;
    }

    // ===================================================================================
    // PARALLEL RESULT GATHERING - Merged from ParallelResultGatherer
    // ===================================================================================

    /**
     * @description
     * Checks if all async tools for a given execution have completed and triggers
     * the final follow-up LLM call if so.
     *
     * This method should be called after each async tool completes to check if
     * all tools are done and it's time to gather results.
     *
     * @param executionId The execution ID to check
     * @param turnIdentifier The turn identifier
     * @param currentTurnCount The current turn count
     * @param logPrefix Logging prefix for debug output
     */
    public static void checkAndTriggerFinalFollowUp(Id executionId, String turnIdentifier, Integer currentTurnCount, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Checking if all async tools have completed for parallel execution');

            // Query for all tool call steps in this turn
            List<ExecutionStep__c> toolCallSteps = [
                SELECT Id, ToolCallId__c, ToolName__c, StepType__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND TurnIdentifier__c = :turnIdentifier
                    AND TurnCount__c = :currentTurnCount
                    AND StepType__c = 'ToolCall'
                ORDER BY CreatedDate
            ];

            // Query for all tool result steps in this turn
            List<ExecutionStep__c> toolResultSteps = [
                SELECT Id, ToolCallId__c, ToolName__c, StepType__c, IsAsyncToolExecution__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND TurnIdentifier__c = :turnIdentifier
                    AND TurnCount__c = :currentTurnCount
                    AND StepType__c = 'ToolResult'
                ORDER BY CreatedDate
            ];

            // Count async tool calls vs async tool results
            Integer asyncToolCalls = 0;
            Integer asyncToolResults = 0;

            // Count total tool calls (we need to check which ones are async)
            Set<String> allToolCallIds = new Set<String>();
            for (ExecutionStep__c step : toolCallSteps) {
                if (String.isNotBlank(step.ToolCallId__c)) {
                    allToolCallIds.add(step.ToolCallId__c);
                }
            }

            // Count async tool results
            for (ExecutionStep__c step : toolResultSteps) {
                if (step.IsAsyncToolExecution__c == true) {
                    asyncToolResults++;
                }
            }

            // We need to determine how many of the tool calls were async
            // This is a bit tricky since we don't store the async flag in the tool call step
            // For now, we'll use a different approach: check if we have more tool calls than sync results
            Integer syncToolResults = toolResultSteps.size() - asyncToolResults;
            asyncToolCalls = toolCallSteps.size() - syncToolResults;

            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Tool execution status - Total calls: ' +
                    toolCallSteps.size() +
                    ', Sync results: ' +
                    syncToolResults +
                    ', Async results: ' +
                    asyncToolResults +
                    ', Expected async calls: ' +
                    asyncToolCalls
            );

            // Check if all async tools have completed
            if (asyncToolCalls > 0 && asyncToolResults >= asyncToolCalls) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCall(executionId, turnIdentifier, currentTurnCount, logPrefix);
            } else {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Still waiting for async tools to complete. ' + (asyncToolCalls - asyncToolResults) + ' remaining.'
                );
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Error checking parallel execution completion: ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }

    /**
     * @description
     * Triggers the final follow-up LLM call to process all tool results
     */
    private static void triggerFinalFollowUpLLMCall(Id executionId, String turnIdentifier, Integer currentTurnCount, String logPrefix) {
        try {
            // Get the execution record to find the agent definition
            AgentExecution__c execution = [
                SELECT Id, AIAgentDefinition__c, User__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (execution == null) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Execution record not found: ' + executionId);
                return;
            }

            // Update execution status to indicate we're ready for final follow-up
            TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
            turnLifecycleSvc.resumeForFollowUpLlmCall(executionId, turnIdentifier, null, logPrefix);

            // Enqueue the final follow-up LLM call
            AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);
            orchestrationDispatchSvc.enqueueFollowUp(
                executionId,
                execution.User__c,
                execution.AIAgentDefinition__c,
                turnIdentifier,
                currentTurnCount + 1,
                logPrefix,
                false // isFinalErrorTurn
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Final follow-up LLM call queued for parallel execution completion');
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Error triggering final follow-up LLM call: ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }

    /**
     * @description
     * Alternative method that uses a more reliable approach to track async tool completion.
     * This method can be called from AsyncActionEngine after each async tool completes.
     *
     * @param executionId The execution ID
     * @param turnIdentifier The turn identifier
     * @param currentTurnCount The current turn count
     * @param completedToolCallId The tool call ID that just completed
     * @param logPrefix Logging prefix
     */
    public static void onAsyncToolCompleted(
        Id executionId,
        String turnIdentifier,
        Integer currentTurnCount,
        String completedToolCallId,
        String logPrefix
    ) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool completed: ' + completedToolCallId + '. Checking if all async tools are done.');

            // Query for all async tool results in this turn
            List<ExecutionStep__c> asyncToolResults = [
                SELECT Id, ToolCallId__c, ToolName__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND TurnIdentifier__c = :turnIdentifier
                    AND TurnCount__c = :currentTurnCount
                    AND StepType__c = 'ToolResult'
                    AND IsAsyncToolExecution__c = TRUE
                ORDER BY CreatedDate
            ];

            // Query for all tool calls in this turn to count total async tools
            List<ExecutionStep__c> allToolCalls = [
                SELECT Id, ToolCallId__c, ToolName__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND TurnIdentifier__c = :turnIdentifier
                    AND TurnCount__c = :currentTurnCount
                    AND StepType__c = 'ToolCall'
                ORDER BY CreatedDate
            ];

            // Query for sync tool results to determine how many tools were async
            List<ExecutionStep__c> syncToolResults = [
                SELECT Id, ToolCallId__c, ToolName__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND TurnIdentifier__c = :turnIdentifier
                    AND TurnCount__c = :currentTurnCount
                    AND StepType__c = 'ToolResult'
                    AND IsAsyncToolExecution__c = FALSE
                ORDER BY CreatedDate
            ];

            Integer totalAsyncTools = allToolCalls.size() - syncToolResults.size();
            Integer completedAsyncTools = asyncToolResults.size();

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Async tool completion status - Total async tools: ' + totalAsyncTools + ', Completed: ' + completedAsyncTools
            );

            if (totalAsyncTools > 0 && completedAsyncTools >= totalAsyncTools) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCall(executionId, turnIdentifier, currentTurnCount, logPrefix);
            } else {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Still waiting for ' + (totalAsyncTools - completedAsyncTools) + ' more async tools to complete.'
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in async tool completion check: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
