/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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

        Id llmConfigurationId = null;
        Id relatedRecordId = null;
        Exception queueableProcessingException = null;

        OrchestrationService orchestrationSvc = new OrchestrationService();
        TurnLifecycleService turnLifecycleSvcForFailure = new TurnLifecycleService();

        ChatSession__c session = null;
        LLMInteractionService.LLMInteractionResult llmInteractionResult = null;

        try {
            List<ChatSession__c> sessions = [
                SELECT
                    Id,
                    ProcessingStatus__c,
                    CurrentTurnIdentifier__c,
                    RelatedRecordId__c,
                    CurrentJobId__c /* Added for more robust check */,
                    AIAgentDefinition__r.LLMConfiguration__c,
                    AIAgentDefinition__r.IsActive__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty()) {
                return;
            }
            session = sessions[0];

            if (!String.escapeSingleQuotes(session.CurrentTurnIdentifier__c).equals(String.escapeSingleQuotes(this.turnIdentifier))) {
                return;
            }

            if (session.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_FOLLOWUP) {
                return;
            }

            if (
                session.AIAgentDefinition__r == null ||
                !session.AIAgentDefinition__r.IsActive__c ||
                session.AIAgentDefinition__r.LLMConfiguration__c == null
            ) {
                throw new ConfigurationException('Agent Definition inactive or LLM Configuration missing for Session: ' + this.chatSessionId);
            }

            relatedRecordId = session.RelatedRecordId__c;
            llmConfigurationId = session.AIAgentDefinition__r.LLMConfiguration__c;

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
            queueableProcessingException = ex;

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
