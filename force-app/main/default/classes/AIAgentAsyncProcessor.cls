/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentAsyncProcessor is a queueable asynchronous processor for AI agent LLM interactions.
 * It is designed to:
 *   - Execute LLM message processing in a queueable context, enabling HTTP callouts
 *   - Prevent callout loop issues when invoked from REST endpoints
 *   - Maintain correct user and session context throughout the interaction lifecycle
 *   - Ensure robust error handling and session state consistency on failures
 *
 * This class is the single entry point for asynchronous LLM message processing within the agent framework.
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
     * Constructs an asynchronous processor for LLM message handling.
     *
     * @param sessionId         The ID of the chat session.
     * @param originalUserId    The ID of the user who initiated the session.
     * @param agentDefinitionId The ID of the agent definition.
     * @param llmConfigurationId The ID of the LLM configuration.
     * @param turnIdentifier    The unique identifier for the current turn.
     * @param userMessage       The message content from the user.
     * @param currentRecordId   The current record context, if any.
     * @param logPrefix         A logging prefix for debug output.
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
     * Executes the asynchronous LLM message processing logic in a queueable context.
     *
     * @param context The QueueableContext provided by the platform.
     * @sideeffect May perform HTTP callouts, update session state, and log errors.
     * @throws AIAgentAsyncException if LLM interaction returns null or other unrecoverable error occurs.
     */
    public void execute(QueueableContext context) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + '[AIAgentAsyncProcessor] Starting asynchronous LLM message processing. SessionId=' + sessionId + ', TurnId=' + turnIdentifier
        );

        try {
            // Prepare the user message data for LLM interaction
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            OrchestrationService orchestrationSvc = new OrchestrationService();

            // Instantiate LLMInteractionService with the execution user context
            LLMInteractionService interactionService = new LLMInteractionService(
                sessionId,
                originalUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1, // Turn count (always 1 for async entry)
                currentRecordId,
                false // Not a retry
            );

            // Execute LLM interaction (HTTP callouts are permitted in queueable context)
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new AIAgentAsyncException('LLMInteractionService returned a null result');
            }

            // Process the LLM result using the orchestration service
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

            System.debug(
                LoggingLevel.INFO,
                logPrefix + '[AIAgentAsyncProcessor] Asynchronous message processing completed successfully. Outcome: ' + outcome
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    '[AIAgentAsyncProcessor] ERROR: Asynchronous processing failed. Exception: ' +
                    e.getMessage() +
                    '\nStack Trace: ' +
                    e.getStackTraceString()
            );

            // Attempt to mark the turn as failed to maintain session state consistency
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    sessionId,
                    turnIdentifier,
                    'Asynchronous processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + '[AIAgentAsyncProcessor] CRITICAL: Failed to update session state after processing failure: ' + failEx.getMessage()
                );
            }
        }
    }

    /**
     * Exception for unrecoverable errors during asynchronous LLM processing.
     */
    public class AIAgentAsyncException extends Exception {
    }
}
