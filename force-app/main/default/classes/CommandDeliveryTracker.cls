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
 * Correlates durable command leases with Flex Queue / AsyncApexJob delivery.
 * A wall-clock lease expiry is not authority to requeue while the worker job
 * is still queued or executing.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class CommandDeliveryTracker {
    public enum JobState {
        Active,
        Inactive,
        Missing
    }

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{ 'Queued', 'Holding', 'Preparing', 'Processing' };

    @TestVisible
    private static Map<Id, String> testJobStatuses;
    @TestVisible
    private static Boolean suppressEnqueueForTest = false;
    @TestVisible
    private static Integer duplicateSuppressions = 0;
    @TestVisible
    private static Integer uncorrelatedDuplicateReleases = 0;
    @TestVisible
    private static Integer resolveInvocationCount = 0;

    public static Map<Id, JobState> resolve(Set<Id> jobIds) {
        resolveInvocationCount++;
        Map<Id, JobState> result = new Map<Id, JobState>();
        if (jobIds == null || jobIds.isEmpty()) {
            return result;
        }
        Set<Id> remaining = new Set<Id>();
        for (Id jobId : jobIds) {
            if (jobId == null) {
                continue;
            }
            if (testJobStatuses != null && testJobStatuses.containsKey(jobId)) {
                result.put(jobId, fromStatus(testJobStatuses.get(jobId)));
            } else {
                remaining.add(jobId);
            }
        }
        if (!remaining.isEmpty()) {
            for (AsyncApexJob job : [SELECT Id, Status FROM AsyncApexJob WHERE Id IN :remaining WITH SYSTEM_MODE]) {
                result.put(job.Id, fromStatus(job.Status));
                remaining.remove(job.Id);
            }
            for (Id missingId : remaining) {
                result.put(missingId, JobState.Missing);
            }
        }
        return result;
    }

    public static Boolean isActive(String workerJobId) {
        if (String.isBlank(workerJobId)) {
            return false;
        }
        try {
            Id jobId = (Id) workerJobId;
            Map<Id, JobState> states = resolve(new Set<Id>{ jobId });
            return states.get(jobId) == JobState.Active;
        } catch (Exception ignored) {
            return false;
        }
    }

    public static Id activeCorrelatedJob(Id commandId) {
        if (commandId == null) {
            return null;
        }
        List<AgentCommand__c> commands = [
            SELECT WorkerJobId__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (commands.isEmpty() || String.isBlank(commands[0].WorkerJobId__c)) {
            return null;
        }
        try {
            Id jobId = (Id) commands[0].WorkerJobId__c;
            return resolve(new Set<Id>{ jobId }).get(jobId) == JobState.Active ? jobId : null;
        } catch (Exception invalidJobId) {
            return null;
        }
    }

    public static Boolean shouldSuppressEnqueue() {
        return Test.isRunningTest() && suppressEnqueueForTest;
    }

    public static Map<Id, JobState> resolveCommands(List<AgentCommand__c> commands) {
        Map<Id, Id> jobIdByCommandId = new Map<Id, Id>();
        Set<Id> jobIds = new Set<Id>();
        for (AgentCommand__c command : commands == null ? new List<AgentCommand__c>() : commands) {
            if (command == null || command.Id == null || String.isBlank(command.WorkerJobId__c)) {
                continue;
            }
            try {
                Id jobId = (Id) command.WorkerJobId__c;
                jobIdByCommandId.put(command.Id, jobId);
                jobIds.add(jobId);
            } catch (Exception invalidJobId) {
                continue;
            }
        }
        Map<Id, JobState> statesByJobId = resolve(jobIds);
        Map<Id, JobState> result = new Map<Id, JobState>();
        for (AgentCommand__c command : commands == null ? new List<AgentCommand__c>() : commands) {
            if (command == null || command.Id == null) {
                continue;
            }
            Id jobId = jobIdByCommandId.get(command.Id);
            result.put(command.Id, jobId == null ? JobState.Missing : statesByJobId.get(jobId));
        }
        return result;
    }

    public static void recordJob(Id commandId, Id jobId) {
        if (commandId == null) {
            return;
        }
        AgentLifecycleStore.updateCommands(
            new List<AgentCommand__c>{
                new AgentCommand__c(
                    Id = commandId,
                    WorkerJobId__c = jobId == null ? null : String.valueOf(jobId),
                    WorkerEnqueuedAt__c = jobId == null ? null : System.now()
                )
            }
        );
    }

    /** Records the worker job of each command in one update, for batch dispatch. */
    public static void recordJobs(Map<Id, Id> jobIdByCommandId) {
        if (jobIdByCommandId == null || jobIdByCommandId.isEmpty()) {
            return;
        }
        Datetime enqueuedAt = System.now();
        List<AgentCommand__c> updates = new List<AgentCommand__c>();
        for (Id commandId : jobIdByCommandId.keySet()) {
            Id jobId = jobIdByCommandId.get(commandId);
            updates.add(
                new AgentCommand__c(
                    Id = commandId,
                    WorkerJobId__c = jobId == null ? null : String.valueOf(jobId),
                    WorkerEnqueuedAt__c = jobId == null ? null : enqueuedAt
                )
            );
        }
        AgentLifecycleStore.updateCommands(updates);
    }

    public static void clearJob(Id commandId) {
        recordJob(commandId, null);
    }

    public static void recordDuplicateSuppression(Id commandId, Boolean correlated) {
        if (correlated == true) {
            duplicateSuppressions++;
            recordAnomaly(commandId, 'DUPLICATE_CORRELATED');
            AgentOperationsLog.emit(LoggingLevel.WARN, 'DISPATCH_DUPLICATE_CORRELATED', null, commandId, null, null);
        } else {
            uncorrelatedDuplicateReleases++;
            recordAnomaly(commandId, 'DUPLICATE_UNCORRELATED');
            AgentOperationsLog.emit(LoggingLevel.WARN, 'DISPATCH_DUPLICATE_RELEASED', null, commandId, null, null);
        }
    }

    public static void recordAnomaly(Id commandId, String anomalyCode) {
        recordAnomalies(commandId == null ? new Set<Id>() : new Set<Id>{ commandId }, anomalyCode);
    }

    public static void recordAnomalies(Set<Id> commandIds, String anomalyCode) {
        if (commandIds == null || commandIds.isEmpty() || String.isBlank(anomalyCode)) {
            return;
        }
        String safeCode = anomalyCode.trim().toUpperCase();
        if (safeCode.length() > 80) {
            safeCode = safeCode.substring(0, 80);
        }
        List<AgentCommand__c> updates = new List<AgentCommand__c>();
        for (AgentCommand__c command : [
            SELECT Id, DeliveryAnomalyCount__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            updates.add(
                new AgentCommand__c(
                    Id = command.Id,
                    DeliveryAnomalyCode__c = safeCode,
                    DeliveryAnomalyCount__c = (command.DeliveryAnomalyCount__c == null ? 0 : command.DeliveryAnomalyCount__c) + 1,
                    LastDeliveryAnomalyAt__c = System.now()
                )
            );
        }
        AgentLifecycleStore.updateCommands(updates);
    }

    public static Integer duplicateSuppressionCount() {
        return duplicateSuppressions;
    }

    public static Integer uncorrelatedDuplicateReleaseCount() {
        return uncorrelatedDuplicateReleases;
    }

    private static JobState fromStatus(String status) {
        return ACTIVE_STATUSES.contains(status) ? JobState.Active : JobState.Inactive;
    }
}
