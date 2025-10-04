/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * DeferredExecutionProcessor is a queueable job that handles LLM processing for agent executions
 * in a separate transaction context to avoid conflicts between DML operations and HTTP callouts.
 *
 * This class solves the transaction conflict issue where platform event subscribers process
 * multiple events in a single batch transaction, causing failures when attempting HTTP callouts
 * after DML operations.
 *
 * Responsibilities:
 *   - Executes in a separate transaction from the platform event trigger
 *   - Delegates to InitialLLMProcessor for actual LLM processing
 *   - Provides proper error handling and logging
 *   - Supports chaining for high-volume processing scenarios
 */
public class DeferredExecutionProcessor implements Queueable, Database.AllowsCallouts {

    /**
     * Exception thrown when deferred processing fails.
     */
    public class DeferredProcessingException extends Exception {}

    private Id executionId;
    private String triggerSource;
    private Map<String, Object> triggerData;

    /**
     * Constructor for deferred execution processing.
     *
     * @param executionId The AgentExecution__c record ID to process
     * @param triggerSource The source that initiated this execution
     * @param triggerData Additional data specific to the trigger source
     */
    public DeferredExecutionProcessor(Id executionId, String triggerSource, Map<String, Object> triggerData) {
        this.executionId = executionId;
        this.triggerSource = triggerSource;
        this.triggerData = triggerData;
    }

    /**
     * Queueable execute method - processes the execution in a separate transaction.
     *
     * @param context QueueableContext provided by the platform
     */
    public void execute(QueueableContext context) {
        String logPrefix = '[DeferredExecutionProcessor.' + triggerSource + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting deferred processing for execution: ' + executionId);

        try {
            // Validate execution still exists and is in correct state
            validateExecution();

            // Delegate to InitialLLMProcessor for actual processing
            // This now runs in a clean transaction context without prior DML operations
            InitialLLMProcessor.processExecution(executionId, triggerSource, triggerData);

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully completed deferred processing for execution: ' + executionId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in deferred processing: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString());

            // Mark execution as failed
            markExecutionAsFailed(e.getMessage());

            // Re-throw to ensure the queueable job is marked as failed
            throw new DeferredProcessingException('Deferred processing failed for execution ' + executionId + ': ' + e.getMessage());
        }
    }

    /**
     * Validates that the execution record exists and is in a valid state for processing.
     */
    private void validateExecution() {
        try {
            AgentExecution__c execution = [
                SELECT Id, ExecutionStatus__c, ProcessingStatus__c, AIAgentDefinition__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            // Check if execution is still in a processable state
            if (execution.ProcessingStatus__c == AIAgentConstants.STATUS_FAILED) {
                throw new DeferredProcessingException('Execution is already marked as failed');
            }

            if (execution.ProcessingStatus__c == AIAgentConstants.STATUS_IDLE) {
                System.debug(LoggingLevel.WARN, '[DeferredExecutionProcessor] Execution already completed, skipping processing: ' + executionId);
                return; // Skip processing if already completed
            }

        } catch (QueryException e) {
            throw new DeferredProcessingException('Execution record not found: ' + executionId);
        }
    }

    /**
     * Marks an execution as failed with appropriate error information.
     *
     * @param errorMessage The error message to record
     */
    private void markExecutionAsFailed(String errorMessage) {
        try {
            ExecutionContextService executionContextService = new ExecutionContextService();
            executionContextService.updateStatus(
                executionId,
                'Failed',
                AIAgentConstants.STATUS_FAILED,
                null,
                'Deferred ' + triggerSource + ' processing failed: ' + errorMessage
            );
        } catch (Exception updateEx) {
            System.debug(LoggingLevel.ERROR, '[DeferredExecutionProcessor] Failed to update execution status: ' + updateEx.getMessage());
        }
    }

    /**
     * Static utility method to enqueue deferred processing for an execution.
     * This provides a clean API for other classes to use deferred processing.
     *
     * @param executionId The execution ID to process
     * @param triggerSource The trigger source
     * @param triggerData The trigger-specific data
     * @return Id of the enqueued job
     */
    public static Id enqueueProcessing(Id executionId, String triggerSource, Map<String, Object> triggerData) {
        DeferredExecutionProcessor processor = new DeferredExecutionProcessor(executionId, triggerSource, triggerData);
        return System.enqueueJob(processor);
    }
}
