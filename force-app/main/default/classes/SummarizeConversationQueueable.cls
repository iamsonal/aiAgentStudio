/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SummarizeConversationQueueable is an asynchronous queueable job that processes and summarizes complete conversation turns
 * in a chat session atomically. It generates a condensed summary by combining the existing summary with entire turns, then marks
 * all messages from processed turns as summarized to optimize memory usage and improve LLM context efficiency. The class is designed for
 * progressive, lossless, turn-based summarization of long-running conversations, ensuring that key facts and decisions are retained
 * while reducing conversational noise and providing predictable token consumption.
 *
 * Responsibilities:
 *   - Retrieve and summarize the oldest unsummarized conversation turns atomically
 *   - Process complete turns to maintain conversational context integrity
 *   - Generate a new summary using an LLM, combining prior summary and new turns
 *   - Update the session with the new summary and mark all processed turn messages
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
     * Main execution method for the queueable job. Processes turn-based conversation summarization for a chat session.
     *
     * Steps:
     *   - Loads agent and LLM configuration
     *   - Atomically retrieves oldest unsummarized conversation turns
     *   - Generates a new summary using the LLM, incorporating complete turns
     *   - Updates the session and marks all messages from processed turns as summarized
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

        Integer chunkTurnCount = (primaryAgentConfig.SummarizationChunkTurnCount__c != null &&
            primaryAgentConfig.SummarizationChunkTurnCount__c > 0)
            ? primaryAgentConfig.SummarizationChunkTurnCount__c.intValue()
            : 10;
        List<ChatMessage__c> messagesToProcess = getOldestUnsummarizedTurns(this.sessionId, chunkTurnCount, logPrefix);

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

    /**
     * Retrieves a specific number of the oldest unsummarized conversation turns atomically.
     * This method first queries for the oldest unsummarized turn identifiers, then fetches all messages
     * belonging to only those turns, ensuring entire conversational turns are processed deterministically.
     *
     * @param sessionId         The chat session ID to process.
     * @param turnCount         Number of oldest turns to retrieve.
     * @param logPrefix         Logging prefix for debug output.
     * @return                  List of ChatMessage__c records representing complete turns, in chronological order.
     */
    private static List<ChatMessage__c> getOldestUnsummarizedTurns(Id sessionId, Integer turnCount, String logPrefix) {
        if (sessionId == null || turnCount == null || turnCount <= 0) {
            return new List<ChatMessage__c>();
        }

        try {
            // Step 1: Get the oldest N unsummarized turn identifiers using a single efficient query
            List<AggregateResult> oldestTurns = [
                SELECT TurnIdentifier__c, MIN(Timestamp__c) earliestTimestamp
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId
                AND IsSummarized__c = FALSE
                AND TurnIdentifier__c != NULL
                GROUP BY TurnIdentifier__c
                ORDER BY MIN(Timestamp__c) ASC
                LIMIT :turnCount
            ];

            if (oldestTurns.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No unsummarized turns found for atomic processing.');
                return new List<ChatMessage__c>();
            }

            // Step 2: Extract turn identifiers from the aggregation results
            Set<String> turnIdentifiersToProcess = new Set<String>();
            for (AggregateResult ar : oldestTurns) {
                String turnId = (String) ar.get('TurnIdentifier__c');
                if (String.isNotBlank(turnId)) {
                    turnIdentifiersToProcess.add(turnId);
                }
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + turnIdentifiersToProcess.size() + ' oldest unsummarized turns atomically.');

            // Step 3: Fetch ALL messages for the identified turns to ensure atomic processing
            List<ChatMessage__c> messagesForTurns = [
                SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, TurnIdentifier__c,
                       AssistantToolCalls__c, ToolCallId__c, ParentMessage__c,
                       TokensUsed__c, ProcessingTimeMillis__c, RecordContextId__c, RecordContextData__c
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId
                AND TurnIdentifier__c IN :turnIdentifiersToProcess
                ORDER BY Timestamp__c ASC, Id ASC
            ];

            System.debug(LoggingLevel.INFO, logPrefix + 'Retrieved ' + messagesForTurns.size() + ' messages from ' + turnIdentifiersToProcess.size() + ' turns for atomic summarization.');

            return messagesForTurns;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve oldest unsummarized turns: ' + e.getMessage());
            return new List<ChatMessage__c>();
        }
    }
}
