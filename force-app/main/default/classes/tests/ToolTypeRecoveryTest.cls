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
 * Reference scenarios 3, 5, and 9: a Stays in This Org or Reads Outside Systems
 * tool type needs no reconciliation; a Changes Outside Systems one, or one
 * without Effects, is never repeated blindly.
 */
@IsTest
private class ToolTypeRecoveryTest {
    private static final String PROBE = 'Tool type recovery probe';

    @IsTest
    static void failedCallRollsBackItsRecordsAndReturnsToTheModel() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.returnPermanentFailure = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = :PROBE], 'The failed call\'s record must be rolled back.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        AgentRun__c run = AgentKernelTestFactory.getRun(toolRun.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, AgentKernelTestFactory.getCommand(run.CurrentCommand__c).CommandType__c);
    }

    @IsTest
    static void unexpectedExceptionRollsBackAndReturnsToTheModelInsteadOfRetrying() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.throwUnexpected = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = :PROBE]);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, command.Status__c, 'An exception that recurs must not be retried.');
        System.assertEquals('TOOL_EXECUTION_ERROR', command.ErrorCode__c);
        AgentRun__c run = AgentKernelTestFactory.getRun(toolRun.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(0, run.RetryCount__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, AgentKernelTestFactory.getCommand(run.CurrentCommand__c).CommandType__c);
    }

    @IsTest
    static void rowLockContentionRollsBackAndRetries() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.throwLockError = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = :PROBE]);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void successfulCallKeepsItsRecords() {
        KernelTestTool.insertAccountName = PROBE;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = :PROBE]);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
    }

    @IsTest
    static void settlementFailureFailsTheJobInsteadOfCommittingARetry() {
        KernelTestTool.insertAccountName = PROBE;
        ToolRun toolRun = leaseTool(AgentToolTypeTestFixtures.IN_ORG);
        CommandAttemptRuntime.failSettlementForTest = true;
        Exception settlementFailure;
        try {
            toolRun.worker.execute(null);
        } catch (AgentKernelException.PersistenceException expected) {
            settlementFailure = expected;
        }

        // The platform rolls back a failed job, and its finalizer recovers the lease.
        System.assertNotEquals(null, settlementFailure, 'A settlement failure must fail the job, not schedule a retry beside the tool write.');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, command.Status__c, 'No retry may be recorded by the failed job.');
    }

    @IsTest
    static void asyncWorkMakesTheOutcomeUnknown() {
        KernelTestTool.enqueueAsync = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void immediateEventMakesTheOutcomeUnknown() {
        KernelTestTool.publishImmediate = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
    }

    /**
     * Documents a platform limit: Core cannot see a batch job a tool starts, so the
     * outcome stays as the tool reports it. The extension contract forbids tools
     * without external effects from starting one.
     */
    @IsTest
    static void batchJobIsNotDetectedAndTheContractForbidsIt() {
        KernelTestTool.startBatch = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertNotEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
    }

    @IsTest
    static void externalToolUnexpectedExceptionIsUnknown() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.throwUnexpected = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.EXTERNAL);

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = :PROBE], 'Core must not undo a tool with external effects.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void externalToolRetriesOnlyWhenItAsksTo() {
        KernelTestTool.throwRetryable = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.EXTERNAL);

        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void onlyAnAdmittedInOrgOrReadsOutsideCommandIsRetrySafe() {
        AgentCommand__c unadmitted = new AgentCommand__c(AdmittedEffects__c = AgentToolTypeService.EFFECTS_IN_ORG);
        AgentCommand__c inOrg = admitted(AgentToolTypeService.EFFECTS_IN_ORG);
        AgentCommand__c external = admitted(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE);
        AgentCommand__c readOnly = admitted(AgentToolTypeService.EFFECTS_READS_OUTSIDE);
        AgentCommand__c blank = admitted(null);
        System.assertEquals(false, AgentToolTypeService.isRetrySafe(unadmitted), 'A command never admitted has no proven binding.');
        System.assertEquals(false, AgentToolTypeService.runsInSavepoint(unadmitted));
        System.assertEquals(true, AgentToolTypeService.isRetrySafe(inOrg));
        System.assertEquals(true, AgentToolTypeService.runsInSavepoint(inOrg));
        System.assertEquals(false, AgentToolTypeService.isRetrySafe(external));
        System.assertEquals(true, AgentToolTypeService.isRetrySafe(readOnly));
        System.assertEquals(false, AgentToolTypeService.runsInSavepoint(readOnly), 'A read-only external call still runs outside a savepoint.');
        System.assertEquals(false, AgentToolTypeService.isRetrySafe(blank), 'A blank admitted value fails closed.');
        System.assertEquals(false, AgentToolTypeService.runsInSavepoint(blank));
        AgentTool__c unknownType = new AgentTool__c(ToolType__c = 'NoSuchToolType');
        System.assertEquals(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE, AgentToolTypeService.effects(unknownType), 'Unknown types fail closed.');
        System.assertEquals(true, AgentToolTypeService.mayChangeOutside(unknownType));
        AgentTool__c unset = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.EFFECTS_UNSET);
        System.assertEquals(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE, AgentToolTypeService.effects(unset), 'A type without Effects fails closed.');
        System.assertEquals(false, AgentToolTypeService.mayChangeOutside(new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL)));
    }

    @IsTest
    static void bindingHashMatchesHashesStoredBeforeEffectsExisted() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'typed_tool', '{"type":"object"}');
        for (
            String toolType : new List<String>{
                AgentToolTypeTestFixtures.IN_ORG,
                AgentToolTypeTestFixtures.EXTERNAL,
                AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL
            }
        ) {
            tool.ToolType__c = toolType;
            List<String> earlier = new List<String>{
                String.valueOf(tool.Id),
                toolType,
                'KernelTestTool',
                String.valueOf(toolType != AgentToolTypeTestFixtures.IN_ORG),
                tool.ImplementationConfiguration__c
            };
            if (toolType == AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL) {
                earlier.add('safeToRepeat');
            }
            String expected = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(JSON.serialize(earlier))));
            System.assertEquals(expected, AgentToolTypeService.bindingHash(tool), 'Commands leased before the upgrade must keep their binding: ' + toolType);
        }
    }

    @IsTest
    static void readOnlyExternalUnexpectedExceptionReturnsToTheModelInsteadOfUnknown() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.throwUnexpected = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = :PROBE], 'Core must not run a tool with external effects in a savepoint.');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, command.Status__c);
        System.assertEquals('TOOL_EXECUTION_ERROR', command.ErrorCode__c);
        AgentRun__c run = AgentKernelTestFactory.getRun(toolRun.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        System.assertEquals(AgentKernelModels.COMMAND_TYPE_MODEL, AgentKernelTestFactory.getCommand(run.CurrentCommand__c).CommandType__c);
    }

    @IsTest
    static void readOnlyExternalCalloutFailureRetries() {
        KernelTestTool.throwCallout = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);

        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void externalCalloutFailureIsUnknown() {
        KernelTestTool.throwCallout = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.EXTERNAL);

        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(toolRun.commandId).Status__c);
    }

    @IsTest
    static void lostReadOnlyExternalCallIsRepeated() {
        ToolRun toolRun = leaseTool(AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentToolTypeService.EFFECTS_READS_OUTSIDE, command.AdmittedEffects__c);
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        AgentKernelTestFactory.updateRecord(command);

        AgentKernel.StaleLeaseRecoveryResult recovered = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());

        System.assertEquals(0, recovered.unknown, 'A lost read-only call is repeated, not reconciled.');
        System.assert(recovered.requeuedCommandIds.contains(command.Id));
        System.assertNotEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void lostExternalCallIsUnknown() {
        ToolRun toolRun = leaseTool(AgentToolTypeTestFixtures.EXTERNAL);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE, command.AdmittedEffects__c);
        command.LeaseExpiresAt__c = System.now().addSeconds(-1);
        AgentKernelTestFactory.updateRecord(command);

        AgentKernel.StaleLeaseRecoveryResult recovered = AgentKernelRecovery.recoverStaleLeases(new List<Id>{ command.Id }, System.now());

        System.assertEquals(1, recovered.unknown);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, AgentKernelTestFactory.getCommand(command.Id).Status__c);
    }

    @IsTest
    static void admittedEffectsAreImmutable() {
        ToolRun toolRun = leaseTool(AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        try {
            Database.update(
                new AgentCommand__c(Id = toolRun.commandId, AdmittedEffects__c = AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE),
                AccessLevel.SYSTEM_MODE
            );
            System.assert(false, 'The admitted Effects value must be immutable.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'), expected.getMessage());
        }
    }

    @IsTest
    static void effectsChangedBeforeFirstInvocationPauses() {
        ToolRun toolRun = leaseTool(AgentToolTypeTestFixtures.READ_ONLY_EXTERNAL);
        AgentTool__c tool = [SELECT Id FROM AgentTool__c WHERE DeveloperName__c = 'typed_tool' LIMIT 1];
        tool.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();

        toolRun.worker.execute(null);

        System.assertEquals(0, KernelTestTool.invocationCount, 'A changed binding is never invoked.');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals('TOOL_BINDING_CHANGED', command.ErrorCode__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(toolRun.runId).Status__c);
    }

    @IsTest
    static void typeWithoutEffectsIsTreatedAsChangingOutside() {
        KernelTestTool.insertAccountName = PROBE;
        KernelTestTool.throwUnexpected = true;
        ToolRun toolRun = runTool(AgentToolTypeTestFixtures.EFFECTS_UNSET);

        System.assertEquals(1, [SELECT COUNT() FROM Account WHERE Name = :PROBE], 'A type without Effects must not run in a savepoint.');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(toolRun.commandId);
        System.assertEquals(AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE, command.AdmittedEffects__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, command.Status__c, 'A type without Effects is never repeated blindly.');
    }

    private class ToolRun {
        Id runId;
        Id commandId;
        ToolCommandQueueable worker;
    }

    private static ToolRun runTool(String toolType) {
        ToolRun toolRun = leaseTool(toolType);
        toolRun.worker.execute(null);
        System.assertEquals(1, KernelTestTool.invocationCount);
        return toolRun;
    }

    private static ToolRun leaseTool(String toolType) {
        KernelTestTool.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'typed_tool', '{"type":"object"}');
        tool.ToolType__c = toolType;
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();
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
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'typed-tool-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(AgentToolTypeService.effects(tool), command.AdmittedEffects__c);

        ToolRun result = new ToolRun();
        result.runId = run.Id;
        result.commandId = command.Id;
        result.worker = new ToolCommandQueueable(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c);
        return result;
    }

    private static AgentCommand__c admitted(String effects) {
        return new AgentCommand__c(AdmittedToolBindingHash__c = 'hash', AdmittedEffects__c = effects);
    }
}
