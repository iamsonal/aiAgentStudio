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
private class CoreHardeningMilestoneTest {
    @IsTest
    static void reconciliationConfirmSucceededContinuesAndIsTraceVisible() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownFixture fixture = createUnknownFixture();
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(fixture, AgentKernelModels.ReconciliationDecision.ConfirmSucceeded);
            request.confirmedOutput = '{"confirmed":true}';

            Test.startTest();
            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(request);
            Test.stopTest();

            AgentRun__c run = AgentKernelTestFactory.getRun(fixture.run.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c);
            System.assertEquals(null, run.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, AgentKernelTestFactory.getCommand(fixture.command.Id).Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, AgentKernelTestFactory.getCommand(result.dispatchedCommandId).Status__c);
            List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(run.Id);
            System.assertEquals(AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED, events[4].EventType__c);
            System.assert(!events[4].Payload__c.contains(request.confirmedOutput), 'The reconciliation event must not copy raw confirmed output.');
        }
    }

    @IsTest
    static void reconciliationConfirmFailedPausesAndIsSanitized() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownFixture fixture = createUnknownFixture();
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(fixture, AgentKernelModels.ReconciliationDecision.ConfirmFailed);
            request.pauseRun = true;
            request.errorCode = 'REMOTE FAILURE!';
            request.errorMessage = 'Rejected\nby operator';

            AgentRunService.reconcileUnknownOutcome(request);

            AgentRun__c run = AgentKernelTestFactory.getRun(fixture.run.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
            System.assertEquals('REMOTE_FAILURE_', run.ErrorCode__c);
            System.assertEquals('Rejected by operator', run.ErrorMessage__c);
            System.assertEquals(fixture.command.Id, run.CurrentCommand__c);
        }
    }

    @IsTest
    static void reconciliationRetryRequiresAttestationAndPreservesOperation() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownFixture fixture = createUnknownFixture();
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(fixture, AgentKernelModels.ReconciliationDecision.Retry);
            assertRejected(request, 'Retry without an attestation must be rejected.');

            request.safeToRetryAttested = true;
            AgentKernelModels.ReconciliationResult result = AgentRunService.reconcileUnknownOutcome(request);
            AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.command.Id);
            System.assertEquals(fixture.command.OperationKey__c, command.OperationKey__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, command.Status__c);
            System.assertEquals(result.revision, command.ExpectedRunRevision__c);
            System.assertEquals(command.Id, result.dispatchedCommandId);
        }
    }

    @IsTest
    static void reconciliationRejectsStaleRevision() {
        UnknownFixture wrongRevision = createUnknownFixture();
        AgentKernelModels.ReconciliationRequest request = reconciliationRequest(wrongRevision, AgentKernelModels.ReconciliationDecision.ConfirmSucceeded);
        request.confirmedOutput = '{"confirmed":true}';
        request.expectedRunRevision--;
        assertRejected(request, 'A stale reconciliation revision must be rejected.');
    }

    @IsTest
    static void reconciliationRejectsMismatchedOperation() {
        UnknownFixture wrongIdentity = createUnknownFixture();
        AgentKernelModels.ReconciliationRequest request = reconciliationRequest(wrongIdentity, AgentKernelModels.ReconciliationDecision.ConfirmSucceeded);
        request.confirmedOutput = '{"confirmed":true}';
        request.operationKey += '-wrong';
        assertRejected(request, 'A mismatched operation must be rejected.');
    }

    @IsTest
    static void reconciliationRejectsInvalidConfirmedOutput() {
        UnknownFixture badOutput = createUnknownFixture();
        AgentKernelModels.ReconciliationRequest request = reconciliationRequest(badOutput, AgentKernelModels.ReconciliationDecision.ConfirmSucceeded);
        request.confirmedOutput = '["not","an","object"]';
        assertRejected(request, 'Confirmed output must be a JSON object, like every tool result.');
    }

    @IsTest
    static void reconciliationRejectsDuplicateDecision() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownFixture duplicate = createUnknownFixture();
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(duplicate, AgentKernelModels.ReconciliationDecision.ConfirmFailed);
            AgentRunService.reconcileUnknownOutcome(request);
            assertRejected(request, 'A second reconciliation must be rejected.');
        }
    }

    @IsTest
    static void unknownOutcomeSurvivesRecoveryAndRemainsReconcilable() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            UnknownFixture fixture = createUnknownFixture();

            CommandLeaseRecoveryService.RecoveryResult recovery = CommandLeaseRecoveryService.recoverOperational(10);

            AgentRun__c protectedRun = AgentKernelTestFactory.getRun(fixture.run.Id);
            System.assertEquals(0, recovery.expiredWaits);
            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, protectedRun.Status__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(fixture.command.Id).Status__c);
            System.assertEquals(AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN, AgentKernelTestFactory.getEvents(fixture.run.Id)[3].EventType__c);
            System.assertEquals(4, protectedRun.LastEventSequence__c);

            fixture.run = protectedRun;
            AgentKernelModels.ReconciliationRequest request = reconciliationRequest(fixture, AgentKernelModels.ReconciliationDecision.ConfirmFailed);
            request.pauseRun = true;
            AgentRunService.reconcileUnknownOutcome(request);
            AgentRun__c reconciledRun = AgentKernelTestFactory.getRun(fixture.run.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, reconciledRun.Status__c);
            System.assertEquals(5, reconciledRun.LastEventSequence__c);
        }
    }

    @IsTest
    static void unexpectedModelProviderExceptionPausesForIntervention() {
        KernelTestModelProvider.mode = 'unexpectedException';
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c model = lease(started.commandId, 'unexpected-provider-fault');

        new ModelCommandQueueable(started.runId, model.Id, model.ExpectedRunRevision__c, model.OperationKey__c, model.LeaseToken__c).execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals(model.Id, run.CurrentCommand__c);
        System.assertEquals('MODEL_INVOCATION_ERROR', run.ErrorCode__c);
        System.assertEquals(0, run.RetryCount__c);
    }

    @IsTest
    static void schedulerRedispatchesOrphansWithoutMutation() {
        AgentKernelModels.StartResult orphan = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = orphan.commandId, AvailableAt__c = System.now().addMinutes(-5)));
        AgentCommand__c before = AgentKernelTestFactory.getCommand(orphan.commandId);
        Test.startTest();
        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(10);
        CommandLeaseRecoveryService.RecoveryResult duplicate = CommandLeaseRecoveryService.recoverOperational(10);
        AgentCommand__c after = AgentKernelTestFactory.getCommand(orphan.commandId);
        System.assertEquals(1, result.orphanRedispatched);
        System.assertEquals(0, duplicate.orphanRedispatched, 'The leased command is not redispatched again.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, before.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, after.Status__c, 'Recovery leases the orphan in the same pass.');
        System.assertEquals(before.OperationKey__c, after.OperationKey__c);
        Test.stopTest();
    }

    @IsTest
    static void retryWaitingOrphanIsRedispatchedWithoutMutation() {
        AgentKernelModels.StartResult orphan = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentCommand__c command = AgentKernelTestFactory.getCommand(orphan.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'retry-fixture-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        AgentKernelTestFactory.updateRecord(command);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_RETRY_WAITING;
        command.LeaseToken__c = null;
        command.LeaseExpiresAt__c = null;
        command.AvailableAt__c = System.now().addMinutes(-5);
        AgentKernelTestFactory.updateRecord(command);

        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(10);

        AgentCommand__c after = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(1, result.orphanRedispatched);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, after.Status__c, 'A due retry is leased in the same pass.');
        System.assertEquals(command.OperationKey__c, after.OperationKey__c);
    }

    @IsTest
    static void finalOutputSchemaIsOptional() {
        executeFinalWithSchema(
            '{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}',
            '{"answer":"ok"}',
            AgentKernelModels.RUN_STATUS_SUCCEEDED
        );
        executeFinalWithSchema(null, 'plain text without a schema', AgentKernelModels.RUN_STATUS_SUCCEEDED);
    }

    @IsTest
    static void finalOutputSchemaRejectsInvalidJsonRequiredAdditionalAndTypeOnce() {
        String schema = '{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}';
        executeFinalWithSchema(schema, 'not-json', AgentKernelModels.RUN_STATUS_RUNNING);
        executeFinalWithSchema(schema, '{}', AgentKernelModels.RUN_STATUS_RUNNING);
        executeFinalWithSchema(schema, '{"answer":"ok","extra":1}', AgentKernelModels.RUN_STATUS_RUNNING);
        executeFinalWithSchema(schema, '{"answer":1}', AgentKernelModels.RUN_STATUS_RUNNING);
    }

    private static void executeFinalWithSchema(String schema, String output, String expectedStatus) {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestModelProvider.finalOutput = output;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.OutputSchema__c = schema;
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = lease(started.commandId, 'schema-' + started.runId);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(expectedStatus, run.Status__c);
        if (expectedStatus == AgentKernelModels.RUN_STATUS_RUNNING) {
            AgentCommand__c failedCommand = AgentKernelTestFactory.getCommand(command.Id);
            System.assertEquals('MODEL_OUTPUT_SCHEMA_MISMATCH', failedCommand.ErrorCode__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, failedCommand.Status__c);
            System.assertEquals(2, [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :run.Id]);
            System.assertEquals(3, AgentKernelTestFactory.getEvents(run.Id).size());
        }
    }

    private static UnknownFixture createUnknownFixture() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unknown_tool', '{"type":"object"}');
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
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.unknown(run.Id, command.Id, run.Revision__c, command.OperationKey__c, 'TOOL_OUTCOME_UNKNOWN', 'Unknown.')
        );
        UnknownFixture fixture = new UnknownFixture();
        fixture.run = AgentKernelTestFactory.getRun(run.Id);
        fixture.command = AgentKernelTestFactory.getCommand(command.Id);
        return fixture;
    }

    private static AgentKernelModels.ReconciliationRequest reconciliationRequest(UnknownFixture fixture, AgentKernelModels.ReconciliationDecision decision) {
        AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
        request.runId = fixture.run.Id;
        request.commandId = fixture.command.Id;
        request.expectedRunRevision = fixture.run.Revision__c;
        request.operationKey = fixture.command.OperationKey__c;
        request.decision = decision;
        request.reason = 'Operator verified the external system.';
        return request;
    }

    private static void assertRejected(AgentKernelModels.ReconciliationRequest request, String message) {
        Boolean rejected = false;
        try {
            AgentRunService.reconcileUnknownOutcome(request);
        } catch (Exception expected) {
            rejected = true;
        }
        System.assert(rejected, message);
    }

    private static AgentCommand__c lease(Id commandId, String token) {
        AgentCommand__c command = AgentKernelTestFactory.getCommand(commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = token;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        AgentKernelTestFactory.updateRecord(command);
        return AgentKernelTestFactory.getCommand(commandId);
    }

    private class UnknownFixture {
        private AgentRun__c run;
        private AgentCommand__c command;
    }
}
