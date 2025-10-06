/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AutonomousOrchestrator handles autonomous agent executions for self-directed agents.
 * This orchestrator:
 *   - Creates AgentExecution__c record for autonomous execution
 *   - Always uses Queueable for async processing
 *   - Supports goal-driven, self-directed agent behavior
 *
 * Async Strategy:
 *   - Always uses Queueable (AutonomousQueueable) for stateful, goal-oriented processing
 */
public class AutonomousOrchestrator implements IAgentOrchestrator {
    private final AIAgentDefinition__c agentDef;
    private static final String LOG_PREFIX = '[AutonomousOrch] ';

    public AutonomousOrchestrator(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AgentOrchestratorException('Agent definition is required for AutonomousOrchestrator');
        }
        this.agentDef = agentDefinition;
    }

    /**
     * Initiates an autonomous execution. Creates the AgentExecution__c record,
     * then enqueues AutonomousQueueable for processing.
     */
    public AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Initiating autonomous execution');

        try {
            // Create autonomous metadata
            Map<String, Object> autonomousMetadata = new Map<String, Object>{
                'goal' => payload.autonomousGoal,
                'context' => payload.autonomousContext,
                'startTime' => Datetime.now()
            };

            // Create AgentExecution__c record
            ExecutionContextService executionContextService = new ExecutionContextService();
            Id executionId = executionContextService.createExecution(
                'Autonomous',
                agentDef.Id,
                payload.triggerSource,
                JSON.serialize(autonomousMetadata),
                payload.sourceRecordId,
                payload.userId,
                payload.serviceUserId
            );

            String turnIdentifier = generateTurnIdentifier();

            // Update execution with turn identifier
            executionContextService.updateStatus(
                executionId,
                'Processing',
                AIAgentConstants.STATUS_PROCESSING,
                turnIdentifier,
                'Starting autonomous execution'
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Created autonomous execution: ' + executionId);

            // Enqueue AutonomousQueueable for async processing
            AutonomousQueueable queueable = new AutonomousQueueable(
                executionId,
                agentDef.Id,
                agentDef.LLMConfiguration__c,
                turnIdentifier,
                payload.userId,
                payload.autonomousGoal,
                payload.autonomousContext
            );

            Id jobId = System.enqueueJob(queueable);
            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued AutonomousQueueable job: ' + jobId + ' for execution: ' + executionId);

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing autonomous execution');

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating autonomous execution: ' + e.getMessage());
            throw new AgentOrchestratorException('Failed to initiate autonomous execution: ' + e.getMessage());
        }
    }

    /**
     * Processes async results for autonomous executions.
     */
    public void processAsyncResult(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = LOG_PREFIX + '[Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing async result');
        // For autonomous agents, async processing happens entirely in AutonomousQueueable
        System.debug(LoggingLevel.INFO, logPrefix + 'Async result processed');
    }

    /**
     * Generates a unique turn identifier.
     */
    private String generateTurnIdentifier() {
        return 'auto_turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
