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

        Id savedUserMessageId = context.msgPersistenceSvc.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            context.relatedRecordId,
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

        Id savedAssistantMessageId = context.msgPersistenceSvc.saveAssistantMessage(context.sessionId, savedUserMessageId, assistantData, logPrefix);
        context.turnLifecycleSvc.completeTurnSuccessfully(context.sessionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }
}
