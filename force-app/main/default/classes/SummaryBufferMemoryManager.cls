/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Implements IMemoryManager for a "summary buffer" strategy. It maintains a
 *              running summary of the conversation, which is updated after each turn via a Queueable.
 *              This is highly token-efficient for very long conversations.
 * @implements IMemoryManager
 */
public class SummaryBufferMemoryManager implements IMemoryManager {
    public List<Map<String, Object>> getHistoryPayload(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        List<Map<String, Object>> payload = new List<Map<String, Object>>();
        try {
            List<ChatMessage__c> unsummarizedMessages = [
                SELECT
                    Id,
                    Role__c,
                    Content__c,
                    AssistantToolCalls__c,
                    ToolCallId__c,
                    ParentMessage__c,
                    TurnIdentifier__c,
                    RecordContextId__c,
                    RecordContextData__c
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId AND IsSummarized__c = FALSE
                ORDER BY Timestamp__c ASC, Id ASC
            ];

            return MessageHistoryFormatter.formatMessagesForApi(unsummarizedMessages, agentConfig, debugPrefix);
        } catch (Exception e) {
            return payload;
        }
    }

    public void onTurnCompletion(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        Integer triggerSize = (agentConfig.SummarizationTriggerSize__c != null &&
            agentConfig.SummarizationTriggerSize__c > 0)
            ? agentConfig.SummarizationTriggerSize__c.intValue()
            : 0;

        if (triggerSize == 0) {
            return;
        }

        try {
            Integer unsummarizedCount = [SELECT COUNT() FROM ChatMessage__c WHERE ChatSession__c = :sessionId AND IsSummarized__c = FALSE];

            if (unsummarizedCount >= triggerSize) {
                System.enqueueJob(new SummarizeConversationQueueable(sessionId, agentConfig.Id, llmConfig.Id));
            }
        } catch (Exception e) {
        }
    }
}
