/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contract for all LLM provider integrations. Standardizes communication with external LLM services.
 */
public interface ILLMProviderAdapter {
    ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    );
}
