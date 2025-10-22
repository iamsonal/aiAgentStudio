/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ParallelResultGatherer handles the coordination of results from parallel tool execution.
 * It determines when all async tools have completed and triggers the final follow-up LLM call
 * to process all results together.
 *
 * This class ensures proper ordering and completion detection for parallel tool execution.
 */
public class ParallelResultGatherer {

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
    public static void checkAndTriggerFinalFollowUp(
        Id executionId,
        String turnIdentifier,
        Integer currentTurnCount,
        String logPrefix
    ) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Checking if all async tools have completed for parallel execution');

            // Query for all tool call steps in this turn
            List<ExecutionStep__c> toolCallSteps = [
                SELECT Id, ToolCallId__c, ToolName__c, StepType__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId
                AND TurnIdentifier__c = :turnIdentifier
                AND TurnCount__c = :currentTurnCount
                AND StepType__c = 'ToolCall'
                ORDER BY CreatedDate
            ];

            // Query for all tool result steps in this turn
            List<ExecutionStep__c> toolResultSteps = [
                SELECT Id, ToolCallId__c, ToolName__c, StepType__c, IsAsyncToolExecution__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId
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

            System.debug(LoggingLevel.INFO, logPrefix + 'Tool execution status - Total calls: ' + toolCallSteps.size() +
                        ', Sync results: ' + syncToolResults + ', Async results: ' + asyncToolResults +
                        ', Expected async calls: ' + asyncToolCalls);

            // Check if all async tools have completed
            if (asyncToolCalls > 0 && asyncToolResults >= asyncToolCalls) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCall(executionId, turnIdentifier, currentTurnCount, logPrefix);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Still waiting for async tools to complete. ' +
                            (asyncToolCalls - asyncToolResults) + ' remaining.');
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error checking parallel execution completion: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    /**
     * @description
     * Triggers the final follow-up LLM call to process all tool results
     */
    private static void triggerFinalFollowUpLLMCall(
        Id executionId,
        String turnIdentifier,
        Integer currentTurnCount,
        String logPrefix
    ) {
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
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error triggering final follow-up LLM call: ' + e.getMessage() + '\n' + e.getStackTraceString());
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
                WHERE AgentExecution__c = :executionId
                AND TurnIdentifier__c = :turnIdentifier
                AND TurnCount__c = :currentTurnCount
                AND StepType__c = 'ToolResult'
                AND IsAsyncToolExecution__c = true
                ORDER BY CreatedDate
            ];

            // Query for all tool calls in this turn to count total async tools
            List<ExecutionStep__c> allToolCalls = [
                SELECT Id, ToolCallId__c, ToolName__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId
                AND TurnIdentifier__c = :turnIdentifier
                AND TurnCount__c = :currentTurnCount
                AND StepType__c = 'ToolCall'
                ORDER BY CreatedDate
            ];

            // Query for sync tool results to determine how many tools were async
            List<ExecutionStep__c> syncToolResults = [
                SELECT Id, ToolCallId__c, ToolName__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId
                AND TurnIdentifier__c = :turnIdentifier
                AND TurnCount__c = :currentTurnCount
                AND StepType__c = 'ToolResult'
                AND IsAsyncToolExecution__c = false
                ORDER BY CreatedDate
            ];

            Integer totalAsyncTools = allToolCalls.size() - syncToolResults.size();
            Integer completedAsyncTools = asyncToolResults.size();

            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool completion status - Total async tools: ' + totalAsyncTools +
                        ', Completed: ' + completedAsyncTools);

            if (totalAsyncTools > 0 && completedAsyncTools >= totalAsyncTools) {
                System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                triggerFinalFollowUpLLMCall(executionId, turnIdentifier, currentTurnCount, logPrefix);
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Still waiting for ' + (totalAsyncTools - completedAsyncTools) + ' more async tools to complete.');
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in async tool completion check: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
