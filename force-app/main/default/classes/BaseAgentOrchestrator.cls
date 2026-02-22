/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Abstract base class for agent orchestrators. Provides common functionality and template method pattern for resume operations.
 */
public inherited sharing abstract class BaseAgentOrchestrator implements IAgentOrchestrator {
    protected AIAgentDefinition__c agentDefinition;
    protected LLMConfiguration__c llmConfig;
    private static final String LOG_PREFIX = '[BaseOrchestrator] ';

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

    public enum ResumeType {
        RETRY_FAILED_TOOL,
        LLM_CONTINUE,
        RETRY_STEP,
        FRESH_START
    }

    public class ResumeOptions {
        @AuraEnabled
        public Boolean retryFailedTool { get; set; }
        @AuraEnabled
        public String resumeReason { get; set; }
        @AuraEnabled
        public String stepName { get; set; }

        public ResumeOptions() {
            this.retryFailedTool = null;
        }

        public ResumeOptions(Boolean retryFailedTool) {
            this.retryFailedTool = retryFailedTool;
        }

        public ResumeOptions withRetryFailedTool(Boolean retry) {
            this.retryFailedTool = retry;
            return this;
        }

        public ResumeOptions withReason(String reason) {
            this.resumeReason = reason;
            return this;
        }

        public ResumeOptions withStepName(String step) {
            this.stepName = step;
            return this;
        }
    }
    public virtual void configure(AIAgentDefinition__c agentDef) {
        if (agentDef == null) {
            throw new AIAgentException.OrchestrationException('Agent definition is required');
        }

        this.agentDefinition = agentDef;

        if (agentDef.LLMConfiguration__c != null) {
            this.llmConfig = AIAgentConfigService.getLLMConfiguration(agentDef.LLMConfiguration__c);
        }

        String agentName = 'ID:' + agentDef.Id;
        try {
            if (agentDef.DeveloperName__c != null) {
                agentName = agentDef.DeveloperName__c;
            }
        } catch (SObjectException e) {
        }
        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Configured orchestrator for agent: ' + agentName);
    }

    public abstract AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);
    public virtual AgentExecutionService.ExecutionResult resume(Id executionId, BaseAgentOrchestrator.ResumeOptions options) {
        String logPrefix = LOG_PREFIX + '[resume Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting resume operation');

        try {
            AgentExecution__c execution = validateResumable(executionId, logPrefix);
            String newTurnIdentifier = generateResumeIdentifier(execution, options);
            System.debug(LoggingLevel.INFO, logPrefix + 'Resume turn identifier: ' + newTurnIdentifier);
            ResumePoint resumePoint = determineResumePoint(executionId, execution, options, logPrefix);
            logResumeAttempt(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
            return executeResume(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Resume failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to resume execution: ' + e.getMessage());
        }
    }

    public virtual Boolean canResume(Id executionId) {
        try {
            AgentExecution__c exec = [
                SELECT ExecutionStatus__c, AIAgentDefinition__r.AgentType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (exec.ExecutionStatus__c == 'Completed') {
                return false;
            }

            return exec.ExecutionStatus__c == 'Failed' || exec.ExecutionStatus__c == 'Pending' || exec.ExecutionStatus__c == 'Processing';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error checking canResume: ' + e.getMessage());
            return false;
        }
    }

    public AIAgentDefinition__c getAgentDefinition() {
        return this.agentDefinition;
    }

    public virtual void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'onChildComplete called but not implemented for this orchestrator type');
    }

    public virtual String buildSystemPromptAdditions(OrchestrationContext context) {
        return '';
    }

    /**
     * @description Enforcement layer for retryable tool failures.
     *
     * When the LLM returns a text-only response (finish_reason:stop / CONTENT_ONLY_RESPONSE)
     * while there are still unretried retryable tool failures in the current turn, this method
     * detects them and injects a synthetic internal user message instructing the LLM to retry.
     * Returning OUTCOME_IMMEDIATE_FOLLOWUP triggers another LLM cycle without consuming a new
     * user turn. The loop continues until all pending retries are addressed or MaxProcessingCycles
     * is reached, at which point the turn is failed.
     *
     * Sub-classes can call super.evaluateToolOutcome() first and then layer their own logic,
     * or override completely to disable this enforcement for their agent type.
     */
    public virtual String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        // Enforcement only fires when the LLM produced a pure text response with no tool calls
        if (!'CONTENT_ONLY_RESPONSE'.equals(scenario)) {
            return null;
        }

        // Load the agent definition (cached by AIAgentConfigService)
        AIAgentDefinition__c agentDef;
        try {
            agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, context.logPrefix + '[evaluateToolOutcome] Could not load agent definition: ' + e.getMessage());
            return null;
        }

        // Retry enforcement only applies to Autonomous recovery mode
        if (!'Autonomous'.equals(agentDef.ErrorRecoveryMode__c)) {
            return null;
        }

        Integer maxCycles = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef);

        // Detect unretried retryable failures for this turn
        List<OrchestrationService.UnretriedFailure> failures = OrchestrationService.detectUnretriedFailures(
            context.executionId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.logPrefix
        );

        if (failures.isEmpty()) {
            return null;
        }

        // We're at or beyond the cycle ceiling — fail the turn rather than loop forever
        if (context.currentTurnCount >= maxCycles) {
            System.debug(
                LoggingLevel.WARN,
                context.logPrefix +
                    '[evaluateToolOutcome] Max processing cycles (' +
                    maxCycles +
                    ') reached with ' +
                    failures.size() +
                    ' unretried failure(s). Failing turn.'
            );
            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Agent reached the maximum processing cycle limit (' +
                    maxCycles +
                    ') while ' +
                    failures.size() +
                    ' tool(s) still had unretried retryable failures: ' +
                    getFailureToolNames(failures),
                AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                context.logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Inject enforcement message and request another LLM cycle
        System.debug(
            LoggingLevel.INFO,
            context.logPrefix +
                '[evaluateToolOutcome] Injecting retry enforcement for ' +
                failures.size() +
                ' unretried tool(s): ' +
                getFailureToolNames(failures)
        );
        new ExecutionStepService().createRetryEnforcementStep(context.executionId, failures, context.turnIdentifier, context.currentTurnCount);
        context.decisionLogger.log(IDecisionStepLogger.EventType.RETRY_ENFORCEMENT, new List<Object>{ failures });
        return OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP;
    }

    private static String getFailureToolNames(List<OrchestrationService.UnretriedFailure> failures) {
        List<String> names = new List<String>();
        for (OrchestrationService.UnretriedFailure f : failures) {
            names.add(f.toolName);
        }
        return String.join(names, ', ');
    }

    public abstract void runAsync(Map<String, Object> payload, String logPrefix);

    protected abstract ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    );

    protected abstract AgentExecutionService.ExecutionResult executeResume(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ResumePoint resumePoint,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    );
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

    protected String generateTurnIdentifier() {
        return UUID.randomUUID().toString();
    }

    protected virtual String generateResumeIdentifier(AgentExecution__c execution, BaseAgentOrchestrator.ResumeOptions options) {
        return generateTurnIdentifier();
    }
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

            decisionLogger.log(IDecisionStepLogger.EventType.AGENT_RESUMED, new List<Object>{ 'agent', description });

            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'Failed to log resume attempt (non-fatal, continuing): ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }
    protected Map<String, Object> findLastFailedTool(Id executionId, String logPrefix) {
        List<ExecutionStep__c> steps = [
            SELECT Id, StepType__c, ToolName__c, ToolCallId__c, ToolResult__c, IsError__c, ToolArguments__c, IsDependencyValidationFailure__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY Timestamp__c DESC, Id DESC
            LIMIT 100
        ];

        ExecutionStep__c lastFailedToolResult = null;
        for (ExecutionStep__c step : steps) {
            // Find failed tool result - EXCLUDE dependency validation failures
            // Dependency failures are not real tool execution errors - they're blocked attempts
            // Retrying a blocked tool will fail again unless dependencies are satisfied
            if (
                step.StepType__c == 'ToolResult' &&
                step.IsError__c == true &&
                step.IsDependencyValidationFailure__c == false &&
                String.isNotBlank(step.ToolCallId__c)
            ) {
                lastFailedToolResult = step;
                break;
            }
        }

        if (lastFailedToolResult == null) {
            return null;
        }

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
