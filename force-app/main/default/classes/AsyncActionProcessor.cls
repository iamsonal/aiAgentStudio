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
 *   - Ensures robust error handling and execution state management throughout the action lifecycle
 *   - Surfaces operational and execution issues clearly via debug output for maintainability
 *   - Uses the unified AgentExecution__c and ExecutionStep__c data models exclusively
 *
 * This class is not intended to be instantiated or extended outside the framework.
 */
public class AsyncActionProcessor {
    // Core execution properties
    private final Id executionId;
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
     * Constructor for asynchronous action processing using the unified AgentExecution__c model.
     *
     * @param executionId      The execution ID (AgentExecution__c).
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
        Id executionId,
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
        this.executionId = executionId;
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

        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(this.executionId, this.turnIdentifier, this.originalUserId);

        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        ActionExecutionService actionService = new ActionExecutionService();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);

        try {
            // Validate execution state to prevent stale executions
            ExecutionContextService executionContextService = new ExecutionContextService();
            AgentExecution__c execution = executionContextService.validateAndGetExecution(this.executionId, this.turnIdentifier);
            if (execution == null || execution.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_ACTION) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Stale execution detected or execution in unexpected state - aborting action execution');
                return;
            }

            // Update execution status to indicate active action processing
            turnLifecycleSvc.startTurnProcessing(this.executionId, this.turnIdentifier, null, logPrefix);

            // Execute the action with performance tracking
            Long actionDuration = 0L;
            ActionOutcome outcome = null;
            Long actionStartTime = System.currentTimeMillis();
            try {
                ActionContext actionContext = new ActionContext(
                    this.executionId,
                    this.originalUserId,
                    executionUserId,
                    this.relatedRecordId,
                    this.agentDefinitionId,
                    this.capability.Id,
                    this.capability.ImplementationDetail__c,
                    this.turnIdentifier,
                    this.currentTurnCount,
                    'Conversational' // Default execution type
                );
                outcome = actionService.executeSingleAction(this.capability, this.llmArgumentsJson, actionContext);
            } catch (Exception ex) {
                outcome = ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    'Async Action failed internally: ' + ex.getMessage() + '\n' + ex.getStackTraceString()
                );
            } finally {
                actionDuration = System.currentTimeMillis() - actionStartTime;
            }

            // Process and store the action execution outcome
            String resultJsonForStorage = OrchestrationService.serializeActionOutcome(outcome, logPrefix);
            Id newRecordContextId = OrchestrationService.extractRecordIdFromOutcome(outcome);

            decisionLogger.logToolResult(
                'Tool Execution Completed (Async)',
                'Asynchronous tool execution has completed',
                resultJsonForStorage,
                actionDuration,
                outcome.isSuccess,
                outcome.errorCode,
                outcome.errorMessage
            );

            // Save the tool result using ExecutionStep__c
            ExecutionStepService executionStepService = new ExecutionStepService();
            executionStepService.createToolResultStep(
                this.executionId,
                this.toolCallId,
                this.capability.CapabilityName__c,
                resultJsonForStorage,
                this.turnIdentifier,
                this.currentTurnCount,
                actionDuration
            );

            // Validate turn limits and dispatch follow-up processing
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((this.currentTurnCount + 1) > maxTurns) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Maximum conversation turns exceeded (' + maxTurns + ') - terminating processing');
                turnLifecycleSvc.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    'Maximum processing cycles reached.',
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
            } else {
                turnLifecycleSvc.resumeForFollowUpLlmCall(this.executionId, this.turnIdentifier, null, logPrefix);
                orchestrationDispatchSvc.enqueueFollowUp(
                    this.executionId,
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
                    this.executionId,
                    this.turnIdentifier,
                    'Action processor internal error: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception finalFailEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution state during error handling: ' + finalFailEx.getMessage());
            }
        } finally {
            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Asynchronous action processing completed');
        }
    }
}
