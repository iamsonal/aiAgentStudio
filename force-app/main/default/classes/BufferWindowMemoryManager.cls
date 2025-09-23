/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BufferWindowMemoryManager implements a memory management strategy for conversational agents that maintains
 * a precise, turn-based buffer of recent conversation history. It ensures optimal performance and predictable
 * token consumption by fetching exactly the configured number of complete conversation turns using a highly
 * efficient single SOQL subquery approach. This eliminates the previous two-query inefficiency and prevents
 * unexpected prompt size increases from "mega-turns."
 *
 * Responsibilities:
 *   - Enforces a precise, turn-based buffer for conversation history (not message-based)
 *   - Uses optimized single-query retrieval for maximum performance
 *   - Provides administrators with precise control over token consumption
 *   - Supports unlimited, zero, or positive turn limits as configured per agent
 *   - Uses the unified AgentExecution__c and ExecutionStep__c data models exclusively
 *
 * This class is not intended for direct use outside the memory management subsystem.
 * @implements IMemoryManager
 */
public class BufferWindowMemoryManager implements IMemoryManager {
    /**
     * Retrieves a precise, turn-based buffer of recent execution history for the given execution.
     * Uses the unified AgentExecution__c and ExecutionStep__c data models exclusively.
     *
     * @param executionId    The execution whose history is being retrieved (AgentExecution__c).
     * @param agentConfig    The agent configuration, including turn limit.
     * @param llmConfig      The LLM configuration (unused in this strategy, but required by interface).
     * @param loggingContext Optional logging context prefix for debug output.
     * @return               A list of formatted message maps for LLM consumption.
     *
     * Behavior:
     *   - If turn limit is null, returns all messages (unbounded history)
     *   - If turn limit is 0 or negative, returns an empty list (no history)
     *   - If turn limit is positive, returns exactly N most recent complete turns using optimized query
     */
    public List<Map<String, Object>> getHistoryPayload(
        Id executionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[BufferWindowMemory] ';
        System.debug(LoggingLevel.INFO, debugPrefix + 'BufferWindowMemoryManager: Starting history retrieval for execution: ' + executionId);

        Decimal turnLimitDecimal = agentConfig.HistoryTurnLimit__c;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Configured turn limit: ' + turnLimitDecimal);

        if (turnLimitDecimal == null) {
            // Unlimited history: fetch all messages for the execution
            System.debug(LoggingLevel.INFO, debugPrefix + 'No turn limit set. Fetching all available messages for execution.');
            return getUnlimitedHistory(executionId, agentConfig, debugPrefix);
        }

        Integer turnLimit = turnLimitDecimal.intValue();

        if (turnLimit <= 0) {
            // Zero or negative limit: return no history
            System.debug(LoggingLevel.INFO, debugPrefix + 'Turn limit is zero or negative. No execution history will be returned.');
            return new List<Map<String, Object>>();
        }

        // Positive limit: fetch exactly N most recent complete execution turns using optimized query
        System.debug(LoggingLevel.INFO, debugPrefix + 'Fetching exactly ' + turnLimit + ' complete execution turns.');
        return getLimitedHistory(executionId, turnLimit, agentConfig, debugPrefix);
    }

    /**
     * Invoked after an execution turn is completed. No-op for buffer window strategy.
     *
     * @param executionId    The execution whose turn has completed (AgentExecution__c).
     * @param agentConfig    The agent configuration.
     * @param llmConfig      The LLM configuration.
     * @param loggingContext Optional logging context prefix for debug output.
     */
    public void onTurnCompletion(Id executionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        // No additional processing required for buffer window memory management
    }

    /**
     * Retrieves unlimited history for the given execution using ExecutionStep__c.
     *
     * @param executionId The execution ID (AgentExecution__c)
     * @param agentConfig The agent configuration
     * @param debugPrefix Debug logging prefix
     * @return Formatted message list for LLM consumption
     */
    private List<Map<String, Object>> getUnlimitedHistory(Id executionId, AIAgentDefinition__c agentConfig, String debugPrefix) {
        ExecutionStepService executionStepService = new ExecutionStepService();
        List<ExecutionStep__c> allSteps = executionStepService.getHistory(executionId, null, 'ASC', null, false);
        return ExecutionStepHistoryFormatter.formatStepsForApi(allSteps, agentConfig, debugPrefix);
    }

    /**
     * Retrieves limited history for the given execution using ExecutionStep__c.
     *
     * @param executionId The execution ID (AgentExecution__c)
     * @param turnLimit The maximum number of turns to retrieve
     * @param agentConfig The agent configuration
     * @param debugPrefix Debug logging prefix
     * @return Formatted message list for LLM consumption
     */
    private List<Map<String, Object>> getLimitedHistory(Id executionId, Integer turnLimit, AIAgentDefinition__c agentConfig, String debugPrefix) {
        ExecutionStepService executionStepService = new ExecutionStepService();
        List<ExecutionStep__c> limitedSteps = executionStepService.getHistoryWithCompleteTurns(executionId, turnLimit, 'DESC', false);
        return ExecutionStepHistoryFormatter.formatStepsForApi(limitedSteps, agentConfig, debugPrefix);
    }
}
