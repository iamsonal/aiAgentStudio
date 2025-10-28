/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Core asynchronous action execution engine for the AI Agent Framework.
 * Handles action processing lifecycle: validation, execution, result processing, and orchestration.
 */
public class AsyncActionEngine {
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
     * Constructor for asynchronous action processing.
     *
     * @param executionId      Execution ID
     * @param origUserId       Original user ID
     * @param agentDefId       Agent definition ID
     * @param parentMsgId      Parent message ID
     * @param toolCallId       Tool call ID
     * @param llmArgs          LLM arguments JSON
     * @param cap              Agent capability
     * @param relId            Related record ID
     * @param turnId           Turn identifier
     * @param turnCount        Turn count
     */
    public AsyncActionEngine(
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
     * Main processing method for asynchronous action execution.
     *
     * @param jobIdForLogging Job ID for logging purposes
     */
    public void process(String jobIdForLogging) {
        Id executionUserId = UserInfo.getUserId();

        String logPrefix =
            '[AsyncActionEngine:' +
            this.turnIdentifier?.left(8) +
            ' Turn:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            (jobIdForLogging != null ? jobIdForLogging : 'PlatformEvent') +
            '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting asynchronous execution for capability: ' + this.capability.CapabilityName__c);

        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(this.executionId, this.turnIdentifier, this.originalUserId);

        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        CapabilityExecutionRouter actionService = new CapabilityExecutionRouter();
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
                actionDuration,
                true // isAsyncToolExecution - asynchronous execution
            );

            // FAIL-FAST CHECK: Apply three-tier error handling policy
            // This ensures async tools respect the same error handling policy as sync tools
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            Boolean shouldFailFast = OrchestrationService.shouldFailFast(this.capability, agentDefinition, outcome, logPrefix);

            if (!outcome.isSuccess && shouldFailFast) {
                // Tool failed and policy requires immediate failure
                System.debug(LoggingLevel.WARN, logPrefix + 'Async tool failed with fail-fast policy enabled. Halting execution immediately.');

                decisionLogger.logToolResult(
                    'Fail-Fast Policy Triggered',
                    'Async tool execution failed and fail-fast policy is enabled - halting execution',
                    '{"reason":"fail_fast_policy","capability":"' + this.capability.CapabilityName__c + '"}',
                    0,
                    false,
                    outcome.errorCode,
                    outcome.errorMessage
                );

                turnLifecycleSvc.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    'Async tool execution failed (fail-fast policy): ' + outcome.errorMessage,
                    outcome.errorCode != null ? outcome.errorCode : AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    logPrefix
                );
                return; // Don't continue to follow-up processing
            }

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
                // Check if this is part of a parallel execution and if all async tools are complete
                ParallelResultGatherer.onAsyncToolCompleted(this.executionId, this.turnIdentifier, this.currentTurnCount, this.toolCallId, logPrefix);
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
