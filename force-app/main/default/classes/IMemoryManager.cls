/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface for Memory Management strategies within the AI Agent Framework.
 *              Defines the contract for classes that load conversation history into a format
 *              suitable for an LLM prompt and handle post-turn processing if needed.
 */
public interface IMemoryManager {
    /**
     * @description Loads the conversation history according to the specific strategy
     *              and formats it into the final message list payload for the LLM.
     * @param sessionId The ID of the ChatSession__c.
     * @param agentConfig The full AIAgentDefinition__c record for the current agent.
     * @param llmConfig The full LLMConfiguration__c record for the current agent.
     * @param loggingContext A string prefix for logging.
     * @return List<Map<String, Object>> A list of message maps, ready to be included
     *         in the LLM API request body.
     */
    List<Map<String, Object>> getHistoryPayload(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext);

    /**
     * @description A hook that is called by the framework after a turn successfully completes.
     *              Strategies like Summary Buffer use this to update their state (e.g., generate a new summary).
     * @param sessionId The ID of the ChatSession__c.
     * @param newMessagesInTurn A list of the ChatMessage__c records that were created
     *        during the just-completed turn (e.g., the user's message and the final assistant reply).
     * @param agentConfig The full AIAgentDefinition__c record.
     * @param llmConfig The full LLMConfiguration__c record.
     * @param loggingContext A string prefix for logging.
     */
    void onTurnCompletion(
        Id sessionId,
        List<ChatMessage__c> newMessagesInTurn,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    );
}
