/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * DLQ-based worker for pipeline executions. Claims a Pending pipeline execution,
 * configures the orchestrator, bootstraps state (PipelineRunStep__c records),
 * enqueues the first child agent, then self-chains to process remaining work.
 *
 * Much simpler than AgentExecutionWorker — pipelines don't make LLM callouts
 * directly, so there's no DML-before-callout complexity or Function agent
 * special-casing. The worker just does DML + enqueues child AgentExecutionWorker
 * instances.
 *
 * **DLQ Architecture:**
 * - Worker claims a pre-assigned execution (or self-pulls from Pending pool)
 * - Calls bootstrapExecution() which creates PipelineRunStep__c records and
 *   enqueues the first child agent
 * - After bootstrap, checks for more Pending pipeline executions and chains
 *
 * @author Sonal
 * @since 2025
 */
public inherited sharing class PipelineExecutionWorker implements Queueable {
    private static final String LOG_PREFIX = '[PipelineWorker] ';

    private Id pipelineDefinitionId;
    private Id preAssignedExecutionId;

    /**
     * @description Constructor.
     * @param pipelineDefinitionId The PipelineDefinition__c to configure the orchestrator
     * @param preAssignedExecutionId Optional pre-assigned execution to process first
     */
    public PipelineExecutionWorker(Id pipelineDefinitionId, Id preAssignedExecutionId) {
        this.pipelineDefinitionId = pipelineDefinitionId;
        this.preAssignedExecutionId = preAssignedExecutionId;
    }

    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[Pipeline:' + pipelineDefinitionId + '] ';
        AgentExecution__c execution = null;

        try {
            if (preAssignedExecutionId != null) {
                execution = claimPreAssignedExecution(preAssignedExecutionId, logPrefix);
                if (execution == null) {
                    execution = claimNextPendingExecution(logPrefix);
                }
            } else {
                execution = claimNextPendingExecution(logPrefix);
            }

            if (execution == null) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No pending pipeline executions. Worker exiting.');
                return;
            }

            processExecution(execution, logPrefix);

            chainToNextPendingWork(logPrefix, execution.Id);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Worker failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            if (execution != null) {
                markExecutionFailed(execution.Id, 'Pipeline worker failure: ' + e.getMessage(), logPrefix);
            }
        }
    }

    private void processExecution(AgentExecution__c execution, String logPrefix) {
        String execLogPrefix = logPrefix + '[Exec:' + execution.Id + '] ';
        System.debug(LoggingLevel.INFO, execLogPrefix + 'Bootstrapping pipeline execution');

        try {
            SequentialPipelineOrchestrator orch = new SequentialPipelineOrchestrator();
            orch.configurePipeline(pipelineDefinitionId);
            orch.bootstrapExecution(execution.Id);

            System.debug(LoggingLevel.INFO, execLogPrefix + 'Pipeline bootstrap completed');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, execLogPrefix + 'Bootstrap failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            markExecutionFailed(execution.Id, 'Pipeline bootstrap failed: ' + e.getMessage(), logPrefix);
        }
    }

    // ==================================================================================
    // CLAIM LOGIC (two-phase candidate locking, mirrors AgentExecutionWorker)
    // ==================================================================================

    private AgentExecution__c claimPreAssignedExecution(Id executionId, String logPrefix) {
        try {
            List<AgentExecution__c> locked = [
                SELECT Id, SourceRecordId__c, User__c, CurrentTurnIdentifier__c, PipelineDefinition__c, ExecutionStatus__c
                FROM AgentExecution__c
                WHERE Id = :executionId AND ExecutionStatus__c = 'Pending'
                FOR UPDATE
            ];

            if (locked.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Pre-assigned execution not Pending or already claimed: ' + executionId);
                return null;
            }

            AgentExecution__c execution = locked[0];
            execution.ExecutionStatus__c = 'Processing';
            execution.ProcessingStartedAt__c = Datetime.now();
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Claimed pre-assigned execution: ' + execution.Id);
            return execution;
        } catch (QueryException qe) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Row lock contention on pre-assigned execution: ' + executionId);
            return null;
        }
    }

    private AgentExecution__c claimNextPendingExecution(String logPrefix) {
        AgentExecution__c execution = lockNextPendingExecution(null);
        if (execution == null) {
            return null;
        }

        try {
            execution.ExecutionStatus__c = 'Processing';
            execution.ProcessingStartedAt__c = Datetime.now();
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Claimed pending execution via DLQ: ' + execution.Id);
            return execution;
        } catch (DmlException dmlEx) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to update claimed execution: ' + dmlEx.getMessage());
            return null;
        }
    }

    /**
     * @description Two-phase candidate locking for pipeline executions.
     * Phase 1: priority-ordered candidate discovery (no lock, Id-only)
     * Phase 2: FOR UPDATE lock attempt per candidate, fall through on contention
     */
    @TestVisible
    private AgentExecution__c lockNextPendingExecution(Id excludeExecutionId) {
        Integer candidateLimit = Math.max(AIAgentFrameworkSettings.getBulkConcurrencyLimit() * 2, 10);

        List<AgentExecution__c> candidates;
        if (excludeExecutionId != null) {
            candidates = [
                SELECT Id
                FROM AgentExecution__c
                WHERE
                    PipelineDefinition__c = :pipelineDefinitionId
                    AND ExecutionType__c = 'Pipeline'
                    AND ExecutionStatus__c = 'Pending'
                    AND Id != :excludeExecutionId
                ORDER BY Priority__c DESC, CreatedDate ASC
                LIMIT :candidateLimit
            ];
        } else {
            candidates = [
                SELECT Id
                FROM AgentExecution__c
                WHERE PipelineDefinition__c = :pipelineDefinitionId AND ExecutionType__c = 'Pipeline' AND ExecutionStatus__c = 'Pending'
                ORDER BY Priority__c DESC, CreatedDate ASC
                LIMIT :candidateLimit
            ];
        }

        if (candidates.isEmpty()) {
            return null;
        }

        for (AgentExecution__c candidate : candidates) {
            try {
                List<AgentExecution__c> locked = [
                    SELECT Id, SourceRecordId__c, User__c, CurrentTurnIdentifier__c, PipelineDefinition__c, ExecutionStatus__c
                    FROM AgentExecution__c
                    WHERE Id = :candidate.Id AND ExecutionStatus__c = 'Pending'
                    LIMIT 1
                    FOR UPDATE
                ];
                if (!locked.isEmpty()) {
                    return locked[0];
                }
            } catch (QueryException qe) {
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Row lock contention on candidate ' + candidate.Id + '. Trying next.');
            }
        }
        return null;
    }

    // ==================================================================================
    // DLQ CHAINING
    // ==================================================================================

    private void chainToNextPendingWork(String logPrefix, Id excludeExecutionId) {
        try {
            Integer availableSlots = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
            if (availableSlots <= 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No queueable slots for DLQ chaining. Exiting.');
                return;
            }

            Integer pendingCount = [
                SELECT COUNT()
                FROM AgentExecution__c
                WHERE
                    PipelineDefinition__c = :pipelineDefinitionId
                    AND ExecutionType__c = 'Pipeline'
                    AND ExecutionStatus__c = 'Pending'
                    AND Id != :excludeExecutionId
            ];

            if (pendingCount == 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No more pending pipeline executions. DLQ exhausted.');
                return;
            }

            Id jobId = System.enqueueJob(new PipelineExecutionWorker(pipelineDefinitionId, null));
            System.debug(LoggingLevel.INFO, logPrefix + 'DLQ chain: enqueued next worker for ' + pendingCount + ' pending pipeline(s). Job: ' + jobId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to chain next DLQ worker: ' + e.getMessage());
        }
    }

    // ==================================================================================
    // FAILURE HANDLING
    // ==================================================================================

    private void markExecutionFailed(Id executionId, String errorMessage, String logPrefix) {
        try {
            AgentStateService stateSvc = new AgentStateService();
            stateSvc.updateStatus(executionId, 'Failed', AIAgentConstants.STATUS_IDLE, null, errorMessage);
            System.debug(LoggingLevel.INFO, logPrefix + 'Marked execution ' + executionId + ' as Failed');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + e.getMessage());
        }
    }
}
