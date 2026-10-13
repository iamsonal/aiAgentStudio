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
 * Bounded, idempotent minimization of retained payloads for terminal runs and
 * paused runs whose operator-rescue retention window has elapsed: command,
 * invocation, and event payloads, token originals, run input, output, error,
 * cancellation, and waiting text, and approval reasons and comments.
 * Hashes, event ordering, lifecycle metadata, decisions, and telemetry remain intact.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class PayloadRetentionPurgeService {
    private static final Integer DEFAULT_RETENTION_DAYS = 30;
    private static final Integer MAX_CHILD_ROWS_PER_TYPE = 2000;
    private static final Integer MAX_ERASURE_SUBJECTS = 200;
    /** Runs deleted per pass; their commands, events, and tokens are removed with them. */
    public static final Integer MAX_RUNS_DELETED_PER_PASS = 50;
    private static Boolean eventPurgeInProgress = false;
    private static Boolean recordDeletionInProgress = false;
    @TestVisible
    private static Integer childRowLimitOverride;

    public class PurgeResult {
        public Integer runsPurged = 0;
        public Integer commandsPurged = 0;
        public Integer eventsPurged = 0;
        public Integer invocationsPurged = 0;
        public Integer approvalsPurged = 0;
        public Integer candidatesDeferred = 0;
        public Boolean hasMore = false;
    }

    public class DeletionResult {
        public Integer runsDeleted = 0;
        public Integer runsBlocked = 0;
        public Boolean hasMore = false;
    }

    public class ErasureResult {
        public Integer runsScheduled = 0;
        public Integer activeRunsDeferred = 0;
        public Boolean hasMore = false;
    }

    /**
     * Brings the payload purge and record deletion deadlines of every run
     * anchored to, or started by, the given data subjects forward to now. The
     * next retention pass (or PayloadRetentionPurgeScheduler.runNow()) then
     * completes the erasure. Paused runs lose their payloads but keep their
     * lifecycle record; running and waiting runs are only counted, so an
     * operator cancels them first and calls this again.
     */
    public static ErasureResult scheduleErasure(Set<Id> subjectIds) {
        assertAuthorized();
        ErasureResult result = new ErasureResult();
        Set<Id> subjects = subjectIds == null ? new Set<Id>() : subjectIds.clone();
        subjects.remove(null);
        if (subjects.isEmpty()) {
            return result;
        }
        if (subjects.size() > MAX_ERASURE_SUBJECTS) {
            throw new AgentKernelException.ConfigurationException('Request erasure for at most ' + MAX_ERASURE_SUBJECTS + ' data subjects at a time.');
        }
        Set<String> anchors = new Set<String>();
        for (Id subjectId : subjects) {
            anchors.add(String.valueOf(subjectId));
        }
        Datetime nowValue = System.now();
        List<AgentRun__c> due = [
            SELECT Id, Status__c
            FROM AgentRun__c
            WHERE
                (AnchorRecordId__c IN :anchors
                OR InitiatingUser__c IN :subjects)
                AND ((Status__c IN ('Succeeded', 'Failed', 'Cancelled')
                AND (PurgeAfter__c = NULL
                OR PurgeAfter__c > :nowValue
                OR DeleteAfter__c = NULL
                OR DeleteAfter__c > :nowValue))
                OR (Status__c = 'Paused'
                AND (PurgeAfter__c = NULL
                OR PurgeAfter__c > :nowValue)))
            WITH SYSTEM_MODE
            LIMIT :MAX_CHILD_ROWS_PER_TYPE
            FOR UPDATE
        ];
        List<AgentRun__c> updates = new List<AgentRun__c>();
        for (AgentRun__c run : due) {
            AgentRun__c scheduled = new AgentRun__c(Id = run.Id, PurgeAfter__c = nowValue);
            if (run.Status__c != 'Paused') {
                scheduled.DeleteAfter__c = nowValue;
            }
            updates.add(scheduled);
        }
        if (!updates.isEmpty()) {
            AgentLifecycleStore.updateRuns(updates);
        }
        result.runsScheduled = updates.size();
        result.hasMore = due.size() == MAX_CHILD_ROWS_PER_TYPE;
        result.activeRunsDeferred = [
            SELECT COUNT()
            FROM AgentRun__c
            WHERE (AnchorRecordId__c IN :anchors OR InitiatingUser__c IN :subjects) AND Status__c IN ('Running', 'Waiting')
            WITH SYSTEM_MODE
        ];
        AgentOperationsLog.emit(LoggingLevel.INFO, 'DATA_SUBJECT_ERASURE_SCHEDULED', null, null, result.runsScheduled, null);
        return result;
    }

    /**
     * Permanently deletes payload-purged terminal runs older than the typed
     * record retention window. The whole batch is deleted together; when any
     * run is blocked (another package still references it), the batch is
     * undone and each run is deleted on its own, so a run, its approvals, and
     * its evidence always go together and the blocked run is counted.
     */
    public static DeletionResult deleteExpiredRecords(Integer requestedLimit) {
        assertAuthorized();
        DeletionResult result = new DeletionResult();
        Integer safeLimit = Math.max(1, Math.min(MAX_RUNS_DELETED_PER_PASS, requestedLimit == null ? MAX_RUNS_DELETED_PER_PASS : requestedLimit));
        Datetime nowValue = System.now();
        List<AgentRun__c> candidates = [
            SELECT Id
            FROM AgentRun__c
            WHERE Status__c IN ('Succeeded', 'Failed', 'Cancelled') AND PayloadPurgedAt__c != NULL AND DeleteAfter__c <= :nowValue
            WITH SYSTEM_MODE
            ORDER BY DeleteAfter__c ASC, Id ASC
            LIMIT :safeLimit
        ];
        if (candidates.isEmpty()) {
            return result;
        }
        Set<Id> candidateIds = new Map<Id, AgentRun__c>(candidates).keySet();
        List<AgentRun__c> runs = [
            SELECT Id
            FROM AgentRun__c
            WHERE Id IN :candidateIds AND Status__c IN ('Succeeded', 'Failed', 'Cancelled') AND PayloadPurgedAt__c != NULL AND DeleteAfter__c <= :nowValue
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        Set<Id> runIds = new Map<Id, AgentRun__c>(runs).keySet();
        Map<Id, List<AgentInvocation__c>> invocationsByRun = new Map<Id, List<AgentInvocation__c>>();
        for (AgentInvocation__c invocation : [
            SELECT Id, AgentRun__c
            FROM AgentInvocation__c
            WHERE AgentRun__c IN :runIds
            WITH SYSTEM_MODE
            LIMIT :MAX_CHILD_ROWS_PER_TYPE
        ]) {
            if (!invocationsByRun.containsKey(invocation.AgentRun__c)) {
                invocationsByRun.put(invocation.AgentRun__c, new List<AgentInvocation__c>());
            }
            invocationsByRun.get(invocation.AgentRun__c).add(invocation);
        }
        Map<Id, List<AgentApproval__c>> approvalsByRun = new Map<Id, List<AgentApproval__c>>();
        for (AgentApproval__c approval : [
            SELECT Id, AgentRun__c
            FROM AgentApproval__c
            WHERE AgentRun__c IN :runIds
            WITH SYSTEM_MODE
            LIMIT :MAX_CHILD_ROWS_PER_TYPE
        ]) {
            if (!approvalsByRun.containsKey(approval.AgentRun__c)) {
                approvalsByRun.put(approval.AgentRun__c, new List<AgentApproval__c>());
            }
            approvalsByRun.get(approval.AgentRun__c).add(approval);
        }
        recordDeletionInProgress = true;
        try {
            Savepoint beforeBatch = Database.setSavepoint();
            Boolean batchDeleted = false;
            try {
                List<AgentApproval__c> allApprovals = new List<AgentApproval__c>();
                for (List<AgentApproval__c> approvals : approvalsByRun.values()) {
                    allApprovals.addAll(approvals);
                }
                List<AgentInvocation__c> allInvocations = new List<AgentInvocation__c>();
                for (List<AgentInvocation__c> invocations : invocationsByRun.values()) {
                    allInvocations.addAll(invocations);
                }
                AgentApprovalService.deleteForRetention(allApprovals);
                if (!allInvocations.isEmpty()) {
                    Database.delete(allInvocations, AccessLevel.SYSTEM_MODE);
                }
                if (!runs.isEmpty()) {
                    Database.delete(runs, AccessLevel.SYSTEM_MODE);
                }
                result.runsDeleted = runs.size();
                batchDeleted = true;
            } catch (DmlException blockedRun) {
                Database.rollback(beforeBatch);
            }
            Database.releaseSavepoint(beforeBatch);
            for (AgentRun__c run : batchDeleted ? new List<AgentRun__c>() : runs) {
                Savepoint beforeRun = Database.setSavepoint();
                List<AgentInvocation__c> invocations = invocationsByRun.get(run.Id);
                try {
                    AgentApprovalService.deleteForRetention(approvalsByRun.get(run.Id));
                    if (invocations != null) {
                        Database.delete(invocations, AccessLevel.SYSTEM_MODE);
                    }
                    Database.delete(run, AccessLevel.SYSTEM_MODE);
                    result.runsDeleted++;
                } catch (DmlException blocked) {
                    Database.rollback(beforeRun);
                    result.runsBlocked++;
                }
                Database.releaseSavepoint(beforeRun);
            }
        } finally {
            recordDeletionInProgress = false;
        }
        result.hasMore = candidates.size() == safeLimit && result.runsDeleted > 0;
        AgentOperationsLog.emit(LoggingLevel.INFO, 'RECORD_RETENTION_PASS', null, null, result.runsDeleted, null);
        return result;
    }

    public static Boolean isRecordDeletionAuthorized() {
        return recordDeletionInProgress && isAuthorized();
    }

    public static PurgeResult purge(Integer requestedLimit) {
        assertAuthorized();
        Integer safeLimit = Math.max(1, Math.min(100, requestedLimit == null ? 25 : requestedLimit));
        Datetime nowValue = System.now();
        List<AgentRun__c> candidates = [
            SELECT Id
            FROM AgentRun__c
            WHERE
                Status__c IN ('Succeeded', 'Failed', 'Cancelled', 'Paused')
                AND (CompletedAt__c != NULL
                OR Status__c = 'Paused')
                AND PayloadPurgedAt__c = NULL
                AND PurgeAfter__c <= :nowValue
            WITH SYSTEM_MODE
            ORDER BY PurgeAfter__c ASC, Id ASC
            LIMIT :safeLimit
        ];
        PurgeResult result = new PurgeResult();
        if (candidates.isEmpty()) {
            return result;
        }
        Set<Id> dueRunIds = new Map<Id, AgentRun__c>(candidates).keySet();
        List<AgentRun__c> dueRuns = [
            SELECT Id
            FROM AgentRun__c
            WHERE Id IN :dueRunIds AND Status__c IN ('Succeeded', 'Failed', 'Cancelled', 'Paused') AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (dueRuns.isEmpty()) {
            return result;
        }

        Set<Id> runIds = new Map<Id, AgentRun__c>(dueRuns).keySet();
        Integer childLimit = childRowLimitOverride == null ? MAX_CHILD_ROWS_PER_TYPE : Math.max(1, Math.min(MAX_CHILD_ROWS_PER_TYPE, childRowLimitOverride));
        TrustService.purgeBounded(runIds, childLimit);
        List<AgentCommand__c> commands = [
            SELECT Id
            FROM AgentCommand__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            LIMIT :childLimit
            FOR UPDATE
        ];
        List<AgentCommand__c> commandsToPurge = new List<AgentCommand__c>();
        for (AgentCommand__c command : commands) {
            commandsToPurge.add(
                new AgentCommand__c(
                    Id = command.Id,
                    Input__c = null,
                    Output__c = null,
                    ErrorMessage__c = null,
                    Rationale__c = null,
                    ProviderRequestId__c = null,
                    PayloadPurgedAt__c = nowValue
                )
            );
        }
        if (!commandsToPurge.isEmpty()) {
            AgentLifecycleStore.updateCommands(commandsToPurge);
        }

        List<AgentInvocation__c> invocations = [
            SELECT Id
            FROM AgentInvocation__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            LIMIT :childLimit
            FOR UPDATE
        ];
        List<AgentInvocation__c> invocationsToPurge = new List<AgentInvocation__c>();
        for (AgentInvocation__c invocation : invocations) {
            invocationsToPurge.add(
                new AgentInvocation__c(
                    Id = invocation.Id,
                    Request__c = null,
                    Response__c = null,
                    NativeEvidence__c = null,
                    ErrorMessage__c = null,
                    ExternalReference__c = null,
                    PayloadPurgedAt__c = nowValue
                )
            );
        }
        if (!invocationsToPurge.isEmpty()) {
            eventPurgeInProgress = true;
            try {
                AgentLifecycleStore.updateInvocations(invocationsToPurge);
            } finally {
                eventPurgeInProgress = false;
            }
        }

        List<AgentEvent__c> events = [
            SELECT Id
            FROM AgentEvent__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            LIMIT :childLimit
            FOR UPDATE
        ];
        List<AgentEvent__c> eventsToPurge = new List<AgentEvent__c>();
        for (AgentEvent__c eventRecord : events) {
            eventsToPurge.add(
                new AgentEvent__c(
                    Id = eventRecord.Id,
                    Summary__c = 'Event details purged by retention policy.',
                    Payload__c = null,
                    PayloadPurgedAt__c = nowValue
                )
            );
        }
        if (!eventsToPurge.isEmpty()) {
            eventPurgeInProgress = true;
            try {
                AgentLifecycleStore.updateEvents(eventsToPurge);
            } finally {
                eventPurgeInProgress = false;
            }
        }

        List<AgentApproval__c> approvals = [
            SELECT Id
            FROM AgentApproval__c
            WHERE AgentRun__c IN :runIds AND Reason__c != NULL
            WITH SYSTEM_MODE
            LIMIT :childLimit
            FOR UPDATE
        ];
        AgentApprovalService.purgeForRetention(approvals);

        Set<Id> incompleteRunIds = incompleteRuns(runIds);
        List<AgentRun__c> completedRuns = new List<AgentRun__c>();
        for (AgentRun__c run : dueRuns) {
            if (incompleteRunIds.contains(run.Id)) {
                continue;
            }
            completedRuns.add(
                new AgentRun__c(
                    Id = run.Id,
                    Input__c = null,
                    Output__c = null,
                    ErrorMessage__c = null,
                    CancellationReason__c = null,
                    WaitingReason__c = null,
                    PayloadPurgedAt__c = nowValue
                )
            );
        }
        if (!completedRuns.isEmpty()) {
            AgentLifecycleStore.updateRuns(completedRuns);
        }
        result.runsPurged = completedRuns.size();
        result.commandsPurged = commands.size();
        result.eventsPurged = eventsToPurge.size();
        result.invocationsPurged = invocationsToPurge.size();
        result.approvalsPurged = approvals.size();
        result.candidatesDeferred = Math.max(0, candidates.size() - completedRuns.size());
        result.hasMore = !incompleteRunIds.isEmpty() || candidates.size() == safeLimit;
        return result;
    }

    public static Datetime purgeAfter(Datetime completedAt, Decimal retentionDays) {
        if (completedAt == null) {
            return null;
        }
        Integer days = retentionDays == null ? DEFAULT_RETENTION_DAYS : Math.max(0, Integer.valueOf(retentionDays));
        return completedAt.addDays(days);
    }

    public static Datetime deleteAfter(Datetime completedAt, Decimal retentionDays) {
        if (completedAt == null || retentionDays == null) {
            return null;
        }
        return completedAt.addDays(Math.max(0, Integer.valueOf(retentionDays)));
    }

    private static Set<Id> incompleteRuns(Set<Id> runIds) {
        Set<Id> result = new Set<Id>();
        for (AggregateResult row : [
            SELECT AgentRun__c runId, COUNT(Id) remaining
            FROM AgentCommand__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            GROUP BY AgentRun__c
        ]) {
            result.add((Id) row.get('runId'));
        }
        for (AggregateResult row : [
            SELECT AgentRun__c runId, COUNT(Id) remaining
            FROM AgentInvocation__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            GROUP BY AgentRun__c
        ]) {
            result.add((Id) row.get('runId'));
        }
        for (AggregateResult row : [
            SELECT AgentRun__c runId, COUNT(Id) remaining
            FROM AgentEvent__c
            WHERE AgentRun__c IN :runIds AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            GROUP BY AgentRun__c
        ]) {
            result.add((Id) row.get('runId'));
        }
        for (AggregateResult row : [
            SELECT AgentRun__c runId, COUNT(Id) remaining
            FROM AgentApproval__c
            WHERE AgentRun__c IN :runIds AND Reason__c != NULL
            WITH SYSTEM_MODE
            GROUP BY AgentRun__c
        ]) {
            result.add((Id) row.get('runId'));
        }
        for (AggregateResult row : [
            SELECT AgentRun__c runId, COUNT(Id) remaining
            FROM AgentTrustToken__c
            WHERE AgentRun__c IN :runIds AND PurgedAt__c = NULL
            WITH SYSTEM_MODE
            GROUP BY AgentRun__c
        ]) {
            result.add((Id) row.get('runId'));
        }
        return result;
    }

    public static Boolean isEventPurgeAuthorized() {
        return eventPurgeInProgress && isAuthorized();
    }

    public static Boolean isInvocationPurgeAuthorized() {
        return eventPurgeInProgress && isAuthorized();
    }

    public static Boolean isTrustPurgeAuthorized() {
        return isAuthorized();
    }

    private static void assertAuthorized() {
        if (!isAuthorized()) {
            throw new AgentKernelException.ConfigurationException('Payload retention purge permission is required.');
        }
    }

    private static Boolean isAuthorized() {
        return FeatureManagement.checkPermission('AgentKernelRetentionPurge');
    }
}
