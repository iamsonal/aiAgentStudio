/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Hides identity entry, durable leasing, worker enqueue, delayed dispatch, and
 * post-commit continuation behind one dispatch module. Durable command state,
 * not the asynchronous queue, remains the execution authority.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class CommandDispatcher {
    private static final Integer MAXIMUM_QUEUEABLE_STACK_DEPTH = AsyncJobCostService.MAXIMUM_INITIATING_USER_CHAIN_DEPTH;
    public static final Integer MAXIMUM_BATCH_SIZE = 25;
    public static final Integer MAXIMUM_QUEUEABLE_DELAY_MINUTES = 10;
    private static final Set<String> DISPATCHABLE_STATUSES = new Set<String>{
        AgentKernelModels.COMMAND_STATUS_PENDING,
        AgentKernelModels.COMMAND_STATUS_RETRY_WAITING
    };
    @TestVisible
    private static Boolean capacityExhaustedForTest = false;

    public class BatchDispatchResult {
        public List<Id> jobIds = new List<Id>();
        public Set<Id> acceptedCommandIds = new Set<Id>();
        public Set<Id> skippedCommandIds = new Set<Id>();
        public Set<Id> deferredCommandIds = new Set<Id>();
        public Set<Id> identityDeferredCommandIds = new Set<Id>();
    }

    public static void assertCapacityForNewRun(AgentDefinition__c definition) {
        if (capacityExhaustedForTest || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            throw new AgentKernelException.QueueCapacityException(
                'No Queueable capacity remains in this transaction. Start fewer runs per transaction and retry the remainder.'
            );
        }
        if (System.isQueueable() && definition != null && !ExecutionIdentityService.usesIdentity(definition)) {
            assertInitiatingUserChainDepth(
                AsyncJobCostService.estimate(definition).requiredInitiatingUserStackDepth,
                System.AsyncInfo.getCurrentQueueableStackDepth(),
                System.AsyncInfo.getMaximumQueueableStackDepth()
            );
        }
    }

    @TestVisible
    private static void assertInitiatingUserChainDepth(Integer requiredDepth, Integer currentDepth, Integer maximumDepth) {
        Integer remainingDepth = Math.max(0, maximumDepth - currentDepth);
        if (requiredDepth > remainingDepth) {
            throw new AgentKernelException.QueueCapacityException(
                'A run of an agent without an Agent Execution Identity needs more Queueable chain depth than remains in this chain.'
            );
        }
    }

    public static Id dispatch(Id commandId) {
        return dispatchInternal(commandId, null);
    }

    public static Id dispatchAfter(Id commandId, Integer delayMinutes) {
        return dispatchInternal(commandId, Math.max(1, Math.min(MAXIMUM_QUEUEABLE_DELAY_MINUTES, delayMinutes)));
    }

    private static Id enqueueLease(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String dispatchToken,
        Integer delayMinutes,
        Boolean inheritedChain
    ) {
        AgentRun__c run = currentRun(runId, commandId, expectedRevision, operationKey, dispatchToken);
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        if (CommandDeliveryTracker.shouldSuppressEnqueue()) {
            return commandId;
        }
        AsyncOptions options = options('lease', commandId, expectedRevision, delayMinutes, inheritedChain);
        try {
            return System.enqueueJob(new CommandLeaseQueueable(runId, commandId, expectedRevision, operationKey, dispatchToken), options);
        } catch (DuplicateMessageException duplicateJob) {
            return null;
        }
    }

    /**
     * Used only after the same-org loopback has established its service
     * principal. Leasing and worker enqueue therefore share one REST
     * transaction, removing the intermediate lease Queueable.
     */
    public static Id leaseAndEnqueueWorker(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String dispatchToken) {
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(runId, commandId, expectedRevision, operationKey, dispatchToken);
        return dispatchLeaseResult(lease, false);
    }

    public static Id dispatchLeaseResult(CommandLeaseService.Result lease, Boolean inheritedChain) {
        if (lease == null) {
            return null;
        }
        if (lease.outcome == CommandLeaseService.Outcome.Deferred) {
            if (isParkable(lease)) {
                AgentOperationsLog.emit(
                    LoggingLevel.INFO,
                    'DISPATCH_PARKED',
                    lease.run.Id,
                    lease.command.Id,
                    lease.delayMinutes,
                    lease.command.OperationKey__c
                );
                return null;
            }
            return enqueueLease(
                lease.run.Id,
                lease.command.Id,
                lease.command.ExpectedRunRevision__c,
                lease.command.OperationKey__c,
                lease.command.DispatchToken__c,
                lease.delayMinutes,
                inheritedChain
            );
        }
        return lease.outcome == CommandLeaseService.Outcome.Leased ? enqueueWorker(lease.run, lease.command, inheritedChain) : null;
    }

    /**
     * A delegated-principal command whose delay exceeds one Queueable hop waits
     * on DispatchDueAt__c for scheduled recovery instead of burning a hop every
     * ten minutes. Runs without an identity keep hopping to stay in their starter's chain.
     */
    private static Boolean isParkable(CommandLeaseService.Result lease) {
        return lease.delayMinutes != null &&
            lease.delayMinutes > MAXIMUM_QUEUEABLE_DELAY_MINUTES &&
            lease.run != null &&
            ExecutionIdentityService.usesIdentity(lease.run);
    }

    /**
     * Finalizer seam for ordinary command-to-command continuation. The caller
     * is already the run's established business principal, so another identity
     * dispatch hop would add cost without changing authority.
     */
    public static Id continueAfterCommit(Id commandId) {
        if (commandId == null) {
            return null;
        }
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                Status__c,
                CommandType__c,
                WorkerJobId__c,
                AgentRun__r.InitiatingUser__c,
                AgentRun__r.ExecutionIdentity__c,
                AgentRun__r.LoopbackNamedCredential__c,
                AgentRun__r.ExpectedPrincipalUser__c,
                AgentRun__r.ResolvedPrincipalUser__c,
                AgentRun__r.ExecutionContextStatus__c,
                AgentRun__r.Status__c,
                AgentRun__r.Revision__c,
                AgentRun__r.CurrentCommand__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (commands.isEmpty()) {
            AgentOperationsLog.emit(LoggingLevel.WARN, 'CONTINUATION_COMMAND_MISSING', null, commandId, null, null);
            return null;
        }
        AgentCommand__c command = commands[0];
        AgentRun__c run = command.AgentRun__r;
        if (
            run == null ||
            run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
            run.CurrentCommand__c != command.Id ||
            run.Revision__c != command.ExpectedRunRevision__c ||
            String.isBlank(command.OperationKey__c)
        ) {
            AgentOperationsLog.emit(LoggingLevel.WARN, 'CONTINUATION_STALE_NOOP', command.AgentRun__c, commandId, null, command.OperationKey__c);
            return null;
        }
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(
            run.Id,
            command.Id,
            command.ExpectedRunRevision__c,
            command.OperationKey__c,
            command.DispatchToken__c
        );
        return dispatchLeaseResult(lease, true);
    }

    public static Id enqueueWorker(AgentRun__c run, AgentCommand__c command) {
        return enqueueWorker(run, command, false);
    }

    private static Id enqueueWorker(AgentRun__c run, AgentCommand__c command, Boolean inheritedChain) {
        Map<Id, Id> enqueuedJobs = new Map<Id, Id>();
        Id jobId = enqueueWorkerJob(run, command, inheritedChain, enqueuedJobs);
        CommandDeliveryTracker.recordJobs(enqueuedJobs);
        return jobId;
    }

    /** Enqueues the worker and adds a new job to enqueuedJobs, which the caller records; a batch records them in one update. */
    private static Id enqueueWorkerJob(AgentRun__c run, AgentCommand__c command, Boolean inheritedChain, Map<Id, Id> enqueuedJobs) {
        if (run == null || command == null || String.isBlank(command.LeaseToken__c)) {
            return null;
        }
        if (CommandDeliveryTracker.shouldSuppressEnqueue()) {
            return command.Id;
        }
        try {
            AsyncOptions options = options('worker', command.Id, command.ExpectedRunRevision__c, null, inheritedChain);
            Id jobId;
            if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
                jobId = System.enqueueJob(
                    new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c),
                    options
                );
            } else {
                jobId = System.enqueueJob(
                    new ModelCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c),
                    options
                );
            }
            enqueuedJobs.put(command.Id, jobId);
            return jobId;
        } catch (DuplicateMessageException duplicateJob) {
            return handleDuplicateWorkerEnqueue(command.Id);
        } catch (Exception enqueueFailure) {
            CommandDeliveryTracker.recordAnomaly(command.Id, 'ENQUEUE_FAILED');
            CommandLeaseService.releaseUndeliveredLease(command.Id, command.LeaseToken__c);
            AgentOperationsLog.emit(LoggingLevel.ERROR, 'WORKER_ENQUEUE_FAILED', run.Id, command.Id, null, command.OperationKey__c);
            return null;
        }
    }

    @TestVisible
    private static Id handleDuplicateWorkerEnqueue(Id commandId) {
        Id correlatedJobId = CommandDeliveryTracker.activeCorrelatedJob(commandId);
        if (correlatedJobId != null) {
            CommandDeliveryTracker.recordDuplicateSuppression(commandId, true);
            return correlatedJobId;
        }
        CommandDeliveryTracker.recordDuplicateSuppression(commandId, false);
        List<AgentCommand__c> commands = [
            SELECT LeaseToken__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!commands.isEmpty()) {
            CommandLeaseService.releaseUndeliveredLease(commandId, commands[0].LeaseToken__c);
        }
        return null;
    }

    public static BatchDispatchResult dispatchBatchDetailed(List<Id> requestedCommandIds) {
        BatchDispatchResult result = new BatchDispatchResult();
        if (requestedCommandIds == null || requestedCommandIds.isEmpty()) {
            return result;
        }
        Set<Id> commandIds = new Set<Id>();
        for (Id commandId : requestedCommandIds) {
            if (commandId == null || commandIds.contains(commandId) || result.deferredCommandIds.contains(commandId)) {
                continue;
            }
            if (commandIds.size() < MAXIMUM_BATCH_SIZE) {
                commandIds.add(commandId);
            } else {
                result.deferredCommandIds.add(commandId);
            }
        }
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                Status__c,
                CommandType__c,
                WorkerJobId__c,
                AgentRun__r.InitiatingUser__c,
                AgentRun__r.ExecutionIdentity__c,
                AgentRun__r.LoopbackNamedCredential__c,
                AgentRun__r.ExpectedPrincipalUser__c,
                AgentRun__r.ResolvedPrincipalUser__c,
                AgentRun__r.ExecutionContextStatus__c,
                AgentRun__r.Status__c,
                AgentRun__r.Revision__c,
                AgentRun__r.CurrentCommand__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            ORDER BY AvailableAt__c ASC, Id ASC
            LIMIT :MAXIMUM_BATCH_SIZE
        ];
        List<AgentCommand__c> directCommands = new List<AgentCommand__c>();
        Set<Id> identityAnomalies = new Set<Id>();
        Set<Id> capacityAnomalies = new Set<Id>();
        Set<Id> enqueueFailures = new Set<Id>();
        Map<String, List<InternalCommandBatchDispatchRest.CommandEnvelope>> envelopesByCredential = new Map<String, List<InternalCommandBatchDispatchRest.CommandEnvelope>>();
        for (AgentCommand__c command : commands) {
            AgentRun__c run = command.AgentRun__r;
            if (!DISPATCHABLE_STATUSES.contains(command.Status__c)) {
                result.skippedCommandIds.add(command.Id);
                continue;
            }
            try {
                validateCurrent(run, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c);
            } catch (AgentKernelException.ConcurrencyException staleCommand) {
                result.skippedCommandIds.add(command.Id);
                continue;
            }
            // A pass already running as the run's user leases directly; no loopback is needed.
            if (ExecutionIdentityService.runsAsCurrentUser(run)) {
                directCommands.add(command);
                continue;
            }
            if (!ExecutionIdentityService.usesIdentity(run)) {
                result.identityDeferredCommandIds.add(command.Id);
                identityAnomalies.add(command.Id);
                continue;
            }
            if (String.isBlank(run.LoopbackNamedCredential__c) || String.isBlank(command.DispatchToken__c)) {
                result.skippedCommandIds.add(command.Id);
                continue;
            }
            String namedCredential = run.LoopbackNamedCredential__c;
            if (!envelopesByCredential.containsKey(namedCredential)) {
                envelopesByCredential.put(namedCredential, new List<InternalCommandBatchDispatchRest.CommandEnvelope>());
            }
            InternalCommandBatchDispatchRest.CommandEnvelope envelope = new InternalCommandBatchDispatchRest.CommandEnvelope();
            envelope.runId = run.Id;
            envelope.commandId = command.Id;
            envelope.expectedRevision = command.ExpectedRunRevision__c;
            envelope.operationKey = command.OperationKey__c;
            envelope.dispatchToken = command.DispatchToken__c;
            envelopesByCredential.get(namedCredential).add(envelope);
        }

        dispatchCurrentUserCommands(directCommands, result, capacityAnomalies);

        List<String> credentialNames = new List<String>(envelopesByCredential.keySet());
        credentialNames.sort();
        for (String namedCredential : credentialNames) {
            List<InternalCommandBatchDispatchRest.CommandEnvelope> envelopes = envelopesByCredential.get(namedCredential);
            if (!hasQueueableSlot()) {
                for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
                    result.deferredCommandIds.add(envelope.commandId);
                    capacityAnomalies.add(envelope.commandId);
                }
                continue;
            }
            AsyncOptions options = batchOptions(envelopes);
            try {
                Id batchJobId = System.enqueueJob(new ServicePrincipalBatchDispatchQueueable(namedCredential, envelopes), options);
                result.jobIds.add(batchJobId);
                for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
                    result.acceptedCommandIds.add(envelope.commandId);
                }
            } catch (DuplicateMessageException duplicateJob) {
                for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
                    result.acceptedCommandIds.add(envelope.commandId);
                }
            } catch (Exception enqueueFailure) {
                for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
                    enqueueFailures.add(envelope.commandId);
                    result.deferredCommandIds.add(envelope.commandId);
                }
                AgentOperationsLog.emit(LoggingLevel.ERROR, 'BATCH_ENQUEUE_FAILED', null, null, envelopes.size(), null);
            }
        }
        CommandDeliveryTracker.recordAnomalies(identityAnomalies, 'IDENTITY_DEFERRED');
        CommandDeliveryTracker.recordAnomalies(capacityAnomalies, 'CAPACITY_DEFERRED');
        CommandDeliveryTracker.recordAnomalies(enqueueFailures, 'ENQUEUE_FAILED');
        return result;
    }

    /** An asynchronous transaction may enqueue only one job; deferred commands are redispatched by the next pass. */
    private static Boolean hasQueueableSlot() {
        return Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
    }

    /**
     * A pass already running as the run's user leases its commands in this
     * transaction, as a single dispatch does, so each reaches its worker in
     * one hop. Leases and job records are bulk, so the cost does not grow
     * with the batch. Commands beyond this transaction's Queueable capacity
     * stay unleased for the next pass.
     */
    private static void dispatchCurrentUserCommands(List<AgentCommand__c> commands, BatchDispatchResult result, Set<Id> capacityAnomalies) {
        Integer capacity = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
        List<CommandLeaseService.ServicePrincipalLeaseRequest> requests = new List<CommandLeaseService.ServicePrincipalLeaseRequest>();
        for (AgentCommand__c command : commands) {
            if (String.isBlank(command.DispatchToken__c)) {
                result.skippedCommandIds.add(command.Id);
            } else if (requests.size() < capacity) {
                CommandLeaseService.ServicePrincipalLeaseRequest request = new CommandLeaseService.ServicePrincipalLeaseRequest();
                request.runId = command.AgentRun__c;
                request.commandId = command.Id;
                request.expectedRevision = command.ExpectedRunRevision__c;
                request.operationKey = command.OperationKey__c;
                request.dispatchToken = command.DispatchToken__c;
                requests.add(request);
            } else {
                result.deferredCommandIds.add(command.Id);
                capacityAnomalies.add(command.Id);
            }
        }
        if (requests.isEmpty()) {
            return;
        }
        List<CommandLeaseService.Result> leases = CommandLeaseService.tryLeaseCurrentUserBatch(requests);
        Map<Id, Id> enqueuedJobs = new Map<Id, Id>();
        for (Integer index = 0; index < leases.size(); index++) {
            CommandLeaseService.Result lease = leases[index];
            Id commandId = requests[index].commandId;
            Id jobId;
            if (lease.outcome == CommandLeaseService.Outcome.Leased) {
                jobId = enqueueWorkerJob(lease.run, lease.command, false, enqueuedJobs);
            } else if (lease.outcome == CommandLeaseService.Outcome.Deferred) {
                jobId = dispatchLeaseResult(lease, false);
            } else {
                result.skippedCommandIds.add(commandId);
                continue;
            }
            if (jobId != null) {
                result.jobIds.add(jobId);
                result.acceptedCommandIds.add(commandId);
            } else {
                // Parked for scheduled recovery, or the worker enqueue failed and released its lease.
                result.deferredCommandIds.add(commandId);
            }
        }
        CommandDeliveryTracker.recordJobs(enqueuedJobs);
    }

    private static Id dispatchInternal(Id commandId, Integer delayMinutes) {
        if (commandId == null) {
            return null;
        }
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                CommandType__c,
                WorkerJobId__c,
                AgentRun__r.InitiatingUser__c,
                AgentRun__r.ExecutionIdentity__c,
                AgentRun__r.LoopbackNamedCredential__c,
                AgentRun__r.ExpectedPrincipalUser__c,
                AgentRun__r.ResolvedPrincipalUser__c,
                AgentRun__r.ExecutionContextStatus__c,
                AgentRun__r.Status__c,
                AgentRun__r.Revision__c,
                AgentRun__r.CurrentCommand__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (commands.isEmpty()) {
            return null;
        }
        AgentCommand__c command = commands[0];
        AgentRun__c run = command.AgentRun__r;
        validateCurrent(run, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c);
        ExecutionIdentityService.assertCurrentActor(run);
        if (ExecutionIdentityService.usesIdentity(run) && ExecutionIdentityService.runsAsCurrentUser(run)) {
            return leaseAndEnqueueWorker(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.DispatchToken__c);
        }
        if (ExecutionIdentityService.usesIdentity(run)) {
            AsyncOptions options = options('principal', command.Id, command.ExpectedRunRevision__c, delayMinutes, false);
            try {
                return System.enqueueJob(
                    new ServicePrincipalDispatchQueueable(
                        run.Id,
                        command.Id,
                        command.ExpectedRunRevision__c,
                        command.OperationKey__c,
                        command.DispatchToken__c,
                        run.LoopbackNamedCredential__c
                    ),
                    options
                );
            } catch (DuplicateMessageException duplicateJob) {
                return null;
            }
        }
        return leaseAndEnqueueWorker(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.DispatchToken__c);
    }

    private static AgentRun__c currentRun(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String dispatchToken) {
        List<AgentRun__c> runs = [
            SELECT
                Id,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Status__c,
                Revision__c,
                CurrentCommand__c,
                CurrentCommand__r.ExpectedRunRevision__c,
                CurrentCommand__r.OperationKey__c,
                CurrentCommand__r.DispatchToken__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found for dispatch.');
        }
        validateCurrent(runs[0], commandId, expectedRevision, operationKey);
        if (
            runs[0].CurrentCommand__r.ExpectedRunRevision__c != expectedRevision ||
            !operationKey.equals(runs[0].CurrentCommand__r.OperationKey__c) ||
            String.isBlank(dispatchToken) ||
            !dispatchToken.equals(runs[0].CurrentCommand__r.DispatchToken__c)
        ) {
            throw new AgentKernelException.ConcurrencyException('Dispatch command identity does not match current durable state.');
        }
        return runs[0];
    }

    private static void validateCurrent(AgentRun__c run, Id commandId, Decimal expectedRevision, String operationKey) {
        if (
            run == null ||
            run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
            run.CurrentCommand__c != commandId ||
            run.Revision__c != expectedRevision ||
            String.isBlank(operationKey)
        ) {
            throw new AgentKernelException.ConcurrencyException('Dispatch identity does not match current durable run state.');
        }
    }

    @TestVisible
    private static AsyncOptions options(String signatureType, Id commandId, Decimal expectedRevision, Integer delayMinutes, Boolean inheritedChain) {
        AsyncOptions options = new AsyncOptions();
        // Salesforce inherits the root Queueable's maximum stack depth and
        // rejects attempts to reset it from a child Queueable. Duplicate
        // signatures and delays remain per-enqueue options.
        if (!System.isQueueable() && inheritedChain != true) {
            options.MaximumQueueableStackDepth = MAXIMUM_QUEUEABLE_STACK_DEPTH;
        }
        if (delayMinutes != null) {
            options.MinimumQueueableDelayInMinutes = Math.max(1, Math.min(MAXIMUM_QUEUEABLE_DELAY_MINUTES, delayMinutes));
        }
        options.DuplicateSignature = expectedRevision == null
            ? QueueableDuplicateSignature.Builder().addString(signatureType).addId(commandId).build()
            : QueueableDuplicateSignature.Builder().addString(signatureType).addId(commandId).addString(String.valueOf(expectedRevision)).build();
        return options;
    }

    private static AsyncOptions batchOptions(List<InternalCommandBatchDispatchRest.CommandEnvelope> envelopes) {
        List<String> commandIdentities = new List<String>();
        for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
            commandIdentities.add(String.valueOf(envelope.commandId) + ':' + String.valueOf(envelope.expectedRevision));
        }
        commandIdentities.sort();
        AsyncOptions options = new AsyncOptions();
        if (!System.isQueueable()) {
            options.MaximumQueueableStackDepth = MAXIMUM_QUEUEABLE_STACK_DEPTH;
        }
        options.DuplicateSignature = QueueableDuplicateSignature.Builder()
            .addString(CanonicalJson.sha256(String.join(commandIdentities, ':')).substring(0, 32))
            .build();
        return options;
    }
}
