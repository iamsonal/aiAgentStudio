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
 * a fixed-size, turn-aware buffer of recent conversation history. It ensures that the conversational context
 * is preserved by always including complete conversation turns, never splitting a turn mid-way, and supports
 * configurable history limits per agent. This class is responsible for retrieving and formatting the appropriate
 * message history for LLM context windows, adapting to agent configuration and session state.
 *
 * Responsibilities:
 *   - Enforces a turn-aware, fixed-size buffer for conversation history
 *   - Prevents mid-turn cutoffs to maintain context integrity
 *   - Supports unlimited, zero, or positive history limits as configured per agent
 *   - Delegates message retrieval and formatting to specialized services
 *
 * This class is not intended for direct use outside the memory management subsystem.
 * @implements IMemoryManager
 */
public class BufferWindowMemoryManager implements IMemoryManager {
    /**
     * Retrieves a turn-aware, fixed-size buffer of recent conversation history for the given session.
     * Ensures that only complete conversation turns are included, never splitting a turn mid-way.
     *
     * @param sessionId      The session whose history is being retrieved.
     * @param agentConfig    The agent configuration, including history limit.
     * @param llmConfig      The LLM configuration (unused in this strategy, but required by interface).
     * @param loggingContext Optional logging context prefix for debug output.
     * @return               A list of formatted message maps for LLM consumption.
     *
     * Behavior:
     *   - If history limit is null, returns all messages (unbounded history)
     *   - If history limit is 0 or negative, returns an empty list (no history)
     *   - If history limit is positive, returns the most recent N turns, always including complete turns
     */
    public List<Map<String, Object>> getHistoryPayload(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[BufferWindowMemory] ';
        System.debug(LoggingLevel.INFO, debugPrefix + 'BufferWindowMemoryManager: Starting history retrieval for session: ' + sessionId);

        Decimal historyLimitDecimal = agentConfig.HistoryLimit__c;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Configured history limit: ' + historyLimitDecimal);

        if (historyLimitDecimal == null) {
            // Unlimited history: fetch all messages for the session
            System.debug(LoggingLevel.INFO, debugPrefix + 'No history limit set. Fetching all available messages for session.');
            List<ChatMessage__c> allMessages = ChatMessageService.getHistory(sessionId, null, 'ASC', null, false);
            return MessageHistoryFormatter.formatMessagesForApi(allMessages, agentConfig, debugPrefix);
        }

        Integer historyLimit = historyLimitDecimal.intValue();

        if (historyLimit <= 0) {
            // Zero or negative limit: return no history
            System.debug(LoggingLevel.INFO, debugPrefix + 'History limit is zero or negative. No conversation history will be returned.');
            return new List<Map<String, Object>>();
        }

        // Positive limit: fetch most recent N turns, always including complete turns
        System.debug(LoggingLevel.INFO, debugPrefix + 'Fetching up to ' + historyLimit + ' complete conversation turns for session.');
        List<ChatMessage__c> finalSortedHistory = ChatMessageService.getHistoryWithCompleteTurns(sessionId, historyLimit, 'DESC', false);
        return MessageHistoryFormatter.formatMessagesForApi(finalSortedHistory, agentConfig, debugPrefix);
    }

    /**
     * Invoked after a conversation turn is completed. No-op for buffer window strategy.
     *
     * @param sessionId      The session whose turn has completed.
     * @param agentConfig    The agent configuration.
     * @param llmConfig      The LLM configuration.
     * @param loggingContext Optional logging context prefix for debug output.
     */
    public void onTurnCompletion(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        // No additional processing required for buffer window memory management
    }
}
