/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable job to asynchronously summarize the oldest batch of messages in a chat session.
 */
public class SummarizeConversationQueueable implements Queueable, Database.AllowsCallouts {
    private static final String SUMMARIZATION_PROMPT_TEMPLATE =
        'You are a conversation summarization engine. Your task is to progressively condense a conversation. ' +
        'You will be given the existing summary and the latest turn(s) of the conversation. ' +
        'Create a new, single, concise summary that incorporates the key facts, decisions, and entities from the new messages into the existing summary. ' +
        'Discard conversational filler but retain crucial information. Your response should contain ONLY the new summary text, nothing else.\n\n' +
        '---\nCURRENT SUMMARY:\n{current_summary}\n\n' +
        '---\nNEW MESSAGES TO INCORPORATE:\n{new_lines}\n\n' +
        '---\nNEW CONDENSED SUMMARY:';

    private final Id sessionId;
    private final Id agentConfigId;
    private final Id llmConfigId;

    public SummarizeConversationQueueable(Id sessId, Id agentId, Id llmId) {
        this.sessionId = sessId;
        this.agentConfigId = agentId;
        this.llmConfigId = llmId;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[SummarizerQueueable Job:' + context.getJobId() + ' Sess:' + this.sessionId + '] ';

        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        try {
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentConfigId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigId);
        } catch (Exception e) {
            return;
        }

        Integer chunkSize = (agentConfig.SummarizationChunkSize__c != null &&
            agentConfig.SummarizationChunkSize__c > 0)
            ? agentConfig.SummarizationChunkSize__c.intValue()
            : 10;

        List<ChatMessage__c> finalMessagesToProcess = ChatMessageService.getHistoryWithCompleteTurns(this.sessionId, chunkSize, 'ASC', true);

        if (finalMessagesToProcess.isEmpty()) {
            return;
        }

        List<String> newLinesList = new List<String>();
        for (ChatMessage__c msg : finalMessagesToProcess) {
            newLinesList.add(msg.Role__c + ': ' + msg.Content__c);
        }
        String newLines = String.join(newLinesList, '\n');

        ChatSession__c session = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :this.sessionId];
        String currentSummary = String.isNotBlank(session.ConversationSummary__c)
            ? session.ConversationSummary__c
            : 'The conversation has just begun.';
        String prompt = SUMMARIZATION_PROMPT_TEMPLATE.replace('{current_summary}', currentSummary).replace('{new_lines}', newLines);

        try {
            ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);
            List<Map<String, Object>> messagesPayload = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
            };

            ProviderResult result = adapter.sendMessage(messagesPayload, null, llmConfig, null);

            if (result != null && String.isNotBlank(result.content)) {
                session.ConversationSummary__c = result.content;
                update session;

                List<ChatMessage__c> messagesToUpdate = new List<ChatMessage__c>();
                for (ChatMessage__c msg : finalMessagesToProcess) {
                    messagesToUpdate.add(new ChatMessage__c(Id = msg.Id, IsSummarized__c = true));
                }
                update messagesToUpdate;
            } else {
            }
        } catch (Exception e) {
        }
    }
}
