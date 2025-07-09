/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Implements the IMemoryManager interface for a "fixed-window buffer" strategy.
 *              It retrieves a base number of recent messages and ensures the oldest turn included
 *              is complete, preventing conversational context from being cut off.
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

        Decimal historyLimitDecimal = agentConfig.HistoryLimit__c;

        if (historyLimitDecimal == null) {
            List<ChatMessage__c> allMessages = ChatMessageService.getHistory(sessionId, null, 'ASC', null, false);
            return MessageHistoryFormatter.formatMessagesForApi(allMessages, agentConfig, debugPrefix);
        }

        Integer historyLimit = historyLimitDecimal.intValue();

        if (historyLimit <= 0) {
            return new List<Map<String, Object>>();
        }

        List<ChatMessage__c> finalSortedHistory = ChatMessageService.getHistoryWithCompleteTurns(sessionId, historyLimit, 'DESC', false);

        return MessageHistoryFormatter.formatMessagesForApi(finalSortedHistory, agentConfig, debugPrefix);
    }

    public void onTurnCompletion(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        return;
    }
}
