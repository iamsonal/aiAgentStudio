/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SummarizeConversationQueueable is an asynchronous queueable job that processes and summarizes the oldest batch of messages
 * in a chat session. It generates a condensed summary by combining the existing summary with new messages, then marks
 * processed messages as summarized to optimize memory usage and improve LLM context efficiency. The class is designed for
 * progressive, lossless summarization of long-running conversations, ensuring that key facts and decisions are retained
 * while reducing conversational noise.
 *
 * Responsibilities:
 *   - Retrieve and summarize the oldest unsummarized messages in a chat session
 *   - Generate a new summary using an LLM, combining prior summary and new messages
 *   - Update the session with the new summary and mark processed messages
 *   - Log all key operations and error conditions for monitoring and troubleshooting
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

    /**
     * Constructs a new SummarizeConversationQueueable job.
     *
     * @param sessId    The chat session ID to summarize.
     * @param agentId   The agent definition ID containing summarization settings.
     * @param llmId     The LLM configuration ID for making summarization calls.
     */
    public SummarizeConversationQueueable(Id sessId, Id agentId, Id llmId) {
        this.sessionId = sessId;
        this.agentConfigId = agentId;
        this.llmConfigId = llmId;
    }

    /**
     * Main execution method for the queueable job. Processes conversation summarization for a chat session.
     *
     * Steps:
     *   - Loads agent and LLM configuration
     *   - Retrieves oldest unsummarized messages (ensuring complete turns)
     *   - Generates a new summary using the LLM
     *   - Updates the session and marks messages as summarized
     *   - Logs all key operations and errors
     *
     * @param context   Queueable execution context.
     * @sideeffect      Updates ChatSession__c and ChatMessage__c records; logs errors and info.
     */
    public void execute(QueueableContext context) {
        String logPrefix = '[SummarizerQueueable Job:' + context.getJobId() + ' Sess:' + this.sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Summarization job started.');

        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        try {
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentConfigId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to load agent or LLM configuration: ' + e.getMessage());
            return;
        }

        Integer chunkSize = (agentConfig.SummarizationChunkSize__c != null &&
            agentConfig.SummarizationChunkSize__c > 0)
            ? agentConfig.SummarizationChunkSize__c.intValue()
            : 10;

        // Retrieve oldest unsummarized messages ensuring complete turns
        List<ChatMessage__c> finalMessagesToProcess = ChatMessageService.getHistoryWithCompleteTurns(this.sessionId, chunkSize, 'ASC', true);

        if (finalMessagesToProcess.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No unsummarized messages found. Exiting.');
            return;
        }

        // Format messages for summarization prompt
        List<String> newLinesList = new List<String>();
        for (ChatMessage__c msg : finalMessagesToProcess) {
            newLinesList.add(msg.Role__c + ': ' + msg.Content__c);
        }
        String newLines = String.join(newLinesList, '\n');

        // Prepare summarization prompt with current summary and new messages
        ChatSession__c session = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :this.sessionId];
        String currentSummary = String.isNotBlank(session.ConversationSummary__c)
            ? session.ConversationSummary__c
            : 'The conversation has just begun.';
        String prompt = SUMMARIZATION_PROMPT_TEMPLATE.replace('{current_summary}', currentSummary).replace('{new_lines}', newLines);

        try {
            // Generate new summary via LLM
            ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);
            List<Map<String, Object>> messagesPayload = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
            };

            ProviderResult result = adapter.sendMessage(messagesPayload, null, llmConfig, null);

            if (result != null && String.isNotBlank(result.content)) {
                // Update session summary and mark messages as processed
                session.ConversationSummary__c = result.content;
                update session;

                List<ChatMessage__c> messagesToUpdate = new List<ChatMessage__c>();
                for (ChatMessage__c msg : finalMessagesToProcess) {
                    messagesToUpdate.add(new ChatMessage__c(Id = msg.Id, IsSummarized__c = true));
                }
                update messagesToUpdate;

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Conversation summary updated and ' + messagesToUpdate.size() + ' messages marked as summarized.'
                );
            } else {
                System.debug(LoggingLevel.ERROR, logPrefix + 'LLM summarization call returned empty content. No update performed.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during summarization: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
