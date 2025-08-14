/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable class to handle AI agent LLM interactions asynchronously,
 *              preventing callout loop issues in REST context.
 */
public class AIAgentAsyncProcessor implements Queueable, Database.AllowsCallouts {
    private Id sessionId;
    private Id originalUserId;
    private Id agentDefinitionId;
    private Id llmConfigurationId;
    private String turnIdentifier;
    private String userMessage;
    private Id currentRecordId;
    private String logPrefix;

    /**
     * @description Constructor for the async processor
     */
    public AIAgentAsyncProcessor(
        Id sessionId,
        Id originalUserId,
        Id agentDefinitionId,
        Id llmConfigurationId,
        String turnIdentifier,
        String userMessage,
        Id currentRecordId,
        String logPrefix
    ) {
        this.sessionId = sessionId;
        this.originalUserId = originalUserId;
        this.agentDefinitionId = agentDefinitionId;
        this.llmConfigurationId = llmConfigurationId;
        this.turnIdentifier = turnIdentifier;
        this.userMessage = userMessage;
        this.currentRecordId = currentRecordId;
        this.logPrefix = logPrefix;
    }

    /**
     * @description Execute method for queueable processing
     */
    public void execute(QueueableContext context) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting async AI agent processing');

        try {
            // Create the user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            // Instantiate services
            OrchestrationService orchestrationSvc = new OrchestrationService();

            // Instantiate LLMInteractionService with the execution user context
            LLMInteractionService interactionService = new LLMInteractionService(
                sessionId,
                originalUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1, // Turn count
                currentRecordId,
                false // Not a retry
            );

            // Call the LLM interaction service (HTTP callouts are allowed in queueable context)
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new AIAgentAsyncException('LLMInteractionService returned a null result');
            }

            // Call OrchestrationService to process the LLM result
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                sessionId,
                originalUserId,
                UserInfo.getUserId(),
                agentDefinitionId,
                turnIdentifier,
                1, // Turn count
                currentUserMessageData,
                currentRecordId
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Async message processing completed successfully. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Async processing failed: ' + e.getMessage() + '\nStackTrace: ' + e.getStackTraceString());

            // Mark the turn as failed
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    sessionId,
                    turnIdentifier,
                    'Async processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark turn as failed: ' + failEx.getMessage());
            }
        }
    }

    /**
     * @description Custom exception for async processing errors
     */
    public class AIAgentAsyncException extends Exception {
    }
}
