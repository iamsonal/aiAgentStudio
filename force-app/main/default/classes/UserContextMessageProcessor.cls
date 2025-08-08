/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable job to process messages in switched user context.
 *              This allows HTTP callouts which are not permitted in platform event triggers.
 */
public class UserContextMessageProcessor implements Queueable, Database.AllowsCallouts {
    private UserContextSwitchEvent__e contextEvent;

    public UserContextMessageProcessor(UserContextSwitchEvent__e event) {
        this.contextEvent = event;
    }

    public void execute(QueueableContext context) {
        Id executionUserId = UserInfo.getUserId();
        Id originalUserId = Id.valueOf(contextEvent.OriginalUserId__c);

        String logPrefix = '[UserContextMessageProcessor OrigUser:' + originalUserId + ' ExecUser:' + executionUserId + '] ';

        try {
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(contextEvent.AgentDefinitionId__c);
            if (agentDefinition == null) {
                throw new UserContextException('Agent definition not found: ' + contextEvent.AgentDefinitionId__c);
            }

            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = contextEvent.UserMessage__c;

            Id currentRecordId = String.isNotBlank(contextEvent.CurrentRecordId__c) ? Id.valueOf(contextEvent.CurrentRecordId__c) : null;

            OrchestrationService orchestrationSvc = new OrchestrationService();

            LLMInteractionService interactionService = new LLMInteractionService(
                contextEvent.SessionId__c,
                originalUserId,
                contextEvent.AgentDefinitionId__c,
                agentDefinition.LLMConfiguration__c,
                contextEvent.TurnIdentifier__c,
                1,
                currentRecordId,
                false
            );

            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new UserContextException('LLMInteractionService returned a null result.');
            }

            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                contextEvent.SessionId__c,
                originalUserId,
                executionUserId,
                contextEvent.AgentDefinitionId__c,
                contextEvent.TurnIdentifier__c,
                1,
                currentUserMessageData,
                currentRecordId
            );
        } catch (Exception e) {
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    contextEvent.SessionId__c,
                    contextEvent.TurnIdentifier__c,
                    'Context switch processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
            }
        }
    }

    public class UserContextException extends AIAgentException {
    }
}
