/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Apex controller for resuming AgentExecution__c records and batch operations.
 * Provides interface for the agentExecutionResume LWC component and batch recovery.
 *
 * **DLQ Architecture:**
 * - Individual execution resume via resumeExecution()
 * - Batch-level resume via resumeBatch() using BatchId__c correlation
 * - Progress tracking via getBatchProgress()
 */
public with sharing class AgentExecutionResumeController {
    /**
     * @description Resumes a failed agent execution
     * Called by the LWC headless quick action component
     * Uses the orchestrator's resume() method for unified resume handling
     * @param executionId The ID of the AgentExecution__c record to resume
     * @return String Success or error message
     */
    @AuraEnabled
    public static String resumeExecution(Id executionId) {
        try {
            if (executionId == null) {
                throw new AuraHandledException('Execution ID is required. This action must be run from an AgentExecution__c record page.');
            }

            // Query execution to get agent definition including service user context requirement
            AgentExecution__c exec = [
                SELECT
                    Id,
                    ExecutionStatus__c,
                    ExecutionType__c,
                    AIAgentDefinition__c,
                    AIAgentDefinition__r.DeveloperName__c,
                    AIAgentDefinition__r.AgentType__c,
                    AIAgentDefinition__r.RequiresServiceUserContext__c,
                    PipelineDefinition__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            // Validate execution is resumable
            if (exec.ExecutionStatus__c == 'Completed') {
                throw new AuraHandledException('Execution is already completed. Nothing to resume.');
            }

            // Pipeline executions route through the explicit composition subsystem
            if (PipelineCompositionService.isPipelineExecution(exec)) {
                if (!PipelineCompositionService.canResume(executionId)) {
                    throw new AuraHandledException('Pipeline execution cannot be resumed from its current state.');
                }
                PipelineCompositionService.resumeExecution(executionId, new ExecutionResumeModels.ResumeOptions().withReason('Manual resume via UI'));
                return 'Pipeline execution resumed successfully.';
            }

            // Check if agent requires service user context
            Boolean requiresServiceUserContext = exec.AIAgentDefinition__r.RequiresServiceUserContext__c == true;

            if (requiresServiceUserContext) {
                // Route through REST API via queueable to execute in service user context
                // This ensures tools and LLM calls run with proper service user permissions
                return resumeViaServiceUser(executionId, exec.AIAgentDefinition__r.DeveloperName__c);
            }

            // No service user context required - execute directly
            return resumeDirectly(executionId, exec);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            String errorMessage = 'Failed to resume execution: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, '[AgentExecutionResumeController] ' + errorMessage + '\n' + e.getStackTraceString());
            throw new AuraHandledException(errorMessage);
        }
    }

    /**
     * @description Resumes execution via service user context by routing through REST API
     * Used when the agent requires service user context for tool execution
     */
    private static String resumeViaServiceUser(Id executionId, String agentName) {
        System.debug(LoggingLevel.INFO, '[AgentExecutionResumeController] Agent requires service user context. Routing resume via REST API.');

        // Enqueue the resume operation to run via REST API in service user context
        System.enqueueJob(
            new HITLServiceQueueable(
                executionId,
                'Manual resume via UI (service user context)',
                null // Auto-detect whether to retry failed tool
            )
        );

        return 'Resume initiated for ' + agentName + ' (' + executionId + '). ' + 'Processing in service user context. Check the Storyboard for progress.';
    }

    /**
     * @description Resumes execution directly in the current user's context
     * Used when the agent does not require service user context
     */
    private static String resumeDirectly(Id executionId, AgentExecution__c exec) {
        // Load agent definition
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(exec.AIAgentDefinition__c);
        if (agentDef == null) {
            throw new AuraHandledException('Agent definition not found for execution: ' + executionId);
        }

        String interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDef, executionId);
        IExecutionStrategy strategy = ExecutionStrategyRegistryService.resolveStrategy(agentDef, interactionChannel);

        // Check if execution can be resumed
        if (!strategy.canResume(executionId, agentDef, interactionChannel)) {
            throw new AuraHandledException('Execution cannot be resumed from its current state.');
        }

        // Build resume options
        ExecutionResumeModels.ResumeOptions options = new ExecutionResumeModels.ResumeOptions().withReason('Manual resume via UI');

        // Execute resume
        // IMPORTANT: Decision steps are committed during the resume operation.
        // If we throw an exception after resume completes, it will cause a rollback
        // and we'll lose the decision steps. So we return a message instead of throwing.
        AgentExecutionService.ExecutionResult result = strategy.resumeExecution(executionId, options, agentDef);

        if (result.success) {
            return 'Execution resumed successfully: ' + exec.AIAgentDefinition__r.DeveloperName__c + ' (' + executionId + ')';
        } else {
            // Resume failed, but decision steps have been created and committed.
            // We return a message (instead of throwing) to preserve the decision steps.
            // The UI can handle this as a warning/info message.
            String message =
                'Resume operation encountered an error: ' +
                result.errorMessage +
                '. Diagnostic steps have been created and are visible in the Storyboard.';
            return message;
        }
    }

    /**
     * @description Resumes failed/pending executions for a batch.
     * Uses AgentExecutionDispatcher.requeueBatch() for DLQ-based recovery.
     *
     * @param batchId The BatchId__c value for the batch to resume
     * @param includeFailedOnly If true, only resume failed executions. If false, resume pending and failed.
     * @return String Success or error message
     */
    @AuraEnabled
    public static String resumeBatch(String batchId, Boolean includeFailedOnly) {
        try {
            if (String.isBlank(batchId)) {
                throw new AuraHandledException('Batch ID is required.');
            }

            Integer requeuedCount = AgentExecutionDispatcher.requeueBatch(batchId, includeFailedOnly);

            if (requeuedCount == 0) {
                return 'No executions to resume for batch: ' + batchId + '. All may have completed or exceeded retry limits.';
            }

            return 'Requeued ' + requeuedCount + ' execution(s) for batch: ' + batchId + '. Workers will process them via DLQ.';
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            String errorMessage = 'Failed to resume batch: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, '[AgentExecutionResumeController] ' + errorMessage + '\n' + e.getStackTraceString());
            throw new AuraHandledException(errorMessage);
        }
    }

    /**
     * @description Gets progress for a batch.
     * @param batchId The BatchId__c value to query
     * @return BatchProgressResult with status counts
     */
    @AuraEnabled(cacheable=true)
    public static BatchProgressResult getBatchProgress(String batchId) {
        try {
            if (String.isBlank(batchId)) {
                throw new AuraHandledException('Batch ID is required.');
            }

            AgentExecutionDispatcher.BatchProgress progress = AgentExecutionDispatcher.getBatchProgress(batchId);

            BatchProgressResult result = new BatchProgressResult();
            result.batchId = progress.batchId;
            result.totalRecords = progress.totalRecords;
            result.pendingRecords = progress.pendingRecords;
            result.processingRecords = progress.processingRecords;
            result.completedRecords = progress.completedRecords;
            result.failedRecords = progress.failedRecords;
            result.overallStatus = progress.overallStatus;

            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            String errorMessage = 'Failed to get batch progress: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, '[AgentExecutionResumeController] ' + errorMessage);
            throw new AuraHandledException(errorMessage);
        }
    }

    /**
     * @description Determines the object type of a given record ID
     * Useful for the LWC component to route to the correct resume method
     * @param recordId The record ID to analyze
     * @return String The object type (e.g., 'AgentExecution__c')
     */
    @AuraEnabled(cacheable=true)
    public static String getObjectType(Id recordId) {
        try {
            if (recordId == null) {
                throw new AuraHandledException('Record ID is required.');
            }

            // Get the SObject type from the record ID
            Schema.SObjectType sObjectType = recordId.getSObjectType();
            return sObjectType.getDescribe().getName();
        } catch (Exception e) {
            String errorMessage = 'Failed to determine object type: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, '[AgentExecutionResumeController] ' + errorMessage);
            throw new AuraHandledException(errorMessage);
        }
    }

    /**
     * @description Progress result wrapper for Aura/LWC components.
     */
    public class BatchProgressResult {
        @AuraEnabled
        public String batchId;
        @AuraEnabled
        public Integer totalRecords;
        @AuraEnabled
        public Integer pendingRecords;
        @AuraEnabled
        public Integer processingRecords;
        @AuraEnabled
        public Integer completedRecords;
        @AuraEnabled
        public Integer failedRecords;
        @AuraEnabled
        public String overallStatus;
    }
}
