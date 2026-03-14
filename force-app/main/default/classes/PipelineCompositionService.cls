/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Explicit composition boundary for pipeline lifecycle operations.
 * Owns start, resume, and child-completion handoff for pipeline executions.
 */
public inherited sharing class PipelineCompositionService {
    private static final String LOG_PREFIX = '[PipelineCompositionService] ';

    public static Boolean hasActivePipelineDefinition(String pipelineDeveloperName) {
        if (String.isBlank(pipelineDeveloperName)) {
            return false;
        }

        return [
                SELECT COUNT()
                FROM PipelineDefinition__c
                WHERE DeveloperName__c = :pipelineDeveloperName AND IsActive__c = TRUE
            ] > 0;
    }

    public static AgentExecutionService.ExecutionResult startExecution(String pipelineDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        return toExecutionResult(startPipelineRun(pipelineDeveloperName, payload));
    }

    public static SequentialPipelineOrchestrator.ExecutionResult startPipelineRun(
        String pipelineDeveloperName,
        AgentExecutionService.ExecutionPayload payload
    ) {
        if (String.isBlank(pipelineDeveloperName)) {
            throw new AIAgentException.OrchestrationException('Pipeline developer name is required');
        }
        if (payload == null) {
            throw new AIAgentException.OrchestrationException('Execution payload is required');
        }

        List<Id> sourceRecordIds = new List<Id>();
        if (payload.sourceRecordIds != null) {
            sourceRecordIds.addAll(payload.sourceRecordIds);
        }
        if (payload.sourceRecordId != null && !sourceRecordIds.contains(payload.sourceRecordId)) {
            sourceRecordIds.add(payload.sourceRecordId);
        }

        if (sourceRecordIds.isEmpty()) {
            throw new AIAgentException.OrchestrationException('Pipeline execution requires at least one source record');
        }

        List<PipelineDefinition__c> definitions = [
            SELECT Id
            FROM PipelineDefinition__c
            WHERE DeveloperName__c = :pipelineDeveloperName AND IsActive__c = TRUE
            LIMIT 1
        ];
        if (definitions.isEmpty()) {
            throw new AIAgentException.OrchestrationException('Active pipeline not found: ' + pipelineDeveloperName);
        }

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(definitions[0].Id);
        return sourceRecordIds.size() == 1
            ? orchestrator.start(sourceRecordIds[0], payload.triggerSource)
            : orchestrator.start(sourceRecordIds, payload.triggerSource);
    }

    public static Boolean canResume(Id executionId) {
        return loadConfiguredOrchestrator(executionId).canResume(executionId);
    }

    public static AgentExecutionService.ExecutionResult resumeExecution(Id executionId, ExecutionResumeModels.ResumeOptions options) {
        SequentialPipelineOrchestrator orchestrator = loadConfiguredOrchestrator(executionId);
        orchestrator.resume(executionId);
        return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Pipeline resumed');
    }

    public static void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        loadConfiguredOrchestrator(executionId).onChildComplete(executionId, asyncPayload);
    }

    public static Boolean isPipelineExecution(AgentExecution__c execution) {
        return execution != null &&
            (execution.PipelineDefinition__c != null || AIAgentConstants.EXECUTION_MODE_PIPELINE.equalsIgnoreCase(execution.ExecutionType__c));
    }

    private static SequentialPipelineOrchestrator loadConfiguredOrchestrator(Id executionId) {
        if (executionId == null) {
            throw new AIAgentException.OrchestrationException('Pipeline execution Id is required');
        }

        AgentExecution__c execution = [
            SELECT Id, PipelineDefinition__c, ExecutionType__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];

        if (!isPipelineExecution(execution) || execution.PipelineDefinition__c == null) {
            throw new AIAgentException.OrchestrationException('Execution is not a pipeline composition run: ' + executionId);
        }

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(execution.PipelineDefinition__c);
        return orchestrator;
    }

    private static AgentExecutionService.ExecutionResult toExecutionResult(SequentialPipelineOrchestrator.ExecutionResult result) {
        if (result == null) {
            return new AgentExecutionService.ExecutionResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Pipeline execution returned no result');
        }
        if (result.success == true) {
            return new AgentExecutionService.ExecutionResult(result.executionId, result.status, result.message);
        }
        return new AgentExecutionService.ExecutionResult(result.errorCode, result.errorMessage);
    }
}
