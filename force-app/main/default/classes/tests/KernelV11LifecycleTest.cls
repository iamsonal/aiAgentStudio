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
private class KernelV11LifecycleTest {
    @IsTest
    static void policyDenyReturnsToTheModelWithoutInvokingTheTool() {
        KernelTestTool.invocationCount = 0;
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.Deny;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'denied_tool', '{"type":"object"}');
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
        AgentCommand__c command = lease(run.CurrentCommand__c, 'deny-lease');
        new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c, 'A policy denial goes back to the model; it does not pause the run.');
        AgentCommand__c denied = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, denied.Status__c);
        System.assertEquals(AgentKernelModels.ERROR_TOOL_AUTHORIZATION_DENIED, denied.ErrorCode__c);
        AgentCommand__c nextModel = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, nextModel.CommandType__c);
        System.assert(nextModel.Input__c.contains(AgentKernelModels.ERROR_TOOL_AUTHORIZATION_DENIED));
        System.assertEquals(0, KernelTestTool.invocationCount);
    }

    @IsTest
    static void invalidPolicyClassIsRejectedAtConfigurationBoundary() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestTool';
        update definition;
        try {
            AgentKernelTestFactory.start(definition.Id, '{}');
            System.assert(false, 'A non-policy implementation must be rejected.');
        } catch (AgentKernelException.ConfigurationException expected) {
        }
    }

    @IsTest
    static void policyDmlIsRolledBackBeforePause() {
        KernelTestToolPolicy.performDml = true;
        Integer accountsBefore = [SELECT COUNT() FROM Account WHERE Name = 'Tool policy must remain query-only'];
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'isolated_policy_tool', '{"type":"object"}');
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
        AgentCommand__c command = lease(run.CurrentCommand__c, 'isolated-policy-lease');

        new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('TOOL_AUTHORIZATION_POLICY_INVALID', run.ErrorCode__c);
        System.assertEquals(accountsBefore, [SELECT COUNT() FROM Account WHERE Name = 'Tool policy must remain query-only']);
        KernelTestToolPolicy.performDml = false;
    }

    @IsTest
    static void approvalRearmsSameToolOperation() {
        KernelTestTool.invocationCount = 0;
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.RequireApproval;
        Id approverId = AgentKernelTestFactory.approverUser();
        KernelTestToolPolicy.configuredApproverId = approverId;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'approved_tool', '{"type":"object"}');
        tool.ImplementationConfiguration__c = '{"objectApiName":"Case"}';
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
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
        AgentCommand__c command = lease(run.CurrentCommand__c, 'approval-lease');
        System.runAs(AgentKernelTestFactory.worker(run.Id)) {
            new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        }

        run = AgentKernelTestFactory.getRun(run.Id);
        command = AgentKernelTestFactory.getCommand(command.Id);
        String originalOperationKey = command.OperationKey__c;
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_WAITING, command.Status__c);
        System.assertEquals(command.Id, run.WaitingCommand__c);
        System.assertEquals(0, KernelTestTool.invocationCount);
        System.assertEquals(false, KernelTestToolPolicy.lastRequest.hasExternalEffects);
        System.assertEquals(run.ExecutionIdentity__c, KernelTestToolPolicy.lastRequest.executionIdentityId);
        System.assertEquals(run.InitiatingUser__c, KernelTestToolPolicy.lastRequest.initiatingActorId);
        System.assertEquals(run.ResolvedPrincipalUser__c, KernelTestToolPolicy.lastRequest.resolvedPrincipalId);

        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(run.Id);
        System.assertEquals(approverId, approval.OwnerId);
        System.assertEquals(command.Id, approval.AgentCommand__c);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, approval.Status__c);
        Id resumedId;
        System.runAs(new User(Id = approverId)) {
            resumedId = AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approval.Id, true, null));
        }
        approval = AgentKernelTestFactory.pendingApproval(run.Id);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, approval.Status__c);
        System.assertEquals(approverId, approval.DecidedBy__c);
        System.assertEquals(null, approval.RelayedBy__c);
        run = AgentKernelTestFactory.getRun(run.Id);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(command.Id, resumedId);
        System.assertEquals(originalOperationKey, command.OperationKey__c);
        System.assertEquals(true, command.PolicyApproved__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, command.Status__c);
        System.assertEquals(null, run.WaitingReason__c);
        System.assertEquals(null, run.WaitingCommand__c);

        command = lease(command.Id, 'approved-lease');
        System.runAs(AgentKernelTestFactory.worker(run.Id)) {
            new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        }
        System.assertEquals(1, KernelTestTool.invocationCount);
        System.assertEquals('{"objectApiName":"Case"}', KernelTestTool.lastRequest.implementationConfiguration);
    }

    @IsTest
    static void initiatingUserPolicyApprovalPausesInsteadOfWaiting() {
        KernelTestTool.invocationCount = 0;
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.RequireApproval;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'attended_tool', '{"type":"object"}');
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
        AgentCommand__c command = lease(run.CurrentCommand__c, 'attended-lease');
        new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('INITIATING_USER_APPROVAL_UNSUPPORTED', run.ErrorCode__c);
        System.assertEquals(null, run.WaitingCommand__c);
        System.assertEquals(0, KernelTestTool.invocationCount);
    }

    @IsTest
    static void changedToolBindingPausesBeforeInvocation() {
        KernelTestTool.invocationCount = 0;
        KernelTestToolPolicy.configuredDecision = AgentKernelModels.ToolAuthorizationDecision.RequireApproval;
        Id approverId = AgentKernelTestFactory.approverUser();
        KernelTestToolPolicy.configuredApproverId = approverId;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'changed_approved_tool', '{"type":"object"}');
        tool.ImplementationConfiguration__c = '{"objectApiName":"Case"}';
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
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
        AgentCommand__c command = lease(run.CurrentCommand__c, 'first-approval-lease');
        System.runAs(AgentKernelTestFactory.worker(run.Id)) {
            new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        }

        run = AgentKernelTestFactory.getRun(run.Id);
        Id approvalId = AgentKernelTestFactory.pendingApproval(run.Id).Id;
        System.runAs(new User(Id = approverId)) {
            AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approvalId, true, null));
        }
        tool.ImplementationConfiguration__c = '{"objectApiName":"Account"}';
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();
        run = AgentKernelTestFactory.getRun(run.Id);
        Decimal toolCallsBefore = run.ToolCallCount__c;
        command = lease(command.Id, 'changed-approval-lease');
        System.runAs(AgentKernelTestFactory.worker(run.Id)) {
            new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        }

        run = AgentKernelTestFactory.getRun(run.Id);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, command.Status__c);
        System.assertEquals('TOOL_BINDING_CHANGED', run.ErrorCode__c);
        System.assertEquals(0, KernelTestTool.invocationCount);
        System.assertEquals(toolCallsBefore, run.ToolCallCount__c, 'A call paused before its tool ran does not use the tool budget.');
    }

    @IsTest
    static void toolWaitValidatesResumeAndContinuesToModel() {
        KernelTestTool.awaitInput = true;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'waiting_tool', '{"type":"object"}');
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
        AgentCommand__c toolCommand = lease(run.CurrentCommand__c, 'wait-lease');
        new ToolCommandQueueable(run.Id, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.CONTINUATION_MODEL, run.ContinuationMode__c);

        try {
            AgentKernel.resume(run.Id, run.Revision__c, '{"wrong":true}');
            System.assert(false, 'Invalid resume payload must be rejected.');
        } catch (AgentKernelException.InvalidTransitionException expected) {
        }
        Id nextId = AgentKernel.resume(run.Id, run.Revision__c, '{"answer":"continue"}');
        AgentCommand__c nextCommand = AgentKernelTestFactory.getCommand(nextId);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, nextCommand.CommandType__c);
        System.assertEquals(null, run.ContinuationMode__c);
        System.assertEquals(null, run.WaitExpiresAt__c);

        nextCommand = lease(nextCommand.Id, 'resume-model-lease');
        new ModelCommandQueueable(run.Id, nextCommand.Id, nextCommand.ExpectedRunRevision__c, nextCommand.OperationKey__c, nextCommand.LeaseToken__c)
            .execute(null);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(1, KernelTestModelProvider.invocationCount);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c);
        System.assertEquals(2, run.ModelCallCount__c, 'The initial model command and resumed model command must both be budgeted.');
    }

    @IsTest
    static void recoveryExpiresIntentionalWait() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.CommandOutcome waiting = AgentKernelModels.waitForResume(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            null
        );
        waiting.waitingReason = 'Waiting for callback.';
        waiting.continuationMode = AgentKernelModels.CONTINUATION_MODEL;
        waiting.waitExpiresAt = System.now().addMinutes(5);
        AgentKernelTestFactory.applyOutcome(waiting);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        run.WaitExpiresAt__c = System.now().addMinutes(-1);
        AgentKernelTestFactory.updateRecord(run);

        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(10);
        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(1, result.expiredWaits);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('WAIT_EXPIRED', run.ErrorCode__c);
    }

    @IsTest
    static void tracePagesUseMonotonicSequenceCursor() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, '{"done":true}')
        );
        AgentKernelModels.EventPageRequest request = new AgentKernelModels.EventPageRequest();
        request.runId = started.runId;
        request.limitSize = 2;
        AgentKernelModels.EventPage first = AgentTraceService.getEventPage(request);
        System.assertEquals(2, first.events.size());
        System.assertEquals(true, first.hasMore);
        request.afterSequence = first.nextSequence;
        request.afterId = first.nextId;
        AgentKernelModels.EventPage second = AgentTraceService.getEventPage(request);
        System.assertEquals(1, second.events.size());
        System.assert(second.events[0].sequence > first.nextSequence);
        System.assertEquals(false, second.hasMore);
    }

    @IsTest
    static void permanentToolFailureContinuesToModel() {
        KernelTestTool.returnPermanentFailure = true;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'permanent_fail_tool', '{"type":"object"}');
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
        AgentCommand__c toolCommand = lease(run.CurrentCommand__c, 'permanent-fail-lease');

        new ToolCommandQueueable(run.Id, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);

        run = AgentKernelTestFactory.getRun(run.Id);
        toolCommand = AgentKernelTestFactory.getCommand(toolCommand.Id);
        AgentCommand__c nextModel = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, toolCommand.Status__c);
        System.assertEquals('TEST_PERMANENT', toolCommand.ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, nextModel.CommandType__c);
        System.assert(nextModel.Input__c.contains('TEST_PERMANENT'), 'The model receives the tool\'s own error code.');
        KernelTestTool.returnPermanentFailure = false;
    }

    @IsTest
    static void deniedToolApprovalContinuesToModelWithoutCancel() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'reject_approval_tool', '{"type":"object"}');
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
        AgentCommand__c toolCommand = lease(run.CurrentCommand__c, 'reject-approval-lease');
        Id approverId = AgentKernelTestFactory.approverUser();
        AgentKernel.waitForApproval(
            run.Id,
            toolCommand.Id,
            toolCommand.ExpectedRunRevision__c,
            toolCommand.OperationKey__c,
            toolCommand.LeaseToken__c,
            AgentKernelTestFactory.approvalRequest(approverId)
        );
        Id approvalId = AgentKernelTestFactory.pendingApproval(run.Id).Id;

        Id modelCommandId;
        System.runAs(new User(Id = approverId)) {
            modelCommandId = AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(approvalId, false, 'Risk owner denied the write.'));
        }

        run = AgentKernelTestFactory.getRun(run.Id);
        toolCommand = AgentKernelTestFactory.getCommand(toolCommand.Id);
        AgentCommand__c modelCommand = AgentKernelTestFactory.getCommand(modelCommandId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, toolCommand.Status__c);
        System.assertEquals('TOOL_APPROVAL_DENIED', toolCommand.ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, modelCommand.CommandType__c);
        System.assert(modelCommand.Input__c.contains('TOOL_APPROVAL_DENIED'));
        System.assert(modelCommand.Input__c.contains('Risk owner denied the write.'));
        System.assertEquals(null, run.WaitingCommand__c);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_REJECTED, AgentKernelTestFactory.pendingApproval(run.Id).Status__c);
    }

    @IsTest
    static void lifecyclePublishingIsBestEffortAndPayloadFree() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        Test.startTest();
        AgentLifecyclePublisher.publish(run, 'Waiting', 3, started.operationKey);
        AgentLifecyclePublisher.publish(null, null, null, null);
        Test.stopTest();
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(run.Id).Status__c);
    }

    @IsTest
    static void lifecycleEventsMarkOnlyRunStatusChanges() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'status_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentLifecyclePublisher.publishedTransitions.clear();
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
        AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                toolCommand.Id,
                toolCommand.ExpectedRunRevision__c,
                toolCommand.OperationKey__c,
                '{"ok":true}',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, '{"ok":true}', null)
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(0, AgentLifecyclePublisher.publishedTransitions.size(), 'Steps that keep the run Running publish no lifecycle event.');
        System.assert(
            [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :run.Id AND EventType__c = :AgentKernelModels.EVENT_TOOL_REQUESTED] > 0,
            'Each step is still recorded as an Agent Event.'
        );

        AgentCommand__c modelCommand = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(run.Id, modelCommand.Id, modelCommand.ExpectedRunRevision__c, modelCommand.OperationKey__c, '{"answer":"done"}')
        );
        System.assertEquals(new List<String>{ 'Succeeded' }, AgentLifecyclePublisher.publishedTransitions);
    }

    @IsTest
    static void unknownToolOutcomePublishesWaiting() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unknown_tool', '{"type":"object"}');
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
        AgentLifecyclePublisher.publishedTransitions.clear();
        AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(AgentKernelTestFactory.getRun(started.runId).CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.unknown(
                started.runId,
                toolCommand.Id,
                toolCommand.ExpectedRunRevision__c,
                toolCommand.OperationKey__c,
                'TOOL_OUTCOME_UNKNOWN',
                'The outside system did not confirm the change.'
            )
        );
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(started.runId).Status__c);
        System.assertEquals(new List<String>{ 'Waiting' }, AgentLifecyclePublisher.publishedTransitions);
    }

    private static AgentCommand__c lease(Id commandId, String leaseToken) {
        AgentCommand__c command = AgentKernelTestFactory.getCommand(commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = leaseToken;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = (command.AttemptNumber__c == null ? 0 : command.AttemptNumber__c) + 1;
        AgentKernelTestFactory.updateRecord(command);
        return AgentKernelTestFactory.getCommand(commandId);
    }
}
