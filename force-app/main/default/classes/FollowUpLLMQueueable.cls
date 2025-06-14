/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable Job: Handles subsequent LLM interactions after initial processing or tool execution.
 *              Performs LLM callout FIRST, then processes response and performs DML via OrchestrationService.
 */
public class FollowUpLLMQueueable implements Queueable, Database.AllowsCallouts {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;

    public virtual class FollowUpLLMException extends AIAgentException {
    }
    public class ConfigurationException extends FollowUpLLMException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }

    public FollowUpLLMQueueable(Id sessId, Id usrId, Id agentDefId, String turnId, Integer turnCount) {
        if (sessId == null || usrId == null || agentDefId == null || String.isBlank(turnId) || turnCount == null || turnCount < 1) {
            throw new IllegalArgumentException('Required arguments missing for FollowUpLLMQueueable.');
        }
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[FollowUpLLM:' + this.turnIdentifier?.left(8) + ' Cycle:' + this.currentTurnCount + ' Job:' + context.getJobId() + '] ';

        OrchestrationService orchestrationSvc = new OrchestrationService();
        TurnLifecycleService turnLifecycleSvcForFailure = new TurnLifecycleService();

        LLMInteractionService.LLMInteractionResult llmInteractionResult = null;
        ChatSession__c session = null;

        try {
            String expectedStatus = AIAgentConstants.STATUS_AWAITING_FOLLOWUP;

            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, AIAgentDefinition__r.LLMConfiguration__c, AIAgentDefinition__r.IsActive__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty()) {
                return;
            }
            session = sessions[0];

            if (session.CurrentTurnIdentifier__c == null || !session.CurrentTurnIdentifier__c.equals(this.turnIdentifier)) {
                return;
            }

            if (session.ProcessingStatus__c != expectedStatus) {
                return;
            }

            if (
                session.AIAgentDefinition__r == null ||
                !session.AIAgentDefinition__r.IsActive__c ||
                session.AIAgentDefinition__r.LLMConfiguration__c == null
            ) {
                throw new ConfigurationException('Agent Definition inactive or LLM Configuration missing for Session: ' + this.chatSessionId);
            }

            Id llmConfigurationId = session.AIAgentDefinition__r.LLMConfiguration__c;
            Id relatedRecordId = null;

            List<ChatMessage__c> userTurnMessages = [
                SELECT RecordContextId__c
                FROM ChatMessage__c
                WHERE ExternalId__c = :this.turnIdentifier AND Role__c = 'user'
                LIMIT 1
            ];
            if (!userTurnMessages.isEmpty()) {
                relatedRecordId = userTurnMessages[0].RecordContextId__c;
            }

            LLMInteractionService interactionService = new LLMInteractionService(
                this.chatSessionId,
                this.userId,
                this.agentDefinitionId,
                llmConfigurationId,
                this.turnIdentifier,
                this.currentTurnCount,
                relatedRecordId
            );
            llmInteractionResult = interactionService.prepareAndCallLLM(null);

            if (llmInteractionResult == null) {
                throw new FollowUpLLMException('LLMInteractionService returned a null result, which is unexpected.');
            }

            String outcome = orchestrationSvc.processLlmResult(
                llmInteractionResult,
                this.chatSessionId,
                this.userId,
                this.agentDefinitionId,
                relatedRecordId,
                this.turnIdentifier,
                this.currentTurnCount,
                null
            );
        } catch (Exception ex) {
            try {
                ChatSession__c currentStateCheck = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :this.chatSessionId LIMIT 1];
                if (currentStateCheck.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
                    String errorDetail = ('Queueable Exception in FollowUpLLM: ' + ex.getMessage()).abbreviate(131072);
                    turnLifecycleSvcForFailure.failTurn(
                        this.chatSessionId,
                        this.turnIdentifier,
                        errorDetail,
                        AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                        logPrefix
                    );
                } else {
                }
            } catch (Exception finalFailEx) {
            }
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }
}
