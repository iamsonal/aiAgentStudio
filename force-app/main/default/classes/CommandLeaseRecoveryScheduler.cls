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

/** Scheduled and immediate entry points for bounded lease recovery. */
@SuppressWarnings('PMD.ApexCRUDViolation')
global without sharing class CommandLeaseRecoveryScheduler implements Schedulable {
    private static final String JOB_NAME = 'Agent Core - Lease Recovery - 10';
    private static final List<String> JOB_NAMES = new List<String>{
        JOB_NAME,
        'Agent Core - Lease Recovery - 20',
        'Agent Core - Lease Recovery - 30',
        'Agent Core - Lease Recovery - 40',
        'Agent Core - Lease Recovery - 50',
        'Agent Core - Lease Recovery - 60'
    };
    private static final List<String> CRON_EXPRESSIONS = new List<String>{
        '0 10 * * * ?',
        '0 20 * * * ?',
        '0 30 * * * ?',
        '0 40 * * * ?',
        '0 50 * * * ?',
        '0 0 * * * ?'
    };
    private static final Integer RECOVERY_LIMIT = CommandDispatcher.MAXIMUM_BATCH_SIZE;
    private static final Integer MAX_CONTINUATION_HOPS = 10;
    private static final Set<String> ACTIVE_STATES = new Set<String>{ 'WAITING', 'ACQUIRED', 'PAUSED', 'BLOCKED', 'ERROR' };
    private static Id installedJobIdThisTransaction;
    private static Boolean removedThisTransaction = false;

    @TestVisible
    private static CommandLeaseRecoveryService.RecoveryResult lastRecoveryResult;

    global void execute(SchedulableContext context) {
        runNow();
    }

    global static void runNow() {
        lastRecoveryResult = CommandLeaseRecoveryService.recoverOperational(RECOVERY_LIMIT);
        if (lastRecoveryResult.continuationRequired) {
            System.enqueueJob(new RecoveryContinuation(1));
        }
    }

    /**
     * Drains a mass-failure backlog between scheduled ticks. Each hop is one
     * bounded recovery pass. A Queueable may enqueue only one job, and the
     * pass may use it for dispatch, so the next hop is chained from a
     * Finalizer, which has its own enqueue allowance.
     */
    public class RecoveryContinuation implements Queueable {
        private final Integer hop;

        public RecoveryContinuation(Integer hop) {
            this.hop = hop;
        }

        public void execute(QueueableContext context) {
            ContinuationFinalizer next = new ContinuationFinalizer(hop);
            if (context != null) {
                System.attachFinalizer(next);
            }
            lastRecoveryResult = CommandLeaseRecoveryService.recoverOperational(RECOVERY_LIMIT);
            next.continuationRequired = lastRecoveryResult.continuationRequired;
        }
    }

    public class ContinuationFinalizer implements Finalizer {
        private final Integer hop;
        public Boolean continuationRequired = false;

        public ContinuationFinalizer(Integer hop) {
            this.hop = hop;
        }

        public void execute(FinalizerContext context) {
            if (continuationRequired && hop < MAX_CONTINUATION_HOPS && context.getResult() == ParentJobResult.SUCCESS && !Test.isRunningTest()) {
                System.enqueueJob(new RecoveryContinuation(hop + 1));
            }
        }
    }

    /** Provisions the trust key and the six recovery jobs. Safe to repeat. */
    global static Id install() {
        if (installedJobIdThisTransaction != null) {
            return installedJobIdThisTransaction;
        }
        TrustKeyProvider.provision();
        removedThisTransaction = false;
        List<CronTrigger> existingJobs = activeJobs();
        Map<String, Id> existingByName = new Map<String, Id>();
        for (CronTrigger existingJob : existingJobs) {
            Integer index = JOB_NAMES.indexOf(existingJob.CronJobDetail.Name);
            if (index >= 0 && existingJob.CronExpression == CRON_EXPRESSIONS[index] && isExecutable(existingJob.State)) {
                existingByName.put(existingJob.CronJobDetail.Name, existingJob.Id);
            } else {
                System.abortJob(existingJob.Id);
            }
        }
        List<Id> createdJobIds = new List<Id>();
        try {
            for (Integer index = 0; index < JOB_NAMES.size(); index++) {
                String jobName = JOB_NAMES[index];
                if (!existingByName.containsKey(jobName)) {
                    Id jobId = System.schedule(jobName, CRON_EXPRESSIONS[index], new CommandLeaseRecoveryScheduler());
                    createdJobIds.add(jobId);
                    existingByName.put(jobName, jobId);
                }
            }
            existingJobs = activeJobs();
            if (!isComplete(existingJobs)) {
                throw new AgentKernelException.ConfigurationException('Lease recovery requires all six scheduled jobs.');
            }
            installedJobIdThisTransaction = jobId(existingJobs, JOB_NAME);
            return installedJobIdThisTransaction;
        } catch (Exception scheduleFailure) {
            for (Id createdJobId : createdJobIds) {
                try {
                    System.abortJob(createdJobId);
                } catch (Exception ignored) {
                }
            }
            // Stable names are unique. A concurrent installer can win between
            // the query and schedule call, so accept only a complete re-read.
            existingJobs = activeJobs();
            if (isComplete(existingJobs)) {
                installedJobIdThisTransaction = jobId(existingJobs, JOB_NAME);
                return installedJobIdThisTransaction;
            }
            throw new AgentKernelException.ConfigurationException(
                'Lease recovery schedule could not be installed: ' + sanitizeScheduleError(scheduleFailure.getMessage())
            );
        }
    }

    global static Integer remove() {
        if (removedThisTransaction) {
            return 0;
        }
        List<CronTrigger> jobs = activeJobs();
        Set<Id> jobIds = new Set<Id>();
        for (CronTrigger job : jobs) {
            jobIds.add(job.Id);
        }
        if (installedJobIdThisTransaction != null) {
            jobIds.add(installedJobIdThisTransaction);
        }
        for (Id jobId : jobIds) {
            System.abortJob(jobId);
        }
        installedJobIdThisTransaction = null;
        removedThisTransaction = true;
        return jobIds.size();
    }

    global static Id getInstalledJobId() {
        if (removedThisTransaction) {
            return null;
        }
        if (installedJobIdThisTransaction != null) {
            return installedJobIdThisTransaction;
        }
        List<CronTrigger> jobs = activeJobs();
        return isComplete(jobs) ? jobId(jobs, JOB_NAME) : null;
    }

    public static List<String> expectedJobNames() {
        return JOB_NAMES.clone();
    }

    public static List<String> expectedCronExpressions() {
        return CRON_EXPRESSIONS.clone();
    }

    private static List<CronTrigger> activeJobs() {
        return [
            SELECT Id, State, CronExpression, CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name IN :JOB_NAMES AND State IN :ACTIVE_STATES
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];
    }

    private static Boolean isComplete(List<CronTrigger> jobs) {
        Set<String> installedNames = new Set<String>();
        for (CronTrigger job : jobs) {
            Integer index = JOB_NAMES.indexOf(job.CronJobDetail.Name);
            if (index < 0 || job.CronExpression != CRON_EXPRESSIONS[index] || !isExecutable(job.State) || installedNames.contains(job.CronJobDetail.Name)) {
                return false;
            }
            installedNames.add(job.CronJobDetail.Name);
        }
        for (String expectedName : JOB_NAMES) {
            if (!installedNames.contains(expectedName)) {
                return false;
            }
        }
        return true;
    }

    private static Boolean isExecutable(String state) {
        return state == 'WAITING' || state == 'ACQUIRED';
    }

    private static Id jobId(List<CronTrigger> jobs, String jobName) {
        for (CronTrigger job : jobs) {
            if (job.CronJobDetail.Name == jobName) {
                return job.Id;
            }
        }
        return null;
    }

    private static String sanitizeScheduleError(String message) {
        if (String.isBlank(message)) {
            return 'Salesforce rejected the scheduled job.';
        }
        String sanitized = message.replace('\r', ' ').replace('\n', ' ').trim();
        return sanitized.length() > 255 ? sanitized.substring(0, 255) : sanitized;
    }
}
