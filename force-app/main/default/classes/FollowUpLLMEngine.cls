/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Coordinates post-tool-execution follow-up LLM interactions. Handles follow-up LLM processing after async operations complete.
 */
public class FollowUpLLMEngine implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Boolean isFinalErrorTurn;
    private final Id recordId;
    public FollowUpLLMEngine(Id executionId, Id usrId, Id agentDefId, String turnId, Integer turnCount, Boolean isFinalError, Id recordId) {
        this.executionId = executionId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.isFinalErrorTurn = isFinalError;
        this.recordId = recordId;
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
     * Executes the follow-up LLM processing logic for a completed tool execution.
     *
     * This method validates session and turn state, invokes the LLM, processes the resulting output,
     * and handles errors. It is safe to call from Queueable jobs, Platform Events, or other asynchronous triggers.
     *
     * Supports multi-LLM optimization: when sync tools don't perform DML/callouts, multiple LLM
     * calls can be made in the same transaction to reduce queueable usage.
     *
     * @param jobIdForLogging  The Apex Job ID or other identifier for logging purposes. Can be null.
     * @return                 None.
     * @throws                 Does not propagate exceptions; all errors are handled and logged internally.
     * @sideeffects            Writes to debug logs, may update session/turn state, and commits orchestration logs.
     */
    public void process(String jobIdForLogging) {
        String logPrefix =
            '[FollowUpLLMEngine:' +
            this.turnIdentifier?.left(8) +
            ' Cycle:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            (jobIdForLogging != null ? jobIdForLogging : 'PlatformEvent') +
            '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Begin follow-up LLM processing for turn.');

        OrchestrationService orchestrationSvc = new OrchestrationService();
        AgentStateService agentStateSvcForFailure = new AgentStateService();

        // Initialize decision logger outside try for finally access
        IDecisionStepLogger.ILogger decisionLogger = null;

        try {
            // Validate execution and turn state before proceeding
            AgentStateService agentStateService = new AgentStateService();
            AgentExecution__c execution = agentStateService.validateAndGetExecution(this.executionId, this.turnIdentifier);
            if (execution == null || execution.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_FOLLOWUP) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Execution state mismatch or stale job detected. Aborting follow-up processing.');
                return;
            }

            // Load agent definition to get LLM configuration
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            if (agentDef == null || !agentDef.IsActive__c) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Agent definition not found or inactive. Aborting follow-up processing.');
                return;
            }
            Id llmConfigurationId = agentDef.LLMConfiguration__c;

            Id executionUserId = UserInfo.getUserId();
            Id originalUserId = this.userId;

            // Initialize the decision step logger - single instance for the entire turn
            decisionLogger = IDecisionStepLogger.create(this.executionId, this.turnIdentifier, originalUserId);

            // Multi-LLM Optimization: Enable deferred DML mode and track LLM calls
            TransactionContext txnCtx = TransactionContext.getInstance();
            txnCtx.enableDeferredDMLMode();
            txnCtx.incrementLLMCallCount();
            txnCtx.capturePreToolLimits();

            // Execution record was created in a previous transaction (this is a queueable follow-up)
            txnCtx.setHasPreExistingExecution(true);

            String outcome;
            Integer currentTurnCount = this.currentTurnCount;

            // Multi-LLM loop: Continue making LLM calls while conditions allow
            do {
                // Perform LLM callout for follow-up interaction
                LLMInteractionService interactionService = new LLMInteractionService(
                    this.executionId,
                    originalUserId,
                    this.agentDefinitionId,
                    llmConfigurationId,
                    this.turnIdentifier,
                    currentTurnCount,
                    this.recordId,
                    this.isFinalErrorTurn,
                    decisionLogger
                );
                LLMInteractionService.LLMInteractionResult llmInteractionResult = interactionService.prepareAndCallLLM(null);

                // Process the LLM result
                outcome = orchestrationSvc.processLlmResult(
                    llmInteractionResult,
                    this.executionId,
                    originalUserId,
                    executionUserId,
                    this.agentDefinitionId,
                    this.turnIdentifier,
                    currentTurnCount,
                    null,
                    this.recordId,
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                // If immediate follow-up is needed, prepare for next iteration
                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    txnCtx.incrementLLMCallCount();
                    txnCtx.capturePreToolLimits();
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Continuing with immediate follow-up (turn ' + currentTurnCount + ')');
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Follow-up LLM orchestration completed. Final outcome: ' + outcome + ', Total LLM calls: ' + txnCtx.getLLMCallCount()
            );
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, logPrefix + ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            try {
                agentStateSvcForFailure.failTurn(
                    this.executionId,
                    this.turnIdentifier,
                    'Processor Exception: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state: ' + failEx.getMessage());
            }
        } finally {
            // Multi-LLM optimization: Commit any remaining buffered DML and decision steps
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }
            if (decisionLogger != null) {
                decisionLogger.commitSteps();
            }
            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM processing finished.');
        }
    }
}
