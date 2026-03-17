/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Shared executor for the initial iterative LLM turn.
 * Centralizes deferred-DML setup, orchestration, and cleanup so all
 * entrypoints follow the same callout-safe transaction contract.
 */
public inherited sharing class ConversationalTurnExecutionService {
    public class RunResult {
        public Boolean success { get; set; }
        public String outcome { get; set; }
        public Integer llmCallCount { get; set; }
        public String errorMessage { get; set; }
    }

    public RunResult executeInitialTurn(
        Id executionId,
        Id originalUserId,
        Id executionUserId,
        Id agentDefinitionId,
        Id llmConfigurationId,
        String turnIdentifier,
        String userMessage,
        Id currentRecordId,
        String logPrefix
    ) {
        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, turnIdentifier, originalUserId);
        RunResult result = new RunResult();

        try {
            String userName = getUserName(originalUserId);
            String agentName = AIAgentConfigService.getAgentName(agentDefinitionId);
            decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ userMessage, userName, agentName });

            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            TransactionContext txnCtx = TransactionContext.getInstance();
            txnCtx.enableDeferredDMLMode();
            txnCtx.incrementLLMCallCount();
            txnCtx.resetTurnSafetyTracking();
            txnCtx.setHasPreExistingExecution(true);

            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome;
            Integer currentTurnCount = 1;

            do {
                LLMInteractionService interactionService = new LLMInteractionService(
                    executionId,
                    originalUserId,
                    agentDefinitionId,
                    llmConfigurationId,
                    turnIdentifier,
                    currentTurnCount,
                    currentRecordId,
                    false,
                    decisionLogger
                );

                LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(
                    currentTurnCount == 1 ? currentUserMessageData : null
                );
                if (llmResult == null) {
                    throw new AIAgentException.OrchestrationException('LLMInteractionService returned a null result');
                }

                outcome = orchestrationSvc.processLlmResult(
                    llmResult,
                    executionId,
                    originalUserId,
                    executionUserId,
                    agentDefinitionId,
                    turnIdentifier,
                    currentTurnCount,
                    currentTurnCount == 1 ? currentUserMessageData : null,
                    currentRecordId,
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    txnCtx.incrementLLMCallCount();
                    txnCtx.resetTurnSafetyTracking();
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Continuing with immediate follow-up (turn ' + currentTurnCount + ')');
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            result.success = true;
            result.outcome = outcome;
            result.llmCallCount = txnCtx.getLLMCallCount();
            System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed. Final outcome: ' + outcome + ', Total LLM calls: ' + result.llmCallCount);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: LLM processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());
            try {
                new AgentStateService()
                    .failTurn(executionId, turnIdentifier, 'LLM processing failed: ' + e.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage());
            }
            result.success = false;
            result.outcome = OrchestrationService.OUTCOME_FAILED;
            result.errorMessage = e.getMessage();
            result.llmCallCount = TransactionContext.getInstance().getLLMCallCount();
        } finally {
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }
            decisionLogger.commitSteps();
        }

        return result;
    }

    private String getUserName(Id userId) {
        if (userId == null) {
            return null;
        }

        try {
            List<User> users = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
            return users.isEmpty() ? null : users[0].Name;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ConversationalTurnExecutionService] Failed to query user name for ID: ' + userId + '. Error: ' + e.getMessage());
            return null;
        }
    }
}
