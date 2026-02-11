/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Asynchronous queueable job that processes and summarizes complete execution turns atomically. Generates condensed summaries using LLM.
 */
public without sharing class SummarizeConversationQueueable implements Queueable, Database.AllowsCallouts {
    private static final String FALLBACK_PROMPT_TEMPLATE =
        'You are a conversation summarization engine. Your task is to progressively condense a conversation. ' +
        'You will be given the existing summary and the latest turn(s) of the conversation. ' +
        'Create a new, single, concise summary that incorporates the key facts, decisions, and entities from the new messages into the existing summary. ' +
        'Discard conversational filler but retain crucial information. Your response should contain ONLY the new summary text, nothing else.\n\n' +
        '---\nCURRENT SUMMARY:\n{current_summary}\n\n' +
        '---\nNEW MESSAGES TO INCORPORATE:\n{new_lines}\n\n' +
        '---\nNEW CONDENSED SUMMARY:';

    private final Id executionId;
    private final Id agentConfigId;

    public class SummarizationException extends Exception {
    }
    public SummarizeConversationQueueable(Id execId, Id agentId) {
        this.executionId = execId;
        this.agentConfigId = agentId;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[SummarizerQueueable Job:' + context.getJobId() + ' AgentExecution:' + this.executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Summarization job started for AgentExecution.');

        AIAgentDefinition__c primaryAgentConfig = null;
        AIAgentDefinition__c summarizationAgentConfig = null;
        LLMConfiguration__c llmConfigToUse = null;
        String promptTemplateToUse = '';
        PIIMaskingService maskingService = null;
        PromptSafetyService safetyService = null;
        String currentJobId = (String) context.getJobId();

        AgentExecution__c execution = null;
        try {
            List<AgentExecution__c> executions = [
                SELECT Id, ExecutionStatus__c, ConversationSummary__c, SummarizationJobId__c
                FROM AgentExecution__c
                WHERE Id = :this.executionId
                LIMIT 1
            ];
            if (executions.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Execution not found. Skipping summarization.');
                return;
            }
            execution = executions[0];
            if (execution.ExecutionStatus__c == 'Cancelled' || execution.ExecutionStatus__c == 'Failed') {
                System.debug(LoggingLevel.INFO, logPrefix + 'Execution is no longer active. Skipping summarization.');
                this.clearSummarizationJobId(currentJobId, logPrefix);
                return;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to load execution for summarization: ' + e.getMessage());
            this.clearSummarizationJobId(currentJobId, logPrefix);
            return;
        }

        try {
            primaryAgentConfig = AIAgentConfigService.getAgentDefinition(this.agentConfigId);

            if (primaryAgentConfig.SummarizerAgent__c != null && primaryAgentConfig.SummarizerAgent__c != null) {
                AIAgentDefinition__c summarizerAgent = primaryAgentConfig.SummarizerAgent__r;
                summarizationAgentConfig = summarizerAgent;
                llmConfigToUse = AIAgentConfigService.getLLMConfiguration(summarizerAgent.LLMConfiguration__c);
                promptTemplateToUse = summarizerAgent.InstructionsPrompt__c;
                System.debug(LoggingLevel.INFO, logPrefix + 'Using dedicated summarizer agent: ' + summarizerAgent.DeveloperName__c);
            } else {
                summarizationAgentConfig = primaryAgentConfig;
                llmConfigToUse = AIAgentConfigService.getLLMConfiguration(primaryAgentConfig.LLMConfiguration__c);
                promptTemplateToUse = FALLBACK_PROMPT_TEMPLATE;
                System.debug(LoggingLevel.WARN, logPrefix + 'No summarizer agent linked. Falling back to primary agent LLM and default prompt.');
            }

            if (String.isBlank(promptTemplateToUse)) {
                throw new SummarizationException('Summarization prompt template is blank for both the dedicated summarizer and the fallback.');
            }

            maskingService = PIIMaskingService.createForAgent(summarizationAgentConfig, this.executionId);
            safetyService = PromptSafetyService.createForAgent(summarizationAgentConfig, this.executionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to load summarization configuration: ' + e.getMessage());
            return;
        }

        Integer chunkTurnCount = (primaryAgentConfig.SummarizationChunkTurnCount__c != null &&
            primaryAgentConfig.SummarizationChunkTurnCount__c > 0)
            ? primaryAgentConfig.SummarizationChunkTurnCount__c.intValue()
            : 10;
        List<Object> messagesToProcess = getOldestUnsummarizedTurns(this.executionId, chunkTurnCount, logPrefix);

        if (messagesToProcess.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No unsummarized messages found. Exiting.');
            this.clearSummarizationJobId(currentJobId, logPrefix);
            return;
        }

        List<String> newLinesList = new List<String>();
        for (Object obj : messagesToProcess) {
            ExecutionStep__c step = (ExecutionStep__c) obj;
            if (step.StepType__c == 'UserInput' || step.StepType__c == 'AgentResponse') {
                newLinesList.add(step.StepRole__c + ': ' + step.Content__c);
            }
        }
        String newLines = String.join(newLinesList, '\n');

        String currentSummary = String.isNotBlank(execution.ConversationSummary__c) ? execution.ConversationSummary__c : 'The execution has just begun.';
        String prompt = promptTemplateToUse.replace('{current_summary}', currentSummary).replace('{new_lines}', newLines);
        String outboundPrompt = prompt;

        if (maskingService != null) {
            outboundPrompt = maskingService.maskText(outboundPrompt);
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Applied PII masking to summarization prompt.');
        }

        if (safetyService != null) {
            ThreatAssessment assessment = safetyService.checkMessage(outboundPrompt);
            if (assessment.shouldBlock()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Summarization prompt blocked by safety policy. Skipping summarization.');
                return;
            }
            if (assessment.hasSanitizedContent()) {
                outboundPrompt = assessment.getSanitizedContent();
                System.debug(LoggingLevel.INFO, logPrefix + 'Summarization prompt sanitized by safety policy.');
            }
        }

        try {
            ILLMProviderAdapter adapter = LLMInteractionService.getLLMProviderAdapter(llmConfigToUse);
            List<Map<String, Object>> messagesPayload = new List<Map<String, Object>>{
                new Map<String, Object>{ 'role' => 'user', 'content' => outboundPrompt }
            };
            ProviderResult result = adapter.sendMessage(messagesPayload, null, llmConfigToUse, null);

            if (result != null && String.isNotBlank(result.content)) {
                String summarizedContent = result.content;
                if (maskingService != null) {
                    summarizedContent = maskingService.unmaskText(summarizedContent);
                }
                AgentExecution__c executionToUpdate = new AgentExecution__c(Id = this.executionId, ConversationSummary__c = summarizedContent);
                update executionToUpdate;

                List<Id> stepIdsToMarkSummarized = new List<Id>();
                for (Object obj : messagesToProcess) {
                    ExecutionStep__c step = (ExecutionStep__c) obj;
                    stepIdsToMarkSummarized.add(step.Id);
                }

                if (!stepIdsToMarkSummarized.isEmpty()) {
                    ExecutionStepService executionStepService = new ExecutionStepService();
                    executionStepService.markStepsAsSummarized(stepIdsToMarkSummarized);
                }
                System.debug(LoggingLevel.INFO, logPrefix + 'Summarization successful.');
            } else {
                System.debug(LoggingLevel.ERROR, logPrefix + 'LLM summarization call returned empty content. No update performed.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during summarization: ' + e.getMessage() + '\n' + e.getStackTraceString());
        } finally {
            this.clearSummarizationJobId(currentJobId, logPrefix);
        }
    }

    private void clearSummarizationJobId(String jobId, String logPrefix) {
        if (String.isBlank(jobId) || this.executionId == null) {
            return;
        }
        try {
            List<AgentExecution__c> executions = [
                SELECT Id, SummarizationJobId__c
                FROM AgentExecution__c
                WHERE Id = :this.executionId
                LIMIT 1
            ];
            if (!executions.isEmpty() && executions[0].SummarizationJobId__c == jobId) {
                update new AgentExecution__c(Id = this.executionId, SummarizationJobId__c = null);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to clear summarization job id: ' + e.getMessage());
        }
    }

    private static List<Object> getOldestUnsummarizedTurns(Id executionId, Integer turnCount, String logPrefix) {
        if (executionId == null || turnCount == null || turnCount <= 0) {
            return new List<Object>();
        }

        try {
            List<AggregateResult> oldestTurns = [
                SELECT TurnIdentifier__c, MIN(Timestamp__c) earliestTimestamp
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND TurnIdentifier__c != NULL AND IsInternal__c = FALSE AND IsSummarized__c = FALSE
                GROUP BY TurnIdentifier__c
                ORDER BY MIN(Timestamp__c) ASC
                LIMIT :turnCount
            ];

            if (oldestTurns.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No unsummarized turns found for ExecutionStep atomic processing.');
                return new List<Object>();
            }

            Set<String> turnIdentifiersToProcess = new Set<String>();
            for (AggregateResult ar : oldestTurns) {
                String turnId = (String) ar.get('TurnIdentifier__c');
                if (String.isNotBlank(turnId)) {
                    turnIdentifiersToProcess.add(turnId);
                }
            }

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Processing ' + turnIdentifiersToProcess.size() + ' oldest unsummarized ExecutionStep turns atomically.'
            );

            List<ExecutionStep__c> stepsForTurns = [
                SELECT
                    Id,
                    StepType__c,
                    StepRole__c,
                    Content__c,
                    ContentType__c,
                    Timestamp__c,
                    TurnIdentifier__c,
                    TurnCount__c,
                    ToolCallId__c,
                    ToolName__c,
                    ToolArguments__c,
                    ToolResult__c,
                    ProcessingDuration__c,
                    StepMetadata__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND TurnIdentifier__c IN :turnIdentifiersToProcess AND IsInternal__c = FALSE
                ORDER BY Timestamp__c ASC, Id ASC
            ];

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Retrieved ' + stepsForTurns.size() + ' steps from ' + turnIdentifiersToProcess.size() + ' turns for atomic summarization.'
            );

            return (List<Object>) stepsForTurns;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve oldest unsummarized turns: ' + e.getMessage());
            return new List<Object>();
        }
    }
}
