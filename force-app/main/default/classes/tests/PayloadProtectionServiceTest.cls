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
private class PayloadProtectionServiceTest {
    @IsTest
    static void fullModeBoundsAndHashesCanonicalOriginal() {
        PayloadProtectionService.Policy policy = policy('Full', 8, null);

        PayloadProtectionService.ProtectionResult first = PayloadProtectionService.protect('{"b":2,"a":1}', policy);
        PayloadProtectionService.ProtectionResult reordered = PayloadProtectionService.protect('{"a":1,"b":2}', policy);

        System.assertEquals('{"b":2,"', first.protectedPayload);
        System.assertEquals(true, first.truncated);
        System.assertEquals(first.payloadHash, reordered.payloadHash);
        System.assertEquals(13, first.originalLength);
    }

    @IsTest
    static void redactedModeRecursesAndHandlesFreeTextSafely() {
        PayloadProtectionService.Policy policy = policy('Redacted', 32768, new Set<String>{ 'privateValue' });
        String input = '{"safe":"visible","password":"hidden","nested":[{"privateValue":"hidden"},{"token":"hidden"}]}';

        PayloadProtectionService.ProtectionResult protectedJson = PayloadProtectionService.protect(input, policy);
        PayloadProtectionService.ProtectionResult protectedText = PayloadProtectionService.protect('plain secret text', policy);

        System.assert(protectedJson.protectedPayload.contains('"safe":"visible"'));
        System.assertEquals(false, protectedJson.protectedPayload.contains('hidden'), protectedJson.protectedPayload);
        System.assert(protectedJson.protectedPayload.contains('[REDACTED]'));
        System.assertEquals(true, protectedJson.redacted);
        System.assertEquals('[REDACTED NON-JSON; length=17]', protectedText.protectedPayload);
        System.assertEquals(false, protectedText.protectedPayload.contains('secret'));
    }

    @IsTest
    static void hashOnlyAndNoneRetainNoRawContent() {
        String raw = '{"password":"do-not-store"}';

        PayloadProtectionService.ProtectionResult hashOnly = PayloadProtectionService.protect(raw, policy('Hash Only', 32768, null));
        PayloadProtectionService.ProtectionResult none = PayloadProtectionService.protect(raw, policy('None', 32768, null));

        System.assertNotEquals(null, hashOnly.payloadHash);
        System.assert(hashOnly.protectedPayload.contains('"protectionMode":"Hash Only"'));
        System.assertEquals(false, hashOnly.protectedPayload.contains('do-not-store'));
        System.assertEquals(null, none.protectedPayload);
        System.assertEquals(null, none.payloadHash);
        System.assertEquals(null, none.originalLength);
    }

    @IsTest
    static void configurationValidationRejectsInvalidBoundsAndKeys() {
        assertPolicyFailure(invalidModePolicy(), 'retention mode');
        assertPolicyFailure(invalidRetainedPolicy(), 'whole number');
        assertPolicyFailure(invalidKeysPolicy('{"not":"an array"}'), 'JSON array');
        assertPolicyFailure(invalidKeysPolicy('["Token","token"]'), 'unique');
        assertPolicyFailure(invalidKeysPolicy('["' + repeat('x', 81) + '"]'), 'length');
        List<String> tooMany = new List<String>();
        for (Integer index = 0; index < 26; index++) {
            tooMany.add('key' + index);
        }
        assertPolicyFailure(invalidKeysPolicy(JSON.serialize(tooMany)), 'count');
    }

    @IsTest
    static void redactionDepthAndSizeRemainBounded() {
        String deep = '{"password":"root"';
        for (Integer index = 0; index < 25; index++) {
            deep += ',"level' + index + '":{';
        }
        deep += '"password":"deep"';
        for (Integer index = 0; index < 25; index++) {
            deep += '}';
        }
        deep += '}';

        PayloadProtectionService.ProtectionResult result = PayloadProtectionService.protect(deep, policy('Redacted', 120, null));

        System.assert(result.protectedPayload.length() <= 120);
        System.assertEquals(false, result.protectedPayload.contains('"root"'));
        System.assertEquals(false, result.protectedPayload.contains('"deep"'));
    }

    @IsTest
    static void activeAndUnknownRunsRetainOperationalPayloads() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy hashOnly = AgentExecutionPolicyService.defaults();
            hashOnly.payloadRetentionMode = 'Hash Only';
            AgentKernelTestFactory.configureExecutionPolicy(hashOnly);
            AgentKernelTestFactory.createTool(definition.Id, 'unknown_tool', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"password":"active-secret"}');
            AgentRun__c activeRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c modelCommand = AgentKernelTestFactory.getCommand(started.commandId);
            System.assert(activeRun.Input__c.contains('active-secret'));
            System.assert(modelCommand.Input__c.contains('active-secret'));

