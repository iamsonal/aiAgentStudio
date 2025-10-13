/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BatchQueueable handles batch processing of records for batch-triggered executions.
 * This queueable is enqueued by BatchOrchestrator to process multiple records sequentially.
 */
public class BatchQueueable implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Id userId;
    private final List<Id> recordIds;
    private final String query;
    private final Map<String, Object> parameters;

    public BatchQueueable(
        Id executionId,
        Id agentDefinitionId,
        Id llmConfigurationId,
        String turnIdentifier,
        Id userId,
        List<Id> recordIds,
        String query,
        Map<String, Object> parameters
    ) {
        this.executionId = executionId;
        this.agentDefinitionId = agentDefinitionId;
        this.llmConfigurationId = llmConfigurationId;
        this.turnIdentifier = turnIdentifier;
        this.userId = userId;
        this.recordIds = recordIds;
        this.query = query;
        this.parameters = parameters;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[BatchQueueable Turn:' + turnIdentifier + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting batch processing in queueable context');

        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, userId);

            // Build batch context message
            String batchContext = buildBatchContext();
            decisionLogger.logUserInput('Batch Processing Started', batchContext, null);

            // Prepare batch message data
            LLMInteractionService.MessageData batchMessageData = new LLMInteractionService.MessageData();
            batchMessageData.role = AIAgentConstants.ROLE_USER;
            batchMessageData.content = batchContext;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                userId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1,
                null,
                false,
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(batchMessageData);

            if (llmResult == null) {
                throw new BatchQueueableException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                userId,
                userId,
                agentDefinitionId,
                turnIdentifier,
                1,
                batchMessageData,
                null,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Batch processing completed successfully. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'ERROR: Batch processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString()
            );

            // Mark turn as failed
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    executionId,
                    turnIdentifier,
                    'Batch processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage()
                );
            }
        }
    }

    /**
     * Builds batch context message for LLM processing.
     */
    private String buildBatchContext() {
        List<String> contextParts = new List<String>();

        contextParts.add('Batch Processing Request');

        if (recordIds != null && !recordIds.isEmpty()) {
            contextParts.add('Processing ' + recordIds.size() + ' records');
            contextParts.add('Record IDs: ' + String.join(recordIds, ', '));
        } else if (String.isNotBlank(query)) {
            contextParts.add('Processing records from query: ' + query);
        }

        if (parameters != null && !parameters.isEmpty()) {
            contextParts.add('Parameters: ' + JSON.serialize(parameters));
        }

        return String.join(contextParts, '\n');
    }

    public class BatchQueueableException extends Exception {
    }
}
