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
public abstract class BaseAgentOrchestrator implements IAgentOrchestrator {
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

    /**
     * @description
     * Handles multi-record DLQ dispatch when payload contains multiple sourceRecordIds.
     * Returns an ExecutionResult if dispatch occurred, or null if not applicable.
     */
    protected AgentExecutionService.ExecutionResult tryDispatchMultiRecord(String logPrefix, String agentName, AgentExecutionService.ExecutionPayload payload) {
        if (payload == null || payload.sourceRecordIds == null || payload.sourceRecordIds.size() <= 1) {
            return null;
        }

        Integer recordCount = payload.sourceRecordIds.size();
        System.debug(LoggingLevel.INFO, logPrefix + 'DLQ dispatch for ' + recordCount + ' records');

        AgentExecutionDispatcher.DispatchResult dispatchResult = AgentExecutionDispatcher.dispatch(agentName, payload);

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'DLQ dispatch completed. BatchId: ' +
                dispatchResult.batchId +
                ', Created: ' +
                dispatchResult.executionIds.size() +
                ' executions' +
                ', Enqueued: ' +
                dispatchResult.enqueuedJobCount +
                ' workers'
        );

        return new AgentExecutionService.ExecutionResult(
            dispatchResult.executionIds.isEmpty() ? null : dispatchResult.executionIds[0],
            'Processing',
            'DLQ dispatch started for ' +
                recordCount +
                ' records. ' +
                dispatchResult.enqueuedJobCount +
                ' workers enqueued. ' +
                'BatchId: ' +
                dispatchResult.batchId +
                '. Workers will self-pull remaining work.'
        );
    }

    public virtual void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'onChildComplete called but not implemented for this orchestrator type');
    }

    public virtual String buildSystemPromptAdditions(OrchestrationContext context) {
        return '';
    }

    public virtual String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        return null;
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
