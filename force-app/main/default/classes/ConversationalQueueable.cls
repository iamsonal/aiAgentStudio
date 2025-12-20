/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ConversationalQueueable handles the LLM processing for low dispatch type conversational executions.
 * This queueable is enqueued by ConversationalOrchestrator when AsyncDispatchType__c is 'Low'.
 * It performs the LLM call and orchestrates the response in an asynchronous context.
 */
public class ConversationalQueueable implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id originalUserId;
    private final Id executionUserId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Id currentRecordId;
    private final String userMessage;

    public ConversationalQueueable(
        Id executionId,
        Id originalUserId,
        Id executionUserId,
        Id agentDefinitionId,
        Id llmConfigurationId,
        String turnIdentifier,
        Id currentRecordId,
        String userMessage
    ) {
        this.executionId = executionId;
        this.originalUserId = originalUserId;
        this.executionUserId = executionUserId;
        this.agentDefinitionId = agentDefinitionId;
        this.llmConfigurationId = llmConfigurationId;
        this.turnIdentifier = turnIdentifier;
        this.currentRecordId = currentRecordId;
        this.userMessage = userMessage;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[ConversationalQueueable Turn:' + turnIdentifier + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting LLM processing in queueable context');

        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, originalUserId);

            // Log user input
            decisionLogger.logUserInput('User Input Received', userMessage, null);

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                originalUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1,
                currentRecordId,
                false,
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new ConversationalQueueableException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                turnIdentifier,
                1,
                currentUserMessageData,
                currentRecordId,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed successfully. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'ERROR: LLM processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString()
            );

            // Mark turn as failed
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(
                    executionId,
                    turnIdentifier,
                    'LLM processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage()
                );
            }
        }
    }

    public class ConversationalQueueableException extends Exception {
    }
}
