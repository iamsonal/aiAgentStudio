/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contract for conversation memory management strategies. Standardizes how execution history is loaded and formatted.
 */
public interface IMemoryManager {
    List<Map<String, Object>> getHistoryPayload(Id executionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext);
    void onTurnCompletion(Id executionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext);
}
