/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Abstract base class for agent orchestrators providing common functionality.
 * Implements template method pattern for resume operations and provides
 * default implementations for optional interface methods.
 *
 * **Subclasses must implement:**
 * - start(): Agent-specific execution initiation
 * - runAsync(): Agent-specific queueable execution
 * - determineResumePoint(): Agent-specific resume point detection
 * - executeResume(): Agent-specific resume execution
 *
 * **Subclasses may override (virtual no-op defaults provided):**
 * - onChildComplete(): For orchestrators that handle async callbacks (default: no-op)
 * - buildSystemPromptAdditions(): For agent-specific prompt modifications (default: empty string)
 * - evaluateToolOutcome(): For agent-specific post-tool behavior (default: null)
 *
 * **Design Note:**
 * The virtual no-op defaults enable pure polymorphism - services can call these methods
 * blindly without instanceof checks. Concrete orchestrators override only what they need.
 */
public abstract class BaseAgentOrchestrator implements IAgentOrchestrator {
    protected AIAgentDefinition__c agentDefinition;
    protected LLMConfiguration__c llmConfig;

    private static final String LOG_PREFIX = '[BaseOrchestrator] ';

    // ===================================================================================
    // RESUME POINT DATA STRUCTURE
    // ===================================================================================

    /**
     * Represents the point from which to resume execution.
     */
    public class ResumePoint {
        public ResumeType resumeType;
        public Integer turnCount;
        public Integer lastTurnCount;
        public String toolCallId;
        public String toolName;
        public String stepName; // For workflow orchestrators
        public String previousStatus;
        public Map<String, Object> metadata;

        public ResumePoint() {
            this.metadata = new Map<String, Object>();
        }
    }

    /**
     * Types of resume operations.
     */
    public enum ResumeType {
        RETRY_FAILED_TOOL, // Re-execute the last failed tool
        LLM_CONTINUE, // Continue with LLM call (let LLM decide)
        RETRY_STEP, // Retry a workflow step (workflow only)
        FRESH_START // Start from beginning (rare)
    }

    /**
     * @description
     * Options for resuming a failed or paused agent execution.
     * Used by resume() methods to control resume behavior.
     */
    public class ResumeOptions {
        /**
         * Resume strategy for tool failures:
         * - true: Retry the last failed tool with same arguments
         * - false: Continue with LLM call (let LLM decide next action)
         * - null: Auto-detect (check for failed tool, retry if found)
         */
        @AuraEnabled
        public Boolean retryFailedTool { get; set; }

        /**
         * Human-readable reason for the resume (for audit trail).
         */
        @AuraEnabled
        public String resumeReason { get; set; }

        /**
         * For workflow orchestrators: specific step name to resume from.
         * If null, auto-detects the step to resume.
         */
        @AuraEnabled
        public String stepName { get; set; }

        /**
         * Default constructor with auto-detect behavior.
         */
        public ResumeOptions() {
            this.retryFailedTool = null; // Auto-detect
        }

        /**
         * Constructor with explicit retry strategy.
         *
         * @param retryFailedTool Whether to retry the failed tool
         */
        public ResumeOptions(Boolean retryFailedTool) {
            this.retryFailedTool = retryFailedTool;
        }

        /**
         * Builder-style method for setting retry strategy.
         */
        public ResumeOptions withRetryFailedTool(Boolean retry) {
            this.retryFailedTool = retry;
            return this;
        }

        /**
         * Builder-style method for setting resume reason.
         */
        public ResumeOptions withReason(String reason) {
            this.resumeReason = reason;
            return this;
        }

        /**
         * Builder-style method for setting step name (workflow only).
         */
        public ResumeOptions withStepName(String step) {
            this.stepName = step;
            return this;
        }
    }

    // ===================================================================================
    // INTERFACE IMPLEMENTATION - LIFECYCLE METHODS
    // ===================================================================================

    /**
     * Configures the orchestrator with agent definition.
     * Loads LLM configuration and validates agent type.
     */
    public virtual void configure(AIAgentDefinition__c agentDef) {
        if (agentDef == null) {
            throw new AIAgentException.OrchestrationException('Agent definition is required');
        }

        this.agentDefinition = agentDef;

        // Load LLM configuration if available
        if (agentDef.LLMConfiguration__c != null) {
            this.llmConfig = AIAgentConfigService.getLLMConfiguration(agentDef.LLMConfiguration__c);
        }

        // Log initialization - handle case where DeveloperName__c wasn't queried
        String agentName = 'ID:' + agentDef.Id;
        try {
            if (agentDef.DeveloperName__c != null) {
                agentName = agentDef.DeveloperName__c;
            }
        } catch (SObjectException e) {
            // Field wasn't queried - use ID instead
        }
        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Configured orchestrator for agent: ' + agentName);
    }

