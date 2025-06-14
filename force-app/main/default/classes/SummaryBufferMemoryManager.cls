/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Implements IMemoryManager for a "summary buffer" strategy. It maintains a
 *              running summary of the conversation, which is updated after each turn.
 *              This is highly token-efficient for very long conversations.
 * @implements IMemoryManager
 */
public class SummaryBufferMemoryManager implements IMemoryManager {
    private static final String SUMMARIZATION_PROMPT_TEMPLATE =
        'You are a conversation summarization engine. Your task is to progressively condense a conversation. ' +
        'You will be given the existing summary and the latest turn of the conversation. ' +
        'Create a new, single, concise summary that incorporates the key facts, decisions, and entities from the new turn into the existing summary. ' +
        'Discard conversational filler but retain crucial information.\n\n' +
        'CURRENT SUMMARY:\n{current_summary}\n\n' +
        'LATEST CONVERSATION TURN:\n{new_lines}\n\n' +
        'NEW CONDENSED SUMMARY:';

    public List<Map<String, Object>> getHistoryPayload(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        List<Map<String, Object>> payload = new List<Map<String, Object>>();
        try {
            List<ChatSession__c> sessions = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1];
            String summary = (sessions.isEmpty() || String.isBlank(sessions[0].ConversationSummary__c))
                ? 'No summary yet.'
                : sessions[0].ConversationSummary__c;

            payload.add(
                new Map<String, Object>{
                    'role' => 'system',
                    'content' => 'This is a summary of the conversation so far. Use it to inform your response:\n' + summary
                }
            );
            return payload;
        } catch (Exception e) {
            return payload;
        }
    }

    @future(callout=true)
    public static void performSummarization(Id sessionId, String currentSummary, String newLines, Id llmConfigId) {
        String logPrefix = '[SummaryBufferMemory.future] ';
        try {
            LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(llmConfigId);

            String prompt = SUMMARIZATION_PROMPT_TEMPLATE.replace('{current_summary}', currentSummary).replace('{new_lines}', newLines);

            List<Map<String, Object>> messagesPayload = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
            };

            ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);

            ProviderResult result = adapter.sendMessage(messagesPayload, null, llmConfig, null);

            if (result != null && String.isNotBlank(result.content)) {
                ChatSession__c sessionToUpdate = new ChatSession__c(Id = sessionId, ConversationSummary__c = result.content);
                Database.update(sessionToUpdate, false);
            } else {
            }
        } catch (Exception e) {
        }
    }

    public void onTurnCompletion(
        Id sessionId,
        List<ChatMessage__c> newMessagesInTurn,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        if (newMessagesInTurn == null || newMessagesInTurn.isEmpty()) {
            return;
        }

        try {
            List<ChatSession__c> sessions = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1];
            String currentSummary = sessions.isEmpty() ? 'No existing summary.' : sessions[0].ConversationSummary__c;

            List<String> newLinesList = new List<String>();
            for (ChatMessage__c msg : newMessagesInTurn) {
                newLinesList.add(msg.Role__c + ': ' + msg.Content__c);
            }
            String newLines = String.join(newLinesList, '\n');

            performSummarization(sessionId, currentSummary, newLines, llmConfig.Id);
        } catch (Exception e) {
        }
    }
}
