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
 * Flow action: Start Agent Run. Bulk-safe for record-triggered and scheduled
 * flows. Runs are persisted one at a time so one request's failure never
 * fails the others, then dispatched together. Starts of agents with an identity
 * beyond this transaction's limits continue in a chained Queueable as the
 * same user; Initiating User starts must fit in the invoking transaction.
 */
global with sharing class AgentStartRunAction {
    /** Starts stop while this share of the query, DML, or CPU limit remains. */
    private static final Decimal START_HEADROOM = 0.35;
    /** Queries kept for dispatch and the continuation after starts are deferred. */
    private static final Integer DEFERRAL_QUERY_RESERVE = 10;
    /** A failed background continuation is retried this many times in all before its starts are reported lost. */
    @TestVisible
    private static final Integer MAX_CONTINUATION_ATTEMPTS = 3;
    private static final Integer MAX_LOST_START_SIGNALS = 200;

    global class StartRequest {
        @InvocableVariable(label='Agent Developer Name' description='Developer name of an active agent shared with the running user.' required=true)
        global String agentDeveloperName;

        @InvocableVariable(label='Input' description='What the agent should do, as text or JSON.')
        global String input;

        @InvocableVariable(label='Anchor Record ID' description='The record the run is about. Both the running user and the agent must be able to read it.')
        global Id anchorRecordId;

        @InvocableVariable(
            label='Parent Run ID'
            description='Optional run this one continues, such as the previous step of a chain. When the parent is limited to a person, this run keeps the same limit.'
        )
        global Id parentRunId;

        @InvocableVariable(
            label='Correlation Key'
            description='Recommended in record-triggered flows. Repeating a start with the same key returns the existing run instead of starting another, so a flow that fires twice starts one run. Example: the record Id plus a step name.'
        )
        global String correlationKey;
    }

    global class StartResult {
        @InvocableVariable(label='Run ID')
        global Id runId;

        @InvocableVariable(label='Started' description='True when the run exists now.')
        global Boolean started;

        @InvocableVariable(label='Queued' description='True when the start continues shortly in the background because this transaction reached its limits.')
        global Boolean queued;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Start Agent Run' description='Starts one agent run per request. Returns an error per request instead of failing the flow.')
    global static List<StartResult> start(List<StartRequest> requests) {
        List<StartResult> results = new List<StartResult>();
        List<AgentKernelModels.StartRequest> deferred = new List<AgentKernelModels.StartRequest>();
        List<Id> commandIds = new List<Id>();
        Map<String, String> deferralErrors = new Map<String, String>();
        for (StartRequest request : requests == null ? new List<StartRequest>() : requests) {
            StartResult result = new StartResult();
            result.started = false;
            result.queued = false;
            results.add(result);
            AgentKernelModels.StartRequest coreRequest = toCoreRequest(request);
            if (deferred.isEmpty() && hasStartHeadroom()) {
                startOne(coreRequest, result, commandIds);
                continue;
            }
            String deferralError = deferralError(coreRequest, deferralErrors);
            if (deferralError != null) {
                result.errorMessage = deferralError;
                continue;
            }
            deferred.add(coreRequest);
            result.queued = true;
        }
        dispatch(commandIds);
        if (!deferred.isEmpty()) {
            if (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
                System.enqueueJob(new StartContinuation(deferred, AttendedAccessService.attendedRequester()));
            } else {
                for (StartResult result : results) {
                    if (result.queued) {
                        result.queued = false;
                        result.errorMessage = 'This transaction cannot queue more agent starts. Start fewer runs at once.';
                    }
                }
            }
        }
        return results;
    }

    /** Continues Starts of agents with an identity that did not fit in the invoking transaction, as the same user. */
    public class StartContinuation implements Queueable {
        private final List<AgentKernelModels.StartRequest> pending;
        /** The person whose own request deferred these starts; they stay attended in the background. */
        private final Id requesterId;
        private final Integer attempt;

        public StartContinuation(List<AgentKernelModels.StartRequest> pending, Id requesterId) {
            this(pending, requesterId, 0);
        }

        public StartContinuation(List<AgentKernelModels.StartRequest> pending, Id requesterId, Integer attempt) {
            this.pending = pending;
            this.requesterId = requesterId;
            this.attempt = attempt == null ? 0 : attempt;
        }

        public void execute(QueueableContext context) {
            AttendedAccessService.continueFor(requesterId);
            // Attached first, so a failure anywhere below still has a handler.
            StartFinalizer finalizer = new StartFinalizer(pending, requesterId, attempt);
            if (context != null) {
                System.attachFinalizer(finalizer);
            }
            List<Id> commandIds = new List<Id>();
            for (AgentKernelModels.StartRequest request : pending) {
                if (!finalizer.remaining.isEmpty() || !hasStartHeadroom()) {
                    finalizer.remaining.add(request);
                    continue;
                }
                StartResult outcome = new StartResult();
                startOne(request, outcome, commandIds);
                if (outcome.errorMessage != null) {
                    AgentOperationsLog.signal('FLOW_START_FAILED', null, null, outcome.errorMessage.left(255));
                }
            }
            dispatch(commandIds);
        }
    }

    /**
     * A Queueable may enqueue one job, which dispatch uses; the next batch is
     * chained from this Finalizer. When the continuation fails, nothing it
     * started committed, so its whole batch is retried; after the last
     * attempt the loss is signalled instead of silent.
     */
    public class StartFinalizer implements Finalizer {
        private final List<AgentKernelModels.StartRequest> pending;
        private final Id requesterId;
        private final Integer attempt;
        @TestVisible
        private List<AgentKernelModels.StartRequest> remaining = new List<AgentKernelModels.StartRequest>();

        public StartFinalizer(List<AgentKernelModels.StartRequest> pending, Id requesterId, Integer attempt) {
            this.pending = pending;
            this.requesterId = requesterId;
            this.attempt = attempt;
        }

        public void execute(FinalizerContext context) {
            if (context.getResult() == ParentJobResult.SUCCESS) {
                if (!remaining.isEmpty() && !Test.isRunningTest()) {
                    System.enqueueJob(new StartContinuation(remaining, requesterId, 0));
                }
                return;
            }
            if (attempt + 1 < MAX_CONTINUATION_ATTEMPTS) {
                // Tests cannot chain a job from a finalizer; they cover the retry decision and the final signal.
                if (!Test.isRunningTest()) {
                    System.enqueueJob(new StartContinuation(pending, requesterId, attempt + 1));
                }
                return;
            }
            AgentOperationsLog.publish(lostStartSignals(pending));
        }
    }

    /** One signal per lost start, naming its agent and anchor, so an admin knows which records to start again. */
    @TestVisible
    private static List<AgentOperationalSignal__e> lostStartSignals(List<AgentKernelModels.StartRequest> lost) {
        List<AgentOperationalSignal__e> signals = new List<AgentOperationalSignal__e>();
        for (AgentKernelModels.StartRequest request : lost) {
            if (signals.size() == MAX_LOST_START_SIGNALS) {
                break;
            }
            signals.add(
                AgentOperationsLog.event(
                    'FLOW_START_LOST',
                    null,
                    null,
                    'Agent ' +
                        request.developerName +
                        '; anchor ' +
                        (request.anchorRecordId == null ? 'none' : String.valueOf(request.anchorRecordId)) +
                        (String.isBlank(request.externalCorrelationKey) ? '' : '; correlation key ' + request.externalCorrelationKey) +
                        '; ' +
                        lost.size() +
                        ' starts lost in this batch'
                )
            );
        }
        return signals;
    }

    private static void startOne(AgentKernelModels.StartRequest request, StartResult result, List<Id> commandIds) {
        Savepoint beforeStart = Database.setSavepoint();
        try {
            AgentKernelModels.StartResult started = AgentRunService.startWithoutDispatch(request, AgentKernelModels.INVOCATION_FLOW);
            result.runId = started.runId;
            result.started = true;
            if (started.deduplicated != true) {
                commandIds.add(started.commandId);
            }
        } catch (Exception failure) {
            Database.rollback(beforeStart);
            result.errorMessage = failure.getMessage();
        } finally {
            // Bulk starts would otherwise accumulate active savepoints in one transaction.
            Database.releaseSavepoint(beforeStart);
        }
    }

    /**
     * Runs without an identity execute in the starting user's own job chain, so
     * they cannot be handed to a background continuation. Each agent name is
     * looked up once, including names that are missing, and lookups stop while
     * the queries dispatch needs remain.
     */
    private static String deferralError(AgentKernelModels.StartRequest request, Map<String, String> deferralErrors) {
        String key = String.isBlank(request.developerName) ? '' : request.developerName.trim().toLowerCase();
        if (deferralErrors.containsKey(key)) {
            return deferralErrors.get(key);
        }
        if (Limits.getLimitQueries() - Limits.getQueries() <= DEFERRAL_QUERY_RESERVE) {
            return 'This transaction reached its limits before this start could be checked. Start fewer runs at once.';
        }
        String error;
        try {
            AgentDefinition__c definition = AgentConfigService.getActiveDefinition(request.developerName);
            if (!ExecutionIdentityService.usesIdentity(definition)) {
                error = 'Too many runs of an agent without an Agent Execution Identity for one transaction. Start fewer at once, or set an Agent Execution Identity on the agent for bulk work.';
            }
        } catch (Exception failure) {
            error = failure.getMessage();
        }
        deferralErrors.put(key, error);
        return error;
    }

    /** Batch dispatch groups runs with an identity by credential; anything it cannot enqueue is left for scheduled recovery. */
    private static void dispatch(List<Id> commandIds) {
        for (Integer offset = 0; offset < commandIds.size(); offset += CommandDispatcher.MAXIMUM_BATCH_SIZE) {
            List<Id> chunk = new List<Id>();
            for (Integer index = offset; index < Math.min(commandIds.size(), offset + CommandDispatcher.MAXIMUM_BATCH_SIZE); index++) {
                chunk.add(commandIds[index]);
            }
            CommandDispatcher.dispatchBatchDetailed(chunk);
        }
    }

    private static AgentKernelModels.StartRequest toCoreRequest(StartRequest request) {
        AgentKernelModels.StartRequest coreRequest = new AgentKernelModels.StartRequest();
        coreRequest.developerName = request == null ? null : request.agentDeveloperName;
        coreRequest.input = request == null ? null : request.input;
        coreRequest.anchorRecordId = request == null ? null : request.anchorRecordId;
        coreRequest.parentRunId = request == null ? null : request.parentRunId;
        coreRequest.externalCorrelationKey = request == null ? null : request.correlationKey;
        return coreRequest;
    }

    private static Boolean hasStartHeadroom() {
        return Limits.getQueries() < Limits.getLimitQueries() * (1 - START_HEADROOM) &&
            Limits.getDmlStatements() < Limits.getLimitDmlStatements() * (1 - START_HEADROOM) &&
            Limits.getCpuTime() < Limits.getLimitCpuTime() * (1 - START_HEADROOM);
    }
}
