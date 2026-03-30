/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Handler for AgentExecutionTrigger. Manages child execution completion notifications
 * for any parent agent type (Pipeline, Function, Conversational).
 *
 * **Key Responsibilities:**
 * - Detect when child executions complete or fail
 * - Notify parent orchestrators via onChildComplete() callback
 * - Handle batch execution chaining via DLQ pattern
 *
 * **DLQ Architecture Note:**
 * Worker chaining is handled here (trigger-based) for BatchId__c groups to avoid
 * queueable slot exhaustion in worker contexts (e.g., pipeline/sub-agent queueables).
 *
 * @author Sonal
 * @since 2025
 */
public without sharing class AgentExecutionTriggerHandler {
    // Recursion guard (defensive - not strictly needed due to hasParent filter)
    private static Boolean isProcessingChildCompletion = false;

    /**
     * @description Handles after update events on AgentExecution__c
     * @param newExecutions List of updated execution records
     * @param oldExecutionsMap Map of old execution records
     */
    public static void handleAfterUpdate(List<AgentExecution__c> newExecutions, Map<Id, AgentExecution__c> oldExecutionsMap) {
        String logPrefix = '[AgentExecutionTriggerHandler] ';

        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + newExecutions.size() + ' execution record updates');

        List<Id> completedChildExecutionIds = new List<Id>();
        Set<Id> completedParentExecutionIds = new Set<Id>();
        Set<String> completedBatchIds = new Set<String>();

        // Find child executions that just transitioned to Completed or Failed
        for (AgentExecution__c newExec : newExecutions) {
            AgentExecution__c oldExec = oldExecutionsMap.get(newExec.Id);

            // Benchmark executions are handled by the addon-only benchmark trigger.
            if (newExec.TriggerSource__c == 'Benchmark') {
                continue;
            }

            // Check if status changed to terminal state
            Boolean statusChanged = (newExec.ExecutionStatus__c != oldExec.ExecutionStatus__c);
            Boolean isTerminalState = (newExec.ExecutionStatus__c == 'Completed' || newExec.ExecutionStatus__c == 'Failed');

            if (statusChanged && isTerminalState) {
                // Check if this is a child execution (has parent)
                if (newExec.ParentExecution__c != null) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Child execution completed: ' +
                            newExec.Id +
                            ', Status: ' +
                            newExec.ExecutionStatus__c +
                            ', Parent: ' +
                            newExec.ParentExecution__c
                    );
                    completedChildExecutionIds.add(newExec.Id);
                }

                // Batch chaining: track parent executions (no ParentExecution__c).
                // Note: BatchId__c may not be present in Trigger.new if updated via partial DML.
                if (newExec.ParentExecution__c == null) {
                    completedParentExecutionIds.add(newExec.Id);
                }
            }
        }

        // Load BatchId__c from database for completed parent executions
        if (!completedParentExecutionIds.isEmpty()) {
            for (AgentExecution__c exec : [
                SELECT Id, BatchId__c
                FROM AgentExecution__c
                WHERE Id IN :completedParentExecutionIds AND BatchId__c != NULL
            ]) {
                completedBatchIds.add(exec.BatchId__c);
            }
        }

        // Process completed child executions SYNCHRONOUSLY (no callouts involved)
        // Recursion guard: only process child completions if not already processing
        if (!completedChildExecutionIds.isEmpty() && !isProcessingChildCompletion) {
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Processing parent notification for ' + completedChildExecutionIds.size() + ' completed child executions'
            );

            isProcessingChildCompletion = true;
            try {
                processChildCompletions(completedChildExecutionIds, logPrefix);
            } finally {
                isProcessingChildCompletion = false;
            }
        } else if (!completedChildExecutionIds.isEmpty() && isProcessingChildCompletion) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Recursion detected - skipping child completion processing');
        }

        // Process completed batch executions - chain next pending record
        // NO recursion guard here - batch chaining must run even during nested triggers
        if (!completedBatchIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Processing batch chaining for ' + completedBatchIds.size() + ' completed batches');
            processBatchExecutionCompletions(completedBatchIds, logPrefix);
        }
    }

    /**
     * @description Processes completed child executions and notifies parent orchestrators.
     * Runs synchronously within trigger context - no callouts are made here.
     *
     * @param childExecutionIds List of completed child execution IDs
     * @param logPrefix Logging prefix
     */
    private static void processChildCompletions(List<Id> childExecutionIds, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Notifying parent orchestrators for ' + childExecutionIds.size() + ' child executions');

        // Query child executions with parent and agent info, including error message
        List<AgentExecution__c> childExecutions = [
            SELECT
                Id,
                ExecutionStatus__c,
                ParentExecution__c,
                AIAgentDefinition__c,
                AIAgentDefinition__r.DeveloperName__c,
                AIAgentDefinition__r.Name,
                ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id IN :childExecutionIds
        ];

        Set<Id> parentIds = new Set<Id>();
        Set<Id> childIds = new Set<Id>();

        for (AgentExecution__c childExec : childExecutions) {
            parentIds.add(childExec.ParentExecution__c);
            childIds.add(childExec.Id);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + parentIds.size() + ' parent orchestrators');

        Map<Id, AgentExecution__c> parentExecutions = new Map<Id, AgentExecution__c>();
        if (!parentIds.isEmpty()) {
            parentExecutions = new Map<Id, AgentExecution__c>(
                [
                    SELECT
                        Id,
                        ExecutionType__c,
                        AIAgentDefinition__c,
                        AIAgentDefinition__r.DeveloperName__c,
                        AIAgentDefinition__r.RuntimeStrategy__c,
                        SourceRecordId__c,
                        TriggerPayload__c,
                        PipelineDefinition__c
                    FROM AgentExecution__c
                    WHERE Id IN :parentIds
                ]
            );
        }

        Map<Id, AIAgentDefinition__c> agentDefinitionsById = new Map<Id, AIAgentDefinition__c>();
        for (AgentExecution__c parentExec : parentExecutions.values()) {
            if (parentExec.AIAgentDefinition__c == null || agentDefinitionsById.containsKey(parentExec.AIAgentDefinition__c)) {
                continue;
            }
            try {
                agentDefinitionsById.put(parentExec.AIAgentDefinition__c, AIAgentConfigService.getAgentDefinition(parentExec.AIAgentDefinition__c));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Unable to preload agent definition: ' + parentExec.AIAgentDefinition__c + '. ' + e.getMessage());
            }
        }

        // Preload latest ExecutionStep__c per child execution (heap-safe)
        Map<Id, ExecutionStep__c> latestStepByExecution = new Map<Id, ExecutionStep__c>();
        if (!childIds.isEmpty()) {
            Map<Id, Datetime> latestStepTimeByExec = new Map<Id, Datetime>();
            for (AggregateResult ar : [
                SELECT AgentExecution__c execId, MAX(Timestamp__c) maxTs
                FROM ExecutionStep__c
                WHERE AgentExecution__c IN :childIds AND (StepType__c = 'AgentResponse' OR StepType__c = 'Error')
                GROUP BY AgentExecution__c
            ]) {
                latestStepTimeByExec.put((Id) ar.get('execId'), (Datetime) ar.get('maxTs'));
            }

            if (!latestStepTimeByExec.isEmpty()) {
                for (ExecutionStep__c step : [
                    SELECT Id, AgentExecution__c, StepType__c, Content__c, Timestamp__c
                    FROM ExecutionStep__c
                    WHERE
                        AgentExecution__c IN :childIds
                        AND Timestamp__c IN :latestStepTimeByExec.values()
                        AND (StepType__c = 'AgentResponse'
                        OR StepType__c = 'Error')
                ]) {
                    ExecutionStep__c current = latestStepByExecution.get(step.AgentExecution__c);
                    if (current == null || step.Timestamp__c > current.Timestamp__c || (step.Timestamp__c == current.Timestamp__c && step.Id > current.Id)) {
                        latestStepByExecution.put(step.AgentExecution__c, step);
                    }
                }
            }
        }

        // Resolve latest logged child errors through the logger abstraction so
        Map<Id, IDecisionStepLogger.LoggedErrorInfo> latestDecisionErrorByExecution = IDecisionStepLogger.getLatestFailedErrors(childIds);

        // Notify each parent runtime/composition boundary once per child completion.
        // On failure: transition the parent to Failed so it does not silently
        // remain stuck in Processing with no error record.
        for (AgentExecution__c childExec : childExecutions) {
            try {
                notifyParentOrchestrator(
                    childExec.ParentExecution__c,
                    childExec,
                    parentExecutions,
                    agentDefinitionsById,
                    latestStepByExecution,
                    latestDecisionErrorByExecution,
                    logPrefix
                );
            } catch (SequentialPipelineOrchestrator.PipelineStateException pse) {
                // Configuration/data problem (e.g. pipeline has no active steps). Log at WARN
                // because this is a deterministic misconfiguration, not an unexpected runtime error.
                String errMsg = 'Trigger handler failed to notify parent orchestrator for child ' + childExec.Id + ': ' + pse.getMessage();
                System.debug(LoggingLevel.WARN, logPrefix + errMsg);
                try {
                    update new AgentExecution__c(Id = childExec.ParentExecution__c, ExecutionStatus__c = 'Failed', ErrorMessage__c = errMsg);
                } catch (Exception updateEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Could not mark parent execution Failed: ' + updateEx.getMessage());
                }
            } catch (Exception e) {
                String errMsg = 'Trigger handler failed to notify parent orchestrator for child ' + childExec.Id + ': ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, logPrefix + errMsg + '\n' + e.getStackTraceString());
                try {
                    update new AgentExecution__c(Id = childExec.ParentExecution__c, ExecutionStatus__c = 'Failed', ErrorMessage__c = errMsg);
                } catch (Exception updateEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Could not mark parent execution Failed: ' + updateEx.getMessage());
                }
            }
        }
    }

    /**
     * @description Processes completed batch executions and chains to next pending record.
     * Uses BatchId__c as the semaphore key to avoid worker-side queueable slot exhaustion.
     *
     * @param completedBatchIds Set of BatchId__c values for completed executions
     * @param logPrefix Logging prefix
     */
    private static void processBatchExecutionCompletions(Set<String> completedBatchIds, String logPrefix) {
        Integer availableSlots = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
        if (availableSlots <= 0) {
            System.debug(LoggingLevel.WARN, logPrefix + 'No queueable slots available for batch chaining. Exiting.');
            return;
        }

        Integer bulkConcurrencyLimit = AIAgentFrameworkSettings.getBulkConcurrencyLimit();
        Datetime now = Datetime.now();
        Map<String, String> agentNameByBatch = new Map<String, String>();

        // Preload agent names for batches (single query)
        for (AgentExecution__c exec : [
            SELECT BatchId__c, AIAgentDefinition__r.DeveloperName__c
            FROM AgentExecution__c
            WHERE BatchId__c IN :completedBatchIds
        ]) {
            if (!agentNameByBatch.containsKey(exec.BatchId__c)) {
                agentNameByBatch.put(exec.BatchId__c, exec.AIAgentDefinition__r.DeveloperName__c);
            }
        }

        for (String batchId : completedBatchIds) {
            try {
                String agentName = agentNameByBatch.get(batchId);
                if (String.isBlank(agentName)) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Batch ' + batchId + ' has no agent name. Skipping chaining.');
                    continue;
                }

                // Chain a single worker per trigger to respect queueable limits
                AgentExecution__c nextExecution = claimNextPendingExecutionForBatch(batchId, now, bulkConcurrencyLimit, logPrefix);
                if (nextExecution == null) {
                    continue;
                }

                AgentExecutionService.ExecutionPayload chainPayload = new AgentExecutionService.ExecutionPayload();
                chainPayload.userId = nextExecution.User__c;
                chainPayload.serviceUserId = nextExecution.ServiceUser__c;
                chainPayload.sourceRecordId = nextExecution.SourceRecordId__c;
                chainPayload.turnIdentifier = nextExecution.CurrentTurnIdentifier__c;
                chainPayload.triggerSource = 'DLQ';
                chainPayload.existingExecutionId = nextExecution.Id;
                chainPayload.executionIdentityProfileDeveloperName = nextExecution.ExecutionIdentityProfileDeveloperName__c;
                chainPayload.executionIdentityNamedCredential = nextExecution.ExecutionIdentityNamedCredential__c;

                try {
                    System.enqueueJob(new AgentExecutionWorker(agentName, chainPayload));
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Batch chain: Enqueued worker for execution ' + nextExecution.Id + ' (BatchId=' + batchId + ')'
                    );
                } catch (Exception enqueueEx) {
                    try {
                        update new AgentExecution__c(Id = nextExecution.Id, ExecutionStatus__c = 'Pending', ProcessingStartedAt__c = null);
                    } catch (Exception revertEx) {
                        System.debug(
                            LoggingLevel.ERROR,
                            logPrefix + 'Failed to revert claimed batch execution ' + nextExecution.Id + ' after enqueue failure: ' + revertEx.getMessage()
                        );
                    }
                    throw enqueueEx;
                }

                // Update availableSlots for subsequent batches.
                // In a Queueable chain context the platform limit is 1; remaining DLQ
                // executions will be self-picked-up by the next worker's DLQ pull.
                availableSlots--;
                if (availableSlots <= 0) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Queueable slot limit reached after chaining 1 worker; remaining DLQ executions will self-pick-up.'
                    );
                    return;
                }
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Failed to chain batch worker for batch ' + batchId + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
                );
            }
        }
    }

    /**
     * @description Claims next pending execution for a batch and marks it Processing.
     * Uses a single FOR UPDATE query to avoid TOCTOU claim collisions.
     *
     * @param batchId BatchId__c to chain
     * @param now Current timestamp for NextRetryAt__c filtering
     * @param bulkConcurrencyLimit Maximum active Processing executions allowed per batch
     * @param logPrefix Logging prefix
     * @return Claimed execution or null if none available
     */
    private static AgentExecution__c claimNextPendingExecutionForBatch(String batchId, Datetime now, Integer bulkConcurrencyLimit, String logPrefix) {
        try {
            List<AgentExecution__c> semaphore = [
                SELECT Id
                FROM AgentExecution__c
                WHERE BatchId__c = :batchId
                LIMIT 1
                FOR UPDATE
            ];
            if (semaphore.isEmpty()) {
                return null;
            }

            Integer processingCount = 0;
            for (AggregateResult ar : [
                SELECT COUNT(Id) cnt
                FROM AgentExecution__c
                WHERE BatchId__c = :batchId AND ExecutionStatus__c = 'Processing'
            ]) {
                processingCount = (Integer) ar.get('cnt');
            }

            if (processingCount >= bulkConcurrencyLimit) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Batch ' + batchId + ' already has ' + processingCount + ' processing executions under lock. Skipping chaining.'
                );
                return null;
            }

            List<AgentExecution__c> candidates = [
                SELECT Id, SourceRecordId__c, User__c, ServiceUser__c, CurrentTurnIdentifier__c, Priority__c, ExecutionIdentityProfileDeveloperName__c, ExecutionIdentityNamedCredential__c
                FROM AgentExecution__c
                WHERE BatchId__c = :batchId AND ExecutionStatus__c = 'Pending' AND (NextRetryAt__c = NULL OR NextRetryAt__c <= :now)
                ORDER BY Priority__c DESC, CreatedDate ASC
                LIMIT 5
            ];

            if (candidates.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Batch ' + batchId + ' has no pending executions under lock.');
                return null;
            }

            AgentExecution__c execution;
            for (AgentExecution__c candidate : candidates) {
                List<AgentExecution__c> locked = [
                    SELECT Id, SourceRecordId__c, User__c, ServiceUser__c, CurrentTurnIdentifier__c, Priority__c, ExecutionIdentityProfileDeveloperName__c, ExecutionIdentityNamedCredential__c
                    FROM AgentExecution__c
                    WHERE Id = :candidate.Id AND ExecutionStatus__c = 'Pending' AND (NextRetryAt__c = NULL OR NextRetryAt__c <= :now)
                    FOR UPDATE
                ];

                if (!locked.isEmpty()) {
                    execution = locked[0];
                    break;
                }
            }

            if (execution == null) {
                return null;
            }
            execution.ExecutionStatus__c = 'Processing';
            execution.ProcessingStartedAt__c = Datetime.now();
            execution.LastActivityTime__c = Datetime.now();
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Locked pending batch execution: ' + execution.Id + ' (Priority: ' + execution.Priority__c + ')');

            return execution;
        } catch (QueryException qe) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Row lock collision during batch claim. Another process claimed the record.');
            return null;
        }
    }

    /**
     * @description Notifies a parent orchestrator that its child execution has completed.
     * Supports any parent agent type (Pipeline, Function, Conversational) by dynamically
     * resolving the parent's execution strategy and forwarding the callback there.
     *
     * @param parentExecutionId The parent execution ID
     * @param childExec The completed child execution
     * @param parentExecutions Preloaded parent execution map
     * @param agentDefinitionsById Preloaded agent definitions
     * @param latestStepByExecution Preloaded latest steps
     * @param latestDecisionErrorByExecution Preloaded latest logged child errors
     * @param logPrefix Logging prefix
     */
    private static void notifyParentOrchestrator(
        Id parentExecutionId,
        AgentExecution__c childExec,
        Map<Id, AgentExecution__c> parentExecutions,
        Map<Id, AIAgentDefinition__c> agentDefinitionsById,
        Map<Id, ExecutionStep__c> latestStepByExecution,
        Map<Id, IDecisionStepLogger.LoggedErrorInfo> latestDecisionErrorByExecution,
        String logPrefix
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Notifying parent ' + parentExecutionId + ' of child completion: ' + childExec.Id);

        AgentExecution__c parentExec = parentExecutions.get(parentExecutionId);
        if (parentExec == null) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Parent execution not found: ' + parentExecutionId);
            return;
        }

        String response = '';
        String errorMessage = null;
        String errorCode = null;
        Boolean success = (childExec.ExecutionStatus__c == 'Completed');

        ExecutionStep__c lastStep = latestStepByExecution.get(childExec.Id);
        if (lastStep != null) {
            if (lastStep.StepType__c == 'AgentResponse') {
                response = lastStep.Content__c != null ? lastStep.Content__c : '';
            } else if (lastStep.StepType__c == 'Error') {
                errorMessage = lastStep.Content__c;
                errorCode = 'EXECUTION_ERROR';
                success = false;
            }
        }

        if (errorMessage == null && !success) {
            IDecisionStepLogger.LoggedErrorInfo errorStep = latestDecisionErrorByExecution.get(childExec.Id);
            if (errorStep != null) {
                errorMessage = errorStep.errorMessage != null ? errorStep.errorMessage : errorStep.description;
                errorCode = errorStep.errorCode != null ? errorStep.errorCode : 'EXECUTION_ERROR';
                System.debug(LoggingLevel.INFO, logPrefix + 'Retrieved error from decision logger lookup: ' + errorMessage);
            }
        }

        if (errorMessage == null && !success && String.isNotBlank(childExec.ErrorMessage__c)) {
            errorMessage = childExec.ErrorMessage__c;

            if (errorMessage.startsWith('[') && errorMessage.contains(']')) {
                Integer codeEndIndex = errorMessage.indexOf(']');
                if (codeEndIndex > 1) {
                    errorCode = errorMessage.substring(1, codeEndIndex);
                    if (errorMessage.length() > codeEndIndex + 1) {
                        String messageAfterCode = errorMessage.substring(codeEndIndex + 1).trim();
                        if (messageAfterCode.contains(': ')) {
                            Integer colonIndex = messageAfterCode.indexOf(': ');
                            errorMessage = messageAfterCode.substring(colonIndex + 2);
                        } else {
                            errorMessage = messageAfterCode;
                        }
                    }
                }
            }

            if (String.isBlank(errorCode)) {
                errorCode = 'EXECUTION_ERROR';
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Retrieved error from execution ErrorMessage__c: Code=' + errorCode + ', Message=' + errorMessage);
        }

        // Extract original userMessage from parent execution TriggerPayload (used by pipeline context)
        String userMessage = null;
        if (String.isNotBlank(parentExec.TriggerPayload__c)) {
            try {
                Map<String, Object> triggerData = (Map<String, Object>) JSON.deserializeUntyped(parentExec.TriggerPayload__c);
                if (triggerData.containsKey('userMessage')) {
                    userMessage = (String) triggerData.get('userMessage');
                }
            } catch (Exception e) {
                // TriggerPayload may not be JSON — safe to ignore
            }
        }

        List<Map<String, Object>> propagatedContextPayload = new ContextManagerService().getPropagatableContextPayload(childExec.Id);

        Map<String, Object> callbackPayload = new Map<String, Object>{
            'completedAgent' => childExec.AIAgentDefinition__r.DeveloperName__c,
            'childExecutionId' => childExec.Id,
            'success' => success,
            'response' => response,
            'errorCode' => errorCode,
            'errorMessage' => errorMessage,
            'userMessage' => userMessage,
            'contextEffects' => propagatedContextPayload
        };

        // Route pipeline parents through the explicit composition subsystem.
        if (PipelineCompositionService.isPipelineExecution(parentExec)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Parent is a pipeline execution — routing to PipelineCompositionService');
            PipelineCompositionService.onChildComplete(parentExecutionId, callbackPayload);
            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully notified PipelineCompositionService');
            return;
        }

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'Callback payload: CompletedAgent=' +
                childExec.AIAgentDefinition__r.DeveloperName__c +
                ', Success=' +
                success +
                ', ParentAgentType=' +
                parentExec.AIAgentDefinition__r.RuntimeStrategy__c
        );

        AIAgentDefinition__c parentAgentDef = agentDefinitionsById.get(parentExec.AIAgentDefinition__c);
        if (parentAgentDef == null) {
            parentAgentDef = AIAgentConfigService.getAgentDefinition(parentExec.AIAgentDefinition__c);
        }

        if (parentAgentDef == null) {
            throw new AgentExecutionTriggerException('Parent agent definition not found: ' + parentExec.AIAgentDefinition__c);
        }

        IExecutionStrategy strategy = ExecutionStrategyRegistryService.resolveStrategy(
            parentAgentDef,
            RuntimeRegistryService.getInteractionChannel(parentAgentDef, parentExecutionId)
        );
        strategy.onChildComplete(parentExecutionId, callbackPayload, parentAgentDef);

        System.debug(LoggingLevel.INFO, logPrefix + 'Successfully notified parent orchestrator (type: ' + parentAgentDef.RuntimeStrategy__c + ')');
    }

    /**
     * @description Exception thrown by trigger handler
     */
    public class AgentExecutionTriggerException extends Exception {
    }
}
