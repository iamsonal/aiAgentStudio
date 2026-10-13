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
private class CoreReviewRemediationTest {
    @IsTest
    static void operationKeysFollowTheRunCommandSequence() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'sequence_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        System.assertEquals(started.runId + ':1:Model', started.operationKey);

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', tool.DeveloperName__c)
            )
        );

        AgentRun__c run = [SELECT CommandSequence__c, CurrentCommand__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE];
        System.assertEquals(2, run.CommandSequence__c);
        System.assertEquals(started.runId + ':2:Tool:sequence_tool', AgentKernelTestFactory.getCommand(run.CurrentCommand__c).OperationKey__c);
    }

    @IsTest
    static void redactedFinalOutputKeepsPlainTextAnswers() {
        PayloadProtectionService.Policy policy = new PayloadProtectionService.Policy();
        policy.mode = PayloadProtectionService.MODE_REDACTED;
        policy.retainedCharacters = 1000;
        policy.sensitiveKeys = new Set<String>{ 'secret' };

        System.assertEquals('Your case is resolved.', PayloadProtectionService.protectFinalOutput('Your case is resolved.', policy).protectedPayload);
        System.assert(!PayloadProtectionService.protectFinalOutput('{"secret":"value"}', policy).protectedPayload.contains('value'));
    }

    @IsTest
    static void unreadableAnchorIsRejectedAtStart() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        Account anchor = new Account(Name = 'Deleted anchor');
        insert anchor;
        delete anchor;
        try {
            AgentKernelTestFactory.start(definition.Id, '{"request":"test"}', anchor.Id);
            System.assert(false, 'An anchor the initiating user cannot read must be rejected.');
        } catch (AgentKernelException.AuthorizationException expected) {
            System.assert(expected.getMessage().contains('initiating user'));
        }

        Id servicePrincipalId = [SELECT Id FROM User WHERE IsActive = TRUE AND Id != :UserInfo.getUserId() LIMIT 1].Id;
        AgentKernelTestFactory.useDelegatedPrincipal(definition, servicePrincipalId);
        try {
            AgentKernelTestFactory.start(definition.Id, '{"request":"test"}', anchor.Id);
            System.assert(false, 'A Delegated Principal run must still require the initiator to read the anchor.');
        } catch (AgentKernelException.AuthorizationException expected) {
            System.assert(expected.getMessage().contains('initiating user'), expected.getMessage());
        }
        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }

    @IsTest
    static void failedWorkerRecoveryRequiresTheCurrentLeaseToken() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'failed-worker-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);

        CommandLeaseRecoveryService.recoverFailedWorker(command.Id, 'stale-lease');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(command.Id).Status__c);

        Test.startTest();
        CommandDeliveryTracker.recordAnomaly(command.Id, 'WORKER_FAILED');
        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverFailedWorker(command.Id, 'failed-worker-lease');
        Test.stopTest();

        AgentCommand__c recovered = [SELECT Status__c, LeaseToken__c, DeliveryAnomalyCode__c FROM AgentCommand__c WHERE Id = :command.Id WITH SYSTEM_MODE];
        System.assertEquals(1, result.requeued);
        System.assertNotEquals(AgentKernelModels.COMMAND_STATUS_LEASED, recovered.Status__c);
        System.assertNotEquals('failed-worker-lease', recovered.LeaseToken__c);
        System.assertEquals('WORKER_FAILED', recovered.DeliveryAnomalyCode__c);
    }

    @IsTest
    static void trustFingerprintsAreKeyedAndClearedOnPurge() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            Id runId = AgentKernelTestFactory.start(definition.Id, 'Contact alice@example.com').runId;
            AgentTrustToken__c mapping = [SELECT Id, ValueFingerprint__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE LIMIT 1];
            String unkeyed = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(runId) + '|Email|alice@example.com')));
            System.assertNotEquals(null, mapping.ValueFingerprint__c);
            System.assertNotEquals(unkeyed, mapping.ValueFingerprint__c);
            System.assert(!String.isBlank(AgentTrustKey__c.getOrgDefaults().Key__c), 'Installing Core provisions the org key.');

            TrustService.purgeBounded(new Set<Id>{ runId }, 2000);

            mapping = [SELECT OriginalValue__c, ValueFingerprint__c, PurgedAt__c FROM AgentTrustToken__c WHERE Id = :mapping.Id WITH SYSTEM_MODE];
            System.assertEquals(null, mapping.OriginalValue__c);
            System.assertEquals(null, mapping.ValueFingerprint__c);
            System.assertNotEquals(null, mapping.PurgedAt__c);
        }
    }

    @IsTest
    static void sandboxPostCopyRotatesKeyAndPurgesVault() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        Id runId = AgentKernelTestFactory.start(definition.Id, 'Contact alice@example.com').runId;
        String copiedKey = [SELECT Key__c FROM AgentTrustKey__c WITH SYSTEM_MODE LIMIT 1].Key__c;

        Test.startTest();
        Test.testSandboxPostCopyScript(new AgentCoreSandboxPostCopy(), UserInfo.getOrganizationId(), UserInfo.getOrganizationId(), 'copy');
        Test.stopTest();

        List<AgentTrustKey__c> keys = [SELECT Key__c FROM AgentTrustKey__c WITH SYSTEM_MODE];
        System.assertEquals(1, keys.size(), 'The post-copy class provisions a replacement key.');
        System.assertNotEquals(copiedKey, keys[0].Key__c, 'The sandbox must not keep the production key.');
        System.assertEquals(0, [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :runId AND PurgedAt__c = NULL WITH SYSTEM_MODE]);
    }

    @IsTest
    static void copiedVaultIsUnresolvableBeforeItsPurgeRuns() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        Id runId = AgentKernelTestFactory.start(definition.Id, 'Contact alice@example.com').runId;
        AgentTrustToken__c copied = [SELECT Id, Token__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE LIMIT 1];
        TrustService.validateTokens(runId, copied.Token__c);

        // The copy predates the sandbox; post-copy then replaces the key.
        Test.setCreatedDate(copied.Id, System.now().addDays(-1));
        TrustKeyProvider.rotate();

        try {
            TrustService.validateTokens(runId, copied.Token__c);
            System.assert(false, 'A mapping from before the rotation must not resolve while its purge is pending.');
        } catch (TrustService.TokenUseException expected) {
            System.assertEquals(1, [SELECT COUNT() FROM AgentTrustToken__c WHERE Id = :copied.Id AND PurgedAt__c = NULL WITH SYSTEM_MODE]);
        }
    }

    @IsTest
    static void requesterMayApproveTheirOwnRun() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(AgentKernelTestFactory.self()) {
            ApprovalFixture allowed = waitingApproval('{}', UserInfo.getUserId());
            AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(allowed.approvalId, true, null));
            AgentEvent__c resumed = [
                SELECT Payload__c
                FROM AgentEvent__c
                WHERE AgentRun__c = :allowed.runId AND EventType__c = :AgentKernelModels.EVENT_RUN_RESUMED
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            System.assert(resumed.Payload__c.contains(UserInfo.getUserId()), 'The resume event must record the approver.');
            System.assert(resumed.Payload__c.contains(String.valueOf(allowed.approvalId)), 'The resume event must name the approval.');
        }
    }

    @IsTest
    static void serviceUserCannotDecideOrRelayItsOwnApprovals() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = createReviewTool(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        Id approverId = AgentKernelTestFactory.approverUser();
        ApprovalFixture fixture = waitingApproval(tool, started, '{}', approverId);
        System.assertEquals(identity.PrincipalUser__c, AgentKernelTestFactory.getRun(fixture.runId).ResolvedPrincipalUser__c);

        System.runAs(AgentKernelTestFactory.principal(identity)) {
            try {
                AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null));
                System.assert(false, 'The execution user must not decide for itself.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('execution user'));
            }
            AgentKernelModels.ApprovalDecision relayed = AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null);
            relayed.deciderId = approverId;
            try {
                AgentKernel.decideApproval(relayed);
                System.assert(false, 'The execution user must not relay a decision for its own run.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('execution user'));
            }
        }

        System.runAs(new User(Id = approverId)) {
            AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null));
        }
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(fixture.commandId).Status__c);
        AgentApproval__c decided = AgentKernelTestFactory.pendingApproval(fixture.runId);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, decided.Status__c);
        System.assertEquals(approverId, decided.DecidedBy__c);

        System.runAs(new User(Id = approverId)) {
            System.assertEquals(null, AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null)));
        }
    }

    @IsTest
    static void onlyTheAssigneeCanDecide() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(AgentKernelTestFactory.self()) {
            Id approverId = AgentKernelTestFactory.approverUser();
            ApprovalFixture fixture = waitingApproval('{}', approverId);
            try {
                AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null));
                System.assert(false, 'A user who is not the assignee must not decide.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('assigned approver'));
            }
            System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, AgentKernelTestFactory.pendingApproval(fixture.runId).Status__c);
        }
    }

    @IsTest
    static void reviewerCanResolveWaitingApprovalInputWithAudit() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = createReviewTool(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        TrustService.ProtectionContext context = TrustService.open(started.runId);
        String protectedInput = TrustService.protect(context, '{"to":"alice@example.com"}');
        TrustService.save(context);
        System.assert(TrustService.containsToken(protectedInput));
        ApprovalFixture fixture = waitingApproval(tool, started, protectedInput, UserInfo.getUserId());

        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(AgentKernelTestFactory.self()) {
            System.assertEquals('{"to":"alice@example.com"}', AgentRunService.resolveApprovalInput(fixture.approvalId));
        }
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM AgentEvent__c
                WHERE AgentRun__c = :fixture.runId AND EventType__c = :AgentKernelModels.EVENT_TRUST_APPROVAL_INPUT_RESOLVED
                WITH SYSTEM_MODE
            ]
        );

        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                AgentRunService.resolveApprovalInput(fixture.approvalId);
                System.assert(false, 'Resolution requires Human Decision authority.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('not authorized'));
            }
        }
    }

    @IsTest
    static void cancellationAndExpiryCloseTheApproval() {
        ApprovalFixture cancelled = waitingApproval('{}', UserInfo.getUserId());
        AgentRun__c run = AgentKernelTestFactory.getRun(cancelled.runId);
        AgentKernel.cancel(run.Id, run.Revision__c, 'No longer needed.');
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_CANCELLED, AgentKernelTestFactory.pendingApproval(run.Id).Status__c);

        ApprovalFixture expired = waitingApproval('{}', UserInfo.getUserId());
        run = AgentKernelTestFactory.getRun(expired.runId);
        AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = run.Id, WaitExpiresAt__c = System.now().addMinutes(-1)));
        AgentKernel.IntentionalWaitExpiryResult transition = AgentKernelRecovery.expireIntentionalWaits(
            new Map<Id, Decimal>{ run.Id => run.Revision__c },
            System.now()
        );
        System.assertEquals(run.Revision__c, transition.approvalDenials.get(run.Id), 'Deny and Continue approvals expire one run at a time.');
        Id modelCommandId = AgentKernel.expireApprovalWithDenial(run.Id, run.Revision__c);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_EXPIRED, AgentKernelTestFactory.pendingApproval(run.Id).Status__c);
        System.assertEquals(AgentKernelModels.ERROR_TOOL_APPROVAL_EXPIRED, AgentKernelTestFactory.getCommand(expired.commandId).ErrorCode__c);
        System.assert(AgentKernelTestFactory.getCommand(modelCommandId).Input__c.contains(AgentKernelModels.ERROR_TOOL_APPROVAL_EXPIRED));
    }

    @IsTest
    static void approvalsChangeOnlyThroughCore() {
        ApprovalFixture fixture = waitingApproval('{}', UserInfo.getUserId());
        Database.SaveResult edited = Database.update(new AgentApproval__c(Id = fixture.approvalId, Status__c = 'Approved'), false);
        System.assertEquals(false, edited.isSuccess());
        Database.DeleteResult deleted = Database.delete(fixture.approvalId, false);
        System.assertEquals(false, deleted.isSuccess());
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, AgentKernelTestFactory.pendingApproval(fixture.runId).Status__c);
    }

    @IsTest
    static void reassignmentNeedsAnOwnerWhoCanDecide() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(AgentKernelTestFactory.self()) {
            Id approverId = AgentKernelTestFactory.approverUser();
            User bystander = AgentKernelTestFactory.userWith(new List<String>());
            ApprovalFixture fixture = waitingApproval('{}', UserInfo.getUserId());

            Database.SaveResult rejected = Database.update(new AgentApproval__c(Id = fixture.approvalId, OwnerId = bystander.Id), false);
            System.assertEquals(false, rejected.isSuccess(), 'An approval never waits for someone who cannot decide it.');
            System.assert(rejected.getErrors()[0].getMessage().contains('Human Decision'), rejected.getErrors()[0].getMessage());

            Database.SaveResult accepted = Database.update(new AgentApproval__c(Id = fixture.approvalId, OwnerId = approverId), false);
            System.assertEquals(true, accepted.isSuccess(), 'An eligible approver can take the approval over.');
            System.assertEquals(approverId, [SELECT OwnerId FROM AgentApproval__c WHERE Id = :fixture.approvalId WITH SYSTEM_MODE].OwnerId);
        }
    }

    @IsTest
    static void healthMarksWindowMetricsTruncatedInsteadOfExhaustingQueryRows() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelHealthService.queryRowBudgetOverride = 1;

        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());

        System.assertEquals(true, report.metricsTruncated);
        System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_LOAD, 'healthMetricsTruncated') > 0);
    }

    @IsTest
    static void dispatchSentinelTracksOnlyDispatchableCommands() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = [SELECT AvailableAt__c, DispatchDueAt__c FROM AgentCommand__c WHERE Id = :started.commandId WITH SYSTEM_MODE];
        System.assertEquals(command.AvailableAt__c.addSeconds(CommandLeaseRecoveryService.ORPHAN_GRACE_SECONDS), command.DispatchDueAt__c);

        AgentKernelTestFactory.updateRecord(
            new AgentCommand__c(
                Id = started.commandId,
                Status__c = AgentKernelModels.COMMAND_STATUS_LEASED,
                LeaseToken__c = 'sentinel-lease',
                LeaseExpiresAt__c = System.now().addMinutes(5),
                AttemptNumber__c = 1
            )
        );
        System.assertEquals(null, [SELECT DispatchDueAt__c FROM AgentCommand__c WHERE Id = :started.commandId WITH SYSTEM_MODE].DispatchDueAt__c);
    }

    @IsTest
    static void humanResponsesStayInLaterTranscriptsUnderTypedDefinitionLimits() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ModelTimeoutSeconds__c = 30;
        definition.TranscriptTurnLimit__c = 5;
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        Database.insert(
            new AgentCommand__c(
                AgentRun__c = started.runId,
                CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                InputSource__c = AgentKernelModels.INPUT_SOURCE_HUMAN_RESPONSE,
                ExpectedRunRevision__c = started.revision,
                OperationKey__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                Input__c = '{"answer":"blue"}',
                AvailableAt__c = System.now(),
                AttemptNumber__c = 1
            ),
            AccessLevel.SYSTEM_MODE
        );
        AgentCommand__c current = AgentKernelTestFactory.getCommand(started.commandId);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(
            started.runId,
            current.Id,
            started.revision,
            current.OperationKey__c,
            current.DispatchToken__c
        );
        System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
        current = AgentKernelTestFactory.getCommand(current.Id);

        new ModelCommandQueueable(started.runId, current.Id, current.ExpectedRunRevision__c, current.OperationKey__c, current.LeaseToken__c).execute(null);

        System.assertEquals(2, KernelTestModelProvider.lastTranscript.size());
        System.assertEquals(AgentKernelModels.TRANSCRIPT_ORIGINAL_INPUT, KernelTestModelProvider.lastTranscript[0].type);
        System.assertEquals(AgentKernelModels.TRANSCRIPT_USER_INPUT, KernelTestModelProvider.lastTranscript[1].type);
        System.assert(KernelTestModelProvider.lastTranscript[1].content.contains('blue'));
        Map<String, Object> providerRequest = (Map<String, Object>) JSON.deserializeUntyped(KernelTestModelProvider.lastRequestJson);
        System.assertEquals(30, providerRequest.get('timeoutSeconds'));
    }

    @IsTest
    static void deferredDispatchHopsOrParksByIdentity() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        CommandLeaseService.Result deferred = new CommandLeaseService.Result();
        deferred.outcome = CommandLeaseService.Outcome.Deferred;
        deferred.run = AgentKernelTestFactory.getRun(started.runId);
        deferred.command = AgentKernelTestFactory.getCommand(started.commandId);
        deferred.delayMinutes = 3;

        Test.startTest();
        Id hopJobId = CommandDispatcher.dispatchLeaseResult(deferred, false);
        Test.stopTest();
        System.assertNotEquals(null, hopJobId, 'An initiating-user deferral must hop through a delayed lease Queueable.');

        deferred.delayMinutes = CommandDispatcher.MAXIMUM_QUEUEABLE_DELAY_MINUTES + 20;
        deferred.run.ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId();
        System.assertEquals(null, CommandDispatcher.dispatchLeaseResult(deferred, false), 'Long delegated deferrals park for recovery.');
        System.assertEquals(null, CommandDispatcher.dispatchLeaseResult(null, false));
    }

    @IsTest
    static void recordRetentionDeletesPurgedTerminalRunsOnly() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy policy = AgentKernelTestFactory.executionPolicyOverride();
            policy.payloadRetentionDays = 0;
            policy.recordRetentionDays = 0;
            AgentKernelTestFactory.configureExecutionPolicy(policy);
            AgentKernelModels.StartResult expired = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.StartResult active = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernel.cancel(expired.runId, expired.revision, 'Finished for retention.');
            System.assertNotEquals(null, [SELECT DeleteAfter__c FROM AgentRun__c WHERE Id = :expired.runId WITH SYSTEM_MODE].DeleteAfter__c);
            policy.recordRetentionDays = 30;
            AgentKernelTestFactory.configureExecutionPolicy(policy);
            AgentRun__c activeRun = [SELECT Id FROM AgentRun__c WHERE Id = :active.runId WITH SYSTEM_MODE];
            try {
                Database.delete(activeRun, AccessLevel.SYSTEM_MODE);
                System.assert(false, 'Runs must not be deleted outside the retention job.');
            } catch (DmlException expected) {
                System.assert(expected.getMessage().contains('record retention job'));
            }

            PayloadRetentionPurgeService.purge(10);
            PayloadRetentionPurgeService.DeletionResult result = PayloadRetentionPurgeService.deleteExpiredRecords(10);

            System.assertEquals(1, result.runsDeleted);
            System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE Id = :expired.runId WITH SYSTEM_MODE]);
            System.assertEquals(0, [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :expired.runId WITH SYSTEM_MODE]);
            System.assertEquals(1, [SELECT COUNT() FROM AgentRun__c WHERE Id = :active.runId WITH SYSTEM_MODE]);
        }
    }

    @IsTest
    static void trustTokenCeilingAndRecordRetentionAreValidated() {
        AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
        policy.maxTrustTokensPerRun = AgentExecutionPolicyService.MAX_TRUST_TOKENS_PER_RUN_CEILING + 1;
        assertInvalidPolicy(policy, 'trust tokens');
        policy = AgentExecutionPolicyService.defaults();
        policy.recordRetentionDays = policy.payloadRetentionDays - 1;
        assertInvalidPolicy(policy, 'Record retention');

        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        policy = AgentKernelTestFactory.executionPolicyOverride();
        policy.maxTrustTokensPerRun = 1;
        AgentKernelTestFactory.configureExecutionPolicy(policy);
        Id runId = AgentKernelTestFactory.startRunWithoutDispatch(definition).runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        TrustService.protect(context, 'alice@example.com');
        try {
            TrustService.protect(context, 'bob@example.com');
            System.assert(false, 'Protection must fail closed at the configured ceiling.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('per-run limit'));
        }
    }

    private static void assertInvalidPolicy(AgentExecutionPolicyService.Policy policy, String expectedMessage) {
        try {
            AgentExecutionPolicyService.validate(policy);
            System.assert(false, 'The execution policy must be rejected.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains(expectedMessage), expected.getMessage());
        }
    }

    @IsTest
    static void relayedDeliveryChannelDeciderMustBeAbleToReadTheApproval() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = createReviewTool(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leasedToolCommand(tool, started, '{}');
        AgentApprovalService.Request request = AgentKernelTestFactory.approvalRequest(null);
        request.approverType = AgentKernelModels.APPROVER_DELIVERY_CHANNEL;
        AgentKernel.waitForApproval(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c, request);
        Id approvalId = AgentKernelTestFactory.pendingApproval(started.runId).Id;
        User reviewer = new User(
            Alias = 'dcrev',
            Email = 'delivery-channel-reviewer@example.com',
            Username = 'delivery-channel-reviewer-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'Reviewer',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert reviewer;
        }
        AgentKernelTestFactory.grant(reviewer.Id, new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.APPROVAL_RELAY });
        AgentKernelModels.ApprovalDecision relayed = AgentKernelTestFactory.approvalDecision(approvalId, true, null);
        relayed.deciderId = reviewer.Id;

        System.runAs(AgentKernelTestFactory.self()) {
            try {
                AgentKernel.decideApproval(relayed);
                System.assert(false, 'A relay must not record a decision for someone the approval was never shared with.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('read this approval'), expected.getMessage());
            }
        }
        insert new AgentApproval__Share(ParentId = approvalId, UserOrGroupId = reviewer.Id, AccessLevel = 'Read');
        System.runAs(AgentKernelTestFactory.self()) {
            AgentKernel.decideApproval(relayed);
        }
        AgentApproval__c decided = AgentKernelTestFactory.pendingApproval(started.runId);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, decided.Status__c);
        System.assertEquals(reviewer.Id, decided.DecidedBy__c);
    }

    private class ApprovalFixture {
        Id runId;
        Id commandId;
        Id approvalId;
        AgentTool__c tool;
    }

    private static ApprovalFixture waitingApproval(String toolInput, Id approverId) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = createReviewTool(definition);
        return waitingApproval(tool, AgentKernelTestFactory.startRunWithoutDispatch(definition), toolInput, approverId);
    }

    private static ApprovalFixture waitingApproval(AgentTool__c tool, AgentKernelModels.StartResult started, String toolInput, Id approverId) {
        AgentCommand__c command = leasedToolCommand(tool, started, toolInput);
        AgentApprovalService.Request request = AgentKernelTestFactory.approvalRequest(approverId);
        AgentKernel.waitForApproval(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c, request);
        ApprovalFixture fixture = new ApprovalFixture();
        fixture.runId = started.runId;
        fixture.commandId = command.Id;
        fixture.approvalId = AgentKernelTestFactory.pendingApproval(started.runId).Id;
        fixture.tool = tool;
        return fixture;
    }

    private static AgentTool__c createReviewTool(AgentDefinition__c definition) {
        return AgentKernelTestFactory.createTool(
            definition.Id,
            'review_tool',
            '{"type":"object","properties":{"to":{"type":"string"}},"additionalProperties":false}'
        );
    }

    private static AgentCommand__c leasedToolCommand(AgentTool__c tool, AgentKernelModels.StartResult started, String toolInput) {
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, toolInput, tool.DeveloperName__c)
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'review-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);
        return AgentKernelTestFactory.getCommand(command.Id);
    }
}
