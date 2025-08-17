/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContentResponseHandler processes LLM responses that contain only textual content (no tool calls),
 * orchestrating the full flow from message persistence to context ledger updates and memory management.
 *
 * Responsibilities:
 *   - Persists user and assistant messages for a text-only LLM turn
 *   - Validates LLM response content and handles error/failure scenarios
 *   - Updates the context ledger and invokes memory management hooks
 *   - Ensures robust logging and error handling throughout the response lifecycle
 *
 * This class is not intended for direct use outside the orchestration and response handling subsystems.
 */
public class ContentResponseHandler implements ILLMResponseHandler {
    /**
     * Handles an LLM response containing only textual content (no tool calls).
     * Orchestrates message persistence, context ledger update, memory management, and error handling.
     *
     * @param context The orchestration context for the current LLM turn.
     * @return        OUTCOME_COMPLETED if successful, OUTCOME_FAILED if validation or persistence fails.
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ContentHandler] ';
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Handling text-only LLM response for session: ' + context.sessionId + ', turn: ' + context.turnIdentifier
        );

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        // Persist the user message as the parent of the assistant's reply
        Id savedUserMessageId = ChatMessageService.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            null,
            logPrefix
        );

        if (String.isBlank(assistantData?.content)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Validation failed: LLM response content is empty.');
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                'LLM returned empty successful response.',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        Id savedAssistantMessageId = ChatMessageService.saveAssistantMessage(
            context.sessionId,
            context.turnIdentifier,
            savedUserMessageId,
            assistantData,
            null,
            logPrefix
        );

        // Commit the turn context to the ledger for traceability
        try {
            context.contextManagerSvc.commitTurnContext(context.sessionId, context.currentTurnCount, context.currentPageRecordId, null);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context ledger update failed: ' + e.getMessage());
        }

        // Invoke memory management completion hook if configured
        try {
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (String.isNotBlank(agentConfig.MemoryStrategy__c)) {
                LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentConfig.LLMConfiguration__c);
                IMemoryManager memoryManager = MemoryManagerFactory.getManager(agentConfig.MemoryStrategy__c);
                memoryManager.onTurnCompletion(context.sessionId, agentConfig, llmConfig, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Memory management completion hook failed: ' + e.getMessage());
        }

        context.turnLifecycleSvc.completeTurnSuccessfully(context.sessionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }
}
