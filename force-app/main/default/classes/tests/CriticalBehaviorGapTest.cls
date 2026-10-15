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

@IsTest(SeeAllData=false)
private class CriticalBehaviorGapTest {
    @IsTest
    static void toolRequestedRetryRepeatsAndStaleInOrgLeaseRequeues() {
        resetDoubles();
        ToolFixture retryFixture = leasedTool('external_retry', true, true, '{}');
        KernelTestTool.returnRetryable = true;

        executeTool(retryFixture);

        AgentRun__c retriedRun = AgentKernelTestFactory.getRun(retryFixture.started.runId);
        AgentCommand__c retriedCommand = AgentKernelTestFactory.getCommand(retryFixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, retriedRun.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, retriedCommand.Status__c);
        System.assertEquals(1, retriedRun.RetryCount__c);

        resetDoubles();
        ToolFixture nativeStale = staleTool('in_org_stale', false);
        ToolFixture unsafeStale = staleTool('external_stale', true);
        AgentKernel.StaleLeaseRecoveryResult recovered = AgentKernelRecovery.recoverStaleLeases(
            new List<Id>{ nativeStale.command.Id, unsafeStale.command.Id },
            System.now()
        );

        System.assertEquals(1, recovered.requeuedCommandIds.size());
        System.assertEquals(nativeStale.command.Id, recovered.requeuedCommandIds[0]);
        System.assertEquals(1, recovered.unknown);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(nativeStale.command.Id).Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(unsafeStale.command.Id).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(unsafeStale.started.runId).Status__c);
    }

    @IsTest
    static void onlyTheApprovalSettingMakesAToolWait() {
        resetDoubles();
        ToolFixture unattended = leasedTool('unattended_write', true, false, '{}');
        executeTool(unattended);
        System.assertEquals(1, KernelTestTool.invocationCount, 'External effects must not add an approval.');
        System.assertNotEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(unattended.started.runId).Status__c);

        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c gated = AgentKernelTestFactory.createTool(definition.Id, 'gated_read', '{"type":"object"}');
        Id approverId = AgentKernelTestFactory.approverUser();
        gated.ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED;
        gated.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        gated.ApproverType__c = AgentKernelModels.APPROVER_USER;
        gated.ApproverUser__c = approverId;
        AgentKernelTestFactory.updateRecord(gated);
        AgentConfigService.clearCacheForTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        ToolFixture fixture = leaseExistingTool(started, gated, false, '{}');

        executeTool(fixture);

        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_WAITING, command.Status__c);
        System.assertEquals(command.Id, run.WaitingCommand__c);
        System.assertEquals(0, KernelTestTool.invocationCount);
        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(run.Id);
        System.assertEquals(approverId, approval.OwnerId);
        System.assertEquals(AgentKernelModels.APPROVER_USER, approval.ApproverType__c);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, approval.Status__c);
    }

    @IsTest
    static void attendedRunsWithholdFailureTextFromToolsThatDoNotFilterForTheRequester() {
        resetDoubles();
        KernelTestTool.returnPermanentFailure = true;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unfiltered_failure', '{"type":"object"}');
        AgentConfigService.clearCacheForTest();
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AttendedAccessService.attendedForTest = null;
        AgentKernelTestFactory.acceptLoopback(started);
        ToolFixture fixture = leaseExistingTool(started, tool, false, '{}');

        executeTool(fixture);
        KernelTestTool.returnPermanentFailure = false;

        AgentCommand__c failed = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals('TEST_PERMANENT', failed.ErrorCode__c);
        System.assert(failed.ErrorMessage__c.contains('details are withheld'), failed.ErrorMessage__c);
        AgentCommand__c next = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, next.CommandType__c);
        System.assert(
            !String.valueOf(next.Input__c).contains('Permanent test tool failure'),
            'Text the tool did not filter for the requester must not reach the model.'
        );
    }

    @IsTest
    static void attendedRunsShowFailureTextFromToolsThatFilterForTheRequester() {
        resetDoubles();
        KernelTestTool.returnPermanentFailure = true;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'filtered_failure', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.FILTERED;
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AttendedAccessService.attendedForTest = null;
        AgentKernelTestFactory.acceptLoopback(started);
        ToolFixture fixture = leaseExistingTool(started, tool, false, '{}');

        executeTool(fixture);
        KernelTestTool.returnPermanentFailure = false;

        AgentCommand__c failed = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals('TEST_PERMANENT', failed.ErrorCode__c);
        System.assert(
            failed.ErrorMessage__c.contains('Permanent test tool failure'),
            'A tool that filters for the requester keeps its text: ' + failed.ErrorMessage__c
        );
    }

    @IsTest
    static void attendedRunsWithholdOutputOfAWaitingToolThatDoesNotFilterForTheRequester() {
        resetDoubles();
        KernelTestTool.awaitInput = true;
        KernelTestTool.outputOverride = '{"result":"service user only"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unfiltered_wait', '{"type":"object"}');
        AgentConfigService.clearCacheForTest();
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AttendedAccessService.attendedForTest = null;
        AgentKernelTestFactory.acceptLoopback(started);
        ToolFixture fixture = leaseExistingTool(started, tool, false, '{}');

        executeTool(fixture);
        KernelTestTool.awaitInput = false;

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c waited = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, waited.Status__c);
        System.assert(String.valueOf(waited.Output__c).contains('outputWithheld'), 'The model replays this output after the resume.');
        System.assert(!String.valueOf(waited.Output__c).contains('service user only'), waited.Output__c);
    }

    @IsTest
    static void principalGrantedApprovalAuthorityAfterSetupCannotRunTools() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'drifted_principal', '{"type":"object"}');
        AgentConfigService.clearCacheForTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        ToolFixture fixture = leaseExistingTool(started, tool, true, '{}');
        AgentKernelTestFactory.grant(identity.PrincipalUser__c, new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });

        executeTool(fixture);

        System.assertEquals(0, KernelTestTool.invocationCount, 'A principal with approval authority must not run a model-chosen tool.');
        System.assertEquals('PRINCIPAL_HAS_APPROVAL_AUTHORITY', AgentKernelTestFactory.getCommand(fixture.command.Id).ErrorCode__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(fixture.started.runId).Status__c);
    }

    @IsTest
    static void singleToolAgentAsksForOneCallAndRejectsABatch() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 10);
        definition.AllowMultipleToolCalls__c = false;
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelTestFactory.createTool(definition.Id, 'active_tool', '{"type":"object"}');
        AgentConfigService.clearCacheForTest();
        KernelTestModelProvider.toolCallsOverride = toolCalls(2, 'active_tool', false);

        AgentKernelModels.StartResult started = invokeModel(definition);

        Map<String, Object> request = (Map<String, Object>) JSON.deserializeUntyped(KernelTestModelProvider.lastRequestJson);
        System.assertEquals(false, request.get('allowMultipleToolCalls'), 'The adapter is asked for one call per turn.');
        assertRunReflection(started.runId, 'TOOL_BATCH_NOT_ALLOWED');
    }

    @IsTest
    static void modelRejectsOversizedDuplicateAndInactiveToolRequests() {
        resetDoubles();
        AgentDefinition__c oversizedDefinition = AgentKernelTestFactory.createDefinition(5, 10);
        AgentKernelTestFactory.createTool(oversizedDefinition.Id, 'active_tool', '{"type":"object"}');
        KernelTestModelProvider.toolCallsOverride = toolCalls(9, 'active_tool', false);
        AgentKernelModels.StartResult oversized = invokeModel(oversizedDefinition);
        assertRunReflection(oversized.runId, 'TOOL_BATCH_LIMIT_EXCEEDED');

        resetDoubles();
        AgentDefinition__c duplicateDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(duplicateDefinition.Id, 'active_tool', '{"type":"object"}');
        KernelTestModelProvider.toolCallsOverride = toolCalls(2, 'active_tool', true);
        AgentKernelModels.StartResult duplicate = invokeModel(duplicateDefinition);
        assertRunReflection(duplicate.runId, 'MALFORMED_PROVIDER_OUTPUT');

        resetDoubles();
        AgentDefinition__c inactiveDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(inactiveDefinition.Id, 'active_tool', '{"type":"object"}');
        AgentTool__c inactive = AgentKernelTestFactory.createTool(inactiveDefinition.Id, 'inactive_tool', '{"type":"object"}');
        inactive.IsActive__c = false;
        AgentKernelTestFactory.updateRecord(inactive);
        KernelTestModelProvider.toolCallsOverride = toolCalls(1, 'inactive_tool', false);
        AgentKernelModels.StartResult inactiveRequest = invokeModel(inactiveDefinition);
        assertRunReflection(inactiveRequest.runId, 'MALFORMED_PROVIDER_OUTPUT');

        resetDoubles();
        AgentDefinition__c invalidInputDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            invalidInputDefinition.Id,
            'validated_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        KernelTestModelProvider.toolCallsOverride = toolCalls(1, 'validated_tool', false);
        AgentKernelModels.StartResult invalidInput = invokeModel(invalidInputDefinition);
        assertRunReflection(invalidInput.runId, 'TOOL_INPUT_SCHEMA_INVALID');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :invalidInput.runId AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL]
        );
    }

    @IsTest
    static void structuredToolOutputIsProtectedAndPersisted() {
        resetDoubles();
        ToolFixture fixture = leasedTool('structured_output', false, true, '{}');
        KernelTestTool.recordSets = new Map<String, List<SObject>>{ 'accounts' => new List<SObject>{ new Account(Name = 'Structured result') } };

        executeTool(fixture);

        AgentCommand__c completed = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, completed.Status__c);
        System.assert(completed.Output__c.contains('accounts'));
        System.assert(completed.Output__c.contains('Structured result'));
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(fixture.started.runId).Status__c);
    }

    /** Record data with a sensitive value reaches the model as a token minted in the same attempt. */
    @IsTest
    static void structuredToolOutputWithSensitiveValueIsTokenized() {
        resetDoubles();
        ToolFixture fixture = leasedTool('structured_sensitive', false, true, '{}');
        KernelTestTool.recordSets = new Map<String, List<SObject>>{
            'contacts' => new List<SObject>{ new Contact(LastName = 'Customer', Email = 'pat.customer@example.com') }
        };

        executeTool(fixture);

        AgentCommand__c completed = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, completed.Status__c, completed.ErrorCode__c + ': ' + completed.ErrorMessage__c);
        System.assert(!completed.Output__c.contains('pat.customer@example.com'));
        System.assert(TrustService.containsToken(completed.Output__c));
        System.assertEquals(1, [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :fixture.started.runId WITH SYSTEM_MODE]);
    }

    /** A token another run minted is still rejected when it arrives inside record data. */
    @IsTest
    static void structuredToolOutputWithForgedTokenIsRejected() {
        resetDoubles();
        ToolFixture fixture = leasedTool('structured_forged', false, true, '{}');
        KernelTestTool.recordSets = new Map<String, List<SObject>>{
            'accounts' => new List<SObject>{ new Account(Name = 'Forged', Description = '{{EMAIL_1_00000000}}') }
        };

        executeTool(fixture);

        AgentCommand__c rejected = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertNotEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, rejected.Status__c);
        System.assertEquals('TRUST_PROTECTION_ERROR', rejected.ErrorCode__c);
    }

    @IsTest
    static void unknownTrustTokenFailsBeforeToolInvocation() {
        resetDoubles();
        String fakeToken = '{{EMAIL_1_00000000}}';
        ToolFixture fixture = leasedTool('trust_rejection', false, true, '{"value":"' + fakeToken + '"}');

        executeTool(fixture);

        System.assertEquals(0, KernelTestTool.invocationCount);
        AgentCommand__c rejected = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, rejected.Status__c);
        System.assertEquals(TrustService.TOKEN_INVALID, rejected.ErrorCode__c);
        System.assertEquals(
            AgentKernelModels.RUN_STATUS_RUNNING,
            AgentKernelTestFactory.getRun(fixture.started.runId).Status__c,
            'An unknown token is returned to the model instead of pausing the run.'
        );
    }

    @IsTest
    static void policyExceptionFailsClosedBeforeToolInvocation() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createPolicyTool(definition.Id, 'policy_failure');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        ToolFixture fixture = leaseExistingTool(started, tool, false, '{}');
        KernelTestToolPolicy.throwUnexpected = true;

        executeTool(fixture);

        assertRunPaused(started.runId, 'TOOL_AUTHORIZATION_POLICY_ERROR');
        System.assertEquals(0, KernelTestTool.invocationCount);
    }

    @IsTest
    static void nullAndConflictingToolOutputsFailClosed() {
        resetDoubles();
        ToolFixture nullOutput = leasedTool('null_output', false, true, '{}');
        KernelTestTool.returnNull = true;
        executeTool(nullOutput);
        assertRunPaused(nullOutput.started.runId, 'MALFORMED_TOOL_OUTPUT');

        resetDoubles();
        ToolFixture conflictingOutput = leasedTool('conflicting_output', false, true, '{}');
        KernelTestTool.recordSets = new Map<String, List<SObject>>{ 'accounts' => new List<SObject>{ new Account(Name = 'Conflicting result') } };
        KernelTestTool.combineOutputAndRecordSets = true;
        executeTool(conflictingOutput);
        assertRunPaused(conflictingOutput.started.runId, 'MALFORMED_TOOL_OUTPUT');

        resetDoubles();
        ToolFixture listOutput = leasedTool('list_output', false, true, '{}');
        KernelTestTool.outputOverride = '["not","an","object"]';
        executeTool(listOutput);
        assertRunPaused(listOutput.started.runId, 'MALFORMED_TOOL_OUTPUT');
    }

    @IsTest
    static void malformedExternalResponseRequiresReconciliation() {
        resetDoubles();
        ToolFixture nullOutput = leasedTool('ambiguous_null', true, true, '{}');
        KernelTestTool.returnNull = true;
        executeTool(nullOutput);
        assertUnknown(nullOutput);

        resetDoubles();
        ToolFixture oversized = leasedTool('ambiguous_oversized', true, true, '{}');
        String large = 'x';
        for (Integer index = 0; index < 18; index++) {
            large += large;
        }
        KernelTestTool.outputOverride = large;
        executeTool(oversized);
        assertUnknown(oversized);
    }

    @IsTest
    static void lateKnownToolOutcomeRemainsTerminal() {
        resetDoubles();
        ToolFixture fixture = leasedTool('late_known', true, true, '{}');
        AgentRunService.cancel(fixture.started.runId, fixture.started.revision, 'Stop after the leased call returns.');

        executeTool(fixture);

        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertNotEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
    }

    @IsTest
    static void unknownSideEffectRequiresReconciliation() {
        resetDoubles();
        ToolFixture fixture = leasedTool('unknown_effect', true, true, '{}');
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.unknown(
            fixture.started.runId,
            fixture.command.Id,
            fixture.command.ExpectedRunRevision__c,
            fixture.command.OperationKey__c,
            'TOOL_OUTCOME_UNKNOWN',
            'The external effect may have completed.'
        );

        AgentKernelTestFactory.applyOutcome(outcome);

        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, command.Status__c);
        System.assertEquals('TOOL_OUTCOME_UNKNOWN', run.ErrorCode__c);
    }

    @IsTest
    static void leaseQueueableDispatchesDeferredAndLeasedBranches() {
        AgentKernelModels.StartResult deferred = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c deferredCommand = AgentKernelTestFactory.getCommand(deferred.commandId);
        deferredCommand.AvailableAt__c = System.now().addMinutes(2);
        AgentKernelTestFactory.updateRecord(deferredCommand);
        resetLeaseCapture();
        CommandLeaseQueueable.captureDispatchForTest = true;

        new CommandLeaseQueueable(deferred.runId, deferred.commandId, deferred.revision, deferred.operationKey, deferredCommand.DispatchToken__c).execute(null);

        System.assertEquals(deferred.commandId, CommandLeaseQueueable.capturedDeferredCommandId);
        System.assert(CommandLeaseQueueable.capturedDelayMinutes >= 1);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(deferred.commandId).Status__c);

        AgentKernelModels.StartResult ready = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c readyCommand = AgentKernelTestFactory.getCommand(ready.commandId);
        resetLeaseCapture();
        CommandLeaseQueueable.captureDispatchForTest = true;
        new CommandLeaseQueueable(ready.runId, ready.commandId, ready.revision, ready.operationKey, readyCommand.DispatchToken__c).execute(null);

        System.assertEquals(ready.commandId, CommandLeaseQueueable.capturedWorkerCommandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(ready.commandId).Status__c);
        CommandLeaseQueueable.captureDispatchForTest = false;
    }

    @IsTest
    static void successfulFinalizerContinuesAfterParentCommit() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());

        Test.startTest();
        System.enqueueJob(new FinalizerProbe(started.commandId));
        Test.stopTest();

        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertEquals(1, command.AttemptNumber__c);
    }

    @IsTest
    static void purgeQueueableContinuesUntilPassBudgetIsExhausted() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelTestFactory.insertRecords(
                new List<AgentCommand__c>{
                    completedCommand(started, 'purge-extra-1'),
                    completedCommand(started, 'purge-extra-2'),
                    completedCommand(started, 'purge-extra-3')
                }
            );
            AgentKernel.cancel(started.runId, started.revision, 'Queueable purge test.');
            AgentKernelTestFactory.updateRecord(
                new AgentRun__c(Id = started.runId, CompletedAt__c = System.now().addDays(-2), PurgeAfter__c = System.now().addMinutes(-1))
            );
            PayloadRetentionPurgeService.childRowLimitOverride = 1;
            PayloadRetentionPurgeQueueable.captureContinuationForTest = true;
            PayloadRetentionPurgeQueueable.capturedContinuationPasses = null;

            new PayloadRetentionPurgeQueueable(3).execute(null);

            System.assertEquals(2, PayloadRetentionPurgeQueueable.capturedContinuationPasses);
            System.assertEquals(null, [SELECT PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE].PayloadPurgedAt__c);

            PayloadRetentionPurgeQueueable.capturedContinuationPasses = null;
            new PayloadRetentionPurgeQueueable(1).execute(null);
            System.assertEquals(null, PayloadRetentionPurgeQueueable.capturedContinuationPasses);
            System.assertEquals(null, [SELECT PayloadPurgedAt__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE].PayloadPurgedAt__c);

            PayloadRetentionPurgeQueueable.captureContinuationForTest = false;
            PayloadRetentionPurgeService.childRowLimitOverride = null;
        }
    }

    private static ToolFixture leasedTool(String name, Boolean externalEffects, Boolean policyApproved, String input) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, name, '{"type":"object"}');
        tool.ToolType__c = externalEffects ? AgentToolTypeTestFixtures.EXTERNAL : AgentToolTypeTestFixtures.IN_ORG;
        AgentKernelTestFactory.updateRecord(tool);
        return leaseExistingTool(AgentKernelTestFactory.startRunWithoutDispatch(definition), tool, policyApproved, input);
    }

    private static ToolFixture staleTool(String name, Boolean externalEffects) {
        ToolFixture fixture = leasedTool(name, externalEffects, true, '{}');
        fixture.command.LeaseExpiresAt__c = System.now().addMinutes(-1);
        AgentKernelTestFactory.updateRecord(fixture.command);
        fixture.command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        return fixture;
    }

    private static ToolFixture leaseExistingTool(AgentKernelModels.StartResult started, AgentTool__c tool, Boolean policyApproved, String input) {
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.Input__c = input;
        command.LeaseToken__c = 'lease-' + tool.DeveloperName__c;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.PolicyApproved__c = policyApproved;
        if (policyApproved) {
            command.ApprovalFingerprint__c = ToolApprovalFingerprint.compute(command, tool, AgentRunConfigurationService.getDefinition(started.runId));
        }
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);
        ToolFixture fixture = new ToolFixture();
        fixture.started = started;
        fixture.command = AgentKernelTestFactory.getCommand(command.Id);
        return fixture;
    }

    private static void executeTool(ToolFixture fixture) {
        System.runAs(AgentKernelTestFactory.worker(fixture.started.runId)) {
            new ToolCommandQueueable(
                    fixture.started.runId,
                    fixture.command.Id,
                    fixture.command.ExpectedRunRevision__c,
                    fixture.command.OperationKey__c,
                    fixture.command.LeaseToken__c
                )
                .execute(null);
        }
    }

    private static AgentKernelModels.StartResult invokeModel(AgentDefinition__c definition) {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'model-lease-' + command.Id;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        return started;
    }

    private static List<AgentKernelModels.ModelToolCall> toolCalls(Integer count, String toolName, Boolean duplicateIds) {
        List<AgentKernelModels.ModelToolCall> calls = new List<AgentKernelModels.ModelToolCall>();
        for (Integer index = 0; index < count; index++) {
            AgentKernelModels.ModelToolCall call = new AgentKernelModels.ModelToolCall();
            call.toolName = toolName;
            call.toolInput = '{}';
            call.toolCallId = duplicateIds ? 'duplicate-call' : 'call-' + index;
            calls.add(call);
        }
        return calls;
    }

    private static void assertRunPaused(Id runId, String expectedCode) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals(expectedCode, run.ErrorCode__c);
    }

    private static void assertUnknown(ToolFixture fixture) {
        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, command.Status__c);
    }

    private static void assertRunReflection(Id runId, String expectedCode) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        List<AgentCommand__c> commands = [
            SELECT Status__c, ErrorCode__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId
            ORDER BY CreatedDate ASC, Id ASC
        ];
        System.assertEquals(2, commands.size());
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, commands[0].Status__c);
        System.assertEquals(expectedCode, commands[0].ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, commands[1].Status__c);
    }

    private static AgentCommand__c completedCommand(AgentKernelModels.StartResult started, String operationKey) {
        return new AgentCommand__c(
            AgentRun__c = started.runId,
            CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
            Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
            ExpectedRunRevision__c = started.revision,
            OperationKey__c = operationKey,
            AttemptNumber__c = 1,
            Input__c = '{"retained":true}',
            Output__c = '{"retained":true}'
        );
    }

    private static void resetDoubles() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestModelProvider.toolCallsOverride = null;
        KernelTestTool.invocationCount = 0;
        KernelTestTool.returnRetryable = false;
        KernelTestTool.throwRetryable = false;
        KernelTestTool.throwUnexpected = false;
        KernelTestTool.returnNull = false;
        KernelTestTool.combineOutputAndRecordSets = false;
        KernelTestTool.outputOverride = null;
        KernelTestTool.recordSets = null;
        KernelTestToolPolicy.throwUnexpected = false;
        KernelTestToolPolicy.performDml = false;
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.Allow;
    }

    private static void resetLeaseCapture() {
        CommandLeaseQueueable.captureDispatchForTest = false;
        CommandLeaseQueueable.capturedDeferredCommandId = null;
        CommandLeaseQueueable.capturedDelayMinutes = null;
        CommandLeaseQueueable.capturedWorkerCommandId = null;
    }

    private class ToolFixture {
        private AgentKernelModels.StartResult started;
        private AgentCommand__c command;
    }

    private class FinalizerProbe implements Queueable {
        private Id commandId;

        private FinalizerProbe(Id commandId) {
            this.commandId = commandId;
        }

        public void execute(QueueableContext context) {
            CommandContinuationFinalizer finalizer = new CommandContinuationFinalizer(null, null, null);
            finalizer.prepare(commandId);
            System.attachFinalizer(finalizer);
        }
    }
}
