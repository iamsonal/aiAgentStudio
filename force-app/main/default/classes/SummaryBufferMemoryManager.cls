/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Turn-based summary buffer memory management strategy. Maintains a running summary of conversation history, updated asynchronously after each turn.
 */
public class SummaryBufferMemoryManager implements IMemoryManager {
    public List<Map<String, Object>> getHistoryPayload(Id executionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';
        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Loading unsummarized execution history (SummaryBuffer strategy).');

        List<Map<String, Object>> payload = new List<Map<String, Object>>();
        try {
            // Use ExecutionStep__c retrieval via ExecutionStepService with summarization support
            ExecutionStepService executionStepService = new ExecutionStepService();
            List<ExecutionStep__c> unsummarizedSteps = executionStepService.getUnsummarizedSteps(executionId, false);
            return LLMFormattingService.formatStepsForApi(unsummarizedSteps, agentConfig, debugPrefix);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to retrieve unsummarized execution history: ' + e.getMessage());
            return payload;
        }
    }

    /**
     * Handles post-turn processing to determine if execution summarization is needed.
     * Uses COUNT_DISTINCT to check if the number of unsummarized execution turns exceeds the configured trigger count
     * and enqueues a summarization job if necessary. This turn-based approach ensures predictable and efficient summarization.
     *
     * @param executionId     The AgentExecution__c ID that completed a turn.
     * @param agentConfig     Agent configuration containing turn-based summarization settings.
     * @param llmConfig       LLM configuration for the execution.
     * @param loggingContext  Optional logging context for debug messages.
     * @sideeffect            May enqueue a SummarizeConversationQueueable job; logs info and errors.
     */
    public void onTurnCompletion(Id executionId, AIAgentDefinition__c agentConfig, LLMConfiguration__c llmConfig, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[SummaryBufferMemory] ';

        Integer triggerTurnCount = (agentConfig.SummarizationTriggerTurnCount__c != null &&
            agentConfig.SummarizationTriggerTurnCount__c > 0)
            ? agentConfig.SummarizationTriggerTurnCount__c.intValue()
            : 0;

        if (triggerTurnCount == 0) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Summarization trigger turn count is 0. Summarization is disabled for this execution.');
            return;
        }

        try {
            // Use ExecutionStep__c counting via ExecutionStepService
            ExecutionStepService executionStepService = new ExecutionStepService();
            Integer unsummarizedTurnCount = executionStepService.getUnsummarizedTurnCount(executionId);

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
                System.enqueueJob(new SummarizeConversationQueueable(executionId, agentConfig.Id));
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
