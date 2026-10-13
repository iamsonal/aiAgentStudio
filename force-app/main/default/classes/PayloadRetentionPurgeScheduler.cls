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
 * Administrative daily scheduler for bounded terminal payload minimization.
 * The scheduling user must retain AgentKernelRetentionPurge permission (granted by AgentKernelAdmin).
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
global without sharing class PayloadRetentionPurgeScheduler implements Schedulable {
    private static final String JOB_NAME = 'Agent Core - Payload Retention Purge';
    private static final String CRON_EXPRESSION = '0 0 2 * * ?';
    private static final Set<String> ACTIVE_STATES = new Set<String>{ 'WAITING', 'ACQUIRED', 'PAUSED', 'BLOCKED' };
    @TestVisible
    private static PayloadRetentionPurgeService.PurgeResult lastResult;

    global void execute(SchedulableContext context) {
        runNow();
    }

    global static void runNow() {
        lastResult = PayloadRetentionPurgeService.purge(100);
        PayloadRetentionPurgeService.DeletionResult deletion = PayloadRetentionPurgeService.deleteExpiredRecords(25);
        AgentOperationalIssues.maintain();
        if ((lastResult.hasMore || deletion.hasMore) && !Test.isRunningTest()) {
            System.enqueueJob(new PayloadRetentionPurgeQueueable());
        }
    }

    global static Id install() {
        for (CronTrigger failedJob : failedJobs()) {
            System.abortJob(failedJob.Id);
        }
        List<CronTrigger> jobs = activeJobs();
        Id validJobId;
        for (CronTrigger job : jobs) {
            if (validJobId == null && job.CronExpression == CRON_EXPRESSION && (job.State == 'WAITING' || job.State == 'ACQUIRED')) {
                validJobId = job.Id;
            } else {
                System.abortJob(job.Id);
            }
        }
        return validJobId == null ? System.schedule(JOB_NAME, CRON_EXPRESSION, new PayloadRetentionPurgeScheduler()) : validJobId;
    }

    public static String expectedJobName() {
        return JOB_NAME;
    }

    public static String expectedCronExpression() {
        return CRON_EXPRESSION;
    }

    global static Integer remove() {
        List<CronTrigger> jobs = allManagedJobs();
        for (CronTrigger job : jobs) {
            System.abortJob(job.Id);
        }
        return jobs.size();
    }

    private static List<CronTrigger> activeJobs() {
        return [
            SELECT Id, State, CronExpression
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME AND State IN :ACTIVE_STATES
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];
    }

    private static List<CronTrigger> failedJobs() {
        return [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME AND State = 'ERROR'
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];
    }

    private static List<CronTrigger> allManagedJobs() {
        Set<String> managedStates = new Set<String>(ACTIVE_STATES);
        managedStates.add('ERROR');
        return [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME AND State IN :managedStates
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
        ];
    }
}
