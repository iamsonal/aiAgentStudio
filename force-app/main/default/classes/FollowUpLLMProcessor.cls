/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Core logic handler for a follow-up LLM interaction after a tool execution.
 *              This class is agnostic of its invocation context (Queueable, Platform Event, etc.).
 */
public class FollowUpLLMProcessor {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Boolean isFinalErrorTurn;

    public FollowUpLLMProcessor(Id sessId, Id usrId, Id agentDefId, String turnId, Integer turnCount, Boolean isFinalError) {
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.isFinalErrorTurn = isFinalError;
    }

    /**
     * @description Main processing method containing the logic from the old Queueable's execute method.
     * @param jobIdForLogging The Apex Job ID or other identifier for logging purposes. Can be null.
     */
    public void process(String jobIdForLogging) {
        String logPrefix =
            '[FollowUpLLMProcessor:' +
            this.turnIdentifier?.left(8) +
            ' Cycle:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            jobIdForLogging +
            '] ';

        OrchestrationService orchestrationSvc = new OrchestrationService();
        TurnLifecycleService turnLifecycleSvcForFailure = new TurnLifecycleService();

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, AIAgentDefinition__r.LLMConfiguration__c, AIAgentDefinition__r.IsActive__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (
                sessions.isEmpty() ||
                !this.turnIdentifier.equals(sessions[0].CurrentTurnIdentifier__c) ||
                sessions[0].ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_FOLLOWUP
            ) {
                return;
            }

            LLMInteractionService interactionService = new LLMInteractionService(
                this.chatSessionId,
                this.userId,
                this.agentDefinitionId,
                sessions[0].AIAgentDefinition__r.LLMConfiguration__c,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                this.isFinalErrorTurn
            );
            LLMInteractionService.LLMInteractionResult llmInteractionResult = interactionService.prepareAndCallLLM(null);

            String outcome = orchestrationSvc.processLlmResult(
                llmInteractionResult,
                this.chatSessionId,
                this.userId,
                this.agentDefinitionId,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                null
            );
        } catch (Exception ex) {
            try {
                turnLifecycleSvcForFailure.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Processor Exception: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception finalFailEx) {
                /* Log and swallow */
            }
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }
}
