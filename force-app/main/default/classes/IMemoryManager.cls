/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * IMemoryManager defines the contract for all conversation memory management strategies in AI agent interactions.
 *
 * Responsibilities:
 *   - Standardizes how conversation history is loaded, formatted, and maintained across chat sessions
 *   - Enables pluggable memory strategies (e.g., buffer window, summarization, hybrid) to optimize context usage
 *   - Ensures memory management respects LLM token limits and performance requirements
 *   - Provides hooks for background processing or summarization after each turn
 *
 * Implementations must:
 *   - Efficiently load and format conversation history for LLM consumption
 *   - Optionally perform background processing or summarization after each turn
 *   - Be stateless or manage state in a scalable, session-safe manner
 */
public interface IMemoryManager {
    /**
     * Loads and formats the conversation history for a given session according to the memory strategy.
     *
     * @param sessionId      The Id of the ChatSession__c.
     * @param agentConfig    The full AIAgentDefinition__c record for the current agent.
     * @param llmConfig      The full LLMConfiguration__c record for the current agent.
     * @param loggingContext A string prefix for logging and diagnostics.
     * @return List<Map<String, Object>>
     *         A list of message maps, ready to be included in the LLM API request body.
     *
     * Implementations should:
     *   - Efficiently load and format the relevant conversation history
     *   - Respect LLM token limits and performance constraints
     *   - Return a list of messages in the expected LLM API format
     */
    List<Map<String, Object>> getHistoryPayload(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext);

    /**
     * Hook called by the framework after a turn successfully completes.
     *
     * @param sessionId      The Id of the ChatSession__c.
     * @param agentConfig    The full AIAgentDefinition__c record.
     * @param llmConfig      The full LLMConfiguration__c record.
     * @param loggingContext A string prefix for logging and diagnostics.
     *
     * Implementations may:
     *   - Perform background processing, summarization, or memory updates as needed
     *   - Be a no-op for stateless or simple memory strategies
     */
    void onTurnCompletion(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext);
}