            AgentKernelModels.CommandSpec toolSpec = new AgentKernelModels.CommandSpec(
                AgentKernelModels.COMMAND_TYPE_TOOL,
                '{"password":"tool-secret"}',
                'unknown_tool'
            );
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.continueWith(activeRun.Id, modelCommand.Id, activeRun.Revision__c, modelCommand.OperationKey__c, null, toolSpec)
            );
            activeRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c toolCommand = AgentKernelTestFactory.getCommand(activeRun.CurrentCommand__c);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.unknown(
                    activeRun.Id,
                    toolCommand.Id,
                    activeRun.Revision__c,
                    toolCommand.OperationKey__c,
                    'UNKNOWN',
                    'Requires reconciliation.'
                )
            );

            AgentRun__c waitingRun = AgentKernelTestFactory.getRun(started.runId);
            toolCommand = AgentKernelTestFactory.getCommand(toolCommand.Id);
            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, waitingRun.Status__c);
            System.assert(waitingRun.Input__c.contains('active-secret'));
            System.assert(toolCommand.Input__c.contains('tool-secret'));

            AgentKernelModels.ReconciliationRequest reconciliation = new AgentKernelModels.ReconciliationRequest();
            reconciliation.runId = waitingRun.Id;
            reconciliation.commandId = toolCommand.Id;
            reconciliation.expectedRunRevision = waitingRun.Revision__c;
            reconciliation.operationKey = toolCommand.OperationKey__c;
            reconciliation.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
            reconciliation.confirmedOutput = '{"confirmed":true}';
            reconciliation.reason = 'Verified externally.';
            AgentKernel.reconcileUnknownOutcome(reconciliation);
            AgentRun__c reconciledRun = AgentKernelTestFactory.getRun(waitingRun.Id);
            AgentCommand__c nextModel = AgentKernelTestFactory.getCommand(reconciledRun.CurrentCommand__c);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, reconciledRun.Status__c);
            System.assert(nextModel.Input__c.contains('confirmed'));
        }
    }

    @IsTest
    static void terminalMinimizationFollowsEveryMode() {
        assertTerminalMode('Full', 20, '{"password":"secret","safe":"kept"}', true, false);
        assertTerminalMode('Redacted', 32768, '{"password":"secret","safe":"kept"}', true, true);
        assertTerminalMode('Hash Only', 32768, '{"password":"secret","safe":"kept"}', false, false);
        assertTerminalMode('None', 32768, '{"password":"secret","safe":"kept"}', false, false);
    }

    @IsTest
    static void terminalRunsAreMinimizedWhilePausedRetainsCheckpoint() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy hashOnly = AgentExecutionPolicyService.defaults();
            hashOnly.payloadRetentionMode = 'Hash Only';
            AgentKernelTestFactory.configureExecutionPolicy(hashOnly);

            AgentKernelModels.StartResult failed = AgentKernelTestFactory.start(definition.Id, '{"password":"failed"}');
            applyFailure(failed);
            assertCleared(failed.runId);

            AgentKernelModels.StartResult cancelled = AgentKernelTestFactory.start(definition.Id, '{"password":"cancelled"}');
            AgentKernel.cancel(cancelled.runId, cancelled.revision, 'cancel');
            assertCleared(cancelled.runId);

            AgentKernelModels.StartResult pausedStart = AgentKernelTestFactory.start(definition.Id, '{"password":"paused"}');
            AgentRun__c toPause = AgentKernelTestFactory.getRun(pausedStart.runId);
            AgentKernel.pause(pausedStart.runId, toPause.Revision__c, 'pause for checkpoint');
            AgentRun__c paused = AgentKernelTestFactory.getRun(pausedStart.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assertNotEquals(null, paused.Input__c);
            System.assertEquals(null, paused.CompletedAt__c);
            System.assertNotEquals(null, paused.PurgeAfter__c);
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(pausedStart.commandId).Status__c);
        }
    }

    @IsTest
    static void terminalMinimizationDoesNotReadHistoricalModelCommands() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy hashOnly = AgentExecutionPolicyService.defaults();
            hashOnly.payloadRetentionMode = 'Hash Only';
            AgentKernelTestFactory.configureExecutionPolicy(hashOnly);
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            List<AgentCommand__c> historical = new List<AgentCommand__c>();
            for (Integer index = 0; index < 200; index++) {
                historical.add(
                    new AgentCommand__c(
                        AgentRun__c = started.runId,
                        CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                        Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                        ExpectedRunRevision__c = started.revision,
                        OperationKey__c = 'minimized-history-' + index,
                        AttemptNumber__c = 1,
                        InputHash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf('input-' + index))),
                        OutputHash__c = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf('output-' + index)))
                    )
                );
            }
            insert historical;

            Test.startTest();
            Integer rowsBefore = Limits.getQueryRows();
            AgentKernel.pause(started.runId, started.revision, 'pause');
            Integer rowsRead = Limits.getQueryRows() - rowsBefore;
            Test.stopTest();

            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assert(rowsRead <= 4, 'Pausing should not reload historical model commands.');
        }
    }

    @IsTest
    static void protectedEventsRemainImmutable() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy hashOnly = AgentExecutionPolicyService.defaults();
        hashOnly.payloadRetentionMode = 'Hash Only';
        AgentKernelTestFactory.configureExecutionPolicy(hashOnly);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"password":"event-secret"}');
        List<AgentEvent__c> events = AgentKernelTestFactory.getEvents(started.runId);
        AgentEvent__c accepted = events[1];
        System.assertEquals('Hash Only', accepted.PayloadProtectionMode__c);
        System.assertNotEquals(null, accepted.PayloadHash__c);
        System.assertEquals(false, accepted.Payload__c.contains('event-secret'));
        accepted.Summary__c = 'mutated';
        try {
            Database.update(accepted, AccessLevel.SYSTEM_MODE);
            System.assert(false, 'Protected events must remain immutable.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
    }

    private static void assertTerminalMode(String mode, Integer retainedLimit, String input, Boolean expectsRetained, Boolean expectsRedacted) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy retention = AgentExecutionPolicyService.defaults();
        retention.payloadRetentionMode = mode;
        retention.retainedPayloadCharacters = retainedLimit;
        AgentKernelTestFactory.configureExecutionPolicy(retention);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, input);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(run.Id, command.Id, run.Revision__c, command.OperationKey__c, '{"password":"output-secret","result":"done"}')
        );

        run = AgentKernelTestFactory.getRun(started.runId);
        command = AgentKernelTestFactory.getCommand(command.Id);
        System.assertEquals(expectsRetained, run.Input__c != null);
        System.assertEquals(expectsRetained, run.Output__c != null);
        System.assertEquals(expectsRetained, command.Input__c != null);
        System.assertEquals(expectsRetained, command.Output__c != null);
        if (mode == 'None') {
            System.assertEquals(null, run.InputHash__c);
            System.assertEquals(null, command.OutputHash__c);
        } else {
            System.assertNotEquals(null, run.InputHash__c);
            System.assertNotEquals(null, command.OutputHash__c);
        }
        if (expectsRedacted) {
            System.assertEquals(false, run.Input__c.contains('secret'));
            System.assertEquals(false, run.Output__c.contains('output-secret'));
        }
        if (mode == 'Full') {
            System.assert(run.Input__c.length() <= retainedLimit);
            System.assert(run.Output__c.length() <= retainedLimit);
        }
    }

    private static void applyFailure(AgentKernelModels.StartResult started) {
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.terminalFailure(started.runId, command.Id, started.revision, command.OperationKey__c, 'TEST_FAILURE', 'failed')
        );
    }

    private static void assertCleared(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        System.assertEquals(null, run.Input__c);
        System.assertNotEquals(null, run.InputHash__c);
        for (AgentCommand__c command : [
            SELECT Input__c, Output__c, InputHash__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId
            WITH SYSTEM_MODE
        ]) {
            System.assertEquals(null, command.Input__c);
            System.assertEquals(null, command.Output__c);
            System.assertNotEquals(null, command.InputHash__c);
        }
    }

    private static PayloadProtectionService.Policy policy(String mode, Integer retainedCharacters, Set<String> sensitiveKeys) {
        PayloadProtectionService.Policy policy = new PayloadProtectionService.Policy();
        policy.mode = mode;
        policy.retainedCharacters = retainedCharacters;
        policy.sensitiveKeys = sensitiveKeys == null ? new Set<String>() : sensitiveKeys;
        return policy;
    }

    private static void assertPolicyFailure(AgentExecutionPolicyService.Policy policy, String expectedMessage) {
        try {
            PayloadProtectionService.validatePolicy(AgentExecutionPolicyService.toPayloadPolicy(policy), policy.sensitiveJsonKeys);
            System.assert(false, 'Expected configuration validation failure.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().toLowerCase().contains(expectedMessage.toLowerCase()), expected.getMessage());
        }
    }

    private static AgentExecutionPolicyService.Policy invalidModePolicy() {
        AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
        policy.payloadRetentionMode = 'Invalid';
        return policy;
    }

    private static AgentExecutionPolicyService.Policy invalidRetainedPolicy() {
        AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
        policy.retainedPayloadCharacters = -1;
        return policy;
    }

    private static AgentExecutionPolicyService.Policy invalidKeysPolicy(String keys) {
        AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
        policy.sensitiveJsonKeys = keys;
        return policy;
    }

    private static String repeat(String value, Integer count) {
        String result = '';
        for (Integer index = 0; index < count; index++) {
            result += value;
        }
        return result;
    }
}
