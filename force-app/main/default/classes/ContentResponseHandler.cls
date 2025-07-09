/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy implementation for handling LLM responses that only contain text content.
 */
public class ContentResponseHandler implements ILLMResponseHandler {
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ContentHandler] ';

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        Id savedUserMessageId = ChatMessageService.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            null,
            logPrefix
        );

        if (String.isBlank(assistantData?.content)) {
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

        try {
            context.contextManagerSvc.commitTurnContext(context.sessionId, context.currentTurnCount, context.currentPageRecordId, null);
        } catch (Exception e) {
        }

        try {
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (String.isNotBlank(agentConfig.MemoryStrategy__c)) {
                LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentConfig.LLMConfiguration__c);
                IMemoryManager memoryManager = MemoryManagerFactory.getManager(agentConfig.MemoryStrategy__c);
                memoryManager.onTurnCompletion(context.sessionId, agentConfig, llmConfig, logPrefix);
            }
        } catch (Exception e) {
        }

        context.turnLifecycleSvc.completeTurnSuccessfully(context.sessionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }
}
