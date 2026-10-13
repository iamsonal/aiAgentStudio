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
private class AgentCoreRemediationTest {
    private static final String LOW_FLS_ALIAS = 'corelf';

    @TestSetup
    static void createLowFlsOperator() {
        Profile profile = [
            SELECT Id
            FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator'
            LIMIT 1
        ];
        String uniqueName = 'agent-core-low-fls-' + System.now().getTime() + '@example.com';
        User operator = new User(
            Alias = LOW_FLS_ALIAS,
            Email = uniqueName,
            EmailEncodingKey = 'UTF-8',
            LastName = 'Core Low FLS',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = uniqueName
        );
        insert operator;
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet permissionSet : [
            SELECT Id
            FROM PermissionSet
            WHERE Name IN ('AgentKernelAdmin', 'AgentKernelServicePrincipal')
        ]) {
            assignments.add(new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = permissionSet.Id));
        }
        System.assertEquals(2, assignments.size());
        insert assignments;
    }

    @IsTest
    static void identityFieldsAreImmutableAfterStart() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(UserInfo.getUserId(), run.ExpectedPrincipalUser__c);
        try {
            Id identityId = AgentKernelTestFactory.serviceUser(AgentKernelTestFactory.servicePrincipalUser().Id).Id;
            Database.update(new AgentRun__c(Id = run.Id, ExecutionIdentity__c = identityId), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'The execution identity must freeze.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
        AgentKernelModels.StartResult other = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        try {
            Database.update(new AgentRun__c(Id = run.Id, ParentRun__c = other.runId), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Parent run must freeze.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        try {
            command.CommandType__c = AgentKernelModels.COMMAND_TYPE_TOOL;
            Database.update(command, AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Command type must freeze.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, AgentKernelTestFactory.getCommand(command.Id).CommandType__c);
        try {
            Database.update(new AgentCommand__c(Id = command.Id, AgentRun__c = other.runId), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Command run must freeze.');
        } catch (DmlException expected) {
            System.assertNotEquals(null, expected.getMessage());
        }
        System.assertEquals(started.runId, AgentKernelTestFactory.getCommand(command.Id).AgentRun__c);
    }

    @IsTest
    static void deliveryTrackerRejectsMalformedJobIds() {
        System.assertEquals(false, CommandDeliveryTracker.isActive('not-an-id'));
    }

    @IsTest
    static void lifecycleStoreEmptyBatchesAreNoOps() {
        AgentLifecycleStore.insertRuns(null);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>());
        AgentLifecycleStore.insertCommands(null);
        AgentLifecycleStore.updateCommands(new List<AgentCommand__c>());
        AgentLifecycleStore.insertEvents(null);
        AgentLifecycleStore.updateEvents(new List<AgentEvent__c>());
        AgentLifecycleStore.insertInvocations(null);
        AgentLifecycleStore.updateInvocations(new List<AgentInvocation__c>());
    }

    @IsTest
    static void directLifecycleWritesRequireRevisionAndLegalTransitions() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        try {
            AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ new AgentRun__c(Id = run.Id, Status__c = AgentKernelModels.RUN_STATUS_FAILED) });
            System.assert(false, 'The public persistence helper must not bypass revision invariants.');
        } catch (AgentKernelException.PersistenceException expected) {
            System.assert(expected.getMessage().contains('RUN_UPDATE_FAILED'));
        }
        try {
            Database.update(new AgentRun__c(Id = run.Id, Status__c = AgentKernelModels.RUN_STATUS_FAILED), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Direct DML must not bypass revision invariants.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('revision'));
        }
        try {
            Database.update(new AgentRun__c(Id = run.Id, CurrentCommand__c = null), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Direct current-command changes must advance the revision.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('revision'));
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(run.Id).Status__c);
    }

    @IsTest
    static void directCommandCompletionAndEmptyLeaseAreRejected() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        try {
            Database.update(new AgentCommand__c(Id = started.commandId, Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'A pending command cannot claim an outcome without a lease.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('status transition'));
        }
        try {
            Database.update(new AgentCommand__c(Id = started.commandId, Status__c = AgentKernelModels.COMMAND_STATUS_LEASED), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'A command cannot enter leased state without a token.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('lease token'));
        }
    }

    @IsTest
    static void rejectedLeasesReturnNoPrivilegedRecords() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        CommandLeaseService.ServicePrincipalLeaseRequest request = new CommandLeaseService.ServicePrincipalLeaseRequest();
        request.runId = run.Id;
        request.commandId = command.Id;
        request.expectedRevision = run.Revision__c;
        request.operationKey = command.OperationKey__c;
        request.dispatchToken = 'invalid-token';
        CommandLeaseService.Result rejected = CommandLeaseService.tryLeaseServicePrincipalBatch(
            new List<CommandLeaseService.ServicePrincipalLeaseRequest>{ request }
        )[0];
        System.assertEquals(CommandLeaseService.Outcome.Noop, rejected.outcome);
        System.assertEquals(null, rejected.run);
        System.assertEquals(null, rejected.command);
        AgentKernelModels.StartResult initiating = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentRun__c initiatingRun = AgentKernelTestFactory.getRun(initiating.runId);
        AgentCommand__c initiatingCommand = AgentKernelTestFactory.getCommand(initiating.commandId);
        CommandLeaseService.Result rejectedSingle = CommandLeaseService.tryLease(
            initiatingRun.Id,
            initiatingCommand.Id,
            initiatingRun.Revision__c,
            initiatingCommand.OperationKey__c,
            'invalid-token'
        );
        System.assertEquals(CommandLeaseService.Outcome.Noop, rejectedSingle.outcome);
        System.assertEquals(null, rejectedSingle.run);
        System.assertEquals(null, rejectedSingle.command);
    }

    @IsTest
    static void wrongPrincipalCannotApplyLeasedOutcome() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = lease(started.runId);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.succeed(
            started.runId,
            command.Id,
            command.ExpectedRunRevision__c,
            command.OperationKey__c,
            '{"ok":true}'
        );
        outcome.leaseToken = command.LeaseToken__c;
        User otherUser = [SELECT Id FROM User WHERE Alias = :LOW_FLS_ALIAS LIMIT 1];
        System.runAs(otherUser) {
            try {
                AgentKernel.applyOutcome(outcome);
                System.assert(false, 'A lease token must not authorize a different business principal.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assertNotEquals(null, expected.getMessage());
            }
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(started.runId).Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void trustResolutionAuditHelperRequiresResolverPermission() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        User otherUser = [SELECT Id FROM User WHERE Alias = :LOW_FLS_ALIAS LIMIT 1];
        System.runAs(otherUser) {
            try {
                AgentKernel.recordTrustOutputResolutions(
                    new Map<Id, Set<String>>{ started.runId => new Set<String>{ 'Email' } },
                    new Map<Id, Integer>{ started.runId => 1 }
                );
                System.assert(false, 'A public audit helper must not append a resolution event for an unauthorized caller.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('permission'));
            }
        }
    }

    @IsTest
    static void leasedExternalToolKeepsItsAdmittedEffectsAfterAuthoringEdit() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'admitted_safety_tool', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
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
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
        System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE, command.AdmittedEffects__c);
        System.assertNotEquals(null, command.AdmittedToolBindingHash__c);
        try {
            Database.update(new AgentCommand__c(Id = command.Id, AdmittedEffects__c = AgentToolTypeService.EFFECTS_IN_ORG), AccessLevel.SYSTEM_MODE);
            System.assert(false, 'The admitted effects must be immutable.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
        tool.ToolType__c = AgentToolTypeTestFixtures.IN_ORG;
        AgentKernelTestFactory.updateRecord(tool);
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernel.StaleLeaseRecoveryResult recovered = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
        System.assertEquals(1, recovered.unknown);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void delegatedBatchLeaseCapturesToolSafetyOnce() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'batch_safety_tool', '{"type":"object"}');
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_PENDING
        );
        AgentKernelTestFactory.replaceCurrentCommand(started, command);
        CommandLeaseService.ServicePrincipalLeaseRequest request = new CommandLeaseService.ServicePrincipalLeaseRequest();
        request.runId = started.runId;
        request.commandId = command.Id;
        request.expectedRevision = started.revision;
        request.operationKey = command.OperationKey__c;
        request.dispatchToken = command.DispatchToken__c;
        CommandLeaseService.Result leased;
        System.runAs(AgentKernelTestFactory.worker(started.runId)) {
            leased = CommandLeaseService.tryLeaseServicePrincipalBatch(new List<CommandLeaseService.ServicePrincipalLeaseRequest>{ request })[0];
        }
        System.assertEquals(CommandLeaseService.Outcome.Leased, leased.outcome);
        AgentCommand__c admitted = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentToolTypeService.EFFECTS_IN_ORG, admitted.AdmittedEffects__c);
        System.assertEquals(AgentToolTypeService.bindingHash(tool), admitted.AdmittedToolBindingHash__c);
    }

    @IsTest
    static void identityFreezeGuardsEveryIdentityKey() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentRun__c persistedRun = AgentKernelTestFactory.getRun(started.runId);
        AgentRun__c previousRun = new AgentRun__c(
            Id = persistedRun.Id,
            InitiatingUser__c = persistedRun.InitiatingUser__c,
            LoopbackNamedCredential__c = persistedRun.LoopbackNamedCredential__c,
            ExpectedPrincipalUser__c = persistedRun.ExpectedPrincipalUser__c,
            ExecutionIdentity__c = persistedRun.ExecutionIdentity__c,
            ParentRun__c = null,
            ResolvedPrincipalUser__c = persistedRun.ResolvedPrincipalUser__c,
            ExecutionContextStatus__c = persistedRun.ExecutionContextStatus__c
        );
        AgentRun__c changedRun = previousRun.clone(true, true, false, false);
        changedRun.InitiatingUser__c = null;
        changedRun.LoopbackNamedCredential__c = 'different-credential';
        changedRun.ExpectedPrincipalUser__c = null;
        AgentIdentityFreezeService.guardRuns(new Map<Id, AgentRun__c>{ previousRun.Id => previousRun }, new List<AgentRun__c>{ changedRun });
        System.assert(changedRun.hasErrors());

        AgentCommand__c persistedCommand = AgentKernelTestFactory.getCommand(started.commandId);
        AgentCommand__c previousCommand = new AgentCommand__c(
            Id = persistedCommand.Id,
            OperationKey__c = persistedCommand.OperationKey__c,
            DispatchToken__c = persistedCommand.DispatchToken__c,
            CommandType__c = persistedCommand.CommandType__c,
            AgentRun__c = persistedCommand.AgentRun__c,
            BatchKey__c = null,
            BatchOrdinal__c = null
        );
        AgentCommand__c changedCommand = previousCommand.clone(true, true, false, false);
        changedCommand.OperationKey__c += '-changed';
        changedCommand.DispatchToken__c += '-changed';
        AgentIdentityFreezeService.guardCommands(
            new Map<Id, AgentCommand__c>{ previousCommand.Id => previousCommand },
            new List<AgentCommand__c>{ changedCommand }
        );
        System.assert(changedCommand.hasErrors());
    }

    @IsTest
    static void recoverySkipsLeasesWithActiveWorkerJobs() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'stale-with-job';
        command.LeaseExpiresAt__c = System.now().addMinutes(-1);
        command.WorkerJobId__c = UserInfo.getUserId();
        AgentKernelTestFactory.updateRecord(command);
        CommandDeliveryTracker.testJobStatuses = new Map<Id, String>{ UserInfo.getUserId() => 'Processing' };

        AgentKernel.StaleLeaseRecoveryResult result = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());

        System.assertEquals(1, result.skipped);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void recoveryRequeuesSafeLeaseWhenWorkerIsMissing() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = staleLease(started.runId, null);
        AgentKernel.StaleLeaseRecoveryResult result = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
        System.assertEquals(1, result.requeuedCommandIds.size());
        AgentCommand__c recovered = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, recovered.Status__c);
        System.assertEquals(null, recovered.WorkerJobId__c);
        System.assertEquals(null, recovered.WorkerEnqueuedAt__c);
    }

    @IsTest
    static void recoveryCancelsSafeLeaseBeforeRequeue() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = lease(started.runId);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentKernel.cancel(run.Id, run.Revision__c, 'operator cancellation');
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernel.StaleLeaseRecoveryResult result = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
        System.assertEquals(1, result.cancelled);
        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, AgentKernelTestFactory.getRun(run.Id).Status__c);
    }

    @IsTest
    static void recoveryRequeuesExpiredSafeModelLease() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = lease(run.Id);
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(run.Id).Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void recoveryLifecyclePersistenceIsAtomic() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'atomic_risky_tool', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'atomic_risky_tool')
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = staleLease(run.Id, null);
        Integer eventsBefore = [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :run.Id];
        AgentLifecycleStore.failNextRunUpdateForTest = true;

        try {
            AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
            System.assert(false, 'Recovery persistence failure must escape.');
        } catch (AgentKernelException.PersistenceException expected) {
            System.assert(expected.getMessage().contains('RUN_UPDATE_FAILED'));
        }

        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(run.Id).Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(command.Id).Status__c);
        System.assertEquals(eventsBefore, [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :run.Id]);
    }

    @IsTest
    static void recoveryMarksRiskyToolUnknownWhenWorkerIsInactive() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'risky_tool', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'risky_tool')
            )
        );
        AgentCommand__c command = staleLease(started.runId, UserInfo.getUserId());
        CommandDeliveryTracker.testJobStatuses = new Map<Id, String>{ UserInfo.getUserId() => 'Failed' };
        AgentKernel.StaleLeaseRecoveryResult result = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());
        System.assertEquals(1, result.unknown);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    @IsTest
    static void sweeperResolvesWorkerStatesOncePerBulk() {
        for (Integer index = 0; index < 5; index++) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
            staleLease(started.runId, null);
        }
        CommandDeliveryTracker.resolveInvocationCount = 0;
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(5);
        CommandDeliveryTracker.suppressEnqueueForTest = false;
        System.assertEquals(5, result.requeued);
        System.assertEquals(1, CommandDeliveryTracker.resolveInvocationCount);
    }

    @IsTest
    static void internalDispatchCanBeDenied() {
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf('{}');
        InternalCommandDispatchRest.dispatch();
        // Missing internal dispatch permission fails closed with a final refusal, so the caller does not retry it.
        System.assertEquals(403, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString().contains('DISPATCH_PRINCIPAL_REFUSED'));
    }

    @IsTest
    static void liveWorkerEnqueueRecordsJobCorrelation() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        Test.startTest();
        Id jobId = CommandDispatcher.dispatch(started.commandId);
        System.assertNotEquals(null, jobId);
        System.assertEquals(String.valueOf(jobId), AgentKernelTestFactory.getCommand(started.commandId).WorkerJobId__c);
        Test.stopTest();
        System.assertEquals(null, AgentKernelTestFactory.getCommand(started.commandId).WorkerJobId__c);
    }

    @IsTest
    static void runServiceStartExecutesProductionInitiatingUserTopology() {
        KernelTestModelProvider.mode = 'success';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.input = '{"request":"production-topology"}';

        Test.startTest();
        AgentKernelModels.StartResult started = AgentRunService.start(request);
        Test.stopTest();

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertEquals(null, command.LeaseToken__c);
        System.assertEquals(null, command.WorkerJobId__c);
    }

    @IsTest
    static void duplicateWorkerEnqueueRetainsActiveCorrelatedLease() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = lease(started.runId);
        command.WorkerJobId__c = UserInfo.getUserId();
        AgentKernelTestFactory.updateRecord(command);
        CommandDeliveryTracker.testJobStatuses = new Map<Id, String>{ UserInfo.getUserId() => 'Processing' };

        Id retainedJobId = CommandDispatcher.handleDuplicateWorkerEnqueue(command.Id);

        System.assertEquals(UserInfo.getUserId(), retainedJobId);
        System.assertEquals(1, CommandDeliveryTracker.duplicateSuppressionCount());
        AgentCommand__c retained = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, retained.Status__c);
        System.assertEquals('DUPLICATE_CORRELATED', retained.DeliveryAnomalyCode__c);
        System.assertEquals(1, retained.DeliveryAnomalyCount__c);
        AgentKernelHealthService.HealthRequest healthRequest = new AgentKernelHealthService.HealthRequest();
        healthRequest.definitionId = definition.Id;
        System.assertEquals(1, AgentKernelHealthService.getHealth(healthRequest).duplicateDispatchSuppressions);
    }

    @IsTest
    static void duplicateWorkerEnqueueReleasesUncorrelatedLease() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = lease(started.runId);

        System.assertEquals(null, CommandDispatcher.handleDuplicateWorkerEnqueue(command.Id));

        AgentCommand__c released = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(1, CommandDeliveryTracker.uncorrelatedDuplicateReleaseCount());
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, released.Status__c);
        System.assertEquals(null, released.LeaseToken__c);
        System.assertEquals('DUPLICATE_UNCORRELATED', released.DeliveryAnomalyCode__c);
        System.assertEquals(1, released.DeliveryAnomalyCount__c);
    }

    @IsTest
    static void testFactoryCanUpdateToolType() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'fls_side_effect', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        System.assertEquals(AgentToolTypeTestFixtures.EXTERNAL, [SELECT ToolType__c FROM AgentTool__c WHERE Id = :tool.Id].ToolType__c);
    }

    @IsTest
    static void batchDispatchResponseDefaultsToZero() {
        InternalCommandBatchDispatchRest.DispatchResponse response = new InternalCommandBatchDispatchRest.DispatchResponse();
        System.assertEquals(0, response.accepted);
        System.assertEquals(0, response.skipped);
        System.assertEquals(0, AgentLifecyclePublisher.lastPublishFailureCount());
    }

    @IsTest
    static void lowFlsInitiatingUserCompletesModelAndToolOutcomes() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolCallId = 'low-fls-call';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        User operator = [SELECT Id FROM User WHERE Alias = :LOW_FLS_ALIAS LIMIT 1];
        AgentKernelModels.StartResult started;
        System.runAs(operator) {
            started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        }
        AgentCommand__c model = leaseAs(started.runId, operator);
        System.runAs(operator) {
            new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        }
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = leaseAs(run.Id, operator);
        System.runAs(operator) {
            new ToolCommandQueueable(run.Id, tool.Id, tool.ExpectedRunRevision__c, tool.OperationKey__c, tool.LeaseToken__c).execute(null);
        }
        run = AgentKernelTestFactory.getRun(run.Id);
        model = leaseAs(run.Id, operator);
        System.runAs(operator) {
            new ModelCommandQueueable(run.Id, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelTestFactory.getRun(run.Id).Status__c);
    }

    @IsTest
    static void outcomeRollsBackWhenRunPersistenceFails() {
        assertOutcomeRollback(false);
    }

    @IsTest
    static void outcomeRollsBackWhenCommandPersistenceFails() {
        assertOutcomeRollback(true);
    }

    private static void assertOutcomeRollback(Boolean failCommand) {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = lease(started.runId);
        Decimal sequenceBefore = AgentKernelTestFactory.getRun(started.runId).LastEventSequence__c;
        Integer eventsBefore = [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :started.runId];
        AgentLifecycleStore.failNextCommandUpdateForTest = failCommand;
        AgentLifecycleStore.failNextRunUpdateForTest = !failCommand;
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.succeed(
            started.runId,
            command.Id,
            command.ExpectedRunRevision__c,
            command.OperationKey__c,
            '{"ok":true}'
        );
        outcome.leaseToken = command.LeaseToken__c;
        try {
            AgentKernel.applyOutcome(outcome);
            System.assert(false, 'Injected lifecycle persistence failure must escape.');
        } catch (AgentKernelException.PersistenceException expected) {
            System.assert(expected.getMessage().contains(failCommand ? 'COMMAND_UPDATE_FAILED' : 'RUN_UPDATE_FAILED'));
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(started.runId).Status__c);
        System.assertEquals(sequenceBefore, AgentKernelTestFactory.getRun(started.runId).LastEventSequence__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(command.Id).Status__c);
        System.assertEquals(eventsBefore, [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :started.runId]);
    }

    private static AgentCommand__c lease(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result result = CommandLeaseService.tryLease(
            run.Id,
            command.Id,
            run.Revision__c,
            command.OperationKey__c,
            command.DispatchToken__c
        );
        System.assertEquals(CommandLeaseService.Outcome.Leased, result.outcome);
        return AgentKernelTestFactory.getCommand(command.Id);
    }

    private static AgentCommand__c leaseAs(Id runId, User actor) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result result;
        System.runAs(actor) {
            result = CommandLeaseService.tryLease(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
        }
        System.assertEquals(CommandLeaseService.Outcome.Leased, result.outcome);
        return AgentKernelTestFactory.getCommand(command.Id);
    }

    private static AgentCommand__c staleLease(Id runId, Id workerJobId) {
        AgentCommand__c command = lease(runId);
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        command.WorkerJobId__c = workerJobId;
        command.WorkerEnqueuedAt__c = workerJobId == null ? null : System.now().addMinutes(-10);
        AgentKernelTestFactory.updateRecord(command);
        return AgentKernelTestFactory.getCommand(command.Id);
    }
}
