/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Implements the IMemoryManager interface for a "fixed-window buffer" strategy.
 *              It retrieves the last N messages from the chat history. This is the default
 *              and most common memory strategy.
 * @implements IMemoryManager
 */
public class BufferWindowMemoryManager implements IMemoryManager {
    public List<Map<String, Object>> getHistoryPayload(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[BufferWindowMemory] ';

        Integer historyLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        if (historyLimit <= 0) {
            return new List<Map<String, Object>>();
        }

        List<ChatMessage__c> rawMessages = ChatMessageService.getHistory(sessionId, historyLimit, 'ASC', null);

        return MessageHistoryFormatter.formatMessagesForApi(rawMessages, agentConfig, '', false, debugPrefix);
    }

    public void onTurnCompletion(
        Id sessionId,
        List<ChatMessage__c> newMessagesInTurn,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        return;
    }
}
