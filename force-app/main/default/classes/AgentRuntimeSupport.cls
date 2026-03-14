/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared runtime support utilities used by strategy-owned runtime classes.
 */
public inherited sharing class AgentRuntimeSupport {
    private static final String LOG_PREFIX = '[AgentRuntimeSupport] ';

    public static LLMConfiguration__c loadLlmConfiguration(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null || agentDefinition.LLMConfiguration__c == null) {
            return null;
        }
        return AIAgentConfigService.getLLMConfiguration(agentDefinition.LLMConfiguration__c);
    }

    public static AgentExecution__c validateResumable(Id executionId, String logPrefix) {
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
        if (
            exec.ExecutionStatus__c != 'Failed' &&
            exec.ExecutionStatus__c != 'Pending' &&
            exec.ExecutionStatus__c != 'Processing' &&
            exec.ExecutionStatus__c != AIAgentConstants.EXECUTION_STATUS_PAUSED
        ) {
            throw new AIAgentException.OrchestrationException('Execution ' + executionId + ' cannot be resumed from status: ' + exec.ExecutionStatus__c);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Validated execution. Status: ' + exec.ExecutionStatus__c);
        return exec;
    }

    public static Boolean canResume(Id executionId) {
        try {
            AgentExecution__c exec = [
                SELECT ExecutionStatus__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];
            if (exec.ExecutionStatus__c == 'Completed') {
                return false;
            }
            return exec.ExecutionStatus__c == 'Failed' ||
                exec.ExecutionStatus__c == 'Pending' ||
                exec.ExecutionStatus__c == 'Processing' ||
                exec.ExecutionStatus__c == AIAgentConstants.EXECUTION_STATUS_PAUSED;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error checking canResume: ' + e.getMessage());
            return false;
        }
    }

    public static String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        if (!'CONTENT_ONLY_RESPONSE'.equals(scenario)) {
            return null;
        }

        AIAgentDefinition__c agentDef;
        try {
            agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, context.logPrefix + '[evaluateToolOutcome] Could not load agent definition: ' + e.getMessage());
            return null;
        }

        if (!'Autonomous'.equals(agentDef.ErrorRecoveryMode__c)) {
            return null;
        }

        Integer maxCycles = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef);
        List<OrchestrationService.UnretriedFailure> failures = OrchestrationService.detectUnretriedFailures(
            context.executionId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.logPrefix
        );

        if (failures.isEmpty()) {
            return null;
        }

        if (context.currentTurnCount >= maxCycles) {
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

        new ExecutionStepService().createRetryEnforcementStep(context.executionId, failures, context.turnIdentifier, context.currentTurnCount);
        context.decisionLogger.log(IDecisionStepLogger.EventType.RETRY_ENFORCEMENT, new List<Object>{ failures });
        return OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP;
    }

    public static String generateTurnIdentifier() {
        return UUID.randomUUID().toString();
    }

    public static void clearResumeTurnGuard(Id executionId, AgentExecution__c execution, String logPrefix) {
        if ('Failed'.equals(execution.ExecutionStatus__c) && String.isNotBlank(execution.CurrentTurnIdentifier__c)) {
            update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = null, AsyncToolTurnIdentifier__c = null);
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Cleared stale CurrentTurnIdentifier__c (and AsyncToolTurnIdentifier__c) on DB to allow resume state transition.'
            );
        }
    }

    public static void logResumeAttempt(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
        ExecutionResumeModels.ResumeOptions options,
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
            if (resumePoint.resumeType == ExecutionResumeModels.ResumeType.RETRY_FAILED_TOOL) {
                description += '. Retrying failed tool: ' + resumePoint.toolName;
            } else if (resumePoint.resumeType == ExecutionResumeModels.ResumeType.RETRY_STEP) {
                description += '. Retrying pipeline step: ' + resumePoint.stepName;
            } else {
                description += '. Continuing with LLM call';
            }

            decisionLogger.log(IDecisionStepLogger.EventType.AGENT_RESUMED, new List<Object>{ 'agent', description, resumeMetadata });
            decisionLogger.commitSteps();
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'Failed to log resume attempt (non-fatal, continuing): ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }

    public static Map<String, Object> findLastFailedTool(Id executionId) {
        List<ExecutionStep__c> steps = [
            SELECT Id, StepType__c, ToolName__c, ToolCallId__c, ToolResult__c, IsError__c, ToolArguments__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY Timestamp__c DESC, Id DESC
            LIMIT 100
        ];

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

    public static Integer getLastTurnCount(Id executionId) {
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

    private static String getFailureToolNames(List<OrchestrationService.UnretriedFailure> failures) {
        List<String> names = new List<String>();
        for (OrchestrationService.UnretriedFailure failure : failures) {
            names.add(failure.toolName);
        }
        return String.join(names, ', ');
    }
}
