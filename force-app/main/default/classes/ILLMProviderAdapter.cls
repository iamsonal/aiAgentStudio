/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ILLMProviderAdapter defines the contract for all Large Language Model (LLM) provider integrations.
 *
 * Responsibilities:
 *   - Standardizes communication with external LLM services (e.g., OpenAI, Anthropic, etc.)
 *   - Supports message history, tool/function calling, and provider-specific response processing
 *   - Ensures all implementations handle provider-specific API formats, authentication, and error conditions
 *   - Enables the agent framework to interact with any LLM provider in a consistent, pluggable manner
 *
 * Implementations must:
 *   - Translate framework message and tool payloads to the provider's API format
 *   - Handle all required authentication, error handling, and response parsing
 *   - Return a ProviderResult containing content, token usage, and any requested actions
 */
public interface ILLMProviderAdapter {
    // ProviderResult class definition remains external (in ProviderResult.cls)

    /**
     * Sends messages and action/tool definitions to the LLM provider and returns the result.
     *
     * @param messagesPayload  Pre-formatted list of message history maps (framework format).
     * @param toolsPayload     Pre-formatted list of action/tool definition maps for the LLM API.
     * @param llmConfig        The LLMConfiguration__c record for provider-specific settings.
     * @param agentConfig      The AIAgentDefinition__c record for agent-specific context.
     * @return ProviderResult  Contains content, token usage, and any requested actions.
     * @throws LLMProviderException for callout errors, HTTP errors, or provider-specific failures.
     *
     * Implementations must:
     *   - Map the framework payloads to the provider's API format
     *   - Handle authentication, error handling, and response parsing
     *   - Return a fully populated ProviderResult for downstream processing
     */
    ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    );
}
