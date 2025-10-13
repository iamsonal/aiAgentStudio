/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * EmailQueueable handles the LLM processing for email-triggered executions.
 * This queueable is enqueued by EmailOrchestrator to process email content.
 */
public class EmailQueueable implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Id userId;
    private final String emailContent;

    public EmailQueueable(Id executionId, Id agentDefinitionId, Id llmConfigurationId, String turnIdentifier, Id userId, String emailContent) {
        this.executionId = executionId;
        this.agentDefinitionId = agentDefinitionId;
        this.llmConfigurationId = llmConfigurationId;
        this.turnIdentifier = turnIdentifier;
        this.userId = userId;
        this.emailContent = emailContent;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[EmailQueueable Turn:' + turnIdentifier + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting email processing in queueable context');

        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, userId);

            // Log email input
            decisionLogger.logUserInput('Email Received', emailContent, null);

            // Prepare email message data
            LLMInteractionService.MessageData emailMessageData = new LLMInteractionService.MessageData();
            emailMessageData.role = AIAgentConstants.ROLE_USER;
            emailMessageData.content = emailContent;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                userId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1,
                null,
                false,
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(emailMessageData);

            if (llmResult == null) {
                throw new EmailQueueableException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                userId,
                userId,
                agentDefinitionId,
                turnIdentifier,
                1,
                emailMessageData,
                null,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Email processing completed successfully. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'ERROR: Email processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString()
            );

            // Mark turn as failed
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    executionId,
                    turnIdentifier,
                    'Email processing failed: ' + e.getMessage(),
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

    public class EmailQueueableException extends Exception {
    }
}
