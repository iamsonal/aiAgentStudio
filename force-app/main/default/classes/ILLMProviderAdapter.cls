/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Interface for LLM communication. Defines method signature including tools.
 */
public interface ILLMProviderAdapter {
    /**
     * @description Sends messages and action/tool definitions to the LLM.
     * @param messagesPayload Pre-formatted list of message history Maps.
     * @param toolsPayload Pre-formatted list of action/tool definition Maps for the LLM API.
     * @param llmConfig The LLMConfiguration__c record.
     * @param agentConfig The AIAgentDefinition__c record.
     * @return ProviderResult containing content, token usage, AND requested actions.
     * @throws LLMProviderException For callout errors, HTTP errors, etc.
     */
    ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    );
}
