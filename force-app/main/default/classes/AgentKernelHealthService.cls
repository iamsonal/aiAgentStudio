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

/** Bounded, caller-visible operational health reporting. */
@SuppressWarnings('PMD.ApexCRUDViolation')
global inherited sharing class AgentKernelHealthService {
    private static final Set<String> ACTIVE_SCHEDULER_STATES = new Set<String>{ 'WAITING', 'ACQUIRED', 'PAUSED', 'BLOCKED', 'ERROR' };
    private static final Integer MAX_DELIVERY_SAMPLE = 2000;
    private static final Integer RECOVERY_SLO_SECONDS = 600;
    private static final Decimal DAILY_LIMIT_WARNING_PERCENT = 80;
    @TestVisible
    private static Integer queryRowBudgetOverride;
    public static final String ACTION_SCHEDULES = 'INSTALL_OR_REPAIR_SCHEDULES';
    public static final String ACTION_IDENTITIES = 'FIX_EXECUTION_IDENTITIES';
    public static final String ACTION_PAUSED_RUNS = 'RESCUE_OR_CANCEL_PAUSED_RUNS';
    public static final String ACTION_UNKNOWN_CALLS = 'RECONCILE_UNKNOWN_CALLS';
    public static final String ACTION_ISSUES = 'REVIEW_OPEN_ISSUES';
    public static final String ACTION_LOAD = 'REDUCE_LOAD';
    /** Permission sets whose holders hand work to an execution user, so they need its credential. */
    private static final Set<String> CREDENTIAL_USER_PERMISSION_SETS = new Set<String>{
        'AgentKernelRunAgents',
        'AgentKernelHumanDecision',
        'AgentKernelApprovalRelay',
        'AgentKernelOperator',
        'AgentKernelAdmin',
        'AgentChannelsPrincipal',
        'AgentChannelsIntegration',
        'AgentHITLRelay'
    };
    private static final Integer MAX_CREDENTIAL_HOLDERS = 2000;
    private static final Integer MAX_LISTED_UNNEEDED = 25;
    @TestVisible
    private static Map<String, Set<Id>> credentialPrincipalIdsForTest;

    global class HealthRequest {
        global Integer lookbackHours { get; set; }
        global Integer sampleLimit { get; set; }
        global Id definitionId { get; set; }
        global HealthRequest() {
        }
    }
    global class SchedulerHealth {
        global Boolean installed { get; set; }
        global Id jobId { get; set; }
        global String state { get; set; }
        global Datetime nextFireTime { get; set; }
        global Integer installedJobCount { get; set; }
        global Integer expectedJobCount { get; set; }
        global List<String> missingJobNames { get; set; }
        global List<String> misconfiguredJobNames { get; set; }
        global SchedulerHealth() {
        }
    }
    global class ErrorCount {
        global String errorCode { get; set; }
        global Integer count { get; set; }
        global ErrorCount() {
        }
    }
    global class ToolHealth {
        global String toolName { get; set; }
        global Integer attempts { get; set; }
        global Integer failures { get; set; }
        global Decimal failureRatePercent { get; set; }
        global ToolHealth() {
        }
    }
    global class AgentHealth {
        global Id definitionId { get; set; }
        global Integer completedRuns { get; set; }
        global Integer failedRuns { get; set; }
        global Decimal failureRatePercent { get; set; }
        global AgentHealth() {
        }
    }
    global class RunSample {
        global Id runId { get; set; }
        global String status { get; set; }
        global String errorCode { get; set; }
        global Datetime lastActivity { get; set; }
        global String correlationKey { get; set; }
        global RunSample() {
        }
    }
    /** One thing an admin should do, why, the numbers behind it, and where to fix it. */
    global class HealthAction {
        global String code { get; set; }
        global String reason { get; set; }
        global String fixTarget { get; set; }
        global Map<String, Integer> counts { get; set; }
        global HealthAction() {
            counts = new Map<String, Integer>();
        }
    }
    /** Users who hold access to an execution identity's credential, and those of them who need none. */
    global class CredentialReview {
        global Id executionIdentityId { get; set; }
        global String namedCredential { get; set; }
        /** False when the platform could not describe the credential; the counts are then unknown. */
        global Boolean available { get; set; }
        global Integer holders { get; set; }
        global List<Id> unneededUserIds { get; set; }
        global List<String> unneededUserNames { get; set; }
        global Boolean truncated { get; set; }
        global CredentialReview() {
            unneededUserIds = new List<Id>();
            unneededUserNames = new List<String>();
        }
    }
    global class HealthReport {
        global Datetime generatedAt { get; set; }
        global String scope { get; set; }
        global String status { get; set; }
        global Integer lookbackHours { get; set; }
        global SchedulerHealth scheduler { get; set; }
        global SchedulerHealth retentionScheduler { get; set; }
        global Integer activeRunning { get; set; }
        global Integer pausedRuns { get; set; }
        /** Paused runs whose saved payload was already purged; they cannot be rescued, only cancelled. */
        global Integer purgedPausedRuns { get; set; }
        global Datetime oldestPausedAt { get; set; }
        global Integer staleLeased { get; set; }
        global Integer dueOrphanCommands { get; set; }
        global Datetime oldestStaleLeaseExpiry { get; set; }
        global Datetime oldestDueOrphanAvailableAt { get; set; }
        global Integer dueRetentionRuns { get; set; }
        global Datetime oldestDueRetentionPurgeAfter { get; set; }
        global Boolean trustVaultFieldExposureProtected { get; set; }
        global Integer waitingUnknown { get; set; }
        global Integer leasedWithWorkerJob { get; set; }
        global Integer staleLeasedInactiveWorker { get; set; }
        global Integer staleLeasedActiveWorker { get; set; }
        global Integer staleLeasedMissingWorker { get; set; }
        global Boolean deliverySampleTruncated { get; set; }
        global Datetime oldestWorkerEnqueuedAt { get; set; }
        global Integer duplicateDispatchSuppressions { get; set; }
        global Integer uncorrelatedDuplicateReleases { get; set; }
        global Integer recoveryCandidatesDeferredByCapacity { get; set; }
        global Integer recoveryCandidatesDeferredByInitiatingUser { get; set; }
        global Integer recoveryCandidateCount { get; set; }
        global Boolean recoveryCandidateCountIsLowerBound { get; set; }
        global Integer recoverySloWindowSeconds { get; set; }
        global Integer oldestRecoverableBacklogAgeSeconds { get; set; }
        global Boolean recoverySloMet { get; set; }
        global Integer oldestStaleLeaseAgeSeconds { get; set; }
        global Integer lifecyclePublishFailures { get; set; }
        global Integer lifecyclePublishFailureRuns { get; set; }
        global Datetime lastLifecyclePublishFailureAt { get; set; }
        global Boolean lifecycleEventCreateAvailable { get; set; }
        global Integer recentSucceeded { get; set; }
        global Integer recentFailed { get; set; }
        global Integer recentCancelled { get; set; }
        global Long modelCalls { get; set; }
        global Long toolCalls { get; set; }
        global Long retries { get; set; }
        global Long totalTokens { get; set; }
        global Long modelDurationMs { get; set; }
        global Long toolDurationMs { get; set; }
        global Decimal recentFailureRatePercent { get; set; }
        global Long averageRunDurationMs { get; set; }
        /** The most any one model or tool attempt used, not a whole transaction. */
        global Long peakCpuTimeMs { get; set; }
        global Long peakSoqlQueries { get; set; }
        global Long peakDmlStatements { get; set; }
        global Integer waitEvents { get; set; }
        global Integer waitTimeouts { get; set; }
        /** Agent Approvals still waiting for a decision, and when the oldest was requested. */
        global Integer pendingApprovals { get; set; }
        global Datetime oldestPendingApprovalAt { get; set; }
        /** Agent Approvals that expired in the lookback window without a decision. */
        global Integer expiredApprovals { get; set; }
        /** Runs recovery set aside after a failed recovery step (RECOVERY_ITEM_FAILED signals). */
        global Integer recoveryQuarantinedRuns { get; set; }
        global List<ErrorCount> retryReasons { get; set; }
        global List<ErrorCount> toolFailures { get; set; }
        global List<ToolHealth> toolMetrics { get; set; }
        global List<AgentHealth> agentMetrics { get; set; }
        global Integer configuredMaxCommands { get; set; }
        global Integer estimatedJobsPerCommand { get; set; }
        global Integer estimatedWorstCaseJobsPerRun { get; set; }
        global Integer requiredInitiatingUserStackDepth { get; set; }
        global List<ErrorCount> topErrors { get; set; }
        global List<RunSample> samples { get; set; }
        /** What an admin should do, at most six actions; empty when nothing needs a person. */
        global List<HealthAction> actions { get; set; }
        /** Paused runs of agents without an identity that only the person who started them can continue. */
        global Integer starterOnlyPausedRuns { get; set; }
        /** Open Agent Operational Issues by code, as the caller can see them. */
        global Map<String, Integer> openIssuesByCode { get; set; }
        /** False when the platform shows the issue subscriber as stopped, so new failures are not recorded. */
        global Boolean issueSubscriberRunning { get; set; }
        /** Who can use each active execution identity's credential; only for Agent Kernel Operator or Admin. */
        global List<CredentialReview> credentialReviews { get; set; }
        global Boolean metricsTruncated { get; set; }
        global Integer workerFailures { get; set; }
        /** False until CommandLeaseRecoveryScheduler.install() provisions the trust key; runs cannot start without it. */
        global Boolean trustKeyProvisioned { get; set; }
        /** Org-wide share of the rolling 24-hour limits that every agent command and loopback dispatch consumes. */
        global Decimal dailyAsyncApexUsedPercent { get; set; }
        global Decimal dailyApiRequestsUsedPercent { get; set; }
        /** Active execution identities whose latest Verify failed, or that changed since it passed. */
        global Integer failedExecutionIdentities { get; set; }
        global HealthReport() {
        }
    }

    global static HealthReport getHealth(HealthRequest request) {
        Integer lookback = request == null || request.lookbackHours == null ? 24 : request.lookbackHours;
        Integer sampleLimit = request == null || request.sampleLimit == null ? 20 : request.sampleLimit;
        if (lookback < 1 || lookback > 168) {
            throw new AgentKernelException.ConfigurationException('lookbackHours must be from 1 through 168.');
        }
        if (sampleLimit < 1 || sampleLimit > 100) {
            throw new AgentKernelException.ConfigurationException('sampleLimit must be from 1 through 100.');
        }
        Id definitionId = request == null ? null : request.definitionId;
        if (
            !Schema.sObjectType.AgentRun__c.isAccessible() ||
            !Schema.sObjectType.AgentCommand__c.isAccessible() ||
            !Schema.sObjectType.AgentRun__c.fields.Status__c.isAccessible() ||
            !Schema.sObjectType.AgentRun__c.fields.ErrorCode__c.isAccessible()
        ) {
            throw new AgentKernelException.ConfigurationException('Required operational health fields are inaccessible.');
        }
        Datetime nowValue = System.now();
        Datetime sinceValue = nowValue.addHours(-lookback);
        HealthReport report = new HealthReport();
        report.generatedAt = nowValue;
        report.scope = 'CallerVisible';
        report.lookbackHours = lookback;
        report.scheduler = schedulerHealth(CommandLeaseRecoveryScheduler.expectedJobNames(), CommandLeaseRecoveryScheduler.expectedCronExpressions());
        report.retentionScheduler = schedulerHealth(
            new List<String>{ PayloadRetentionPurgeScheduler.expectedJobName() },
            new List<String>{ PayloadRetentionPurgeScheduler.expectedCronExpression() }
        );
        report.topErrors = new List<ErrorCount>();
        report.retryReasons = new List<ErrorCount>();
        report.toolFailures = new List<ErrorCount>();
        report.toolMetrics = new List<ToolHealth>();
        report.agentMetrics = new List<AgentHealth>();
        report.samples = new List<RunSample>();
        report.actions = new List<HealthAction>();
        Boolean asyncJobBudgetExceeded = false;
        if (definitionId != null) {
            List<AgentDefinition__c> definitions;
            try {
                definitions = [
                    SELECT ExecutionIdentity__c, MaxModelCalls__c, MaxToolCalls__c, MaxRetries__c
                    FROM AgentDefinition__c
                    WHERE Id = :definitionId
                    WITH USER_MODE
                    LIMIT 1
                ];
            } catch (QueryException fieldsInaccessible) {
                // Callers without the definition's budget fields get no job estimate, consistent with the caller-visible scope.
                definitions = new List<AgentDefinition__c>();
            }
            if (!definitions.isEmpty()) {
                AsyncJobCostService.Estimate estimate = AsyncJobCostService.estimate(definitions[0]);
                report.configuredMaxCommands = estimate.configuredMaxCommands;
                report.estimatedJobsPerCommand = estimate.jobsPerCommand;
                report.estimatedWorstCaseJobsPerRun = estimate.worstCaseJobsPerRun;
                if (!ExecutionIdentityService.usesIdentity(definitions[0])) {
                    report.requiredInitiatingUserStackDepth = estimate.requiredInitiatingUserStackDepth;
                    asyncJobBudgetExceeded = estimate.exceedsInitiatingUserChainDepth == true;
                }
            }
        }

        report.metricsTruncated = false;
        Map<String, Object> binds = new Map<String, Object>{ 'sinceValue' => sinceValue, 'definitionId' => definitionId };
        String runDefinitionFilter = definitionId == null ? '' : ' AND AgentDefinition__c = :definitionId';
        String childDefinitionFilter = definitionId == null ? '' : ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        Boolean completedRunsAffordable = affordable('AgentRun__c WHERE CompletedAt__c >= :sinceValue' + runDefinitionFilter, binds, report);
        Map<String, Integer> statusCounts = statusCounts(definitionId, sinceValue, completedRunsAffordable);
        report.activeRunning = count(statusCounts, 'ACTIVE_RUNNING');
        report.recentSucceeded = count(statusCounts, AgentKernelModels.RUN_STATUS_SUCCEEDED);
        report.recentFailed = count(statusCounts, AgentKernelModels.RUN_STATUS_FAILED);
        report.recentCancelled = count(statusCounts, AgentKernelModels.RUN_STATUS_CANCELLED);
        PausedBacklog paused = pausedBacklog(definitionId);
        report.pausedRuns = paused.count;
        report.purgedPausedRuns = paused.purged;
        report.starterOnlyPausedRuns = paused.starterOnly;
        report.oldestPausedAt = paused.oldestActivity;
        CommandBacklog backlog = commandBacklog(definitionId, nowValue);
        report.staleLeased = backlog.staleLeased;
        report.dueOrphanCommands = backlog.dueOrphans;
        report.oldestStaleLeaseExpiry = backlog.oldestStaleLeaseExpiry;
        report.oldestDueOrphanAvailableAt = backlog.oldestDueOrphanAvailableAt;
        report.waitingUnknown = backlog.waitingUnknown;
        addApprovalAndQuarantineMetrics(report, definitionId, sinceValue, nowValue);
        report.leasedWithWorkerJob = backlog.leasedWithWorkerJob;
        report.staleLeasedInactiveWorker = backlog.staleLeasedInactiveWorker;
        report.staleLeasedActiveWorker = backlog.staleLeasedActiveWorker;
        report.staleLeasedMissingWorker = backlog.staleLeasedMissingWorker;
        report.deliverySampleTruncated = backlog.deliverySampleTruncated;
        report.oldestWorkerEnqueuedAt = backlog.oldestWorkerEnqueuedAt;
        Map<String, Integer> deliveryAnomalies = affordable(
                'AgentCommand__c WHERE DeliveryAnomalyCode__c != NULL AND LastDeliveryAnomalyAt__c >= :sinceValue' + childDefinitionFilter,
                binds,
                report
            )
            ? deliveryAnomalyCounts(definitionId, sinceValue)
            : new Map<String, Integer>();
        report.workerFailures = count(deliveryAnomalies, 'WORKER_FAILED');
        report.duplicateDispatchSuppressions = count(deliveryAnomalies, 'DUPLICATE_CORRELATED');
        report.uncorrelatedDuplicateReleases = count(deliveryAnomalies, 'DUPLICATE_UNCORRELATED');
        report.recoveryCandidatesDeferredByCapacity = count(deliveryAnomalies, 'CAPACITY_DEFERRED');
        report.recoveryCandidatesDeferredByInitiatingUser = count(deliveryAnomalies, 'IDENTITY_DEFERRED');
        report.recoveryCandidateCount = backlog.staleLeasedInactiveWorker + backlog.staleLeasedMissingWorker + backlog.dueOrphans;
        report.recoveryCandidateCountIsLowerBound = backlog.deliverySampleTruncated;
        report.recoverySloWindowSeconds = RECOVERY_SLO_SECONDS;
        report.oldestStaleLeaseAgeSeconds = backlog.oldestStaleLeaseExpiry == null
            ? 0
            : Integer.valueOf((nowValue.getTime() - backlog.oldestStaleLeaseExpiry.getTime()) / 1000);
        Integer oldestOrphanAgeSeconds = backlog.oldestDueOrphanAvailableAt == null
            ? 0
            : Integer.valueOf((nowValue.getTime() - backlog.oldestDueOrphanAvailableAt.getTime()) / 1000);
        Integer oldestRecoverableLeaseAgeSeconds = backlog.oldestRecoverableLeaseExpiry == null
            ? 0
            : Integer.valueOf((nowValue.getTime() - backlog.oldestRecoverableLeaseExpiry.getTime()) / 1000);
        report.oldestRecoverableBacklogAgeSeconds = Math.max(oldestRecoverableLeaseAgeSeconds, oldestOrphanAgeSeconds);
        report.recoverySloMet =
            !backlog.deliverySampleTruncated &&
            report.oldestRecoverableBacklogAgeSeconds <= RECOVERY_SLO_SECONDS &&
            report.recoveryCandidatesDeferredByCapacity == 0;
        AggregateResult publishHealth = lifecyclePublishHealth(definitionId);
        report.lifecyclePublishFailures = integerValue(publishHealth.get('failures'));
        report.lifecyclePublishFailureRuns = integerValue(publishHealth.get('failedRuns'));
        report.lastLifecyclePublishFailureAt = (Datetime) publishHealth.get('lastFailure');
        report.lifecycleEventCreateAvailable = Schema.sObjectType.AgentLifecycleEvent__e.isCreateable();
        RetentionBacklog retention = retentionBacklog(definitionId, nowValue);
        report.dueRetentionRuns = retention.dueRuns;
        report.oldestDueRetentionPurgeAfter = retention.oldestPurgeAfter;
        report.trustVaultFieldExposureProtected = trustVaultFieldUngranted();
        report.failedExecutionIdentities = [
            SELECT COUNT()
            FROM AgentExecutionIdentity__c
            WHERE IsActive__c = TRUE AND VerifiedAt__c = NULL AND VerificationResult__c != NULL
            WITH SYSTEM_MODE
        ];
        report.openIssuesByCode = AgentOperationalIssues.openCountsByCode();
        report.issueSubscriberRunning = issueSubscriberRunning();
        report.credentialReviews = ExecutionIdentityService.canReconcile() ? credentialReviews() : new List<CredentialReview>();
        AgentTrustKey__c trustKey = AgentTrustKey__c.getOrgDefaults();
        report.trustKeyProvisioned = trustKey != null && !String.isBlank(trustKey.Key__c);
        Map<String, System.OrgLimit> orgLimits = OrgLimits.getMap();
        report.dailyAsyncApexUsedPercent = usedPercent(orgLimits.get('DailyAsyncApexExecutions'));
        report.dailyApiRequestsUsedPercent = usedPercent(orgLimits.get('DailyApiRequests'));
        Boolean dailyLimitPressure =
            report.dailyAsyncApexUsedPercent >= DAILY_LIMIT_WARNING_PERCENT ||
            report.dailyApiRequestsUsedPercent >= DAILY_LIMIT_WARNING_PERCENT;

        Integer terminalCount = report.recentSucceeded + report.recentFailed + report.recentCancelled;
        report.recentFailureRatePercent = terminalCount == 0 ? 0 : (Decimal.valueOf(report.recentFailed) * 100 / terminalCount).setScale(2);
        if (completedRunsAffordable) {
            populateAgentFailureRates(report, definitionId, sinceValue);
        }

        populateWindowMetrics(
            report,
            definitionId,
            sinceValue,
            affordable('AgentInvocation__c WHERE StartedAt__c >= :sinceValue' + childDefinitionFilter, binds, report),
            affordable('AgentEvent__c WHERE OccurredAt__c >= :sinceValue' + childDefinitionFilter, binds, report),
            completedRunsAffordable
        );
        Boolean errorsAffordable = affordable(
            'AgentRun__c WHERE ErrorCode__c != NULL AND (CompletedAt__c >= :sinceValue OR (Status__c = \'Paused\' AND LastActivityAt__c >= :sinceValue))' +
            runDefinitionFilter,
            binds,
            report
        );
        for (AggregateResult row : errorsAffordable ? errors(definitionId, sinceValue) : new List<AggregateResult>()) {
            ErrorCount error = new ErrorCount();
            error.errorCode = sanitizeCode((String) row.get('code'));
            error.count = Integer.valueOf(row.get('quantity'));
            report.topErrors.add(error);
        }
        for (AgentRun__c run : sampleRuns(definitionId, sampleLimit)) {
            RunSample sample = new RunSample();
            sample.runId = run.Id;
            sample.status = run.Status__c;
            sample.errorCode = sanitizeCode(run.ErrorCode__c);
            sample.lastActivity = run.LastActivityAt__c;
            sample.correlationKey = bounded(run.ExternalCorrelationKey__c, 255);
            report.samples.add(sample);
        }

        Boolean schedulerFailed = report.scheduler.misconfiguredJobNames.size() > 0;
        Boolean retentionSchedulerFailed = report.retentionScheduler.misconfiguredJobNames.size() > 0;
        Boolean pausedBreached = report.pausedRuns > 0 && report.oldestPausedAt != null && report.oldestPausedAt <= nowValue.addHours(-24);
        if (
            report.staleLeased > 0 ||
            report.dueRetentionRuns > 0 ||
            schedulerFailed ||
            retentionSchedulerFailed ||
            pausedBreached ||
            report.trustKeyProvisioned != true
        ) {
            report.status = 'Critical';
        } else if (
            report.scheduler.installed != true ||
            report.retentionScheduler.installed != true ||
            report.waitingUnknown > 0 ||
            report.pausedRuns > 0 ||
            report.dueOrphanCommands > 0 ||
            report.recentFailed > 0 ||
            report.lifecycleEventCreateAvailable != true ||
            report.recoveryCandidatesDeferredByCapacity > 0 ||
            report.recoveryCandidatesDeferredByInitiatingUser > 0 ||
            report.workerFailures > 0 ||
            report.expiredApprovals > 0 ||
            report.recoveryQuarantinedRuns > 0 ||
            report.failedExecutionIdentities > 0 ||
            sum(report.openIssuesByCode) > 0 ||
            report.issueSubscriberRunning != true ||
            report.metricsTruncated ||
            dailyLimitPressure
        ) {
            report.status = 'Warning';
        } else {
            report.status = 'Healthy';
        }
        addActions(report, schedulerFailed || retentionSchedulerFailed, dailyLimitPressure, asyncJobBudgetExceeded);
        return report;
    }

    /** Groups every problem into at most six admin actions, each with its numbers and where to fix it. */
    private static void addActions(HealthReport report, Boolean schedulerFailed, Boolean dailyLimitPressure, Boolean asyncJobBudgetExceeded) {
        HealthAction schedules = action(ACTION_SCHEDULES, 'Agent Core Health: Install Schedules, Run Recovery Now, or Run Retention Now');
        Integer missingSchedules = report.scheduler.missingJobNames.size() + report.retentionScheduler.missingJobNames.size();
        put(schedules, 'missingSchedules', missingSchedules);
        put(schedules, 'failedSchedules', report.scheduler.misconfiguredJobNames.size() + report.retentionScheduler.misconfiguredJobNames.size());
        put(schedules, 'trustKeyMissing', report.trustKeyProvisioned == true ? 0 : 1);
        put(schedules, 'staleLeasedCommands', report.staleLeased);
        put(schedules, 'dueOrphanCommands', report.dueOrphanCommands);
        put(schedules, 'dueRetentionRuns', report.dueRetentionRuns);
        schedules.reason = schedulerFailed ||
            missingSchedules > 0 ||
            report.trustKeyProvisioned != true
            ? 'Recovery or retention is not scheduled as expected, so stuck work is not picked up and data is not removed on time.'
            : 'Work is waiting for the next recovery or retention pass.';
        addIfNeeded(report, schedules);

        HealthAction identities = action(ACTION_IDENTITIES, 'Agent Execution Identity: Verify; Permission Sets: External Credential Principal Access');
        put(identities, 'failedExecutionIdentities', report.failedExecutionIdentities);
        Integer unneeded = 0;
        for (CredentialReview review : report.credentialReviews) {
            unneeded += review.unneededUserIds.size();
        }
        put(identities, 'unneededCredentialHolders', unneeded);
        identities.reason = report.failedExecutionIdentities > 0
            ? 'An execution identity failed Verify or changed since it passed, so its runs cannot start their steps.'
            : 'Some users can use an execution user\'s credential but hold no permission set that needs it. Remove their access.';
        addIfNeeded(report, identities);

        HealthAction paused = action(ACTION_PAUSED_RUNS, 'Agent Run: Operate, or the Rescue Agent Run and Cancel Agent Run Flow actions');
        Integer cancelOnly = report.purgedPausedRuns;
        Integer starterOnly = report.starterOnlyPausedRuns == null ? 0 : report.starterOnlyPausedRuns;
        put(paused, 'rescuablePausedRuns', Math.max(0, report.pausedRuns - cancelOnly - starterOnly));
        put(paused, 'starterOnlyPausedRuns', starterOnly);
        put(paused, 'cancelOnlyPausedRuns', cancelOnly);
        put(paused, 'initiatingUserRecoveryDeferred', report.recoveryCandidatesDeferredByInitiatingUser);
        paused.reason = 'Paused runs wait for an operator. Fix the cause and rescue them; ask the starter to continue their own runs of agents without an identity; cancel runs whose data was already removed.';
        addIfNeeded(report, paused);

        HealthAction unknown = action(ACTION_UNKNOWN_CALLS, 'Agent Run: Operate, or the Reconcile Agent Tool Call Flow action');
        put(unknown, 'unknownToolCalls', report.waitingUnknown);
        unknown.reason = 'A tool may have acted in another system but Core could not confirm it. Check that system, then record what happened.';
        addIfNeeded(report, unknown);

        HealthAction issues = action(ACTION_ISSUES, 'Agent Operational Issues tab, Open list view');
        for (String code : report.openIssuesByCode.keySet()) {
            put(issues, code, report.openIssuesByCode.get(code));
        }
        put(issues, 'issueSubscriberStopped', report.issueSubscriberRunning == true ? 0 : 1);
        put(issues, 'recoveryQuarantinedRuns', report.recoveryQuarantinedRuns);
        put(issues, 'lifecyclePublishFailures', report.lifecyclePublishFailures);
        put(issues, 'expiredApprovals', report.expiredApprovals);
        put(issues, 'lifecycleEventCreateMissing', report.lifecycleEventCreateAvailable == true ? 0 : 1);
        put(issues, 'trustVaultFieldExposed', report.trustVaultFieldExposureProtected == true ? 0 : 1);
        issues.reason = 'Failures and setup warnings need a person. Each open issue names its next step.';
        addIfNeeded(report, issues);

        HealthAction load = action(ACTION_LOAD, 'Agent schedules, start volume, and the Health lookback');
        put(load, 'dailyLimitPressure', dailyLimitPressure ? 1 : 0);
        put(load, 'recoveryCapacityDeferred', report.recoveryCandidatesDeferredByCapacity);
        put(load, 'recoveryTargetMissed', report.recoverySloMet == true ? 0 : 1);
        put(load, 'healthMetricsTruncated', report.metricsTruncated == true || report.deliverySampleTruncated == true ? 1 : 0);
        put(load, 'asyncJobBudgetExceeded', asyncJobBudgetExceeded ? 1 : 0);
        load.reason = 'Agent Core is near a platform limit or behind on recovery. Start fewer runs at once, lower agent budgets, or narrow the Health scope.';
        addIfNeeded(report, load);
    }

    private static HealthAction action(String code, String fixTarget) {
        HealthAction result = new HealthAction();
        result.code = code;
        result.fixTarget = fixTarget;
        return result;
    }

    private static void put(HealthAction target, String name, Integer value) {
        if (value != null && value > 0) {
            target.counts.put(name, value);
        }
    }

    private static void addIfNeeded(HealthReport report, HealthAction candidate) {
        if (!candidate.counts.isEmpty()) {
            report.actions.add(candidate);
        }
    }

    private static Integer sum(Map<String, Integer> counts) {
        Integer total = 0;
        for (Integer value : counts == null ? new List<Integer>() : counts.values()) {
            total += value == null ? 0 : value;
        }
        return total;
    }

    /** False only when the platform reports the issue subscriber as stopped or failing. */
    private static Boolean issueSubscriberRunning() {
        try {
            for (EventBusSubscriber subscriber : [
                SELECT Status
                FROM EventBusSubscriber
                WHERE Topic = 'AgentOperationalSignal__e' AND Name = 'AgentOperationalIssueSubscriber'
                WITH SYSTEM_MODE
                LIMIT 1
            ]) {
                return subscriber.Status != 'Suspended' && subscriber.Status != 'Error';
            }
        } catch (Exception unavailable) {
            // The subscriber view is unavailable to this context; nothing shows it stopped.
        }
        return true;
    }

    /**
     * For each active execution identity, who holds access to its credential's
     * principals, and which of them hold no permission set that hands work to
     * an execution user, own a Core schedule, or is the execution user itself.
     */
    private static List<CredentialReview> credentialReviews() {
        List<CredentialReview> reviews = new List<CredentialReview>();
        List<AgentExecutionIdentity__c> identities = [
            SELECT Id, PrincipalUser__c, LoopbackNamedCredential__c
            FROM AgentExecutionIdentity__c
            WHERE IsActive__c = TRUE
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC
            LIMIT 10
        ];
        if (identities.isEmpty()) {
            return reviews;
        }
        Set<Id> neededUserIds = new Set<Id>();
        for (PermissionSetAssignment assignment : [
            SELECT AssigneeId
            FROM PermissionSetAssignment
            WHERE PermissionSet.Name IN :CREDENTIAL_USER_PERMISSION_SETS AND Assignee.IsActive = TRUE
            WITH SYSTEM_MODE
            LIMIT :MAX_CREDENTIAL_HOLDERS
        ]) {
            neededUserIds.add(assignment.AssigneeId);
        }
        for (CronTrigger job : [SELECT CreatedById FROM CronTrigger WHERE CronJobDetail.Name LIKE 'Agent Core%' WITH SYSTEM_MODE LIMIT 50]) {
            neededUserIds.add(job.CreatedById);
        }
        for (AgentExecutionIdentity__c identity : identities) {
            CredentialReview review = new CredentialReview();
            review.executionIdentityId = identity.Id;
            review.namedCredential = identity.LoopbackNamedCredential__c;
            Set<Id> principalIds = credentialPrincipalIds(identity.LoopbackNamedCredential__c);
            review.available = principalIds != null;
            if (principalIds == null || principalIds.isEmpty()) {
                review.holders = 0;
                review.truncated = false;
                reviews.add(review);
                continue;
            }
            Set<Id> grantingSets = new Set<Id>();
            for (SetupEntityAccess access : [SELECT ParentId FROM SetupEntityAccess WHERE SetupEntityId IN :principalIds WITH SYSTEM_MODE]) {
                grantingSets.add(access.ParentId);
            }
            List<PermissionSetAssignment> holders = [
                SELECT AssigneeId, Assignee.Name
                FROM PermissionSetAssignment
                WHERE PermissionSetId IN :grantingSets AND Assignee.IsActive = TRUE
                WITH SYSTEM_MODE
                LIMIT :MAX_CREDENTIAL_HOLDERS
            ];
            review.truncated = holders.size() >= MAX_CREDENTIAL_HOLDERS;
            Set<Id> seen = new Set<Id>();
            for (PermissionSetAssignment holder : holders) {
                if (!seen.add(holder.AssigneeId)) {
                    continue;
                }
                if (!neededUserIds.contains(holder.AssigneeId) && holder.AssigneeId != identity.PrincipalUser__c) {
                    review.unneededUserIds.add(holder.AssigneeId);
                    if (review.unneededUserNames.size() < MAX_LISTED_UNNEEDED) {
                        review.unneededUserNames.add(holder.Assignee.Name);
                    }
                }
            }
            review.holders = seen.size();
            reviews.add(review);
        }
        return reviews;
    }

    /** The principals of the External Credentials a Named Credential uses; null when the platform cannot describe them. */
    private static Set<Id> credentialPrincipalIds(String namedCredential) {
        if (Test.isRunningTest() && credentialPrincipalIdsForTest != null) {
            return credentialPrincipalIdsForTest.get(namedCredential);
        }
        try {
            Set<Id> principalIds = new Set<Id>();
            ConnectApi.NamedCredential credential = ConnectApi.NamedCredentials.getNamedCredential(namedCredential);
            for (
                ConnectApi.ExternalCredential external : credential.externalCredentials == null
                    ? new List<ConnectApi.ExternalCredential>()
                    : credential.externalCredentials
            ) {
                ConnectApi.ExternalCredential described = ConnectApi.NamedCredentials.getExternalCredential(external.developerName);
                for (
                    ConnectApi.ExternalCredentialPrincipal principal : described.principals == null
                        ? new List<ConnectApi.ExternalCredentialPrincipal>()
                        : described.principals
                ) {
                    principalIds.add(principal.id);
                }
            }
            return principalIds;
        } catch (Exception unavailable) {
            return null;
        }
    }

    private static void addApprovalAndQuarantineMetrics(HealthReport report, Id definitionId, Datetime sinceValue, Datetime nowValue) {
        report.pendingApprovals = 0;
        report.expiredApprovals = 0;
        report.recoveryQuarantinedRuns = 0;
        try {
            List<AggregateResult> pending = definitionId == null
                ? [SELECT COUNT(Id) total, MIN(CreatedDate) oldest FROM AgentApproval__c WHERE Status__c = 'Pending' WITH USER_MODE]
                : [
                      SELECT COUNT(Id) total, MIN(CreatedDate) oldest
                      FROM AgentApproval__c
                      WHERE Status__c = 'Pending' AND AgentRun__r.AgentDefinition__c = :definitionId
                      WITH USER_MODE
                  ];
            report.pendingApprovals = (Integer) pending[0].get('total');
            report.oldestPendingApprovalAt = (Datetime) pending[0].get('oldest');
            report.expiredApprovals = definitionId == null
                ? [SELECT COUNT() FROM AgentApproval__c WHERE Status__c = 'Expired' AND ClosedAt__c >= :sinceValue WITH USER_MODE]
                : [
                      SELECT COUNT()
                      FROM AgentApproval__c
                      WHERE Status__c = 'Expired' AND ClosedAt__c >= :sinceValue AND AgentRun__r.AgentDefinition__c = :definitionId
                      WITH USER_MODE
                  ];
        } catch (QueryException approvalsInaccessible) {
            // Callers without Agent Approval access see zero, consistent with the caller-visible scope.
        }
        try {
            report.recoveryQuarantinedRuns = definitionId == null
                ? [SELECT COUNT() FROM AgentRun__c WHERE RecoveryCheckAt__c > :nowValue WITH USER_MODE]
                : [SELECT COUNT() FROM AgentRun__c WHERE RecoveryCheckAt__c > :nowValue AND AgentDefinition__c = :definitionId WITH USER_MODE];
        } catch (QueryException fieldInaccessible) {
            // Reported as zero for callers without the field, consistent with the caller-visible scope.
        }
    }

    private static SchedulerHealth schedulerHealth(List<String> expectedJobNames, List<String> expectedCronExpressions) {
        SchedulerHealth result = new SchedulerHealth();
        result.expectedJobCount = expectedJobNames.size();
        result.missingJobNames = new List<String>();
        result.misconfiguredJobNames = new List<String>();
        List<CronTrigger> jobs = [
            SELECT Id, State, NextFireTime, CronExpression, CronJobDetail.Name
            FROM CronTrigger
            WHERE CronJobDetail.Name IN :expectedJobNames AND State IN :ACTIVE_SCHEDULER_STATES
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        Map<String, CronTrigger> jobsByName = new Map<String, CronTrigger>();
        for (CronTrigger job : jobs) {
            String name = job.CronJobDetail.Name;
            Integer index = expectedJobNames.indexOf(name);
            if (index < 0) {
                continue;
            }
            if (
                jobsByName.containsKey(name) ||
                job.CronExpression != expectedCronExpressions[index] ||
                !new Set<String>{ 'WAITING', 'ACQUIRED' }.contains(job.State)
            ) {
                if (!result.misconfiguredJobNames.contains(name)) {
                    result.misconfiguredJobNames.add(name);
                }
            }
            jobsByName.put(name, job);
        }
        for (String expectedName : expectedJobNames) {
            if (!jobsByName.containsKey(expectedName)) {
                result.missingJobNames.add(expectedName);
            }
        }
        result.installedJobCount = jobsByName.size();
        result.installed = result.missingJobNames.isEmpty() && result.misconfiguredJobNames.isEmpty();
        result.state = jobs.isEmpty()
            ? 'NotInstalled'
            : (result.installed ? jobsByName.get(expectedJobNames[0]).State : result.misconfiguredJobNames.isEmpty() ? 'Incomplete' : 'Misconfigured');
        if (jobsByName.containsKey(expectedJobNames[0])) {
            result.jobId = jobsByName.get(expectedJobNames[0]).Id;
            result.nextFireTime = jobsByName.get(expectedJobNames[0]).NextFireTime;
        }
        return result;
    }

    /**
     * Probes a window's matched-row count within half the remaining query-row
     * headroom. When the window is larger, the aggregate is skipped and the
     * report is marked truncated instead of failing on the row governor.
     */
    private static Boolean affordable(String scope, Map<String, Object> binds, HealthReport report) {
        Integer headroom = (queryRowBudgetOverride != null ? queryRowBudgetOverride : Limits.getLimitQueryRows() - Limits.getQueryRows()) / 2;
        if (headroom <= 0) {
            report.metricsTruncated = true;
            return false;
        }
        Integer matched = Database.countQueryWithBinds('SELECT COUNT() FROM ' + scope + ' LIMIT ' + headroom, binds, AccessLevel.USER_MODE);
        if (matched >= headroom) {
            report.metricsTruncated = true;
            return false;
        }
        return true;
    }

    private static Map<String, Integer> statusCounts(Id definitionId, Datetime sinceValue, Boolean includeTerminal) {
        Map<String, Integer> result = new Map<String, Integer>();
        List<AggregateResult> activeRows;
        List<AggregateResult> terminalRows = new List<AggregateResult>();
        if (definitionId == null) {
            activeRows = [
                SELECT COUNT(Id) quantity
                FROM AgentRun__c
                WHERE Status__c = 'Running'
                WITH USER_MODE
            ];
            if (includeTerminal) {
                terminalRows = [
                    SELECT Status__c status, COUNT(Id) quantity
                    FROM AgentRun__c
                    WHERE Status__c IN ('Succeeded', 'Failed', 'Cancelled') AND CompletedAt__c >= :sinceValue
                    WITH USER_MODE
                    GROUP BY Status__c
                ];
            }
        } else {
            activeRows = [
                SELECT COUNT(Id) quantity
                FROM AgentRun__c
                WHERE AgentDefinition__c = :definitionId AND Status__c = 'Running'
                WITH USER_MODE
            ];
            if (includeTerminal) {
                terminalRows = [
                    SELECT Status__c status, COUNT(Id) quantity
                    FROM AgentRun__c
                    WHERE AgentDefinition__c = :definitionId AND Status__c IN ('Succeeded', 'Failed', 'Cancelled') AND CompletedAt__c >= :sinceValue
                    WITH USER_MODE
                    GROUP BY Status__c
                ];
            }
        }
        result.put('ACTIVE_RUNNING', aggregateCount(activeRows));
        for (AggregateResult row : terminalRows) {
            result.put((String) row.get('status'), Integer.valueOf(row.get('quantity')));
        }
        return result;
    }

    private class CommandBacklog {
        public Integer staleLeased;
        public Integer dueOrphans;
        public Datetime oldestStaleLeaseExpiry;
        public Datetime oldestDueOrphanAvailableAt;
        public Integer waitingUnknown;
        public Integer leasedWithWorkerJob;
        public Integer staleLeasedInactiveWorker;
        public Integer staleLeasedActiveWorker;
        public Integer staleLeasedMissingWorker;
        public Datetime oldestRecoverableLeaseExpiry;
        public Boolean deliverySampleTruncated;
        public Datetime oldestWorkerEnqueuedAt;
    }

    private static Integer initiatingUserRecoveryDeferred(Id definitionId, Datetime nowValue) {
        Id currentUserId = UserInfo.getUserId();
        List<AggregateResult> rows = definitionId == null
            ? [
                  SELECT COUNT(Id) quantity
                  FROM AgentCommand__c
                  WHERE
                      Status__c IN ('Pending', 'Retry Waiting')
                      AND AvailableAt__c <= :nowValue
                      AND AgentRun__r.Status__c = 'Running'
                      AND AgentRun__r.ExecutionIdentity__c = NULL
                      AND AgentRun__r.InitiatingUser__c != :currentUserId
                  WITH USER_MODE
              ]
            : [
                  SELECT COUNT(Id) quantity
                  FROM AgentCommand__c
                  WHERE
                      AgentRun__r.AgentDefinition__c = :definitionId
                      AND Status__c IN ('Pending', 'Retry Waiting')
                      AND AvailableAt__c <= :nowValue
                      AND AgentRun__r.Status__c = 'Running'
                      AND AgentRun__r.ExecutionIdentity__c = NULL
                      AND AgentRun__r.InitiatingUser__c != :currentUserId
                  WITH USER_MODE
              ];
        return aggregateCount(rows);
    }

    private class RetentionBacklog {
        public Integer dueRuns;
        public Datetime oldestPurgeAfter;
    }

    private class PausedBacklog {
        public Integer count;
        public Integer purged;
        public Integer starterOnly;
        public Datetime oldestActivity;
    }

    private static PausedBacklog pausedBacklog(Id definitionId) {
        List<AggregateResult> rows = definitionId == null
            ? [
                  SELECT COUNT(Id) quantity, MIN(LastActivityAt__c) oldest
                  FROM AgentRun__c
                  WHERE Status__c = 'Paused'
                  WITH USER_MODE
              ]
            : [
                  SELECT COUNT(Id) quantity, MIN(LastActivityAt__c) oldest
                  FROM AgentRun__c
                  WHERE AgentDefinition__c = :definitionId AND Status__c = 'Paused'
                  WITH USER_MODE
              ];
        PausedBacklog result = new PausedBacklog();
        result.count = aggregateCount(rows);
        result.oldestActivity = rows.isEmpty() ? null : (Datetime) rows[0].get('oldest');
        result.purged = result.count == 0
            ? 0
            : (definitionId == null
                  ? [SELECT COUNT() FROM AgentRun__c WHERE Status__c = 'Paused' AND PayloadPurgedAt__c != NULL WITH USER_MODE]
                  : [
                        SELECT COUNT()
                        FROM AgentRun__c
                        WHERE AgentDefinition__c = :definitionId AND Status__c = 'Paused' AND PayloadPurgedAt__c != NULL
                        WITH USER_MODE
                    ]);
        // Runs without an identity only their starter can continue; the caller's own runs stay rescuable.
        Id callerId = UserInfo.getUserId();
        result.starterOnly = result.count == 0
            ? 0
            : (definitionId == null
                  ? [
                        SELECT COUNT()
                        FROM AgentRun__c
                        WHERE Status__c = 'Paused' AND PayloadPurgedAt__c = NULL AND ExecutionIdentity__c = NULL AND InitiatingUser__c != :callerId
                        WITH USER_MODE
                    ]
                  : [
                        SELECT COUNT()
                        FROM AgentRun__c
                        WHERE
                            AgentDefinition__c = :definitionId
                            AND Status__c = 'Paused'
                            AND PayloadPurgedAt__c = NULL
                            AND ExecutionIdentity__c = NULL
                            AND InitiatingUser__c != :callerId
                        WITH USER_MODE
                    ]);
        return result;
    }

    /** Checks every profile and permission set, not only the caller's field access. */
    private static Boolean trustVaultFieldUngranted() {
        return !Schema.sObjectType.AgentTrustToken__c.fields.OriginalValue__c.isAccessible() &&
            [
                SELECT COUNT()
                FROM FieldPermissions
                WHERE SobjectType = 'AgentTrustToken__c' AND Field = 'AgentTrustToken__c.OriginalValue__c' AND PermissionsRead = TRUE
                WITH SYSTEM_MODE
            ] == 0;
    }

    private static RetentionBacklog retentionBacklog(Id definitionId, Datetime nowValue) {
        List<AggregateResult> rows = definitionId == null
            ? [
                  SELECT COUNT(Id) quantity, MIN(PurgeAfter__c) oldest
                  FROM AgentRun__c
                  WHERE Status__c IN ('Succeeded', 'Failed', 'Cancelled') AND PayloadPurgedAt__c = NULL AND PurgeAfter__c <= :nowValue
                  WITH USER_MODE
              ]
            : [
                  SELECT COUNT(Id) quantity, MIN(PurgeAfter__c) oldest
                  FROM AgentRun__c
                  WHERE
                      AgentDefinition__c = :definitionId
                      AND Status__c IN ('Succeeded', 'Failed', 'Cancelled')
                      AND PayloadPurgedAt__c = NULL
                      AND PurgeAfter__c <= :nowValue
                  WITH USER_MODE
              ];
        RetentionBacklog result = new RetentionBacklog();
        result.dueRuns = aggregateCount(rows);
        result.oldestPurgeAfter = rows.isEmpty() ? null : (Datetime) rows[0].get('oldest');
        return result;
    }

    private static CommandBacklog commandBacklog(Id definitionId, Datetime nowValue) {
        CommandBacklog result = new CommandBacklog();
        List<AggregateResult> staleRows;
        List<AggregateResult> orphanRows;
        List<AggregateResult> unknownRows;
        if (definitionId == null) {
            staleRows = [
                SELECT COUNT(Id) quantity, MIN(LeaseExpiresAt__c) oldest
                FROM AgentCommand__c
                WHERE Status__c = 'Leased' AND LeaseExpiresAt__c != NULL AND LeaseExpiresAt__c <= :nowValue
                WITH USER_MODE
            ];
            orphanRows = [
                SELECT COUNT(Id) quantity, MIN(AvailableAt__c) oldest
                FROM AgentCommand__c
                WHERE DispatchDueAt__c != NULL AND DispatchDueAt__c <= :nowValue AND AgentRun__r.Status__c = 'Running'
                WITH USER_MODE
            ];
            unknownRows = [
                SELECT COUNT(Id) quantity
                FROM AgentCommand__c
                WHERE Status__c = 'Unknown' AND AgentRun__r.Status__c IN ('Waiting', 'Paused')
                WITH USER_MODE
            ];
        } else {
            staleRows = [
                SELECT COUNT(Id) quantity, MIN(LeaseExpiresAt__c) oldest
                FROM AgentCommand__c
                WHERE AgentRun__r.AgentDefinition__c = :definitionId AND Status__c = 'Leased' AND LeaseExpiresAt__c != NULL AND LeaseExpiresAt__c <= :nowValue
                WITH USER_MODE
            ];
            orphanRows = [
                SELECT COUNT(Id) quantity, MIN(AvailableAt__c) oldest
                FROM AgentCommand__c
                WHERE
                    AgentRun__r.AgentDefinition__c = :definitionId
                    AND DispatchDueAt__c != NULL
                    AND DispatchDueAt__c <= :nowValue
                    AND AgentRun__r.Status__c = 'Running'
                WITH USER_MODE
            ];
            unknownRows = [
                SELECT COUNT(Id) quantity
                FROM AgentCommand__c
                WHERE AgentRun__r.AgentDefinition__c = :definitionId AND Status__c = 'Unknown' AND AgentRun__r.Status__c IN ('Waiting', 'Paused')
                WITH USER_MODE
            ];
        }
        result.staleLeased = aggregateCount(staleRows);
        result.dueOrphans = aggregateCount(orphanRows);
        result.oldestStaleLeaseExpiry = staleRows.isEmpty() ? null : (Datetime) staleRows[0].get('oldest');
        result.oldestDueOrphanAvailableAt = orphanRows.isEmpty() ? null : (Datetime) orphanRows[0].get('oldest');
        result.waitingUnknown = aggregateCount(unknownRows);
        List<AggregateResult> workerRows = definitionId == null
            ? [
                  SELECT COUNT(Id) quantity, MIN(WorkerEnqueuedAt__c) oldestEnqueued
                  FROM AgentCommand__c
                  WHERE Status__c = 'Leased' AND WorkerJobId__c != NULL
                  WITH USER_MODE
              ]
            : [
                  SELECT COUNT(Id) quantity, MIN(WorkerEnqueuedAt__c) oldestEnqueued
                  FROM AgentCommand__c
                  WHERE AgentRun__r.AgentDefinition__c = :definitionId AND Status__c = 'Leased' AND WorkerJobId__c != NULL
                  WITH USER_MODE
              ];
        List<AggregateResult> missingWorkerRows = definitionId == null
            ? [
                  SELECT COUNT(Id) quantity, MIN(LeaseExpiresAt__c) oldest
                  FROM AgentCommand__c
                  WHERE Status__c = 'Leased' AND LeaseExpiresAt__c != NULL AND LeaseExpiresAt__c <= :nowValue AND WorkerJobId__c = NULL
                  WITH USER_MODE
              ]
            : [
                  SELECT COUNT(Id) quantity, MIN(LeaseExpiresAt__c) oldest
                  FROM AgentCommand__c
                  WHERE
                      AgentRun__r.AgentDefinition__c = :definitionId
                      AND Status__c = 'Leased'
                      AND LeaseExpiresAt__c != NULL
                      AND LeaseExpiresAt__c <= :nowValue
                      AND WorkerJobId__c = NULL
                  WITH USER_MODE
              ];
        result.leasedWithWorkerJob = aggregateCount(workerRows);
        result.oldestWorkerEnqueuedAt = workerRows.isEmpty() ? null : (Datetime) workerRows[0].get('oldestEnqueued');
        result.staleLeasedMissingWorker = aggregateCount(missingWorkerRows);
        result.oldestRecoverableLeaseExpiry = missingWorkerRows.isEmpty() ? null : (Datetime) missingWorkerRows[0].get('oldest');
        List<AgentCommand__c> correlatedStale = definitionId == null
            ? [
                  SELECT Id, WorkerJobId__c, LeaseExpiresAt__c
                  FROM AgentCommand__c
                  WHERE Status__c = 'Leased' AND LeaseExpiresAt__c != NULL AND LeaseExpiresAt__c <= :nowValue AND WorkerJobId__c != NULL
                  WITH USER_MODE
                  ORDER BY LeaseExpiresAt__c ASC
                  LIMIT :MAX_DELIVERY_SAMPLE
              ]
            : [
                  SELECT Id, WorkerJobId__c, LeaseExpiresAt__c
                  FROM AgentCommand__c
                  WHERE
                      AgentRun__r.AgentDefinition__c = :definitionId
                      AND Status__c = 'Leased'
                      AND LeaseExpiresAt__c != NULL
                      AND LeaseExpiresAt__c <= :nowValue
                      AND WorkerJobId__c != NULL
                  WITH USER_MODE
                  ORDER BY LeaseExpiresAt__c ASC
                  LIMIT :MAX_DELIVERY_SAMPLE
              ];
        Map<Id, CommandDeliveryTracker.JobState> states = CommandDeliveryTracker.resolveCommands(correlatedStale);
        result.staleLeasedActiveWorker = 0;
        result.staleLeasedInactiveWorker = 0;
        for (AgentCommand__c command : correlatedStale) {
            if (states.get(command.Id) == CommandDeliveryTracker.JobState.Active) {
                result.staleLeasedActiveWorker++;
            } else {
                result.staleLeasedInactiveWorker++;
                if (result.oldestRecoverableLeaseExpiry == null || command.LeaseExpiresAt__c < result.oldestRecoverableLeaseExpiry) {
                    result.oldestRecoverableLeaseExpiry = command.LeaseExpiresAt__c;
                }
            }
        }
        Integer correlatedStaleCount = Math.max(0, result.staleLeased - result.staleLeasedMissingWorker);
        result.deliverySampleTruncated = correlatedStaleCount > correlatedStale.size();
        return result;
    }

    private static Map<String, Integer> deliveryAnomalyCounts(Id definitionId, Datetime sinceValue) {
        String queryText =
            'SELECT DeliveryAnomalyCode__c code, SUM(DeliveryAnomalyCount__c) quantity' +
            ' FROM AgentCommand__c' +
            ' WHERE DeliveryAnomalyCode__c != NULL AND LastDeliveryAnomalyAt__c >= :sinceValue';
        if (definitionId != null) {
            queryText += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        }
        queryText += ' GROUP BY DeliveryAnomalyCode__c';
        List<AggregateResult> rows = (List<AggregateResult>) Database.query(queryText, AccessLevel.USER_MODE);
        Map<String, Integer> result = new Map<String, Integer>();
        for (AggregateResult row : rows) {
            result.put((String) row.get('code'), integerValue(row.get('quantity')));
        }
        return result;
    }

    private static AggregateResult lifecyclePublishHealth(Id definitionId) {
        List<AggregateResult> rows = definitionId == null
            ? [
                  SELECT SUM(LifecyclePublishFailureCount__c) failures, COUNT(Id) failedRuns, MAX(LastLifecyclePublishFailureAt__c) lastFailure
                  FROM AgentRun__c
                  WHERE LifecyclePublishFailureCount__c > 0
                  WITH USER_MODE
              ]
            : [
                  SELECT SUM(LifecyclePublishFailureCount__c) failures, COUNT(Id) failedRuns, MAX(LastLifecyclePublishFailureAt__c) lastFailure
                  FROM AgentRun__c
                  WHERE AgentDefinition__c = :definitionId AND LifecyclePublishFailureCount__c > 0
                  WITH USER_MODE
              ];
        return rows[0];
    }

    private static void populateWindowMetrics(
        HealthReport report,
        Id definitionId,
        Datetime sinceValue,
        Boolean invocationsAffordable,
        Boolean eventsAffordable,
        Boolean completedRunsAffordable
    ) {
        report.modelCalls = 0;
        report.toolCalls = 0;
        report.retries = 0;
        report.totalTokens = 0;
        report.modelDurationMs = 0;
        report.toolDurationMs = 0;
        report.peakCpuTimeMs = 0;
        report.peakSoqlQueries = 0;
        report.peakDmlStatements = 0;
        report.waitEvents = 0;
        report.waitTimeouts = 0;
        String invocationQuery =
            'SELECT InvocationType__c type, COUNT(Id) attempts, SUM(TotalTokens__c) tokens, SUM(DurationMs__c) duration,' +
            ' MAX(CpuTimeMs__c) cpu, MAX(SoqlQueries__c) soql, MAX(DmlStatements__c) dml' +
            ' FROM AgentInvocation__c WHERE StartedAt__c >= :sinceValue';
        if (definitionId != null) {
            invocationQuery += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        }
        invocationQuery += ' GROUP BY InvocationType__c';
        for (
            AggregateResult row : invocationsAffordable
                ? (List<AggregateResult>) Database.query(invocationQuery, AccessLevel.USER_MODE)
                : new List<AggregateResult>()
        ) {
            String invocationType = (String) row.get('type');
            if (invocationType == 'Model') {
                report.modelCalls = longValue(row.get('attempts'));
                report.modelDurationMs = longValue(row.get('duration'));
            } else if (invocationType == 'Tool') {
                report.toolCalls = longValue(row.get('attempts'));
                report.toolDurationMs = longValue(row.get('duration'));
            }
            report.totalTokens += longValue(row.get('tokens'));
            report.peakCpuTimeMs = Math.max(report.peakCpuTimeMs, longValue(row.get('cpu')));
            report.peakSoqlQueries = Math.max(report.peakSoqlQueries, longValue(row.get('soql')));
            report.peakDmlStatements = Math.max(report.peakDmlStatements, longValue(row.get('dml')));
        }
        String eventQuery = 'SELECT EventType__c type, COUNT(Id) quantity FROM AgentEvent__c WHERE OccurredAt__c >= :sinceValue';
        if (definitionId != null) {
            eventQuery += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        }
        eventQuery += ' AND EventType__c IN (\'Command Retry Scheduled\', \'Run Waiting\', \'Tool Outcome Unknown\', \'Wait Expired\') GROUP BY EventType__c';
        for (AggregateResult row : eventsAffordable ? (List<AggregateResult>) Database.query(eventQuery, AccessLevel.USER_MODE) : new List<AggregateResult>()) {
            String eventType = (String) row.get('type');
            Integer quantity = integerValue(row.get('quantity'));
            if (eventType == AgentKernelModels.EVENT_COMMAND_RETRY_SCHEDULED) {
                report.retries = quantity;
            } else if (eventType == AgentKernelModels.EVENT_RUN_WAITING || eventType == AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN) {
                report.waitEvents += quantity;
            } else if (eventType == AgentKernelModels.EVENT_WAIT_EXPIRED) {
                report.waitTimeouts = quantity;
            }
        }
        List<AggregateResult> durations = !completedRunsAffordable
            ? new List<AggregateResult>()
            : definitionId == null
                  ? [SELECT AVG(RunDurationMs__c) duration FROM AgentRun__c WHERE CompletedAt__c >= :sinceValue WITH USER_MODE]
                  : [
                        SELECT AVG(RunDurationMs__c) duration
                        FROM AgentRun__c
                        WHERE AgentDefinition__c = :definitionId AND CompletedAt__c >= :sinceValue
                        WITH USER_MODE
                    ];
        report.averageRunDurationMs = durations.isEmpty() ? 0 : longValue(durations[0].get('duration'));
        if (!invocationsAffordable) {
            return;
        }
        String retryQuery =
            'SELECT ErrorCode__c code, COUNT(Id) quantity FROM AgentInvocation__c' +
            ' WHERE Outcome__c = \'Retry Requested\' AND StartedAt__c >= :sinceValue AND ErrorCode__c != NULL';
        if (definitionId != null) {
            retryQuery += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        }
        retryQuery += ' GROUP BY ErrorCode__c ORDER BY COUNT(Id) DESC LIMIT 20';
        for (AggregateResult row : (List<AggregateResult>) Database.query(retryQuery, AccessLevel.USER_MODE)) {
            ErrorCount reason = new ErrorCount();
            reason.errorCode = sanitizeCode((String) row.get('code'));
            reason.count = integerValue(row.get('quantity'));
            report.retryReasons.add(reason);
        }
        String toolQuery =
            'SELECT AgentCommand__r.ToolName__c name, COUNT(Id) quantity FROM AgentInvocation__c' +
            ' WHERE InvocationType__c = \'Tool\' AND Outcome__c IN (\'Failed\', \'Unknown\', \'Retry Requested\') AND StartedAt__c >= :sinceValue';
        if (definitionId != null) {
            toolQuery += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
        }
        toolQuery += ' GROUP BY AgentCommand__r.ToolName__c ORDER BY COUNT(Id) DESC LIMIT 20';
        Set<String> failureToolNames = new Set<String>();
        for (AggregateResult row : (List<AggregateResult>) Database.query(toolQuery, AccessLevel.USER_MODE)) {
            ErrorCount failure = new ErrorCount();
            failure.errorCode = sanitizeCode((String) row.get('name'));
            failure.count = integerValue(row.get('quantity'));
            report.toolFailures.add(failure);
            failureToolNames.add((String) row.get('name'));
        }
        if (!failureToolNames.isEmpty()) {
            String toolAttemptsQuery =
                'SELECT AgentCommand__r.ToolName__c name, COUNT(Id) quantity FROM AgentInvocation__c' +
                ' WHERE InvocationType__c = \'Tool\' AND StartedAt__c >= :sinceValue' +
                ' AND AgentCommand__r.ToolName__c IN :failureToolNames';
            if (definitionId != null) {
                toolAttemptsQuery += ' AND AgentRun__r.AgentDefinition__c = :definitionId';
            }
            toolAttemptsQuery += ' GROUP BY AgentCommand__r.ToolName__c';
            Map<String, Integer> failuresByTool = new Map<String, Integer>();
            for (ErrorCount failure : report.toolFailures) {
                failuresByTool.put(failure.errorCode, failure.count);
            }
            for (AggregateResult row : (List<AggregateResult>) Database.query(toolAttemptsQuery, AccessLevel.USER_MODE)) {
                ToolHealth tool = new ToolHealth();
                tool.toolName = sanitizeCode((String) row.get('name'));
                tool.attempts = integerValue(row.get('quantity'));
                tool.failures = failuresByTool.get(tool.toolName);
                tool.failureRatePercent = tool.attempts == 0 ? 0 : (Decimal.valueOf(tool.failures) * 100 / tool.attempts).setScale(2);
                report.toolMetrics.add(tool);
            }
        }
    }

    private static void populateAgentFailureRates(HealthReport report, Id definitionId, Datetime sinceValue) {
        String failureQuery =
            'SELECT AgentDefinition__c definition, COUNT(Id) quantity FROM AgentRun__c' + ' WHERE Status__c = \'Failed\' AND CompletedAt__c >= :sinceValue';
        if (definitionId != null) {
            failureQuery += ' AND AgentDefinition__c = :definitionId';
        }
        failureQuery += ' GROUP BY AgentDefinition__c ORDER BY COUNT(Id) DESC LIMIT 20';
        Map<Id, AgentHealth> byDefinition = new Map<Id, AgentHealth>();
        for (AggregateResult row : (List<AggregateResult>) Database.query(failureQuery, AccessLevel.USER_MODE)) {
            AgentHealth agent = new AgentHealth();
            agent.definitionId = (Id) row.get('definition');
            agent.failedRuns = integerValue(row.get('quantity'));
            byDefinition.put(agent.definitionId, agent);
        }
        if (byDefinition.isEmpty()) {
            return;
        }
        Set<Id> definitionIds = byDefinition.keySet();
        for (AggregateResult row : [
            SELECT AgentDefinition__c definition, COUNT(Id) quantity
            FROM AgentRun__c
            WHERE AgentDefinition__c IN :definitionIds AND CompletedAt__c >= :sinceValue AND Status__c IN ('Succeeded', 'Failed', 'Cancelled')
            WITH USER_MODE
            GROUP BY AgentDefinition__c
        ]) {
            AgentHealth agent = byDefinition.get((Id) row.get('definition'));
            agent.completedRuns = integerValue(row.get('quantity'));
            agent.failureRatePercent = agent.completedRuns == 0 ? 0 : (Decimal.valueOf(agent.failedRuns) * 100 / agent.completedRuns).setScale(2);
            report.agentMetrics.add(agent);
        }
    }
    private static List<AggregateResult> errors(Id definitionId, Datetime sinceValue) {
        return definitionId == null
            ? [
                  SELECT ErrorCode__c code, COUNT(Id) quantity
                  FROM AgentRun__c
                  WHERE ErrorCode__c != NULL AND (CompletedAt__c >= :sinceValue OR (Status__c = 'Paused' AND LastActivityAt__c >= :sinceValue))
                  WITH USER_MODE
                  GROUP BY ErrorCode__c
                  ORDER BY COUNT(Id) DESC, ErrorCode__c ASC
                  LIMIT 20
              ]
            : [
                  SELECT ErrorCode__c code, COUNT(Id) quantity
                  FROM AgentRun__c
                  WHERE
                      AgentDefinition__c = :definitionId
                      AND ErrorCode__c != NULL
                      AND (CompletedAt__c >= :sinceValue
                      OR (Status__c = 'Paused'
                      AND LastActivityAt__c >= :sinceValue))
                  WITH USER_MODE
                  GROUP BY ErrorCode__c
                  ORDER BY COUNT(Id) DESC, ErrorCode__c ASC
                  LIMIT 20
              ];
    }
    private static List<AgentRun__c> sampleRuns(Id definitionId, Integer sampleLimit) {
        return definitionId == null
            ? [
                  SELECT Id, Status__c, ErrorCode__c, LastActivityAt__c, ExternalCorrelationKey__c
                  FROM AgentRun__c
                  WITH USER_MODE
                  ORDER BY LastActivityAt__c DESC NULLS LAST, Id DESC
                  LIMIT :sampleLimit
              ]
            : [
                  SELECT Id, Status__c, ErrorCode__c, LastActivityAt__c, ExternalCorrelationKey__c
                  FROM AgentRun__c
                  WHERE AgentDefinition__c = :definitionId
                  WITH USER_MODE
                  ORDER BY LastActivityAt__c DESC NULLS LAST, Id DESC
                  LIMIT :sampleLimit
              ];
    }

    private static void increment(Map<String, Integer> values, String key) {
        values.put(key, count(values, key) + 1);
    }
    private static Integer aggregateCount(List<AggregateResult> rows) {
        return rows.isEmpty() || rows[0].get('quantity') == null ? 0 : Integer.valueOf(rows[0].get('quantity'));
    }
    private static Integer count(Map<String, Integer> values, String key) {
        return values.containsKey(key) ? values.get(key) : 0;
    }
    private static Long longValue(Object value) {
        return value == null ? 0 : Long.valueOf(String.valueOf(Decimal.valueOf(String.valueOf(value)).setScale(0)));
    }

    private static Integer integerValue(Object value) {
        return value == null ? 0 : Integer.valueOf(String.valueOf(value));
    }

    private static Decimal usedPercent(System.OrgLimit orgLimit) {
        if (orgLimit == null || orgLimit.getLimit() == null || orgLimit.getLimit() <= 0) {
            return 0;
        }
        return (Decimal.valueOf(orgLimit.getValue()) * 100 / orgLimit.getLimit()).setScale(2);
    }
    private static String sanitizeCode(String value) {
        if (String.isBlank(value))
            return null;
        String result = value.replaceAll('[^A-Za-z0-9_\\-]', '_');
        return bounded(result, 100);
    }
    private static String bounded(String value, Integer limitValue) {
        if (String.isBlank(value))
            return null;
        String result = value.replace('\r', ' ').replace('\n', ' ').trim();
        return result.length() > limitValue ? result.substring(0, limitValue) : result;
    }
}
