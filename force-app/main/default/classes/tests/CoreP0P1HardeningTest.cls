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
private class CoreP0P1HardeningTest {
    @IsTest
    static void externalToolFailureIsQuarantinedInsteadOfRetried() {
        ToolFixture fixture = leasedExternalTool('unexpected');
        KernelTestTool.throwUnexpected = true;

        new ToolCommandQueueable(
                fixture.started.runId,
                fixture.command.Id,
                fixture.started.revision,
                fixture.command.OperationKey__c,
                fixture.command.LeaseToken__c
            )
            .execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, command.Status__c);
        System.assertEquals(0, run.RetryCount__c);
        KernelTestTool.throwUnexpected = false;
    }

    @IsTest
    static void externalToolRetryableResponseIsRetriedBecauseTheToolAsked() {
        ToolFixture fixture = leasedExternalTool('retryable-response');
        KernelTestTool.returnRetryable = true;

        new ToolCommandQueueable(
                fixture.started.runId,
                fixture.command.Id,
                fixture.started.revision,
                fixture.command.OperationKey__c,
                fixture.command.LeaseToken__c
            )
            .execute(null);

        assertRetried(fixture);
        KernelTestTool.returnRetryable = false;
    }

    @IsTest
    static void externalToolRetryableExceptionIsRetriedBecauseTheToolAsked() {
        ToolFixture fixture = leasedExternalTool('retryable-exception');
        KernelTestTool.throwRetryable = true;

        new ToolCommandQueueable(
                fixture.started.runId,
                fixture.command.Id,
                fixture.started.revision,
                fixture.command.OperationKey__c,
                fixture.command.LeaseToken__c
            )
            .execute(null);

        assertRetried(fixture);
        KernelTestTool.throwRetryable = false;
    }

    @IsTest
    static void staleExternalToolLeaseRequiresReconciliation() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'non_idempotent_recovery', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.LeaseToken__c = 'expired-write-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(-1);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);

        AgentKernel.StaleLeaseRecoveryResult result = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());

        System.assertEquals(1, result.unknown);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    @IsTest
    static void humanDecisionPermissionGatesEveryDecisionPath() {
        WaitingFixture approval = waitingFixture(AgentKernelModels.CONTINUATION_REINVOKE_TOOL, AgentKernelModels.COMMAND_TYPE_TOOL);
        assertDecisionDenied(new DecisionWork('resume', approval), 'Tool approval must require explicit authority.');

        WaitingFixture reconciliation = waitingFixture(null, AgentKernelModels.COMMAND_TYPE_TOOL);
        assertDecisionDenied(new DecisionWork('reconcile', reconciliation), 'Unknown-outcome reconciliation must require explicit authority.');
    }

    @IsTest
    static void startFailsBeforePersistenceWhenQueueCapacityIsExhausted() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        CommandDispatcher.capacityExhaustedForTest = true;
        try {
            AgentRunService.start(AgentKernelTestFactory.startRequest(definition, '{}'));
            System.assert(false, 'Expected Queueable capacity failure.');
        } catch (AgentKernelException.QueueCapacityException expected) {
            System.assert(expected.getMessage().contains('Queueable capacity'));
        } finally {
            CommandDispatcher.capacityExhaustedForTest = false;
        }
        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }

    @IsTest
    static void toolSecurityChecksAndStripsFields() {
        ToolSecurity.assertReadable(Account.SObjectType);
        ToolSecurity.assertCreateable(Account.SObjectType);
        ToolSecurity.assertUpdateable(Account.SObjectType);
        ToolSecurity.assertFieldsReadable(Account.SObjectType, new List<String>{ 'Id', 'Name' });
        List<SObject> records = new List<SObject>{ new Account(Name = 'Secure fixture') };
        System.assertEquals(1, ToolSecurity.stripReadable(records).size());
        System.assertEquals(1, ToolSecurity.stripCreateable(records).size());
        System.assertEquals(1, ToolSecurity.stripUpdateable(records).size());
        System.assertEquals(0, ToolSecurity.stripReadable(null).size());
        System.assertEquals(0, ToolSecurity.stripCreateable(null).size());
        System.assertEquals(0, ToolSecurity.stripUpdateable(null).size());
        try {
            ToolSecurity.assertFieldsReadable(Account.SObjectType, new List<String>{ 'NotAField__c' });
            System.assert(false, 'Unknown fields must fail closed.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('requested fields'));
        }
    }

    @IsTest
    static void toolApprovalWaitsAreDecidedOnlyThroughTheDecisionApi() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION });
        System.runAs(AgentKernelTestFactory.self()) {
            WaitingFixture fixture = waitingFixture(AgentKernelModels.CONTINUATION_REINVOKE_TOOL, AgentKernelModels.COMMAND_TYPE_TOOL);
            try {
                AgentRunService.resume(AgentKernelTestFactory.resumeRequest(fixture.run.Id, fixture.run.Revision__c, '{"approved":true}'));
                System.assert(false, 'A generic resume must never re-arm a tool.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('decideApproval'));
            }
            AgentCommand__c otherCommand = [
                SELECT Id, ToolName__c
                FROM AgentCommand__c
                WHERE AgentRun__c = :fixture.run.Id AND Id != :fixture.command.Id
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            AgentApproval__c stale = AgentKernelTestFactory.openApproval(fixture.run, otherCommand, UserInfo.getUserId());
            try {
                AgentRunService.decideApproval(AgentKernelTestFactory.approvalDecision(stale.Id, true, null));
                System.assert(false, 'A decision for a different tool call must fail.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('no longer waiting'));
            }
            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(fixture.run.Id).Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_WAITING, AgentKernelTestFactory.getCommand(fixture.command.Id).Status__c);
        }
    }

    @IsTest
    static void pendingCommandCannotApplyOutcomeWithoutLease() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        try {
            AgentKernel.applyOutcome(AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, '{}'));
            System.assert(false, 'Pending commands must not accept outcomes.');
        } catch (AgentKernelException.InvalidTransitionException expected) {
            System.assert(expected.getMessage().contains('leased'));
        }
        System.assertEquals(2, AgentKernelTestFactory.getEvents(started.runId).size());
    }

    private static WaitingFixture waitingFixture(String continuationMode, String commandType) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command;
        if (commandType == AgentKernelModels.COMMAND_TYPE_TOOL) {
            command = AgentKernelTestFactory.insertToolCommand(
                started.runId,
                started.revision,
                'test_tool',
                continuationMode == null ? AgentKernelModels.COMMAND_STATUS_UNKNOWN : AgentKernelModels.COMMAND_STATUS_WAITING
            );
        } else {
            command = AgentKernelTestFactory.getCommand(started.commandId);
            command.Status__c = continuationMode == null ? AgentKernelModels.COMMAND_STATUS_UNKNOWN : AgentKernelModels.COMMAND_STATUS_WAITING;
            AgentKernelTestFactory.updateRecord(command);
        }
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        run.Status__c = AgentKernelModels.RUN_STATUS_WAITING;
        run.Revision__c = run.Revision__c + 1;
        run.CurrentCommand__c = null;
        run.ContinuationMode__c = continuationMode;
        run.WaitingCommand__c = continuationMode == null ? null : command.Id;
        run.ResumeJsonSchema__c = continuationMode == AgentKernelModels.CONTINUATION_REINVOKE_TOOL
            ? '{"type":"object","properties":{"approved":{"type":"boolean"}},"required":["approved"],"additionalProperties":false}'
            : null;
        run.WaitExpiresAt__c = System.now().addHours(1);
        AgentKernelTestFactory.updateRecord(run);
        WaitingFixture result = new WaitingFixture();
        result.run = run;
        result.command = command;
        if (continuationMode == AgentKernelModels.CONTINUATION_REINVOKE_TOOL) {
            result.approval = AgentKernelTestFactory.openApproval(run, command, UserInfo.getUserId());
        }
        return result;
    }

    private static void assertRetried(ToolFixture fixture) {
        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, command.Status__c);
        System.assertEquals(1, run.RetryCount__c);
    }

    private static ToolFixture leasedExternalTool(String suffix) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'non_idempotent_write_' + suffix, '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.LeaseToken__c = 'write-lease-' + suffix;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.PolicyApproved__c = true;
        command.ApprovalFingerprint__c = ToolApprovalFingerprint.compute(command, tool, definition);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);
        ToolFixture result = new ToolFixture();
        result.started = started;
        result.command = command;
        return result;
    }

    private static void assertDecisionDenied(DecisionWork work, String message) {
        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                work.execute();
                System.assert(false, message);
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('not authorized'));
            }
        }
    }

    private class WaitingFixture {
        AgentRun__c run;
        AgentCommand__c command;
        AgentApproval__c approval;
    }

    private class ToolFixture {
        AgentKernelModels.StartResult started;
        AgentCommand__c command;
    }

    private class DecisionWork {
        String type;
        WaitingFixture fixture;
        DecisionWork(String type, WaitingFixture fixture) {
            this.type = type;
            this.fixture = fixture;
        }
        void execute() {
            if (type == 'resume') {
                AgentRunService.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approval.Id, true, null));
            } else {
                AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
                request.runId = fixture.run.Id;
                request.commandId = fixture.command.Id;
                request.expectedRunRevision = fixture.run.Revision__c;
                request.operationKey = fixture.command.OperationKey__c;
                request.decision = AgentKernelModels.ReconciliationDecision.ConfirmFailed;
                request.reason = 'Test decision.';
                AgentRunService.reconcileUnknownOutcome(request);
            }
        }
    }
}
