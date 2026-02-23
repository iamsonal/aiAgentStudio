/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Core asynchronous action execution engine. Handles action processing lifecycle: validation, execution, result processing, and orchestration.
 */
public without sharing class AsyncActionEngine implements Queueable, Database.AllowsCallouts {
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
     * Queueable execute method for async job invocation.
     * Delegates to the process() method with job ID for logging.
     *
     * @param context The QueueableContext provided by the platform
     */
    public void execute(QueueableContext context) {
        String jobId = context.getJobId();
        process(jobId);
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

        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(this.executionId, this.turnIdentifier, this.originalUserId);

        AgentStateService agentStateSvc = new AgentStateService();
        CapabilityExecutionService actionService = new CapabilityExecutionService();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(agentStateSvc);

        try {
            // Validate execution state to prevent stale executions
            AgentStateService agentStateService = new AgentStateService();
            AgentExecution__c execution = agentStateService.validateAndGetExecution(this.executionId, this.turnIdentifier);
            if (execution == null || execution.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_ACTION) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Stale execution detected or execution in unexpected state - aborting action execution');
                return;
            }

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

            // Add async execution flag and tool metadata to the result for decision step logging
            Map<String, Object> resultWithMetadata = (Map<String, Object>) JSON.deserializeUntyped(resultJsonForStorage);
            resultWithMetadata.put('isAsyncToolExecution', true);
            resultWithMetadata.put('toolName', this.capability.CapabilityName__c);
            resultWithMetadata.put('toolCallId', this.toolCallId);
            String enhancedResultJson = JSON.serialize(resultWithMetadata);

            Id newRecordContextId = OrchestrationService.extractRecordIdFromOutcome(outcome);

            decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ this.capability, outcome, actionDuration });

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
                true, // isAsyncToolExecution - asynchronous execution
                this.capability.Id,
                !outcome.isSuccess // isError = !isSuccess
            );

            // FAIL-FAST CHECK: Apply error handling policy
            // Pre-load execution state and failure count once (on failure only) so that:
            //   a) IsToolTerminatingMode__c and LastFunctionResumeTimestamp__c share one SOQL
            //   b) The failure count is scoped to the post-resume window, preventing pre-resume
            //      failures from depleting the circuit breaker budget on resumed executions.
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            Integer preloadedFailureCount = -1;
            Boolean isToolTerminatingMode = false;
            if (!outcome.isSuccess) {
                AgentExecution__c executionRecord = [
                    SELECT IsToolTerminatingMode__c, LastFunctionResumeTimestamp__c
                    FROM AgentExecution__c
                    WHERE Id = :this.executionId
                    LIMIT 1
                ];
                isToolTerminatingMode = executionRecord.IsToolTerminatingMode__c == true;
                preloadedFailureCount = OrchestrationService.countSuccessiveToolFailures(
                    this.executionId,
                    this.capability.CapabilityName__c,
                    executionRecord.LastFunctionResumeTimestamp__c,
                    logPrefix
                );
            }

            Boolean shouldFailFast = OrchestrationService.shouldFailFast(
                this.capability,
                agentDefinition,
                outcome,
                this.executionId,
                preloadedFailureCount,
                logPrefix
            );

            if (isToolTerminatingMode && !shouldFailFast) {
                shouldFailFast = true;
                System.debug(LoggingLevel.INFO, logPrefix + 'Tool-terminating mode detected. Overriding autonomous recovery - failing execution immediately.');
            }

            if (!outcome.isSuccess && shouldFailFast) {
                // Tool failed and policy requires immediate failure (could be fail-fast or max retries exceeded)
                Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
                Integer failureCount = preloadedFailureCount >= 0
                    ? preloadedFailureCount
                    : OrchestrationService.countSuccessiveToolFailures(this.executionId, this.capability.CapabilityName__c, logPrefix);
                String failureReason;
                String logMessage;

                if (isToolTerminatingMode) {
                    failureReason = 'Async tool execution failed in tool-terminating mode';
                    logMessage = 'Async tool failed in tool-terminating mode - no follow-up LLM call planned, halting execution';
                } else if (failureCount >= maxRetries) {
                    failureReason =
                        'Async tool "' +
                        this.capability.CapabilityName__c +
                        '" exceeded MaxToolRetries__c (' +
                        maxRetries +
                        ') after ' +
                        failureCount +
                        ' successive failures';
                    logMessage = 'Async tool exceeded MaxToolRetries__c - halting execution';
                } else {
                    failureReason = 'Async tool execution failed (fail-fast policy)';
                    logMessage = 'Async tool failed with fail-fast policy enabled - halting execution';
                }

                System.debug(LoggingLevel.WARN, logPrefix + logMessage);

                decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ this.capability, outcome, maxRetries, failureCount });

                agentStateSvc.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    failureReason + ': ' + outcome.errorMessage,
                    outcome.errorCode != null ? outcome.errorCode : AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    logPrefix
                );
                return; // Don't continue to follow-up processing
            }

            // Validate turn limits and dispatch follow-up processing (per-agent override with org-wide fallback)
            // Use the object overload to avoid a redundant SOQL — agentDefinition is already loaded
            Integer maxTurns = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDefinition);
            if ((this.currentTurnCount + 1) > maxTurns) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Maximum conversation turns exceeded (' + maxTurns + ') - terminating processing');
                agentStateSvc.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    'Maximum processing cycles reached.',
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
            } else {
                // Check if this is part of a parallel execution and if all async tools are complete
                OrchestrationService.onAsyncToolCompleted(this.executionId, this.turnIdentifier, this.currentTurnCount, this.toolCallId, logPrefix);
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, logPrefix + ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            try {
                agentStateSvc.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    'Action processor internal error: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state: ' + failEx.getMessage());
            }
        } finally {
            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Asynchronous action processing completed');
        }
    }
}
