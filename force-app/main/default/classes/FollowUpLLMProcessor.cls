/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * FollowUpLLMProcessor coordinates the post-tool-execution phase of an LLM-driven chat session, handling follow-up LLM interactions
 * after asynchronous operations complete. It validates session state, invokes the LLM, processes results, and manages error handling
 * and logging. The class is context-agnostic and can be invoked from Queueable jobs, Platform Events, or other triggers.
 *
 * Responsibilities:
 *   - Validate session and turn state before proceeding with follow-up LLM processing
 *   - Invoke LLM interaction logic and process the resulting output
 *   - Handle both success and error scenarios, including marking turns as failed if needed
 *   - Provide clear, actionable debug output and commit logs for diagnostics
 *   - Remain agnostic to invocation context for flexible integration
 */
public class FollowUpLLMProcessor {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Boolean isFinalErrorTurn;

    /**
     * Constructs a new FollowUpLLMProcessor with all required context for follow-up processing.
     *
     * @param sessId        The chat session ID for this interaction.
     * @param usrId         The original user ID who initiated the conversation.
     * @param agentDefId    The AI agent definition ID being used.
     * @param turnId        The unique turn identifier for tracking this conversation turn.
     * @param turnCount     The current turn number in the conversation.
     * @param isFinalError  Whether this is a final error turn that should terminate the conversation.
     */
    public FollowUpLLMProcessor(Id sessId, Id usrId, Id agentDefId, String turnId, Integer turnCount, Boolean isFinalError) {
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.isFinalErrorTurn = isFinalError;
    }

    /**
     * Executes the follow-up LLM processing logic for a completed tool execution.
     *
     * This method validates session and turn state, invokes the LLM, processes the result, and handles errors.
     * It is safe to call from Queueable jobs, Platform Events, or other asynchronous triggers.
     *
     * @param jobIdForLogging  The Apex Job ID or other identifier for logging purposes. Can be null.
     * @return                 None.
     * @throws                 Does not propagate exceptions; all errors are handled and logged internally.
     * @sideeffects            Writes to debug logs, may update session/turn state, and commits orchestration logs.
     */
    public void process(String jobIdForLogging) {
        String logPrefix =
            '[FollowUpLLMProcessor:' +
            this.turnIdentifier?.left(8) +
            ' Cycle:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            (jobIdForLogging != null ? jobIdForLogging : 'PlatformEvent') +
            '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Begin follow-up LLM processing for turn.');

        OrchestrationService orchestrationSvc = new OrchestrationService();
        TurnLifecycleService turnLifecycleSvcForFailure = new TurnLifecycleService();

        try {
            // Validate session and turn state before proceeding
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
                System.debug(LoggingLevel.WARN, logPrefix + 'Session state mismatch or stale job detected. Aborting follow-up processing.');
                return;
            }
            Id executionUserId = UserInfo.getUserId();
            Id originalUserId = this.userId;
            // Perform LLM callout for follow-up interaction
            LLMInteractionService interactionService = new LLMInteractionService(
                this.chatSessionId,
                originalUserId,
                this.agentDefinitionId,
                sessions[0].AIAgentDefinition__r.LLMConfiguration__c,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                this.isFinalErrorTurn
            );
            LLMInteractionService.LLMInteractionResult llmInteractionResult = interactionService.prepareAndCallLLM(null);
            // Process the LLM result and update orchestration state
            String outcome = orchestrationSvc.processLlmResult(
                llmInteractionResult,
                this.chatSessionId,
                originalUserId,
                executionUserId,
                this.agentDefinitionId,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                null
            );
            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM orchestration outcome: ' + outcome);
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    'Exception during follow-up LLM processing: ' +
                    ex.getTypeName() +
                    ': ' +
                    ex.getMessage() +
                    '\n' +
                    ex.getStackTraceString()
            );
            try {
                turnLifecycleSvcForFailure.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Processor Exception: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception finalFailEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Failed to mark turn as failed after exception: ' + finalFailEx.getTypeName() + ': ' + finalFailEx.getMessage()
                );
            }
        } finally {
            OrchestrationLogger.commitLogs();
            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM processing finished.');
        }
    }
}
