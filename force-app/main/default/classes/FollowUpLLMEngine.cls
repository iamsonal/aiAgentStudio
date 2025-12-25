/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * FollowUpLLMEngine coordinates the post-tool-execution phase of an LLM-driven execution, handling follow-up LLM interactions
 * after asynchronous operations complete. This engine contains all the business logic for follow-up LLM processing.
 *
 * Implements Queueable with Database.AllowsCallouts for direct async execution without unnecessary wrapper classes.
 * Can be invoked via System.enqueueJob (low dispatch) or Platform Events (high dispatch).
 *
 * Responsibilities:
 *   - Validate execution and turn state before proceeding with follow-up LLM processing
 *   - Invoke LLM interaction logic and process the resulting output
 *   - Handle both success and error scenarios, including marking turns as failed if needed
 *   - Provide clear, actionable debug output and commit logs for diagnostics
 */
public class FollowUpLLMEngine implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Boolean isFinalErrorTurn;

    /**
     * Constructor for follow-up LLM processing using the unified AgentExecution__c model.
     *
     * @param executionId   The execution ID (AgentExecution__c) for this interaction.
     * @param usrId         The original user ID who initiated the execution.
     * @param agentDefId    The AI agent definition ID being used.
     * @param turnId        The unique turn identifier for tracking this execution turn.
     * @param turnCount     The current turn number in the execution.
     * @param isFinalError  Whether this is a final error turn that should terminate the execution.
     */
    public FollowUpLLMEngine(Id executionId, Id usrId, Id agentDefId, String turnId, Integer turnCount, Boolean isFinalError) {
        this.executionId = executionId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.isFinalErrorTurn = isFinalError;
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
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(this.executionId, this.turnIdentifier, originalUserId);

            // Perform LLM callout for follow-up interaction with decision logger
            LLMInteractionService interactionService = new LLMInteractionService(
                this.executionId,
                originalUserId,
                this.agentDefinitionId,
                llmConfigurationId,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                this.isFinalErrorTurn,
                decisionLogger
            );
            LLMInteractionService.LLMInteractionResult llmInteractionResult = interactionService.prepareAndCallLLM(null);

            // Process the LLM result and update orchestration state with decision logger
            String outcome = orchestrationSvc.processLlmResult(
                llmInteractionResult,
                this.executionId,
                originalUserId,
                executionUserId,
                this.agentDefinitionId,
                this.turnIdentifier,
                this.currentTurnCount,
                null,
                null,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM orchestration outcome: ' + outcome);
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Exception during follow-up LLM processing: ' + ex.getTypeName() + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString()
            );
            try {
                agentStateSvcForFailure.failTurn(
                    this.executionId,
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
            System.debug(LoggingLevel.INFO, logPrefix + 'Follow-up LLM processing finished.');
        }
    }
}
