/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Dead Letter Queue (DLQ) based worker for agent executions.
 * Processes individual records and self-pulls next pending work from same agent.
 *
 * **DLQ Architecture:**
 * - Worker processes assigned execution (or picks from pool if none assigned)
 * - After completion, worker queries for next Pending execution from same agent
 * - Uses FOR UPDATE to claim record and prevent collisions
 * - Self-regulating: workers naturally exhaust when no more pending work
 *
 * **Execution Modes:**
 * 1. Pre-assigned Mode: Worker receives specific executionId from dispatcher (initial dispatch)
 * 2. Pool Selection Mode: Worker selects next pending record from same agent (DLQ self-pull)
 *
 * **Priority & Backoff:**
 * - Workers process records ordered by Priority DESC, CreatedDate ASC
 * - Respects NextRetryAt__c for exponential backoff on retries
 * - Sets ProcessingStartedAt__c for stale job detection
 *
 * @author Sonal
 * @since 2025
 */
// inherited sharing: the worker runs in the service user's sharing context, so Salesforce
// sharing rules govern which AgentExecution__c records are visible.  The service user must
// have at minimum Read/Edit OWD (or explicit sharing rules) on AgentExecution__c.
// "without sharing" was previously used here, which allowed the worker to claim and process
// any execution record regardless of record ownership — a privilege-escalation risk.
public inherited sharing class AgentExecutionWorker implements Queueable, Database.AllowsCallouts {
    private static final String LOG_PREFIX = '[AgentExecutionWorker] ';

    private String agentName;
    private Id agentDefinitionId;
    private AIAgentDefinition__c cachedAgentDef;
    private AgentExecutionService.ExecutionPayload payload;
    private Boolean isPreAssignedMode;
    private Boolean allowPreCalloutDml;
    private Boolean deferProcessingAfterClaim = false;

    /**
     * @description Constructor for individual agent execution job.
     * @param agentName The agent developer name
     * @param payload Execution payload (may include pre-assigned existingExecutionId)
     */
    public AgentExecutionWorker(String agentName, AgentExecutionService.ExecutionPayload payload) {
        this.agentName = agentName;
        this.payload = payload;
        this.isPreAssignedMode = (payload.existingExecutionId != null);
    }

    /**
     * @description Queueable execute method.
     * Processes assigned execution, then self-pulls next pending work using DLQ pattern.
     * @param context Queueable context
     */
    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentName + '] ';
        AgentExecution__c execution = null;

        try {
            // Load and cache the agent definition so getOrchestrator() can reuse it
            // without a second round-trip to AIAgentConfigService.
            try {
                this.cachedAgentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentName);
                this.agentDefinitionId = this.cachedAgentDef.Id;
                // Function agents make LLM callouts synchronously in this transaction;
                // avoid any DML before orchestrator.start() to prevent "uncommitted work pending".
                this.allowPreCalloutDml = (this.cachedAgentDef.AgentType__c != 'Function');
            } catch (AIAgentConfigService.ConfigurationException e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Agent definition not found: ' + agentName);
                return;
            }

            // Get execution to process
            if (isPreAssignedMode) {
                // PRE-ASSIGNED MODE: Use specific execution from dispatcher
                execution = claimPreAssignedExecution(payload.existingExecutionId, logPrefix);
                if (execution == null) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Pre-assigned execution not found or already claimed: ' + payload.existingExecutionId);
                    // Try DLQ pull instead
                    execution = claimNextPendingExecution(logPrefix);
                }
            } else {
                // POOL SELECTION MODE: Self-pull from DLQ
                execution = claimNextPendingExecution(logPrefix);
            }

            if (execution == null) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No pending executions available. Worker exiting.');
                return;
            }

            if (deferProcessingAfterClaim) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Deferred processing for function agent execution ' + execution.Id + ' to avoid DML before callout'
                );
                Integer availableSlots = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
                if (availableSlots <= 0) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'No queueable slots available to defer processing. Execution remains Processing.');
                    return;
                }

                AgentExecutionService.ExecutionPayload followUpPayload = new AgentExecutionService.ExecutionPayload();
                followUpPayload.userId = execution.User__c;
                followUpPayload.sourceRecordId = execution.SourceRecordId__c;
                followUpPayload.turnIdentifier = execution.CurrentTurnIdentifier__c;
                followUpPayload.triggerSource = payload.triggerSource != null ? payload.triggerSource : 'DLQ';
                followUpPayload.existingExecutionId = execution.Id;
                followUpPayload.userMessage = payload.userMessage;
                followUpPayload.claimToken = payload.claimToken;

                System.enqueueJob(new AgentExecutionWorker(agentName, followUpPayload));
                return;
            }

            // Process the execution
            processExecution(execution, logPrefix);

            // DLQ PATTERN: After processing, check for more pending work
            chainToNextPendingWork(logPrefix, execution.Id);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Worker failed unexpectedly: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Mark execution as failed if we have one
            if (execution != null) {
                markExecutionFailed(execution, 'Worker-level failure: ' + e.getMessage(), logPrefix);
            }
        }
    }

    /**
     * @description Claims a pre-assigned execution by ID.
     * Sets ProcessingStartedAt__c and transitions to Processing status.
     * @param executionId The pre-assigned execution ID
     * @param logPrefix Logging prefix
     * @return The claimed execution, or null if not found/already claimed
     */
    private AgentExecution__c claimPreAssignedExecution(Id executionId, String logPrefix) {
        try {
            // Function agents can arrive already pre-assigned in Processing state. Require the
            // dispatcher-issued claim token before allowing that worker to continue.
            if (!this.allowPreCalloutDml) {
                List<AgentExecution__c> preAssigned = [
                    SELECT
                        Id,
                        SourceRecordId__c,
                        User__c,
                        CurrentTurnIdentifier__c,
                        AIAgentDefinition__c,
                        ExecutionStatus__c,
                        Priority__c,
                        RetryCount__c,
                        WorkerClaimToken__c
                    FROM AgentExecution__c
                    WHERE Id = :executionId AND ExecutionStatus__c IN ('Pending', 'Processing')
                    LIMIT 1
                ];

                if (preAssigned.isEmpty()) {
                    return null;
                }

                AgentExecution__c execution = preAssigned[0];

                if (String.isNotBlank(execution.WorkerClaimToken__c) && execution.WorkerClaimToken__c != payload.claimToken) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Pre-assigned execution token mismatch for ' + executionId + '. Rejecting worker.');
                    return null;
                }

                if (
                    execution.ExecutionStatus__c == 'Processing' &&
                    (String.isBlank(execution.WorkerClaimToken__c) ||
                    String.isBlank(payload.claimToken) ||
                    execution.WorkerClaimToken__c != payload.claimToken)
                ) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Processing pre-assigned execution is missing a valid claim token. Rejecting worker.');
                    return null;
                }

                if (
                    String.isNotBlank(payload.turnIdentifier) &&
                    String.isNotBlank(execution.CurrentTurnIdentifier__c) &&
                    execution.CurrentTurnIdentifier__c != payload.turnIdentifier
                ) {
                    System.debug(
                        LoggingLevel.WARN,
                        logPrefix +
                            'Pre-assigned execution turn mismatch for ' +
                            executionId +
                            '. Worker turn=' +
                            payload.turnIdentifier +
                            ', execution turn=' +
                            execution.CurrentTurnIdentifier__c +
                            '. Rejecting worker.'
                    );
                    return null;
                }

                if (execution.ExecutionStatus__c == 'Processing') {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Function agent detected - execution already Processing, skipping status update');
                    return execution;
                }

                // Claim and mark Processing with lock (no callout in this transaction).
                List<AgentExecution__c> locked = [
                    SELECT Id, SourceRecordId__c, User__c, CurrentTurnIdentifier__c, AIAgentDefinition__c, ExecutionStatus__c, Priority__c, RetryCount__c
                    FROM AgentExecution__c
                    WHERE Id = :executionId AND ExecutionStatus__c = 'Pending'
                    FOR UPDATE
                ];

                if (locked.isEmpty()) {
                    return null;
                }

                execution = locked[0];
                String claimToken = String.isNotBlank(payload.claimToken) ? payload.claimToken : UUID.randomUUID().toString();
                execution.ExecutionStatus__c = 'Processing';
                execution.ProcessingStartedAt__c = Datetime.now();
                execution.WorkerClaimToken__c = claimToken;
                update execution;
                payload.claimToken = claimToken;
                deferProcessingAfterClaim = true;

                System.debug(LoggingLevel.INFO, logPrefix + 'Locked pre-assigned execution: ' + execution.Id);
                return execution;
            }

            // Non-Function agents: lock and update when needed.
            List<AgentExecution__c> executions = [
                SELECT Id, SourceRecordId__c, User__c, CurrentTurnIdentifier__c, AIAgentDefinition__c, ExecutionStatus__c, Priority__c, RetryCount__c
                FROM AgentExecution__c
                WHERE Id = :executionId AND ExecutionStatus__c IN ('Pending', 'Processing')
                FOR UPDATE
            ];

            if (executions.isEmpty()) {
                return null;
            }

            AgentExecution__c execution = executions[0];

            if (execution.ExecutionStatus__c == 'Pending') {
                // Mark as Processing with timestamp (safe for non-Function agents that do not call out synchronously)
                execution.ExecutionStatus__c = 'Processing';
                execution.ProcessingStartedAt__c = Datetime.now();
                update execution;
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'Execution already Processing, skipping status update');
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Locked pre-assigned execution: ' + execution.Id);
            return execution;
        } catch (QueryException qe) {
            // Row lock exception - another worker claimed it
            System.debug(LoggingLevel.WARN, logPrefix + 'Pre-assigned execution locked by another process: ' + executionId);
            return null;
        }
    }

    /**
     * @description Claims next pending execution from the same agent using DLQ pattern.
     * Orders by Priority DESC, CreatedDate ASC.
     * Respects NextRetryAt__c for exponential backoff.
     * @param logPrefix Logging prefix
     * @return The claimed execution, or null if none available
     */
    private AgentExecution__c claimNextPendingExecution(String logPrefix) {
        try {
            AgentExecution__c execution = lockNextPendingExecution(null);
            if (execution == null) {
                return null;
            }

            if (this.allowPreCalloutDml) {
                // Mark as Processing with timestamp (safe for non-Function agents that do not call out synchronously)
                execution.ExecutionStatus__c = 'Processing';
                execution.ProcessingStartedAt__c = Datetime.now();
                update execution;
            } else {
                String claimToken = String.isNotBlank(payload.claimToken) ? payload.claimToken : UUID.randomUUID().toString();
                execution.ExecutionStatus__c = 'Processing';
                execution.ProcessingStartedAt__c = Datetime.now();
                execution.WorkerClaimToken__c = claimToken;
                update execution;
                payload.claimToken = claimToken;
                deferProcessingAfterClaim = true;
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Locked pending execution via DLQ: ' + execution.Id + ' (Priority: ' + execution.Priority__c + ')');
            return execution;
        } catch (QueryException qe) {
            // Row lock exception - another worker got it first
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Row lock collision during DLQ claim. Another worker claimed the record.');
            return null;
        }
    }

    /**
     * @description Processes a claimed execution by invoking the orchestrator.
     * @param execution The execution to process
     * @param logPrefix Logging prefix
     */
    private void processExecution(AgentExecution__c execution, String logPrefix) {
        String execLogPrefix = logPrefix + '[Exec:' + execution.Id + ' Record:' + execution.SourceRecordId__c + '] ';

        System.debug(LoggingLevel.INFO, execLogPrefix + 'Starting AI orchestration...');

        try {
            // Get orchestrator
            IAgentOrchestrator orchestrator = getOrchestrator();

            // Build payload for orchestration
            AgentExecutionService.ExecutionPayload execPayload = new AgentExecutionService.ExecutionPayload();
            execPayload.userId = execution.User__c;
            execPayload.sourceRecordId = execution.SourceRecordId__c;
            execPayload.turnIdentifier = execution.CurrentTurnIdentifier__c;
            execPayload.triggerSource = payload.triggerSource != null ? payload.triggerSource : 'DLQ';
            execPayload.existingExecutionId = execution.Id;
            execPayload.userMessage = payload.userMessage;

            // Execute orchestration
            orchestrator.start(agentName, execPayload);

            System.debug(LoggingLevel.INFO, execLogPrefix + 'AI orchestration completed successfully');
        } catch (DmlException dmlEx) {
            if (isRowLockException(dmlEx)) {
                System.debug(LoggingLevel.WARN, execLogPrefix + 'Row lock collision during orchestration. Execution may be processed by another worker.');
            } else {
                String errorMsg = 'DML error during orchestration: ' + dmlEx.getMessage();
                System.debug(LoggingLevel.ERROR, execLogPrefix + errorMsg);
                markExecutionFailed(execution, errorMsg, logPrefix);
            }
        } catch (Exception e) {
            String errorMsg = 'Orchestration error: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, execLogPrefix + errorMsg + '\n' + e.getStackTraceString());
            markExecutionFailed(execution, errorMsg, logPrefix);
        }
    }

    /**
     * @description DLQ Pattern: After processing, check for more pending work and chain.
     * Only chains if there are pending records AND we have queueable capacity.
     * @param logPrefix Logging prefix
     */
    private void chainToNextPendingWork(String logPrefix, Id excludeExecutionId) {
        try {
            // Check queueable capacity
            Integer availableSlots = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
            if (availableSlots <= 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No queueable slots available for DLQ chaining. Exiting.');
                return;
            }

            if (!this.allowPreCalloutDml) {
                // Function agents: pre-assign the next execution and mark Processing AFTER callout
                AgentExecution__c nextExecution = claimNextPendingExecutionForChaining(logPrefix, excludeExecutionId);
                if (nextExecution == null) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'No more pending executions. DLQ exhausted. Worker exiting.');
                    return;
                }

                AgentExecutionService.ExecutionPayload chainPayload = new AgentExecutionService.ExecutionPayload();
                chainPayload.userId = nextExecution.User__c;
                chainPayload.sourceRecordId = nextExecution.SourceRecordId__c;
                chainPayload.turnIdentifier = nextExecution.CurrentTurnIdentifier__c;
                chainPayload.triggerSource = 'DLQ';
                chainPayload.existingExecutionId = nextExecution.Id;
                chainPayload.claimToken = nextExecution.WorkerClaimToken__c;

                try {
                    Id jobId = System.enqueueJob(new AgentExecutionWorker(agentName, chainPayload));
                    System.debug(LoggingLevel.INFO, logPrefix + 'DLQ chain: Pre-assigned execution ' + nextExecution.Id + ' to next worker. Job ID: ' + jobId);
                } catch (Exception enqueueEx) {
                    // Revert the claimed execution to Pending so StaleJobDetector
                    // or a future worker can pick it up without a 30-min delay.
                    System.debug(
                        LoggingLevel.WARN,
                        logPrefix + 'Enqueue failed for claimed execution ' + nextExecution.Id + ': ' + enqueueEx.getMessage() + '. Reverting to Pending.'
                    );
                    try {
                        nextExecution.ExecutionStatus__c = 'Pending';
                        nextExecution.ProcessingStartedAt__c = null;
                        nextExecution.WorkerClaimToken__c = null;
                        update nextExecution;
                    } catch (Exception revertEx) {
                        System.debug(
                            LoggingLevel.ERROR,
                            logPrefix + 'Could not revert execution ' + nextExecution.Id + ' to Pending: ' + revertEx.getMessage()
                        );
                    }
                }
                return;
            }

            // Check for pending work (without locking - just existence check)
            Datetime now = Datetime.now();
            Integer pendingCount;
            if (excludeExecutionId != null) {
                pendingCount = [
                    SELECT COUNT()
                    FROM AgentExecution__c
                    WHERE
                        AIAgentDefinition__c = :agentDefinitionId
                        AND ExecutionStatus__c = 'Pending'
                        AND (NextRetryAt__c = NULL
                        OR NextRetryAt__c <= :now)
                        AND Id != :excludeExecutionId
                ];
            } else {
                pendingCount = [
                    SELECT COUNT()
                    FROM AgentExecution__c
                    WHERE AIAgentDefinition__c = :agentDefinitionId AND ExecutionStatus__c = 'Pending' AND (NextRetryAt__c = NULL OR NextRetryAt__c <= :now)
                ];
            }

            if (pendingCount == 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No more pending executions. DLQ exhausted. Worker exiting.');
                return;
            }

            // Chain a new worker (pool selection mode)
            AgentExecutionService.ExecutionPayload chainPayload = new AgentExecutionService.ExecutionPayload();
            chainPayload.userId = UserInfo.getUserId();
            chainPayload.triggerSource = 'DLQ';
            // Note: existingExecutionId NOT set - worker will self-pull

            Id jobId = System.enqueueJob(new AgentExecutionWorker(agentName, chainPayload));

            System.debug(LoggingLevel.INFO, logPrefix + 'DLQ chain: Enqueued next worker for ' + pendingCount + ' pending execution(s). Job ID: ' + jobId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to chain next DLQ worker: ' + e.getMessage());
            // Don't throw - let this worker complete
        }
    }

    /**
     * @description Claims the next pending execution for chaining and marks it Processing.
     * Used by Function agents after callout to avoid pre-callout DML in the next worker.
     * @param logPrefix Logging prefix
     * @param excludeExecutionId Optional execution to exclude
     * @return The claimed execution, or null if none available
     */
    private AgentExecution__c claimNextPendingExecutionForChaining(String logPrefix, Id excludeExecutionId) {
        try {
            AgentExecution__c execution = lockNextPendingExecution(excludeExecutionId);
            if (execution == null) {
                return null;
            }
            execution.ExecutionStatus__c = 'Processing';
            execution.ProcessingStartedAt__c = Datetime.now();
            execution.LastActivityTime__c = Datetime.now();
            execution.WorkerClaimToken__c = UUID.randomUUID().toString();
            update execution;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Locked pending execution for chaining: ' + execution.Id + ' (Priority: ' + execution.Priority__c + ')'
            );
            return execution;
        } catch (QueryException qe) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Row lock collision during DLQ chain claim. Another worker claimed the record.');
            return null;
        }
    }

    /**
     * @description Locks the next pending execution for this agent in priority order.
     * @param excludeExecutionId Optional execution to exclude
     * @return Locked execution or null if none available
     */
    /**
     * Claims the next pending execution for this agent.
     *
     * Two-phase approach: SOQL does not allow ORDER BY with FOR UPDATE, so we
     * first retrieve a priority-ordered candidate set (no lock, lightweight
     * Id-only query), then attempt a FOR UPDATE lock on each candidate in order.
     * Under zero contention this is exactly 2 queries. Under contention we fall
     * through to the next candidate.
     *
     * The candidate pool size is 2× BulkConcurrencyLimit (minimum 10) so that
     * transient unavailability of some candidates cannot starve a worker at the
     * tail of the list under high-concurrency dispatch.
     */
    private AgentExecution__c lockNextPendingExecution(Id excludeExecutionId) {
        Datetime now = Datetime.now();

        // Candidate pool must be at least 2× the max concurrent workers so that
        // transient unavailability of some candidates (expired retries, races with
        // pre-assigned workers) cannot starve a worker at the tail of the list.
        Integer candidateLimit = Math.max(AIAgentFrameworkSettings.getBulkConcurrencyLimit() * 2, 10);

        // Phase 1 — priority-ordered candidate discovery (no lock, Id only)
        List<AgentExecution__c> candidates;
        if (excludeExecutionId != null) {
            candidates = [
                SELECT Id
                FROM AgentExecution__c
                WHERE
                    AIAgentDefinition__c = :agentDefinitionId
                    AND ExecutionStatus__c = 'Pending'
                    AND (NextRetryAt__c = NULL
                    OR NextRetryAt__c <= :now)
                    AND Id != :excludeExecutionId
                ORDER BY Priority__c DESC, CreatedDate ASC
                LIMIT :candidateLimit
            ];
        } else {
            candidates = [
                SELECT Id
                FROM AgentExecution__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND ExecutionStatus__c = 'Pending' AND (NextRetryAt__c = NULL OR NextRetryAt__c <= :now)
                ORDER BY Priority__c DESC, CreatedDate ASC
                LIMIT :candidateLimit
            ];
        }

        if (candidates.isEmpty()) {
            return null;
        }

        // Phase 2 — attempt a FOR UPDATE lock on each candidate in priority order
        for (AgentExecution__c candidate : candidates) {
            try {
                List<AgentExecution__c> locked = [
                    SELECT Id, SourceRecordId__c, User__c, CurrentTurnIdentifier__c, AIAgentDefinition__c, ExecutionStatus__c, Priority__c, RetryCount__c
                    FROM AgentExecution__c
                    WHERE Id = :candidate.Id AND ExecutionStatus__c = 'Pending' AND (NextRetryAt__c = NULL OR NextRetryAt__c <= :now)
                    LIMIT 1
                    FOR UPDATE
                ];
                if (!locked.isEmpty()) {
                    return locked[0];
                }
            } catch (QueryException qe) {
                // Row-lock contention — another worker claimed this record; try next candidate
                System.debug(LoggingLevel.DEBUG, '[AgentExecutionWorker] Row lock contention on candidate ' + candidate.Id + '. Trying next.');
            }
        }
        return null;
    }

    /**
     * @description Marks an execution as failed.
     * @param execution The execution to mark as failed
     * @param errorMessage Error message
     * @param logPrefix Logging prefix
     */
    private void markExecutionFailed(AgentExecution__c execution, String errorMessage, String logPrefix) {
        try {
            // Check current status - only update if still in non-terminal state
            List<AgentExecution__c> currentExec = [
                SELECT Id, ExecutionStatus__c
                FROM AgentExecution__c
                WHERE Id = :execution.Id
                LIMIT 1
            ];

            if (currentExec.isEmpty()) {
                return;
            }

            if (currentExec[0].ExecutionStatus__c == 'Pending' || currentExec[0].ExecutionStatus__c == 'Processing') {
                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.updateStatus(execution.Id, 'Failed', 'Failed', execution.CurrentTurnIdentifier__c, errorMessage);
                System.debug(LoggingLevel.INFO, logPrefix + 'Marked execution ' + execution.Id + ' as Failed');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + e.getMessage());
        }
    }

    /**
     * @description Checks if a DmlException is caused by UNABLE_TO_LOCK_ROW.
     * @param dmlEx The DmlException to check
     * @return True if this is a row lock exception
     */
    private Boolean isRowLockException(DmlException dmlEx) {
        for (Integer i = 0; i < dmlEx.getNumDml(); i++) {
            if (dmlEx.getDmlType(i) == StatusCode.UNABLE_TO_LOCK_ROW) {
                return true;
            }
        }
        return dmlEx.getMessage().containsIgnoreCase('UNABLE_TO_LOCK_ROW');
    }

    /**
     * @description Gets orchestrator for agent, reusing the cached definition from execute().
     * @return IAgentOrchestrator instance
     */
    private IAgentOrchestrator getOrchestrator() {
        if (this.cachedAgentDef == null) {
            throw new AgentExecutionException('Agent definition not loaded for: ' + agentName);
        }
        try {
            return AgentExecutionService.getOrchestrator(this.cachedAgentDef);
        } catch (Exception e) {
            throw new AgentExecutionException('Failed to load orchestrator for agent: ' + agentName + '. ' + e.getMessage());
        }
    }

    /**
     * @description Custom exception for agent execution failures.
     */
    public class AgentExecutionException extends Exception {
    }

    // Comparator removed - ordering is handled in SOQL when selecting the top candidate.
}
