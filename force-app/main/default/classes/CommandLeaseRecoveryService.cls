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
 * Focused stale-lease recovery entry point. Model operations and tools without
 * external effects can be re-leased; tools with external effects are moved to Waiting by the
 * kernel for operator reconciliation.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class CommandLeaseRecoveryService {
    public static final Integer ORPHAN_GRACE_SECONDS = 120;
    /** Longer than one ten-minute Queueable delay hop plus queue latency. */
    public static final Integer INITIATING_USER_CHAIN_GRACE_MINUTES = 30;
    public static final Integer DEFAULT_MAXIMUM_DISPATCHES_PER_RUN = 25;
    public static final Integer PLATFORM_MAXIMUM_DISPATCHES_PER_RUN = CommandDispatcher.MAXIMUM_BATCH_SIZE;
    /** Expired waits are paused in bulk with constant queries, so they get their own budget. */
    public static final Integer MAXIMUM_EXPIRED_WAITS_PER_RUN = 25;
    /** Deny and Continue expiries run one at a time and create a model command to dispatch. */
    public static final Integer MAXIMUM_APPROVAL_DENIALS_PER_RUN = 5;
    /** A run or command whose recovery step failed is set aside this long so others progress. */
    public static final Integer QUARANTINE_MINUTES = 15;
    /** Redispatches of one queued command before its run pauses as undeliverable; each waits ten minutes longer. */
    public static final Integer MAXIMUM_REDISPATCHES = 3;
    private static final Integer REDISPATCH_BACKOFF_MINUTES = 10;
    /** Item-by-item fallback stops while this share of the query limit remains, deferring the rest. */
    private static final Decimal FALLBACK_QUERY_HEADROOM = 0.3;
    @TestVisible
    private static Integer dispatchLimitOverride;
    @TestVisible
    private static Set<Id> failingRunIdsForTest = new Set<Id>();

    public class RecoveryResult {
        public Integer requeued = 0;
        public Integer unknown = 0;
        public Integer cancelled = 0;
        public Integer paused = 0;
        public Integer expiredWaits = 0;
        public Integer orphanRedispatched = 0;
        public Integer skipped = 0;
        public Integer deferredByCapacity = 0;
        public Integer deferredByInitiatingUser = 0;
        public Integer lostInitiatingUserChains = 0;
        public Integer deferredByActiveWorker = 0;
        public Boolean continuationRequired = false;
        private Set<Id> capacityDeferredCommandIds = new Set<Id>();
    }

    public static RecoveryResult recoverOperational(Integer requestedLimit) {
        Integer safeLimit = Math.max(1, Math.min(configuredDispatchLimit(), requestedLimit == null ? 25 : requestedLimit));
        RecoveryResult result = new RecoveryResult();
        List<Id> dispatchIds = new List<Id>();
        Map<Id, Decimal> orphanIds = new Map<Id, Decimal>();
        expireIntentionalWaits(MAXIMUM_EXPIRED_WAITS_PER_RUN, result, dispatchIds);
        Integer remaining = Math.max(0, safeLimit - dispatchIds.size());
        Integer staleUsage = recoverStaleInto(remaining, result, dispatchIds);
        remaining = Math.max(0, remaining - staleUsage);
        remaining = Math.max(0, remaining - endLostInitiatingUserChains(remaining, result));
        redispatchOrphans(remaining, result, dispatchIds, orphanIds);
        dispatchRecovered(dispatchIds, orphanIds, result);
        CommandDeliveryTracker.recordAnomalies(result.capacityDeferredCommandIds, 'CAPACITY_DEFERRED');
        result.continuationRequired = result.continuationRequired || result.deferredByCapacity > 0;
        AgentOperationsLog.recoveryPass(
            result.requeued,
            result.expiredWaits,
            result.orphanRedispatched,
            result.deferredByCapacity,
            result.deferredByActiveWorker
        );
        return result;
    }

    /**
     * Recovers one command whose worker job failed after leasing it, without
     * waiting for lease expiry or the next scheduled pass. The lease token must
     * still match, so a newer attempt is never disturbed.
     */
    public static RecoveryResult recoverFailedWorker(Id commandId, String leaseToken) {
        RecoveryResult result = new RecoveryResult();
        if (commandId == null || String.isBlank(leaseToken)) {
            return result;
        }
        List<AgentCommand__c> commands = [
            SELECT Id, LeaseToken__c, LeaseExpiresAt__c
            FROM AgentCommand__c
            WHERE Id = :commandId AND Status__c = :AgentKernelModels.COMMAND_STATUS_LEASED
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (commands.isEmpty() || !leaseToken.equals(commands[0].LeaseToken__c)) {
            return result;
        }
        Datetime nowValue = System.now();
        if (commands[0].LeaseExpiresAt__c == null || commands[0].LeaseExpiresAt__c > nowValue) {
            AgentLifecycleStore.updateCommands(new List<AgentCommand__c>{ new AgentCommand__c(Id = commandId, LeaseExpiresAt__c = nowValue) });
        }
        AgentKernel.StaleLeaseRecoveryResult transition = AgentKernelRecovery.recoverStaleLeases(
            new List<Id>{ commandId },
            nowValue,
            new Map<Id, CommandDeliveryTracker.JobState>{ commandId => CommandDeliveryTracker.JobState.Inactive }
        );
        result.requeued = transition.requeuedCommandIds.size();
        result.unknown = transition.unknown;
        result.cancelled = transition.cancelled;
        result.paused = transition.paused;
        List<Id> dispatchIds = new List<Id>();
        for (Id requeuedId : transition.requeuedCommandIds) {
            queueForDispatch(requeuedId, dispatchIds, result);
        }
        dispatchRecovered(dispatchIds, new Map<Id, Decimal>(), result);
        return result;
    }

    private static Integer recoverStaleInto(Integer safeLimit, RecoveryResult result, List<Id> dispatchIds) {
        if (safeLimit <= 0) {
            return 0;
        }
        Datetime nowValue = System.now();
        Integer lookaheadLimit = safeLimit + 1;
        List<AgentCommand__c> staleCommands = [
            SELECT Id, AgentRun__c, WorkerJobId__c
            FROM AgentCommand__c
            WHERE Status__c = :AgentKernelModels.COMMAND_STATUS_LEASED AND RecoveryCheckAt__c != NULL AND RecoveryCheckAt__c <= :nowValue
            WITH SYSTEM_MODE
            ORDER BY RecoveryCheckAt__c ASC, Id ASC
            LIMIT :lookaheadLimit
        ];
        if (staleCommands.size() > safeLimit) {
            AgentCommand__c deferred = staleCommands.remove(safeLimit);
            result.deferredByCapacity++;
            result.capacityDeferredCommandIds.add(deferred.Id);
        }
        List<Id> staleCommandIds = new List<Id>();
        Map<Id, CommandDeliveryTracker.JobState> jobStates = CommandDeliveryTracker.resolveCommands(staleCommands);
        List<AgentCommand__c> activeDeferrals = new List<AgentCommand__c>();
        for (AgentCommand__c candidate : staleCommands) {
            if (jobStates.get(candidate.Id) == CommandDeliveryTracker.JobState.Active) {
                activeDeferrals.add(new AgentCommand__c(Id = candidate.Id, RecoveryCheckAt__c = nowValue.addMinutes(5)));
                result.deferredByActiveWorker++;
            } else {
                staleCommandIds.add(candidate.Id);
            }
        }
        if (!activeDeferrals.isEmpty()) {
            AgentLifecycleStore.updateCommands(activeDeferrals);
        }
        AgentKernel.StaleLeaseRecoveryResult transition = recoverStaleIsolated(staleCommandIds, nowValue, jobStates);
        result.requeued += transition.requeuedCommandIds.size();
        result.unknown += transition.unknown;
        result.cancelled += transition.cancelled;
        result.paused += transition.paused;
        result.skipped += transition.skipped;
        if (!transition.skippedCommandIds.isEmpty()) {
            List<AgentCommand__c> skippedDeferrals = new List<AgentCommand__c>();
            for (Id commandId : transition.skippedCommandIds) {
                skippedDeferrals.add(new AgentCommand__c(Id = commandId, RecoveryCheckAt__c = nowValue.addMinutes(5)));
            }
            AgentLifecycleStore.updateCommands(skippedDeferrals);
        }
        result.deferredByCapacity += transition.deferredCommandIds.size();
        result.capacityDeferredCommandIds.addAll(transition.deferredCommandIds);
        for (Id commandId : transition.requeuedCommandIds) {
            queueForDispatch(commandId, dispatchIds, result);
        }
        return staleCommands.size();
    }

    /**
     * Pauses expired waits in bulk. An expired approval whose tool says Deny
     * and Continue is denied one run at a time, at most
     * MAXIMUM_APPROVAL_DENIALS_PER_RUN per pass. A run whose expiry fails is
     * set aside instead of blocking the runs behind it.
     */
    private static void expireIntentionalWaits(Integer waitLimit, RecoveryResult result, List<Id> dispatchIds) {
        Datetime nowValue = System.now();
        Integer lookaheadLimit = waitLimit + 1;
        Map<Id, Decimal> waitRevisions = new Map<Id, Decimal>();
        for (AgentRun__c run : [
            SELECT Id, Revision__c
            FROM AgentRun__c
            WHERE
                Status__c = :AgentKernelModels.RUN_STATUS_WAITING
                AND WaitExpiresAt__c != NULL
                AND WaitExpiresAt__c <= :nowValue
                AND (RecoveryCheckAt__c = NULL
                OR RecoveryCheckAt__c <= :nowValue)
            WITH SYSTEM_MODE
            ORDER BY WaitExpiresAt__c ASC, Id ASC
            LIMIT :lookaheadLimit
        ]) {
            if (waitRevisions.size() == waitLimit) {
                result.continuationRequired = true;
                break;
            }
            waitRevisions.put(run.Id, run.Revision__c);
        }
        AgentKernel.IntentionalWaitExpiryResult transition = expireWaitsIsolated(waitRevisions, nowValue);
        result.expiredWaits += transition.expired;
        result.skipped += transition.skipped;
        Integer denials = 0;
        for (Id runId : transition.approvalDenials.keySet()) {
            if (denials == MAXIMUM_APPROVAL_DENIALS_PER_RUN || !hasQueryHeadroom()) {
                result.continuationRequired = true;
                break;
            }
            denials++;
            Savepoint beforeDenial = Database.setSavepoint();
            Exception failure;
            try {
                Id nextCommandId = AgentKernel.expireApprovalWithDenial(runId, transition.approvalDenials.get(runId));
                if (nextCommandId == null) {
                    result.skipped++;
                } else {
                    result.expiredWaits++;
                    queueForDispatch(nextCommandId, dispatchIds, result);
                }
            } catch (Exception caught) {
                failure = caught;
                Database.rollback(beforeDenial);
            } finally {
                Database.releaseSavepoint(beforeDenial);
            }
            if (failure != null) {
                quarantineRuns(new Set<Id>{ runId }, failure, result);
            }
        }
    }

    /** Bulk expiry first; when it fails, expire each run on its own and set failures aside. */
    private static AgentKernel.IntentionalWaitExpiryResult expireWaitsIsolated(Map<Id, Decimal> waitRevisions, Datetime nowValue) {
        if (waitRevisions.isEmpty()) {
            return new AgentKernel.IntentionalWaitExpiryResult();
        }
        Savepoint beforeBulk = Database.setSavepoint();
        try {
            failForTest(waitRevisions.keySet());
            return AgentKernelRecovery.expireIntentionalWaits(waitRevisions, nowValue);
        } catch (Exception bulkFailure) {
            Database.rollback(beforeBulk);
        } finally {
            Database.releaseSavepoint(beforeBulk);
        }
        AgentKernel.IntentionalWaitExpiryResult combined = new AgentKernel.IntentionalWaitExpiryResult();
        for (Id runId : waitRevisions.keySet()) {
            if (!hasQueryHeadroom()) {
                combined.skipped++;
                continue;
            }
            Savepoint beforeRun = Database.setSavepoint();
            Exception failure;
            try {
                failForTest(new Set<Id>{ runId });
                AgentKernel.IntentionalWaitExpiryResult single = AgentKernelRecovery.expireIntentionalWaits(
                    new Map<Id, Decimal>{ runId => waitRevisions.get(runId) },
                    nowValue
                );
                combined.expired += single.expired;
                combined.skipped += single.skipped;
                combined.approvalDenials.putAll(single.approvalDenials);
            } catch (Exception caught) {
                failure = caught;
                Database.rollback(beforeRun);
            } finally {
                Database.releaseSavepoint(beforeRun);
            }
            if (failure != null) {
                combined.skipped++;
                quarantineRuns(new Set<Id>{ runId }, failure, null);
            }
        }
        return combined;
    }

    /** Bulk stale-lease recovery first; when it fails, recover each command on its own and set failures aside. */
    private static AgentKernel.StaleLeaseRecoveryResult recoverStaleIsolated(
        List<Id> commandIds,
        Datetime nowValue,
        Map<Id, CommandDeliveryTracker.JobState> jobStates
    ) {
        if (commandIds.isEmpty()) {
            return new AgentKernel.StaleLeaseRecoveryResult();
        }
        Savepoint beforeBulk = Database.setSavepoint();
        try {
            return AgentKernelRecovery.recoverStaleLeases(commandIds, nowValue, jobStates);
        } catch (Exception bulkFailure) {
            Database.rollback(beforeBulk);
        } finally {
            Database.releaseSavepoint(beforeBulk);
        }
        AgentKernel.StaleLeaseRecoveryResult combined = new AgentKernel.StaleLeaseRecoveryResult();
        Set<Id> failedCommandIds = new Set<Id>();
        for (Id commandId : commandIds) {
            if (!hasQueryHeadroom()) {
                combined.deferredCommandIds.add(commandId);
                continue;
            }
            Savepoint beforeCommand = Database.setSavepoint();
            try {
                AgentKernel.StaleLeaseRecoveryResult single = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ commandId }, nowValue, jobStates);
                combined.requeuedCommandIds.addAll(single.requeuedCommandIds);
                combined.unknown += single.unknown;
                combined.cancelled += single.cancelled;
                combined.paused += single.paused;
                combined.skipped += single.skipped;
                combined.skippedCommandIds.addAll(single.skippedCommandIds);
                combined.deferredCommandIds.addAll(single.deferredCommandIds);
            } catch (Exception failure) {
                Database.rollback(beforeCommand);
                failedCommandIds.add(commandId);
                AgentOperationsLog.signal('RECOVERY_ITEM_FAILED', null, commandId, failure.getTypeName());
            } finally {
                Database.releaseSavepoint(beforeCommand);
            }
        }
        quarantineCommands(failedCommandIds, nowValue);
        return combined;
    }

    private static void quarantineCommands(Set<Id> commandIds, Datetime nowValue) {
        if (commandIds.isEmpty()) {
            return;
        }
        List<AgentCommand__c> deferrals = new List<AgentCommand__c>();
        for (Id commandId : commandIds) {
            deferrals.add(new AgentCommand__c(Id = commandId, RecoveryCheckAt__c = nowValue.addMinutes(QUARANTINE_MINUTES)));
        }
        AgentLifecycleStore.updateCommands(deferrals);
        CommandDeliveryTracker.recordAnomalies(commandIds, 'RECOVERY_FAILED');
    }

    private static void quarantineRuns(Set<Id> runIds, Exception failure, RecoveryResult result) {
        List<AgentRun__c> deferrals = new List<AgentRun__c>();
        for (Id runId : runIds) {
            deferrals.add(new AgentRun__c(Id = runId, RecoveryCheckAt__c = System.now().addMinutes(QUARANTINE_MINUTES)));
            AgentOperationsLog.signal('RECOVERY_ITEM_FAILED', runId, null, failure.getTypeName());
        }
        AgentLifecycleStore.updateRuns(deferrals);
        if (result != null) {
            result.skipped += runIds.size();
        }
    }

    private static void failForTest(Set<Id> runIds) {
        for (Id runId : runIds) {
            if (Test.isRunningTest() && failingRunIdsForTest.contains(runId)) {
                throw new AgentKernelException.PersistenceException('RECOVERY_TEST_FAILURE');
            }
        }
    }

    private static Boolean hasQueryHeadroom() {
        return Limits.getQueries() < Limits.getLimitQueries() * (1 - FALLBACK_QUERY_HEADROOM);
    }

    /**
     * Scheduled recovery cannot continue another user's run without an identity, so
     * a command still undelivered well after it was due has lost its chain.
     */
    private static Integer endLostInitiatingUserChains(Integer safeLimit, RecoveryResult result) {
        if (safeLimit <= 0) {
            return 0;
        }
        Datetime nowValue = System.now();
        Datetime lostBefore = nowValue.addMinutes(-INITIATING_USER_CHAIN_GRACE_MINUTES);
        Id currentUserId = UserInfo.getUserId();
        List<AgentCommand__c> candidates = [
            SELECT Id, AgentRun__c, ExpectedRunRevision__c, AgentRun__r.Revision__c, AgentRun__r.CurrentCommand__c
            FROM AgentCommand__c
            WHERE
                DispatchDueAt__c != NULL
                AND DispatchDueAt__c <= :lostBefore
                AND AgentRun__r.Status__c = :AgentKernelModels.RUN_STATUS_RUNNING
                AND AgentRun__r.ExecutionIdentity__c = NULL
                AND AgentRun__r.InitiatingUser__c != :currentUserId
            WITH SYSTEM_MODE
            ORDER BY DispatchDueAt__c ASC, Id ASC
            LIMIT :safeLimit
        ];
        List<Id> lostCommandIds = new List<Id>();
        Set<Id> invalidCommandIds = new Set<Id>();
        Set<Id> invalidRunIds = new Set<Id>();
        for (AgentCommand__c command : candidates) {
            if (command.AgentRun__r.CurrentCommand__c != command.Id || command.AgentRun__r.Revision__c != command.ExpectedRunRevision__c) {
                result.skipped++;
                invalidCommandIds.add(command.Id);
                invalidRunIds.add(command.AgentRun__c);
            } else {
                lostCommandIds.add(command.Id);
            }
        }
        cancelInvalidOrphans(invalidCommandIds, invalidRunIds);
        if (lostCommandIds.isEmpty()) {
            return candidates.size();
        }
        Savepoint beforeLostChains = Database.setSavepoint();
        try {
            result.lostInitiatingUserChains += AgentKernelRecovery.endLostInitiatingUserChains(lostCommandIds, nowValue);
            return candidates.size();
        } catch (Exception bulkFailure) {
            Database.rollback(beforeLostChains);
        } finally {
            Database.releaseSavepoint(beforeLostChains);
        }
        for (Id commandId : lostCommandIds) {
            if (!hasQueryHeadroom()) {
                break;
            }
            Savepoint beforeCommand = Database.setSavepoint();
            try {
                result.lostInitiatingUserChains += AgentKernelRecovery.endLostInitiatingUserChains(new List<Id>{ commandId }, nowValue);
            } catch (Exception failure) {
                Database.rollback(beforeCommand);
                Database.releaseSavepoint(beforeCommand);
                AgentOperationsLog.signal('RECOVERY_ITEM_FAILED', null, commandId, failure.getTypeName());
                AgentLifecycleStore.updateCommands(
                    new List<AgentCommand__c>{ new AgentCommand__c(Id = commandId, DispatchDueAt__c = nowValue.addMinutes(QUARANTINE_MINUTES)) }
                );
                result.skipped++;
                continue;
            }
            Database.releaseSavepoint(beforeCommand);
        }
        return candidates.size();
    }

    /**
     * Redispatches queued commands nobody picked up. Each redispatch pushes the
     * command's due time back, so a command that can never be delivered (for
     * example, a Named Credential that signs in as the wrong user) cannot hold
     * the front of the queue; after MAXIMUM_REDISPATCHES its run pauses with
     * DISPATCH_UNDELIVERABLE for an operator.
     */
    private static void redispatchOrphans(Integer safeLimit, RecoveryResult result, List<Id> dispatchIds, Map<Id, Decimal> orphanIds) {
        if (safeLimit <= 0) {
            return;
        }
        Datetime nowValue = System.now();
        Id currentUserId = UserInfo.getUserId();
        Integer lookaheadLimit = safeLimit + 1;
        List<AgentCommand__c> candidates = [
            SELECT Id, AgentRun__c, ExpectedRunRevision__c, RedispatchCount__c, AgentRun__r.Revision__c, AgentRun__r.CurrentCommand__c
            FROM AgentCommand__c
            WHERE
                DispatchDueAt__c != NULL
                AND DispatchDueAt__c <= :nowValue
                AND AgentRun__r.Status__c = :AgentKernelModels.RUN_STATUS_RUNNING
                AND (AgentRun__r.ExecutionIdentity__c != NULL
                OR AgentRun__r.InitiatingUser__c = :currentUserId)
            WITH SYSTEM_MODE
            ORDER BY DispatchDueAt__c ASC, Id ASC
            LIMIT :lookaheadLimit
        ];
        if (candidates.size() > safeLimit) {
            AgentCommand__c deferred = candidates.remove(safeLimit);
            result.deferredByCapacity++;
            result.capacityDeferredCommandIds.add(deferred.Id);
        }
        Set<Id> invalidCommandIds = new Set<Id>();
        Set<Id> invalidRunIds = new Set<Id>();
        List<Id> undeliverableIds = new List<Id>();
        for (AgentCommand__c command : candidates) {
            if (command.AgentRun__r.CurrentCommand__c != command.Id || command.AgentRun__r.Revision__c != command.ExpectedRunRevision__c) {
                result.skipped++;
                invalidCommandIds.add(command.Id);
                invalidRunIds.add(command.AgentRun__c);
                continue;
            }
            Decimal redispatches = command.RedispatchCount__c == null ? 0 : command.RedispatchCount__c;
            if (redispatches >= MAXIMUM_REDISPATCHES) {
                undeliverableIds.add(command.Id);
                continue;
            }
            if (queueForDispatch(command.Id, dispatchIds, result)) {
                orphanIds.put(command.Id, redispatches);
            }
        }
        cancelInvalidOrphans(invalidCommandIds, invalidRunIds);
        pauseUndeliverable(undeliverableIds, nowValue, result);
    }

    private static void pauseUndeliverable(List<Id> commandIds, Datetime nowValue, RecoveryResult result) {
        if (commandIds.isEmpty()) {
            return;
        }
        Savepoint beforePause = Database.setSavepoint();
        Exception failure;
        try {
            result.paused += AgentKernelRecovery.pauseUndeliverableCommands(commandIds, nowValue);
        } catch (Exception caught) {
            failure = caught;
            Database.rollback(beforePause);
        } finally {
            Database.releaseSavepoint(beforePause);
        }
        if (failure != null) {
            List<AgentCommand__c> deferrals = new List<AgentCommand__c>();
            for (Id commandId : commandIds) {
                deferrals.add(new AgentCommand__c(Id = commandId, DispatchDueAt__c = nowValue.addMinutes(QUARANTINE_MINUTES)));
                AgentOperationsLog.signal('RECOVERY_ITEM_FAILED', null, commandId, failure.getTypeName());
            }
            AgentLifecycleStore.updateCommands(deferrals);
            result.skipped += commandIds.size();
        }
    }

    private static void cancelInvalidOrphans(Set<Id> commandIds, Set<Id> runIds) {
        if (commandIds.isEmpty()) {
            return;
        }
        Map<Id, AgentRun__c> lockedRuns = new Map<Id, AgentRun__c>(
            [SELECT Id, Status__c, Revision__c, CurrentCommand__c FROM AgentRun__c WHERE Id IN :runIds WITH SYSTEM_MODE FOR UPDATE]
        );
        List<AgentCommand__c> invalidCommands = new List<AgentCommand__c>();
        for (AgentCommand__c command : [
            SELECT Id, AgentRun__c, Status__c, ExpectedRunRevision__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            AgentRun__c run = lockedRuns.get(command.AgentRun__c);
            if (
                run == null ||
                run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
                !new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c) ||
                (run.CurrentCommand__c == command.Id &&
                run.Revision__c == command.ExpectedRunRevision__c)
            ) {
                continue;
            }
            invalidCommands.add(
                new AgentCommand__c(
                    Id = command.Id,
                    Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED,
                    ErrorCode__c = 'STALE_ORPHAN',
                    ErrorMessage__c = 'The pending command is no longer current for its run.'
                )
            );
        }
        AgentLifecycleStore.updateCommands(invalidCommands);
    }

    private static void dispatchRecovered(List<Id> commandIds, Map<Id, Decimal> orphanIds, RecoveryResult result) {
        if (commandIds.isEmpty()) {
            return;
        }
        List<AgentCommand__c> backoffs = new List<AgentCommand__c>();
        Datetime nowValue = System.now();
        CommandDispatcher.BatchDispatchResult dispatchResult = CommandDispatcher.dispatchBatchDetailed(commandIds);
        result.skipped += dispatchResult.skippedCommandIds.size();
        result.deferredByCapacity += dispatchResult.deferredCommandIds.size();
        result.deferredByInitiatingUser += dispatchResult.identityDeferredCommandIds.size();
        for (Id commandId : commandIds) {
            if (dispatchResult.acceptedCommandIds.contains(commandId)) {
                if (orphanIds.containsKey(commandId)) {
                    result.orphanRedispatched++;
                    Decimal redispatches = orphanIds.get(commandId) + 1;
                    backoffs.add(
                        new AgentCommand__c(
                            Id = commandId,
                            RedispatchCount__c = redispatches,
                            DispatchDueAt__c = nowValue.addMinutes(REDISPATCH_BACKOFF_MINUTES * redispatches.intValue())
                        )
                    );
                }
            } else if (
                !dispatchResult.skippedCommandIds.contains(commandId) &&
                !dispatchResult.deferredCommandIds.contains(commandId) &&
                !dispatchResult.identityDeferredCommandIds.contains(commandId)
            ) {
                result.skipped++;
            }
        }
        if (!backoffs.isEmpty()) {
            AgentLifecycleStore.updateCommands(backoffs);
        }
    }

    private static Boolean queueForDispatch(Id commandId, List<Id> commandIds, RecoveryResult result) {
        if (commandIds.size() >= configuredDispatchLimit()) {
            result.skipped++;
            result.deferredByCapacity++;
            result.capacityDeferredCommandIds.add(commandId);
            return false;
        }
        commandIds.add(commandId);
        return true;
    }

    public static Integer configuredDispatchLimit() {
        Integer configured = DEFAULT_MAXIMUM_DISPATCHES_PER_RUN;
        if (Test.isRunningTest() && dispatchLimitOverride != null) {
            configured = dispatchLimitOverride;
        }
        return Math.max(1, Math.min(PLATFORM_MAXIMUM_DISPATCHES_PER_RUN, configured));
    }
}
