/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BatchOrchestrator handles batch agent executions for processing multiple records.
 * This orchestrator:
 *   - Creates AgentExecution__c record for batch processing
 *   - Always uses Queueable for async processing (stateful batch iteration)
 *   - Can process either a list of record IDs or a SOQL query
 *
 * Async Strategy:
 *   - Always uses Queueable (BatchQueueable) for stateful, sequential batch processing
 */
public class BatchOrchestrator implements IAgentOrchestrator {
    private final AIAgentDefinition__c agentDef;
    private static final String LOG_PREFIX = '[BatchOrch] ';

    public BatchOrchestrator(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AgentOrchestratorException('Agent definition is required for BatchOrchestrator');
        }
        this.agentDef = agentDefinition;
    }

    /**
     * Initiates a batch execution. Creates the AgentExecution__c record,
     * then enqueues BatchQueueable for processing.
     */
    public AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Initiating batch execution');

        try {
            // Validate batch-specific fields
            if ((payload.batchRecordIds == null || payload.batchRecordIds.isEmpty()) && String.isBlank(payload.batchQuery)) {
                throw new AgentOrchestratorException('Batch record IDs or SOQL query is required for batch execution');
            }

            // Create batch metadata
            Map<String, Object> batchMetadata = new Map<String, Object>{
                'batchType' => payload.batchRecordIds != null ? 'RecordIdList' : 'Query',
                'recordCount' => payload.batchRecordIds != null ? payload.batchRecordIds.size() : 0,
                'query' => payload.batchQuery,
                'parameters' => payload.batchParameters,
                'startTime' => Datetime.now()
            };

            // Create AgentExecution__c record
            ExecutionContextService executionContextService = new ExecutionContextService();
            Id executionId = executionContextService.createExecution(
                'Batch',
                agentDef.Id,
                payload.triggerSource,
                JSON.serialize(batchMetadata),
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
                'Processing batch records'
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Created batch execution: ' + executionId);

            // Enqueue BatchQueueable for async processing
            BatchQueueable queueable = new BatchQueueable(
                executionId,
                agentDef.Id,
                agentDef.LLMConfiguration__c,
                turnIdentifier,
                payload.userId,
                payload.batchRecordIds,
                payload.batchQuery,
                payload.batchParameters
            );

            Id jobId = System.enqueueJob(queueable);
            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued BatchQueueable job: ' + jobId + ' for execution: ' + executionId);

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing batch');

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating batch execution: ' + e.getMessage());
            throw new AgentOrchestratorException('Failed to initiate batch execution: ' + e.getMessage());
        }
    }

    /**
     * Processes async results for batch executions.
     */
    public void processAsyncResult(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = LOG_PREFIX + '[Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing async result');
        // For batch agents, async processing happens entirely in BatchQueueable
        System.debug(LoggingLevel.INFO, logPrefix + 'Async result processed');
    }

    /**
     * Generates a unique turn identifier.
     */
    private String generateTurnIdentifier() {
        return 'batch_turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
