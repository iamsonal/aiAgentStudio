/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SummaryBufferMemoryManager implements a turn-based summary buffer memory management strategy for AI conversations.
 * It maintains a running summary of conversation history, updated asynchronously after each turn via Queueable jobs.
 * This approach provides predictable, efficient token management for very long conversations while preserving essential context for LLMs.
 *
 * Responsibilities:
 *   - Retrieve only unsummarized messages for LLM context injection
 *   - Trigger summarization jobs when unsummarized turn count exceeds a configured threshold
 *   - Process complete conversation turns atomically for deterministic summarization
 *   - Ensure memory usage remains bounded while retaining key conversational facts
 *   - Provide clear debug output for monitoring and troubleshooting
 *
 * @implements IMemoryManager
 */
public class SummaryBufferMemoryManager implements IMemoryManager {
    /**
     * Retrieves conversation history payload containing only unsummarized messages.
     * Loads messages that have not yet been processed into the conversation summary.
     *
     * @param sessionId       The chat session ID to retrieve history for.
     * @param agentConfig     Agent configuration containing memory settings.
     * @param llmConfig       LLM configuration for the session.
     * @param loggingContext  Optional logging context for debug messages.
     * @return                List of formatted message maps ready for LLM API consumption.
     * @sideeffect            Logs errors if retrieval fails.
     */
    public List<Map<String, Object>> getHistoryPayload(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';
        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Loading unsummarized message history (SummaryBuffer strategy).');

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
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to retrieve unsummarized conversation history: ' + e.getMessage());
            return payload;
        }
    }

    /**
     * Handles post-turn processing to determine if conversation summarization is needed.
     * Uses COUNT_DISTINCT to check if the number of unsummarized conversation turns exceeds the configured trigger count
     * and enqueues a summarization job if necessary. This turn-based approach ensures predictable and efficient summarization.
     *
     * @param sessionId       The chat session ID that completed a turn.
     * @param agentConfig     Agent configuration containing turn-based summarization settings.
     * @param llmConfig       LLM configuration for the session.
     * @param loggingContext  Optional logging context for debug messages.
     * @sideeffect            May enqueue a SummarizeConversationQueueable job; logs info and errors.
     */
    public void onTurnCompletion(Id sessionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        Integer triggerTurnCount = (agentConfig.SummarizationTriggerTurnCount__c != null &&
            agentConfig.SummarizationTriggerTurnCount__c > 0)
            ? agentConfig.SummarizationTriggerTurnCount__c.intValue()
            : 0;

        if (triggerTurnCount == 0) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Summarization trigger turn count is 0. Summarization is disabled for this session.');
            return;
        }

        try {
            List<AggregateResult> results = [
                    SELECT COUNT_DISTINCT(TurnIdentifier__c) unsummarizedTurns
                    FROM ChatMessage__c
                    WHERE ChatSession__c = :sessionId
                    AND IsSummarized__c = FALSE
                    AND TurnIdentifier__c != NULL
            ];

            Integer unsummarizedTurnCount = 0;
            if (!results.isEmpty() && results[0].get('unsummarizedTurns') != null) {
                unsummarizedTurnCount = (Integer) results[0].get('unsummarizedTurns');
            }


            if (unsummarizedTurnCount >= triggerTurnCount) {
                System.debug(
                    LoggingLevel.INFO,
                    debugPrefix +
                        'Unsummarized turn count (' +
                        unsummarizedTurnCount +
                        ') exceeds trigger turn count (' +
                        triggerTurnCount +
                        '). Enqueueing summarization job.'
                );
                System.enqueueJob(new SummarizeConversationQueueable(sessionId, agentConfig.Id));
            } else {
                System.debug(
                    LoggingLevel.DEBUG,
                    debugPrefix +
                        'Unsummarized turn count (' +
                        unsummarizedTurnCount +
                        ') is below trigger turn count (' +
                        triggerTurnCount +
                        '). No summarization needed.'
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to check unsummarized turn count or enqueue summarization job: ' + e.getMessage());
        }
    }
}
