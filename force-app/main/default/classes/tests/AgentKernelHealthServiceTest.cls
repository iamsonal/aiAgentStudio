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

@IsTest
private class AgentKernelHealthServiceTest {
    @IsTest
    static void reportIsBoundedAndContainsNoRawPayloadProperties() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        for (Integer index = 0; index < 3; index++) {
            AgentKernelTestFactory.startRunWithoutDispatch(definition);
        }
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.lookbackHours = 24;
        request.sampleLimit = 2;
        request.definitionId = definition.Id;
        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);
        System.assertEquals('CallerVisible', report.scope);
        System.assertEquals(3, report.activeRunning);
        System.assertEquals(2, report.samples.size());
        System.assertEquals(0, report.dueOrphanCommands, 'Newly dispatched commands remain inside the orphan grace period.');
        String serialized = JSON.serialize(report).toLowerCase();
        System.assertEquals(false, serialized.contains('"input"'));
        System.assertEquals(false, serialized.contains('"output"'));
        System.assertEquals(false, serialized.contains('leasetoken'));
        System.assertEquals(false, serialized.contains('errormessage'));
    }

    @IsTest
    static void pausedRunRequiresOperatorAttention() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.pause(started.runId, started.revision, 'Planned maintenance.');
            AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
            request.definitionId = definition.Id;

            AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

            System.assertEquals(1, report.pausedRuns);
            System.assertNotEquals(null, report.oldestPausedAt);
            System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'rescuablePausedRuns') > 0);
            System.assertEquals('Warning', report.status);
        }
    }

    @IsTest
    static void pausedRunWithPurgedPayloadIsSentToCancelNotRescue() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.pause(started.runId, started.revision, 'Planned maintenance.');
            AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = started.runId, PayloadPurgedAt__c = System.now()));
            AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
            request.definitionId = definition.Id;

            AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

            System.assertEquals(1, report.purgedPausedRuns);
            System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'cancelOnlyPausedRuns') > 0);
            System.assert(
                !(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'rescuablePausedRuns') > 0),
                'A purged run cannot be rescued.'
            );
        }
    }

    @IsTest
    static void missingTrustKeyIsCriticalUntilCoreIsInstalled() {
        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        System.assertEquals(false, report.trustKeyProvisioned);
        System.assertEquals('Critical', report.status);
        System.assert(
            AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'missingSchedules') > 0 ||
                AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'trustKeyMissing') > 0
        );
        System.assertNotEquals(null, report.dailyAsyncApexUsedPercent);

        TrustKeyProvider.provision();
        System.assertEquals(true, AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest()).trustKeyProvisioned);
    }

    @IsTest
    static void requestBoundsAreEnforced() {
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.lookbackHours = 169;
        try {
            AgentKernelHealthService.getHealth(request);
            System.assert(false, 'Expected lookback validation.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('lookbackHours'));
        }
        request.lookbackHours = 24;
        request.sampleLimit = 101;
        try {
            AgentKernelHealthService.getHealth(request);
            System.assert(false, 'Expected sample validation.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('sampleLimit'));
        }
    }

    @IsTest
    static void reportIncludesBothRequiredSchedulers() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            CommandLeaseRecoveryScheduler.install();
            PayloadRetentionPurgeScheduler.install();

            AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());

            System.assertEquals(true, report.scheduler.installed);
            System.assertEquals(6, report.scheduler.installedJobCount);
            System.assertEquals(6, report.scheduler.expectedJobCount);
            System.assertEquals(0, report.scheduler.missingJobNames.size());
            System.assertEquals(true, report.retentionScheduler.installed);
            System.assert(
                !(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'missingSchedules') > 0 ||
                AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'trustKeyMissing') > 0)
            );
            // Jobs left installed run after the test, outside this runAs, where the purge permission is not visible.
            AgentCoreSchedules.remove();
        }
    }

    @IsTest
    static void partialRecoveryScheduleIsReportedAsIncomplete() {
        CommandLeaseRecoveryScheduler.remove();
        Id partialJobId = System.schedule('Agent Core - Lease Recovery - 10', '0 10 * * * ?', new CommandLeaseRecoveryScheduler());

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());

        System.assertEquals(false, report.scheduler.installed);
        System.assertEquals('Incomplete', report.scheduler.state);
        System.assertEquals(1, report.scheduler.installedJobCount);
        System.assertEquals(6, report.scheduler.expectedJobCount);
        System.assertEquals(5, report.scheduler.missingJobNames.size());
        System.assert(
            AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'missingSchedules') > 0 ||
                AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'trustKeyMissing') > 0
        );
        System.abortJob(partialJobId);
    }

    @IsTest
    static void agedPendingCommandIsReportedAsOrphaned() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        Datetime agedAt = System.now().addSeconds(-601);
        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = started.commandId, AvailableAt__c = agedAt));
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.definitionId = definition.Id;

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

        System.assertEquals(1, report.dueOrphanCommands);
        System.assertEquals(1, report.recoveryCandidateCount);
        System.assertEquals(600, report.recoverySloWindowSeconds);
        System.assertEquals(false, report.recoverySloMet);
        System.assert(
            AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'staleLeasedCommands') > 0 ||
                AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_SCHEDULES, 'dueOrphanCommands') > 0
        );
        System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_LOAD, 'recoveryTargetMissed') > 0);
    }

    @IsTest
    static void lookbackUsesAttemptTimestampInsteadOfRunActivity() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        Datetime oldStart = System.now().addHours(-30);
        Datetime recentStart = System.now().addMinutes(-5);
        AgentKernelTestFactory.insertRecords(
            new List<AgentInvocation__c>{ invocation(started.runId, command, 1, oldStart, 999), invocation(started.runId, command, 2, recentStart, 5) }
        );
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.definitionId = definition.Id;
        request.lookbackHours = 24;

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

        System.assertEquals(1, report.modelCalls);
        System.assertEquals(5, report.totalTokens);
        System.assertEquals(12, report.modelDurationMs);
        System.assertEquals(17, report.peakCpuTimeMs);
        System.assertEquals(4, report.peakSoqlQueries);
        System.assertEquals(2, report.peakDmlStatements);
    }

    @IsTest
    static void wrongRecoveryCadenceIsUnhealthyAndInstallerRepairsIt() {
        CommandLeaseRecoveryScheduler.remove();
        System.schedule('Agent Core - Lease Recovery - 10', '0 11 * * * ?', new CommandLeaseRecoveryScheduler());

        AgentKernelHealthService.HealthReport before = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        System.assertEquals(false, before.scheduler.installed);
        System.assertEquals('Misconfigured', before.scheduler.state);
        System.assert(before.scheduler.misconfiguredJobNames.contains('Agent Core - Lease Recovery - 10'));
        System.assert(AgentKernelTestFactory.healthCount(before, AgentKernelHealthService.ACTION_SCHEDULES, 'failedSchedules') > 0);

        CommandLeaseRecoveryScheduler.install();
        AgentKernelHealthService.HealthReport afterRepair = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        System.assertEquals(true, afterRepair.scheduler.installed);
        System.assertEquals(0, afterRepair.scheduler.misconfiguredJobNames.size());
    }

    @IsTest
    static void toolFailureRateUsesAllInWindowAttempts() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c toolCommand = AgentKernelTestFactory.insertToolCommand(started.runId, started.revision, 'health_tool', 'Pending');
        AgentInvocation__c failed = invocation(started.runId, toolCommand, 1, System.now().addMinutes(-2), 3);
        failed.InvocationType__c = 'Tool';
        failed.Outcome__c = 'Failed';
        AgentInvocation__c succeeded = invocation(started.runId, toolCommand, 2, System.now().addMinutes(-1), 4);
        succeeded.InvocationType__c = 'Tool';
        AgentKernelTestFactory.insertRecords(new List<AgentInvocation__c>{ failed, succeeded });
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.definitionId = definition.Id;

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

        System.assertEquals(2, report.toolCalls);
        System.assertEquals(1, report.toolMetrics.size());
        System.assertEquals('health_tool', report.toolMetrics[0].toolName);
        System.assertEquals(2, report.toolMetrics[0].attempts);
        System.assertEquals(1, report.toolMetrics[0].failures);
        System.assertEquals(50, report.toolMetrics[0].failureRatePercent);
    }

    @IsTest
    static void terminalFailureRateUsesCompletedRunsInWindow() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.updateRecord(
            new AgentRun__c(
                Id = started.runId,
                Status__c = AgentKernelModels.RUN_STATUS_FAILED,
                Revision__c = started.revision + 1,
                CompletedAt__c = System.now(),
                ErrorCode__c = 'TEST_FAILURE'
            )
        );
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.definitionId = definition.Id;

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(request);

        System.assertEquals(1, report.recentFailed);
        System.assertEquals(100, report.recentFailureRatePercent);
        System.assertEquals(1, report.agentMetrics.size());
        System.assertEquals(definition.Id, report.agentMetrics[0].definitionId);
        System.assertEquals(1, report.agentMetrics[0].completedRuns);
        System.assertEquals(1, report.agentMetrics[0].failedRuns);
    }

    private static AgentInvocation__c invocation(Id runId, AgentCommand__c command, Integer attempt, Datetime startedAt, Integer tokens) {
        return new AgentInvocation__c(
            AgentRun__c = runId,
            AgentCommand__c = command.Id,
            InvocationKey__c = String.valueOf(command.Id) + ':' + attempt,
            AttemptNumber__c = attempt,
            CommandRevision__c = command.ExpectedRunRevision__c,
            InvocationType__c = 'Model',
            Outcome__c = 'Succeeded',
            OperationKey__c = command.OperationKey__c,
            StartedAt__c = startedAt,
            CompletedAt__c = startedAt.addSeconds(1),
            PayloadProtectionMode__c = 'Redacted',
            TotalTokens__c = tokens,
            DurationMs__c = 12,
            CpuTimeMs__c = 17,
            SoqlQueries__c = 4,
            DmlStatements__c = 2
        );
    }

    @IsTest
    static void pausedInitiatingUserRunsOfOthersAreStarterOnly() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        AgentDefinition__c definition;
        System.runAs(AgentKernelTestFactory.self()) {
            definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.pause(started.runId, started.revision, 'Planned maintenance.');
            insert new AgentRun__Share(
                ParentId = started.runId,
                UserOrGroupId = otherOperator().Id,
                AccessLevel = 'Read',
                RowCause = Schema.AgentRun__Share.RowCause.Manual
            );
        }
        AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
        request.definitionId = definition.Id;

        AgentKernelHealthService.HealthReport mine = AgentKernelHealthService.getHealth(request);
        AgentKernelHealthService.HealthReport theirs;
        System.runAs(otherOperator()) {
            theirs = AgentKernelHealthService.getHealth(request);
        }

        System.assertEquals(1, AgentKernelTestFactory.healthCount(mine, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'rescuablePausedRuns'));
        System.assertEquals(1, AgentKernelTestFactory.healthCount(theirs, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'starterOnlyPausedRuns'));
        System.assertEquals(0, AgentKernelTestFactory.healthCount(theirs, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'rescuablePausedRuns'));
    }

    @IsTest
    static void openIssuesAppearAsOneAction() {
        AgentOperationalIssues.record(
            new List<AgentOperationalSignal__e>{
                AgentOperationsLog.event('FLOW_START_LOST', null, null, 'Agent a; anchor none'),
                AgentOperationsLog.event('FLOW_START_LOST', null, null, 'Agent b; anchor none')
            }
        );
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        AgentKernelHealthService.HealthReport report;
        System.runAs(AgentKernelTestFactory.self()) {
            report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        }

        System.assertEquals(2, report.openIssuesByCode.get('FLOW_START_LOST'));
        System.assertEquals(2, AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_ISSUES, 'FLOW_START_LOST'));
        System.assert(report.actions.size() <= 6, 'Health shows at most six actions.');
    }

    @IsTest
    static void credentialReviewListsHoldersWhoNeedNoAccess() {
        User idle = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.TRUST_RESOLVER });
        User runner = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents', AgentKernelTestFactory.TRUST_RESOLVER });
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.serviceUser(AgentKernelTestFactory.servicePrincipalUser().Id);
        // Access to the TrustService class stands in for credential principal access: both are SetupEntityAccess grants.
        Id grantedEntity = [SELECT Id FROM ApexClass WHERE Name = 'TrustService' WITH SYSTEM_MODE LIMIT 1].Id;
        AgentKernelHealthService.credentialPrincipalIdsForTest = new Map<String, Set<Id>>{
            AgentKernelTestFactory.TEST_LOOPBACK => new Set<Id>{ grantedEntity }
        };
        User operator = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.OPERATOR });

        AgentKernelHealthService.HealthReport report;
        System.runAs(operator) {
            report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        }

        AgentKernelHealthService.CredentialReview review;
        for (AgentKernelHealthService.CredentialReview candidate : report.credentialReviews) {
            if (candidate.executionIdentityId == identity.Id) {
                review = candidate;
            }
        }
        System.assertNotEquals(null, review);
        System.assert(review.unneededUserIds.contains(idle.Id), 'A holder with no run, decide, relay, or operate permission set needs no access.');
        System.assert(!review.unneededUserIds.contains(runner.Id), 'People who start runs need the credential.');
        System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_IDENTITIES, 'unneededCredentialHolders') > 0);
    }

    @IsTest
    static void personWithoutOperatorSeesNoCredentialReview() {
        AgentKernelTestFactory.serviceUser(AgentKernelTestFactory.servicePrincipalUser().Id);
        User runner = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        AgentKernelHealthService.HealthReport report;
        System.runAs(runner) {
            report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        }
        System.assert(report.credentialReviews.isEmpty(), 'Only operators and admins see who holds credential access.');
    }

    private static User cachedOtherOperator;

    private static User otherOperator() {
        if (cachedOtherOperator == null) {
            cachedOtherOperator = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.OPERATOR });
        }
        return cachedOtherOperator;
    }
}