    /**
     * Abstract method - subclasses must implement agent-specific initiation.
     */
    public abstract AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);

    /**
     * Template method for resume operations.
     * Provides common validation and logging, delegates to abstract methods for agent-specific logic.
     */
    public virtual AgentExecutionService.ExecutionResult resume(Id executionId, BaseAgentOrchestrator.ResumeOptions options) {
        String logPrefix = LOG_PREFIX + '[resume Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting resume operation');

        try {
            // 1. Validate execution is resumable (common)
            AgentExecution__c execution = validateResumable(executionId, logPrefix);

            // 2. Generate turn identifier (agent-specific behavior)
            String newTurnIdentifier = generateResumeIdentifier(execution, options);
            System.debug(LoggingLevel.INFO, logPrefix + 'Resume turn identifier: ' + newTurnIdentifier);

            // 3. Determine resume point (agent-specific)
            ResumePoint resumePoint = determineResumePoint(executionId, execution, options, logPrefix);

            // 4. Log resume attempt (common)
            logResumeAttempt(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);

            // 5. Execute resume (agent-specific)
            return executeResume(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Resume failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to resume execution: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // INTERFACE IMPLEMENTATION - CAPABILITY QUERY METHODS
    // ===================================================================================

    /**
     * Default implementation checks basic resumability conditions.
     * Subclasses may override for additional checks.
     */
    public virtual Boolean canResume(Id executionId) {
        try {
            AgentExecution__c exec = [
                SELECT ExecutionStatus__c, AIAgentDefinition__r.AgentType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            // Cannot resume completed executions
            if (exec.ExecutionStatus__c == 'Completed') {
                return false;
            }

            // Can resume Failed, Pending, or Processing (interrupted)
            return exec.ExecutionStatus__c == 'Failed' || exec.ExecutionStatus__c == 'Pending' || exec.ExecutionStatus__c == 'Processing';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error checking canResume: ' + e.getMessage());
            return false;
        }
    }

    // ===================================================================================
    // INTERFACE IMPLEMENTATION - ACCESSOR METHODS
    // ===================================================================================

    /**
     * Returns the agent definition this orchestrator was initialized with.
     */
    public AIAgentDefinition__c getAgentDefinition() {
        return this.agentDefinition;
    }

    // ===================================================================================
    // VIRTUAL NO-OP DEFAULTS (override in subclasses as needed)
    // ===================================================================================

    /**
     * Handles async operation results (e.g., workflow child agent completion).
     * Default implementation is a no-op - override in orchestrators that support child delegation.
     *
     * @param executionId  Execution ID
     * @param asyncPayload Async-specific context and results
     */
    public virtual void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        // No-op default - orchestrators that don't support child delegation do nothing
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'onChildComplete called but not implemented for this orchestrator type');
    }

    /**
     * Returns agent-specific additions to the system prompt.
     * Default implementation returns empty string - override for agent-specific prompt modifications.
     *
     * @param context The orchestration context for the current turn
     * @return        String to append to system prompt, or empty string
     */
    public virtual String buildSystemPromptAdditions(OrchestrationContext context) {
        // No-op default - return empty string (no additions)
        return '';
    }

    /**
     * Handles agent-specific behavior after tool execution completes.
     * Default implementation returns null (use default behavior) - override for agent-specific post-tool behavior.
     *
     * @param context     The orchestration context
     * @param toolResults Results from tool execution(s)
     * @param scenario    The scenario type (e.g., 'APPROVAL_REQUIRED', 'TOOL_COMPLETED', 'CONTENT_ONLY_RESPONSE')
     * @return            Outcome constant or null for default behavior
     */
    public virtual String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        // No-op default - return null to use default behavior
        return null;
    }

    // ===================================================================================
    // ABSTRACT METHODS - SUBCLASSES MUST IMPLEMENT
    // ===================================================================================

    /**
     * Executes agent-specific logic when invoked from a queueable job.
     * Called by UnifiedAgentQueueable to delegate all async execution to orchestrators.
     *
     * @param payload Job-specific execution parameters
     * @param logPrefix Logging prefix for debug output
     */
    public abstract void runAsync(Map<String, Object> payload, String logPrefix);

    /**
     * Determines the point from which to resume execution.
     * Agent-specific logic for analyzing execution state and determining resume strategy.
     *
     * @param executionId The execution ID
     * @param execution   The execution record
     * @param options     Resume options from caller
     * @param logPrefix   Logging prefix
     * @return            ResumePoint indicating where and how to resume
     */
    protected abstract ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    );

    /**
     * Executes the resume operation from the determined point.
     * Agent-specific logic for actually resuming execution.
     *
     * @param executionId      The execution ID
     * @param execution        The execution record
     * @param newTurnIdentifier New turn identifier for this resume
     * @param resumePoint      The determined resume point
     * @param options          Resume options from caller
     * @param logPrefix        Logging prefix
     * @return                 Execution result
     */
    protected abstract AgentExecutionService.ExecutionResult executeResume(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ResumePoint resumePoint,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    );

    // ===================================================================================
    // PROTECTED HELPER METHODS (available to subclasses)
    // ===================================================================================

    /**
     * Validates that an execution can be resumed.
     * Throws exception if not resumable.
     */
    protected AgentExecution__c validateResumable(Id executionId, String logPrefix) {
        List<AgentExecution__c> executions = [
            SELECT
                Id,
                ExecutionStatus__c,
                ProcessingStatus__c,
                AIAgentDefinition__c,
                AIAgentDefinition__r.DeveloperName__c,
                AIAgentDefinition__r.AgentType__c,
                CurrentTurnIdentifier__c,
                User__c,
                SourceRecordId__c,
                ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];

        if (executions.isEmpty()) {
            throw new AIAgentException.OrchestrationException('Execution not found: ' + executionId);
        }

        AgentExecution__c exec = executions[0];

        if (exec.ExecutionStatus__c == 'Completed') {
            throw new AIAgentException.OrchestrationException('Execution ' + executionId + ' is already completed. Nothing to resume.');
        }

        if (exec.ExecutionStatus__c != 'Failed' && exec.ExecutionStatus__c != 'Pending' && exec.ExecutionStatus__c != 'Processing') {
            throw new AIAgentException.OrchestrationException('Execution ' + executionId + ' cannot be resumed from status: ' + exec.ExecutionStatus__c);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Validated execution. Status: ' + exec.ExecutionStatus__c);
        return exec;
    }

    /**
     * Generates a unique turn identifier.
     */
    protected String generateTurnIdentifier() {
        return UUID.randomUUID().toString();
    }

    /**
     * Generates turn identifier for resume operations.
     * Default behavior: generates new identifier (for Conversational/Workflow agents).
     * Override in subclasses for different behavior (e.g., Function agents preserve existing).
     */
    protected virtual String generateResumeIdentifier(AgentExecution__c execution, BaseAgentOrchestrator.ResumeOptions options) {
        return generateTurnIdentifier(); // Default: new identifier
    }

    /**
     * Logs the resume attempt to decision steps.
     */
    protected virtual void logResumeAttempt(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ResumePoint resumePoint,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    ) {
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, newTurnIdentifier, execution.User__c);

            Map<String, Object> resumeMetadata = new Map<String, Object>{
                'resumeType' => resumePoint.resumeType.name(),
                'turnCount' => resumePoint.turnCount,
                'lastTurnCount' => resumePoint.lastTurnCount,
                'previousStatus' => execution.ExecutionStatus__c,
                'originalTurnIdentifier' => execution.CurrentTurnIdentifier__c,
                'newTurnIdentifier' => newTurnIdentifier
            };

            if (String.isNotBlank(resumePoint.toolName)) {
                resumeMetadata.put('toolName', resumePoint.toolName);
                resumeMetadata.put('toolCallId', resumePoint.toolCallId);
            }

            if (String.isNotBlank(resumePoint.stepName)) {
                resumeMetadata.put('stepName', resumePoint.stepName);
            }

            if (String.isNotBlank(options?.resumeReason)) {
                resumeMetadata.put('resumeReason', options.resumeReason);
            }

            String description = 'Execution manually resumed';
            if (resumePoint.resumeType == ResumeType.RETRY_FAILED_TOOL) {
                description += '. Retrying failed tool: ' + resumePoint.toolName;
            } else if (resumePoint.resumeType == ResumeType.RETRY_STEP) {
                description += '. Retrying workflow step: ' + resumePoint.stepName;
            } else {
                description += '. Continuing with LLM call';
            }

            decisionLogger.logContextGathering('Execution Resumed', description, JSON.serialize(resumeMetadata), null);

            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log resume attempt: ' + e.getMessage());
            // Non-fatal - continue with resume
        }
    }

    /**
     * Finds the last failed tool in an execution.
     * Returns null if no failed tool found.
     */
    protected Map<String, Object> findLastFailedTool(Id executionId, String logPrefix) {
        List<ExecutionStep__c> steps = [
            SELECT Id, StepType__c, ToolName__c, ToolCallId__c, ToolResult__c, IsError__c, ToolArguments__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY Timestamp__c DESC, Id DESC
            LIMIT 100
        ];

        // Find the last failed tool result
        ExecutionStep__c lastFailedToolResult = null;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'ToolResult' && step.IsError__c == true && String.isNotBlank(step.ToolCallId__c)) {
                lastFailedToolResult = step;
                break;
            }
        }

        if (lastFailedToolResult == null) {
            return null;
        }

        // Find the corresponding ToolCall step
        ExecutionStep__c toolCallStep = null;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'ToolCall' && step.ToolCallId__c == lastFailedToolResult.ToolCallId__c) {
                toolCallStep = step;
                break;
            }
        }

        if (toolCallStep == null || String.isBlank(toolCallStep.ToolName__c)) {
            return null;
        }

        return new Map<String, Object>{
            'toolCallId' => lastFailedToolResult.ToolCallId__c,
            'toolName' => toolCallStep.ToolName__c,
            'toolArguments' => toolCallStep.ToolArguments__c,
            'toolResult' => lastFailedToolResult.ToolResult__c
        };
    }

    /**
     * Gets the last turn count from execution steps.
     */
    protected Integer getLastTurnCount(Id executionId) {
        List<ExecutionStep__c> steps = [
            SELECT TurnCount__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY TurnCount__c DESC
            LIMIT 1
        ];

        if (steps.isEmpty() || steps[0].TurnCount__c == null) {
            return 0;
        }

        return Integer.valueOf(steps[0].TurnCount__c);
    }
}
