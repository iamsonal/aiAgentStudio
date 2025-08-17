/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AsyncActionProcessor is the core asynchronous action execution engine for the AI Agent Framework.
 * Responsibilities:
 *   - Handles individual agent actions independently of invocation context (user, REST, or platform event)
 *   - Provides comprehensive action execution lifecycle management: validation, execution, result processing, and follow-up orchestration
 *   - Ensures robust error handling and session state management throughout the action lifecycle
 *   - Surfaces operational and execution issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended outside the framework.
 */
public class AsyncActionProcessor {
    // Properties are identical to the original Queueable
    private final Id chatSessionId;
    private final Id originalUserId;
    private final Id agentDefinitionId;
    private final Id parentAssistantMessageId;
    private final String toolCallId;
    private final String llmArgumentsJson;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Id relatedRecordId;
    private final AgentCapability__c capability;

    /**
     * Constructs an AsyncActionProcessor for a single agent action execution.
     *
     * @param sessId           The chat session ID.
     * @param origUserId       The original user ID.
     * @param agentDefId       The agent definition ID.
     * @param parentMsgId      The parent assistant message ID.
     * @param toolCallId       The tool call ID.
     * @param llmArgs          The LLM arguments as a JSON string.
     * @param cap              The AgentCapability__c record to execute.
     * @param relId            The related record ID for context.
     * @param turnId           The unique turn identifier.
     * @param turnCount        The current turn count.
     */
    public AsyncActionProcessor(
        Id sessId,
        Id origUserId,
        Id agentDefId,
        Id parentMsgId,
        String toolCallId,
        String llmArgs,
        AgentCapability__c cap,
        Id relId,
        String turnId,
        Integer turnCount
    ) {
        this.chatSessionId = sessId;
        this.originalUserId = origUserId;
        this.agentDefinitionId = agentDefId;
        this.parentAssistantMessageId = parentMsgId;
        this.toolCallId = toolCallId;
        this.llmArgumentsJson = llmArgs;
        this.capability = cap;
        this.relatedRecordId = relId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    /**
     * Main processing method for asynchronous agent action execution.
     * Handles session validation, action execution, result processing, and follow-up orchestration.
     *
     * @param jobIdForLogging The Apex Job ID or other identifier for logging purposes. Can be null.
     * @sideeffect May update session state, enqueue follow-up jobs, and log errors.
     */
    public void process(String jobIdForLogging) {
        Id executionUserId = UserInfo.getUserId();

        String logPrefix =
            '[AsyncActionProcessor:' +
            this.turnIdentifier?.left(8) +
            ' Turn:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            (jobIdForLogging != null ? jobIdForLogging : 'PlatformEvent') +
            '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting asynchronous execution for capability: ' + this.capability.CapabilityName__c);

        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        ActionExecutionService actionService = new ActionExecutionService();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);

        try {
            // Lock session and validate current state to prevent stale executions
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (
                sessions.isEmpty() ||
                !this.turnIdentifier.equals(sessions[0].CurrentTurnIdentifier__c) ||
                sessions[0].ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_ACTION
            ) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Stale execution detected or session in unexpected state - aborting action execution');
                return;
            }

            // Update session status to indicate active action processing
            turnLifecycleSvc.startTurnProcessing(this.chatSessionId, this.turnIdentifier, null, logPrefix);

            // Execute the action with performance tracking
            Long actionDuration = 0L;
            ActionResult actionResult;
            Long actionStartTime = System.currentTimeMillis();
            try {
                ActionContext actionContext = new ActionContext(
                    this.chatSessionId,
                    this.originalUserId,
                    executionUserId,
                    this.relatedRecordId,
                    this.agentDefinitionId,
                    this.capability.Id,
                    this.capability.ImplementationDetail__c,
                    this.turnIdentifier,
                    this.currentTurnCount
                );
                actionResult = actionService.executeSingleAction(this.capability, this.llmArgumentsJson, actionContext);
            } catch (Exception ex) {
                actionResult = new ActionResult(
                    'Async Action failed internally: ' + ex.getMessage(),
                    ex.getStackTraceString(),
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION
                );
            } finally {
                actionDuration = System.currentTimeMillis() - actionStartTime;
            }

            // Process and store the action execution result
            String resultJsonForStorage = OrchestrationService.serializeActionResult(actionResult, logPrefix);
            Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);

            ChatMessageService.saveToolResultMessage(
                this.chatSessionId,
                this.turnIdentifier,
                this.parentAssistantMessageId,
                this.toolCallId,
                resultJsonForStorage,
                actionResult.internalDetails,
                actionResult.errorCode,
                actionDuration,
                newRecordContextId,
                resultJsonForStorage,
                this.capability.CapabilityName__c,
                logPrefix
            );

            // Validate turn limits and dispatch follow-up processing
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((this.currentTurnCount + 1) > maxTurns) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Maximum conversation turns exceeded (' + maxTurns + ') - terminating processing');
                turnLifecycleSvc.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Maximum processing cycles reached.',
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
            } else {
                turnLifecycleSvc.resumeForFollowUpLlmCall(this.chatSessionId, this.turnIdentifier, null, logPrefix);
                orchestrationDispatchSvc.enqueueFollowUp(
                    this.chatSessionId,
                    this.originalUserId,
                    this.agentDefinitionId,
                    this.turnIdentifier,
                    this.currentTurnCount + 1,
                    logPrefix,
                    false
                );
            }
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    'CRITICAL: Unhandled exception during action processing: ' +
                    ex.getMessage() +
                    '\nStack Trace: ' +
                    ex.getStackTraceString()
            );
            try {
                turnLifecycleSvc.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Action processor internal error: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception finalFailEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update session state during error handling: ' + finalFailEx.getMessage());
            }
        } finally {
            OrchestrationLogger.commitLogs();
            System.debug(LoggingLevel.INFO, logPrefix + 'Asynchronous action processing completed');
        }
    }
}
