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
private class InvocationEvidenceTest {
    @IsTest
    static void capturesExactNormalizedModelRequestAndResponse() {
        resetDoubles();
        KernelTestModelProvider.nativeRequestEvidence = '{"authorization":"secret","wire":"request"}';
        KernelTestModelProvider.nativeResponseEvidence = '{"wire":"response"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assertEquals('Model', invocation.InvocationType__c);
        System.assertEquals('KernelTestModelProvider', invocation.ModelAdapterClass__c);
        System.assertEquals('kernel-test-model', invocation.ModelIdentifier__c);
        System.assertEquals(null, invocation.EstimatedCostUSD__c);
        System.assertEquals('Succeeded', invocation.Outcome__c);
        System.assert(invocation.Request__c.contains('Run the focused phase-one kernel tests.'));
        System.assert(invocation.Request__c.contains('kernel-test-model'));
        System.assert(invocation.Request__c.contains('\\"request\\":\\"test\\"'));
        System.assert(invocation.Response__c.contains('test model output'));
        System.assert(invocation.NativeEvidence__c.contains('[REDACTED]'));
        System.assert(invocation.NativeEvidence__c.contains('response'));
        System.assertNotEquals(null, invocation.NativeEvidenceHash__c);
        System.assertNotEquals(null, invocation.RequestHash__c);
        System.assertNotEquals(null, invocation.ResponseHash__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    @IsTest
    static void deactivatedModelStopsLeasedModelCommand() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);
        AgentModel__mdt deactivated = AgentKernelTestFactory.kernelTestModel();
        deactivated.IsActive__c = false;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ deactivated });

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        System.assertEquals(0, KernelTestModelProvider.invocationCount);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('MODEL_NOT_APPROVED', run.ErrorCode__c);
    }

    @IsTest
    static void capturesModelAndPriceEstimateWithInvocation() {
        resetDoubles();
        KernelTestModelProvider.inputTokens = 1000;
        KernelTestModelProvider.outputTokens = 500;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentModel__mdt priced = AgentKernelTestFactory.kernelTestModel();
        priced.InputPricePerMillion__c = 3;
        priced.OutputPricePerMillion__c = 4;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ priced });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assertEquals(0.005, invocation.EstimatedCostUSD__c);
        System.assertEquals(3, invocation.AppliedInputPricePerMillion__c);
        System.assertEquals(4, invocation.AppliedOutputPricePerMillion__c);
        System.assertEquals(AgentKernelTestFactory.KERNEL_TEST_MODEL, invocation.Model__c);
    }

    @IsTest
    static void recordsWhatEachAttemptUsedNotTheTransactionTotal() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);
        Integer queriesBeforeWorker = Limits.getQueries();

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        Integer workerQueries = Limits.getQueries() - queriesBeforeWorker;

        AgentInvocation__c measured = [
            SELECT SoqlQueries__c, DmlStatements__c, CpuTimeMs__c, TransactionId__c
            FROM AgentInvocation__c
            WHERE AgentCommand__c = :command.Id
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assertNotEquals(null, measured.SoqlQueries__c);
        System.assert(measured.SoqlQueries__c >= 0 && measured.DmlStatements__c >= 0 && measured.CpuTimeMs__c >= 0);
        System.assert(measured.SoqlQueries__c <= workerQueries, 'Usage starts at the call, not at the start of the transaction.');
        System.assertEquals(InvocationEvidenceService.TRANSACTION_ID, measured.TransactionId__c);

        InvocationEvidenceService.Capture unmeasured = new InvocationEvidenceService.Capture();
        unmeasured.runId = started.runId;
        unmeasured.commandId = started.commandId;
        unmeasured.commandRevision = started.revision;
        unmeasured.attemptNumber = 2;
        unmeasured.invocationType = 'Model';
        unmeasured.outcome = 'Succeeded';
        unmeasured.operationKey = started.operationKey;
        unmeasured.startedAt = System.now();
        unmeasured.requestJson = '{}';
        Id unmeasuredId = InvocationEvidenceService.record(unmeasured);
        System.assertEquals(
            null,
            [SELECT SoqlQueries__c FROM AgentInvocation__c WHERE Id = :unmeasuredId WITH SYSTEM_MODE].SoqlQueries__c,
            'Without a start snapshot, usage is unknown and left blank.'
        );
    }

    @IsTest
    static void preservesSeparateEvidenceForEveryRetryAttempt() {
        resetDoubles();
        KernelTestModelProvider.mode = 'retry';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(2, 0, 1);
        AgentExecutionPolicyService.Policy fastRetry = AgentExecutionPolicyService.resolve(definition);
        fastRetry.retryBaseDelaySeconds = 1;
        fastRetry.retryMaxDelaySeconds = 1;
        fastRetry.retryJitterPercent = 0;
        AgentKernelTestFactory.configureExecutionPolicy(fastRetry);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c first = invocationFor(command.Id, 1);
        System.assertEquals('Retry Requested', first.Outcome__c);
        System.assertEquals('TEST_RETRY', first.ErrorCode__c);

        update new AgentCommand__c(Id = command.Id, AvailableAt__c = System.now().addSeconds(-1));
        KernelTestModelProvider.mode = 'final';
        command = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c second = invocationFor(command.Id, 2);
        System.assertEquals('Succeeded', second.Outcome__c);
        System.assertEquals(first.AgentCommand__c, second.AgentCommand__c);
        System.assertEquals(first.OperationKey__c, second.OperationKey__c);
        System.assertEquals(2, [SELECT COUNT() FROM AgentInvocation__c WHERE AgentCommand__c = :command.Id]);
    }

    @IsTest
    static void correlatesModelToolCallWithToolInvocation() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        resetDoubles();
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.toolCallId = 'provider-tool-call-1';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c modelCommand = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, modelCommand.Id, modelCommand.ExpectedRunRevision__c, modelCommand.OperationKey__c, modelCommand.LeaseToken__c)
            .execute(null);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c toolCommand = leaseCurrent(run.Id);
        new ToolCommandQueueable(run.Id, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);

        AgentInvocation__c toolInvocation = invocationFor(toolCommand.Id, 1);
        System.assertEquals('Tool', toolInvocation.InvocationType__c);
        System.assertEquals('provider-tool-call-1', toolInvocation.ProviderToolCallId__c);
        System.assert(toolInvocation.Request__c.contains('\\"value\\":\\"test\\"'));
        System.assert(toolInvocation.Response__c.contains('test tool output'));
    }

    @IsTest
    static void capturesToolRetryEvidenceBeforeScheduling() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(2, 0, 1);
        AgentExecutionPolicyService.Policy fastRetry = AgentExecutionPolicyService.resolve(definition);
        fastRetry.retryBaseDelaySeconds = 1;
        fastRetry.retryMaxDelaySeconds = 1;
        fastRetry.retryJitterPercent = 0;
        AgentKernelTestFactory.configureExecutionPolicy(fastRetry);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'retrying_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leasedToolCommand(started, tool);
        KernelTestTool.returnRetryable = true;

        new ToolCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assertEquals('Tool', invocation.InvocationType__c);
        System.assertEquals('Retry Requested', invocation.Outcome__c);
        System.assertEquals('TEST_RETRYABLE', invocation.ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void preservesUnknownToolOutcomeEvidence() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'uncertain_tool', '{"type":"object"}');
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leasedToolCommand(started, tool);
        KernelTestTool.throwUnexpected = true;

        new ToolCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assertEquals('Unknown', invocation.Outcome__c);
        System.assertEquals('TOOL_OUTCOME_UNKNOWN', invocation.ErrorCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    @IsTest
    static void capturesMalformedProviderResponseBeforeFailingClosed() {
        resetDoubles();
        KernelTestModelProvider.mode = 'malformed';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assertEquals('Failed', invocation.Outcome__c);
        System.assertEquals('MALFORMED_PROVIDER_OUTPUT', invocation.ErrorCode__c);
        System.assertNotEquals(null, invocation.Response__c);
        // The malformed turn goes back to the model, so the error belongs to the command and the continuing run shows none.
        System.assertEquals('MALFORMED_PROVIDER_OUTPUT', AgentKernelTestFactory.getCommand(command.Id).ErrorCode__c);
        System.assertEquals(null, AgentKernelTestFactory.getRun(started.runId).ErrorCode__c);
    }

    @IsTest
    static void capturesTokenizedModelResponseEvidence() {
        resetDoubles();
        KernelTestModelProvider.finalOutput = '{"result":"contact admin@example.com"}';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy fullRetention = AgentExecutionPolicyService.defaults();
        fullRetention.payloadRetentionMode = PayloadProtectionService.MODE_FULL;
        AgentKernelTestFactory.configureExecutionPolicy(fullRetention);
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentInvocation__c invocation = invocationFor(command.Id, 1);
        System.assert(TrustService.containsToken(invocation.Response__c));
        System.assert(!invocation.Response__c.contains('admin@example.com'));
    }

    @IsTest
    static void evidenceCannotBeEditedOrDeleted() {
        resetDoubles();
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);
        AgentInvocation__c invocation = invocationFor(command.Id, 1);

        try {
            invocation.Outcome__c = 'Failed';
            Database.update(invocation, AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Invocation evidence updates must be rejected.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
        try {
            Database.delete(invocation, AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Invocation evidence deletes must be rejected.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
    }

    @IsTest
    static void appliesEveryRunPayloadProtectionMode() {
        AgentInvocation__c full = captureWithMode(PayloadProtectionService.MODE_FULL);
        AgentInvocation__c redacted = captureWithMode(PayloadProtectionService.MODE_REDACTED);
        AgentInvocation__c hashOnly = captureWithMode(PayloadProtectionService.MODE_METADATA_ONLY);
        AgentInvocation__c none = captureWithMode(PayloadProtectionService.MODE_NONE);

        System.assert(full.Request__c.contains('classified'));
        System.assert(redacted.Request__c.contains('[REDACTED]'));
        System.assertNotEquals(null, redacted.RequestHash__c);
        System.assert(hashOnly.Request__c.contains('Hash Only'));
        System.assertNotEquals(null, hashOnly.RequestHash__c);
        System.assertEquals(null, none.Request__c);
        System.assertEquals(null, none.RequestHash__c);
    }

    private static AgentCommand__c leaseCurrent(Id runId) {
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

    private static AgentCommand__c leasedToolCommand(AgentKernelModels.StartResult started, AgentTool__c tool) {
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.LeaseToken__c = 'tool-lease-' + command.Id;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.PolicyApproved__c = true;
        command.ApprovalFingerprint__c = ToolApprovalFingerprint.compute(command, tool, AgentRunConfigurationService.getDefinition(started.runId));
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);
        return AgentKernelTestFactory.getCommand(command.Id);
    }

    private static AgentInvocation__c invocationFor(Id commandId, Integer attemptNumber) {
        return [
            SELECT
                Id,
                AgentCommand__c,
                AttemptNumber__c,
                InvocationType__c,
                Model__c,
                ModelAdapterClass__c,
                ModelIdentifier__c,
                EstimatedCostUSD__c,
                AppliedInputPricePerMillion__c,
                AppliedOutputPricePerMillion__c,
                Outcome__c,
                OperationKey__c,
                ProviderToolCallId__c,
                Request__c,
                Response__c,
                NativeEvidence__c,
                RequestHash__c,
                ResponseHash__c,
                NativeEvidenceHash__c,
                ErrorCode__c
            FROM AgentInvocation__c
            WHERE AgentCommand__c = :commandId AND AttemptNumber__c = :attemptNumber
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    private static AgentInvocation__c captureWithMode(String mode) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy retention = AgentExecutionPolicyService.defaults();
        retention.payloadRetentionMode = mode;
        retention.sensitiveJsonKeys = '["privateValue"]';
        AgentKernelTestFactory.configureExecutionPolicy(retention);
        update definition;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        InvocationEvidenceService.Capture capture = new InvocationEvidenceService.Capture();
        capture.runId = started.runId;
        capture.commandId = started.commandId;
        capture.commandRevision = started.revision;
        capture.attemptNumber = 1;
        capture.invocationType = 'Model';
        capture.outcome = 'Succeeded';
        capture.operationKey = started.operationKey;
        capture.startedAt = System.now();
        capture.requestJson = '{"privateValue":"classified"}';
        capture.responseJson = '{"result":"ok"}';

        Id invocationId = InvocationEvidenceService.record(capture);
        return [
            SELECT Request__c, RequestHash__c
            FROM AgentInvocation__c
            WHERE Id = :invocationId
            WITH SYSTEM_MODE
        ];
    }

    private static void resetDoubles() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestModelProvider.finalOutput = '{"result":"test model output"}';
        KernelTestModelProvider.toolCallId = null;
        KernelTestModelProvider.nativeRequestEvidence = null;
        KernelTestModelProvider.nativeResponseEvidence = null;
        KernelTestModelProvider.inputTokens = null;
        KernelTestModelProvider.outputTokens = null;
        KernelTestModelProvider.totalTokens = null;
        KernelTestTool.invocationCount = 0;
        KernelTestTool.awaitInput = false;
        KernelTestTool.throwUnexpected = false;
        KernelTestTool.throwRetryable = false;
        KernelTestTool.returnRetryable = false;
    }
}
