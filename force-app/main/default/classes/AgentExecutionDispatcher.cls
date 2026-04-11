/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Dead Letter Queue (DLQ) based dispatcher for agent executions.
 * Creates AgentExecution__c records and enqueues limited workers that self-regulate.
 *
 * **Architecture - DLQ Pattern:**
 * - Dispatch creates N AgentExecution__c records with 'Pending' status
 * - Limited workers are enqueued (using Hybrid Cap)
 * - Each worker processes its record, then pulls next pending record from same agent
 * - Workers self-regulate: no central coordination needed
 * - System naturally scales based on platform capacity
 *
 * **Key Benefits:**
 * - Safe at any scale (never hits queueable limits)
 * - Self-healing (stuck jobs can be detected and retried)
 * - Priority support (ORDER BY Priority__c DESC)
 * - Progress tracking via aggregate queries on BatchId__c
 *
 * @author Sonal
 * @since 2025
 */
public with sharing class AgentExecutionDispatcher {
    private static final String LOG_PREFIX = '[AgentDispatcher] ';

    /**
     * @description Dispatches agent executions for a batch of records.
     * Creates AgentExecution__c records and enqueues limited workers using DLQ pattern.
     *
     * @param agentName The agent developer name
     * @param payload Execution payload containing source record IDs
     * @return DispatchResult with batch ID and worker count
     */
    public static DispatchResult dispatch(String agentName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentName + '] ';

        try {
            // Ensure userId is always the authenticated caller — prevents spoofing $Context.UserId
            // tokens in action backend configurations when dispatch is called programmatically.
            if (payload.userId == null) {
                payload.userId = UserInfo.getUserId();
            }

            Integer recordCount = payload.sourceRecordIds != null ? payload.sourceRecordIds.size() : 0;
            System.debug(LoggingLevel.INFO, logPrefix + 'DLQ dispatch started for ' + recordCount + ' records');

            if (recordCount == 0) {
                throw new AgentExecutionException('No source record IDs provided');
            }

            // Get agent definition
            AIAgentDefinition__c agentDef;
            try {
                agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentName);
            } catch (AIAgentConfigService.ConfigurationException e) {
                throw new AgentExecutionException('Agent definition not found or inactive: ' + agentName + '. ' + e.getMessage());
            }
            String runtimeChannel = String.isNotBlank(payload.interactionChannel)
                ? payload.interactionChannel
                : RuntimeRegistryService.getInteractionChannel(agentDef, null);

            // Generate batch ID for correlation
            String batchId = generateBatchId();

            System.debug(LoggingLevel.INFO, logPrefix + 'Generated BatchId: ' + batchId);

            // Create AgentExecution__c records
            List<AgentExecution__c> executions = createExecutionRecords(agentDef, payload, batchId, logPrefix);

            // Determine optimal worker count using Hybrid Cap
            Integer workerCount = Math.min(AIAgentFrameworkSettings.calculateOptimalWorkerCount(executions.size()), executions.size());

            System.debug(LoggingLevel.INFO, logPrefix + 'Hybrid Cap: ' + workerCount + ' workers for ' + executions.size() + ' records');

            // For Function agents, pre-mark the pre-assigned executions as Processing
            // so workers can call out without a deferral queueable.
            if (workerCount > 0 && RuntimeRegistryService.getTraits(agentDef, runtimeChannel).requiresCleanPreCalloutTransaction == true) {
                markPreAssignedProcessing(executions, workerCount, logPrefix);
            }

            // Enqueue workers with pre-assigned execution IDs
            for (Integer i = 0; i < workerCount; i++) {
                AgentExecution__c execution = executions[i];

                AgentExecutionService.ExecutionPayload workerPayload = buildWorkerPayload(payload, execution);

                new AgentJobEnqueuer().enqueueQueueable(new AgentExecutionWorker(agentName, workerPayload), logPrefix, agentDef.Id);

                System.debug(LoggingLevel.DEBUG, logPrefix + 'Enqueued worker ' + (i + 1) + ' for execution ' + execution.Id);
            }

            Integer remainingRecords = executions.size() - workerCount;
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'DLQ dispatch completed. BatchId: ' +
                    batchId +
                    ', Created: ' +
                    executions.size() +
                    ' executions' +
                    ', Enqueued: ' +
                    workerCount +
                    ' workers' +
                    ', Remaining: ' +
                    remainingRecords +
                    ' (will be pulled by workers via DLQ)'
            );

            // Build result
            DispatchResult result = new DispatchResult();
            result.success = true;
            result.batchId = batchId;
            result.executionIds = new List<Id>();
            for (AgentExecution__c exec : executions) {
                result.executionIds.add(exec.Id);
            }
            result.enqueuedJobCount = workerCount;
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'DLQ dispatch failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AgentExecutionException('Failed to dispatch agent execution: ' + e.getMessage());
        }
    }

    /**
     * @description Marks the first N executions as Processing for pre-assigned workers.
     * This avoids DML in the worker before callout for Function agents.
     */
    private static void markPreAssignedProcessing(List<AgentExecution__c> executions, Integer workerCount, String logPrefix) {
        if (executions == null || executions.isEmpty() || workerCount == null || workerCount <= 0) {
            return;
        }

        Integer cappedCount = Math.min(workerCount, executions.size());
        List<AgentExecution__c> updates = new List<AgentExecution__c>();
        Datetime now = Datetime.now();

        for (Integer i = 0; i < cappedCount; i++) {
            String claimToken = UUID.randomUUID().toString();
            executions[i].WorkerClaimToken__c = claimToken;
            updates.add(
                new AgentExecution__c(
                    Id = executions[i].Id,
                    ExecutionStatus__c = 'Processing',
                    ProcessingStartedAt__c = now,
                    LastActivityTime__c = now,
                    WorkerClaimToken__c = claimToken
                )
            );
        }

        update updates;

        System.debug(LoggingLevel.INFO, logPrefix + 'Pre-marked ' + cappedCount + ' execution(s) as Processing for direct worker dispatch');
    }

    /**
     * @description Creates AgentExecution__c records for all source records.
     * @param agentDef Agent definition
     * @param payload Execution payload
     * @param batchId Batch correlation ID
     * @param logPrefix Log prefix
     * @return List of created execution records
     */
    private static List<AgentExecution__c> createExecutionRecords(
        AIAgentDefinition__c agentDef,
        AgentExecutionService.ExecutionPayload payload,
        String batchId,
        String logPrefix
    ) {
        List<AgentExecution__c> executions = new List<AgentExecution__c>();
        String interactionChannel = String.isNotBlank(payload.interactionChannel)
            ? payload.interactionChannel
            : RuntimeRegistryService.getInteractionChannel(agentDef, null);

        // Get priority from payload (default 0)
        Integer priority = payload.priority != null ? payload.priority : 0;

        for (Id recordId : payload.sourceRecordIds) {
            executions.add(
                new AgentExecution__c(
                    SourceRecordId__c = recordId,
                    ExecutionStatus__c = 'Pending',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    AIAgentDefinition__c = agentDef.Id,
                    User__c = payload.userId,
                    ServiceUser__c = payload.serviceUserId,
                    ExecutionType__c = agentDef.RuntimeStrategy__c,
                    InteractionChannel__c = interactionChannel,
                    TriggerSource__c = payload.triggerSource != null ? payload.triggerSource : 'Apex',
                    TriggerPayload__c = payload.triggerPayload,
                    CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
                    StartTime__c = Datetime.now(),
                    LastActivityTime__c = Datetime.now(),
                    // New DLQ fields
                    BatchId__c = batchId,
                    Priority__c = priority,
                    RetryCount__c = 0,
                    MaxRetries__c = 3,
                    ExecutionIdentityProfileDeveloperName__c = payload.executionIdentityProfileDeveloperName,
                    ExecutionIdentityNamedCredential__c = payload.executionIdentityNamedCredential
                )
            );
        }

        // Bulk insert
        insert executions;

        System.debug(LoggingLevel.INFO, logPrefix + 'Created ' + executions.size() + ' AgentExecution__c records');

        return executions;
    }

    /**
     * @description Builds worker payload from execution record.
     * @param originalPayload Original dispatch payload
     * @param execution Execution record
     * @return Worker payload
     */
    private static AgentExecutionService.ExecutionPayload buildWorkerPayload(
        AgentExecutionService.ExecutionPayload originalPayload,
        AgentExecution__c execution
    ) {
        AgentExecutionService.ExecutionPayload workerPayload = new AgentExecutionService.ExecutionPayload();
        workerPayload.userId = originalPayload.userId;
        workerPayload.serviceUserId = execution.ServiceUser__c != null ? execution.ServiceUser__c : originalPayload.serviceUserId;
        workerPayload.triggerSource = originalPayload.triggerSource;
        workerPayload.userMessage = originalPayload.userMessage;
        workerPayload.isInServiceUserContext = originalPayload.isInServiceUserContext;
        workerPayload.sourceRecordId = execution.SourceRecordId__c;
        workerPayload.existingExecutionId = execution.Id;
        workerPayload.turnIdentifier = execution.CurrentTurnIdentifier__c;
        workerPayload.claimToken = execution.WorkerClaimToken__c;
        workerPayload.interactionChannel = execution.InteractionChannel__c;
        workerPayload.executionIdentityProfileDeveloperName = execution.ExecutionIdentityProfileDeveloperName__c;
        workerPayload.executionIdentityNamedCredential = execution.ExecutionIdentityNamedCredential__c;
        return workerPayload;
    }

    /**
     * @description Generates a unique batch ID.
     * @return UUID-based batch identifier
     */
    private static String generateBatchId() {
        return 'BATCH-' + UUID.randomUUID().toString();
    }

    // ================================================================================
    // PROGRESS TRACKING (On-Demand Queries)
    // ================================================================================

    /**
     * @description Gets progress summary for a batch.
     *
     * @param batchId The batch ID to query
     * @return BatchProgress with counts by status
     */
    public static BatchProgress getBatchProgress(String batchId) {
        BatchProgress progress = new BatchProgress();
        progress.batchId = batchId;

        // Aggregate query for status counts
        List<AggregateResult> results = [
            SELECT ExecutionStatus__c status, COUNT(Id) cnt
            FROM AgentExecution__c
            WHERE BatchId__c = :batchId
            GROUP BY ExecutionStatus__c
        ];

        for (AggregateResult ar : results) {
            String status = (String) ar.get('status');
            Integer count = (Integer) ar.get('cnt');
            progress.totalRecords += count;

            if (status == 'Completed') {
                progress.completedRecords = count;
            } else if (status == 'Failed') {
                progress.failedRecords = count;
            } else if (status == 'Pending') {
                progress.pendingRecords = count;
            } else if (status == 'Processing') {
                progress.processingRecords = count;
            }
        }

        // Determine overall status
        if (progress.pendingRecords == 0 && progress.processingRecords == 0) {
            progress.overallStatus = progress.failedRecords > 0 ? 'Completed With Errors' : 'Completed';
        } else if (progress.completedRecords > 0 || progress.failedRecords > 0 || progress.processingRecords > 0) {
            progress.overallStatus = 'Processing';
        } else {
            progress.overallStatus = 'Pending';
        }

        return progress;
    }

    /**
     * @description Requeues pending/failed executions for a batch.
     * Used for manual retry of stuck or failed jobs.
     *
     * @param batchId The batch ID to retry
     * @param includeFailedOnly If true, only retry failed jobs. If false, retry pending and failed.
     * @return Number of executions requeued
     */
    public static Integer requeueBatch(String batchId, Boolean includeFailedOnly) {
        String logPrefix = LOG_PREFIX + '[Requeue][Batch:' + batchId + '] ';

        // A manual requeue is an explicit admin override — include all eligible executions
        // regardless of RetryCount__c so that permanently-failed records can be rescued.
        List<AgentExecution__c> executions = [
            SELECT
                Id,
                AIAgentDefinition__c,
                User__c,
                ServiceUser__c,
                AIAgentDefinition__r.DeveloperName__c,
                AIAgentDefinition__r.RuntimeStrategy__c,
                Priority__c,
                CreatedDate,
                LastActivityTime__c,
                CurrentTurnIdentifier__c,
                InteractionChannel__c,
                ExecutionIdentityProfileDeveloperName__c,
                ExecutionIdentityNamedCredential__c
            FROM AgentExecution__c
            WHERE BatchId__c = :batchId AND ExecutionStatus__c IN ('Pending', 'Failed')
            ORDER BY Priority__c DESC, CreatedDate ASC
        ];

        if (executions.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No executions to requeue');
            return 0;
        }

        // Phase 1 — group by agent and compute final worker counts BEFORE any DML.
        // This lets us set each record's final status in a single update, avoiding
        // the previous double-write (all→Pending then first-N→Processing for Function agents).
        Map<String, List<AgentExecution__c>> executionsByAgent = new Map<String, List<AgentExecution__c>>();
        Map<String, String> agentTypeByName = new Map<String, String>();
        for (AgentExecution__c exec : executions) {
            String agentName = exec.AIAgentDefinition__r != null ? exec.AIAgentDefinition__r.DeveloperName__c : null;
            if (String.isBlank(agentName)) {
                continue;
            }
            if (!executionsByAgent.containsKey(agentName)) {
                executionsByAgent.put(agentName, new List<AgentExecution__c>());
                agentTypeByName.put(agentName, exec.AIAgentDefinition__r.RuntimeStrategy__c);
            }
            executionsByAgent.get(agentName).add(exec);
        }

        // Phase 2 — reset every execution to Pending/Idle in a single update.
        // Do NOT pre-assign any execution to Processing here. The worker is responsible
        // for claiming and transitioning its own execution when it starts.
        // Do NOT increment RetryCount__c — only the automated stale-job detector counts
        // against MaxRetries__c; a manual admin requeue is an unconditional override.
        Map<String, Integer> workerCountByAgent = new Map<String, Integer>();
        for (String agentName : executionsByAgent.keySet()) {
            List<AgentExecution__c> agentExecutions = executionsByAgent.get(agentName);
            Integer workerCount = Math.min(AIAgentFrameworkSettings.calculateOptimalWorkerCount(agentExecutions.size()), agentExecutions.size());
            workerCountByAgent.put(agentName, workerCount);

            for (AgentExecution__c exec : agentExecutions) {
                exec.ExecutionStatus__c = 'Pending';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_IDLE;
                exec.ProcessingStartedAt__c = null;
                exec.ErrorMessage__c = null;
                exec.WorkerClaimToken__c = null;
            }
        }

        // Handle any executions that were not grouped (no valid agentName)
        for (AgentExecution__c exec : executions) {
            if (exec.ExecutionStatus__c == 'Failed' || exec.ExecutionStatus__c == 'Pending') {
                exec.ExecutionStatus__c = 'Pending';
                exec.ProcessingStatus__c = AIAgentConstants.STATUS_IDLE;
                exec.ProcessingStartedAt__c = null;
                exec.ErrorMessage__c = null;
                exec.WorkerClaimToken__c = null;
            }
        }

        update executions;

        // Phase 3 — enqueue workers (no markPreAssignedProcessing needed; status already set above).
        Integer totalWorkersEnqueued = 0;
        for (String agentName : executionsByAgent.keySet()) {
            List<AgentExecution__c> agentExecutions = executionsByAgent.get(agentName);
            Integer workerCount = workerCountByAgent.get(agentName);

            for (Integer i = 0; i < workerCount; i++) {
                AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
                payload.existingExecutionId = agentExecutions[i].Id;
                payload.userId = agentExecutions[i].User__c;
                payload.serviceUserId = agentExecutions[i].ServiceUser__c;
                payload.triggerSource = 'Retry';
                payload.turnIdentifier = agentExecutions[i].CurrentTurnIdentifier__c;
                payload.interactionChannel = agentExecutions[i].InteractionChannel__c;
                payload.executionIdentityProfileDeveloperName = agentExecutions[i].ExecutionIdentityProfileDeveloperName__c;
                payload.executionIdentityNamedCredential = agentExecutions[i].ExecutionIdentityNamedCredential__c;

                new AgentJobEnqueuer().enqueueQueueable(new AgentExecutionWorker(agentName, payload), logPrefix);
                totalWorkersEnqueued++;
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Requeued ' + executions.size() + ' executions, enqueued ' + totalWorkersEnqueued + ' workers');

        return executions.size();
    }

    // ================================================================================
    // INNER CLASSES
    // ================================================================================

    /**
     * @description Result wrapper for dispatch operations
     */
    public class DispatchResult {
        public Boolean success;
        public String batchId;
        public List<Id> executionIds;
        public Integer enqueuedJobCount;
        public String errorMessage;
    }

    /**
     * @description Progress tracking for a batch
     */
    public class BatchProgress {
        public String batchId;
        public Integer totalRecords = 0;
        public Integer pendingRecords = 0;
        public Integer processingRecords = 0;
        public Integer completedRecords = 0;
        public Integer failedRecords = 0;
        public String overallStatus;
    }

    /**
     * @description Custom exception for agent execution failures
     */
    public class AgentExecutionException extends Exception {
    }
}
