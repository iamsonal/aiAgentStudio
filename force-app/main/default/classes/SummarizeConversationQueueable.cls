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
    private static final String FALLBACK_PROMPT_TEMPLATE =
        'You are a conversation summarization engine. Your task is to progressively condense a conversation. ' +
        'You will be given the existing summary and the latest turn(s) of the conversation. ' +
        'Create a new, single, concise summary that incorporates the key facts, decisions, and entities from the new messages into the existing summary. ' +
        'Discard conversational filler but retain crucial information. Your response should contain ONLY the new summary text, nothing else.\n\n' +
        '---\nCURRENT SUMMARY:\n{current_summary}\n\n' +
        '---\nNEW MESSAGES TO INCORPORATE:\n{new_lines}\n\n' +
        '---\nNEW CONDENSED SUMMARY:';

    private final Id sessionId;
    private final Id agentConfigId;

    public class SummarizationException extends Exception {
    }

    /**
     * Constructs a new SummarizeConversationQueueable job.
     *
     * @param sessId    The chat session ID to summarize.
     * @param agentId   The agent definition ID containing summarization settings.
     */
    public SummarizeConversationQueueable(Id sessId, Id agentId) {
        this.sessionId = sessId;
        this.agentConfigId = agentId;
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

        AIAgentDefinition__c primaryAgentConfig = null;
        LLMConfiguration__c llmConfigToUse = null;
        String promptTemplateToUse = '';

        try {
            primaryAgentConfig = AIAgentConfigService.getAgentDefinition(this.agentConfigId);

            if (primaryAgentConfig.SummarizerAgent__c != null && primaryAgentConfig.SummarizerAgent__c != null) {
                // A dedicated summarizer agent IS configured. Use its settings.
                AIAgentDefinition__c summarizerAgent = primaryAgentConfig.SummarizerAgent__r;
                llmConfigToUse = AIAgentConfigService.getLLMConfiguration(summarizerAgent.LLMConfiguration__c);
                promptTemplateToUse = summarizerAgent.InstructionsPrompt__c;
                System.debug(LoggingLevel.INFO, logPrefix + 'Using dedicated summarizer agent: ' + summarizerAgent.DeveloperName__c);
            } else {
                // FALLBACK: No dedicated summarizer is linked. Use the primary agent's LLM and the hardcoded default prompt.
                llmConfigToUse = AIAgentConfigService.getLLMConfiguration(primaryAgentConfig.LLMConfiguration__c);
                promptTemplateToUse = FALLBACK_PROMPT_TEMPLATE;
                System.debug(LoggingLevel.WARN, logPrefix + 'No summarizer agent linked. Falling back to primary agent LLM and default prompt.');
            }

            if (String.isBlank(promptTemplateToUse)) {
                throw new SummarizationException('Summarization prompt template is blank for both the dedicated summarizer and the fallback.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to load summarization configuration: ' + e.getMessage());
            return;
        }

        Integer chunkSize = (primaryAgentConfig.SummarizationChunkSize__c != null &&
            primaryAgentConfig.SummarizationChunkSize__c > 0)
            ? primaryAgentConfig.SummarizationChunkSize__c.intValue()
            : 10;
        List<ChatMessage__c> messagesToProcess = ChatMessageService.getHistoryWithCompleteTurns(this.sessionId, chunkSize, 'ASC', true);

        if (messagesToProcess.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No unsummarized messages found. Exiting.');
            return;
        }

        List<String> newLinesList = new List<String>();
        for (ChatMessage__c msg : messagesToProcess)
            newLinesList.add(msg.Role__c + ': ' + msg.Content__c);
        String newLines = String.join(newLinesList, '\n');

        ChatSession__c session = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :this.sessionId];
        String currentSummary = String.isNotBlank(session.ConversationSummary__c)
            ? session.ConversationSummary__c
            : 'The conversation has just begun.';
        String prompt = promptTemplateToUse.replace('{current_summary}', currentSummary).replace('{new_lines}', newLines);

        try {
            ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfigToUse);
            List<Map<String, Object>> messagesPayload = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => prompt }
            };
            ProviderResult result = adapter.sendMessage(messagesPayload, null, llmConfigToUse, null);

            if (result != null && String.isNotBlank(result.content)) {
                session.ConversationSummary__c = result.content;
                update session;
                List<ChatMessage__c> messagesToUpdate = new List<ChatMessage__c>();
                for (ChatMessage__c msg : messagesToProcess) {
                    messagesToUpdate.add(new ChatMessage__c(Id = msg.Id, IsSummarized__c = true));
                }
                update messagesToUpdate;
                System.debug(LoggingLevel.INFO, logPrefix + 'Summarization successful.');
            } else {
                System.debug(LoggingLevel.ERROR, logPrefix + 'LLM summarization call returned empty content. No update performed.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during summarization: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
