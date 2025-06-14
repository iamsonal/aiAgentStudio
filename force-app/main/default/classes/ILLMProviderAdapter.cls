/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
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
