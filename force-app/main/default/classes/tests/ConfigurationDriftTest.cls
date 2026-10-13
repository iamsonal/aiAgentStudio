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

/** Every run records the configuration it executed with, and a change during the run is visible. */
@IsTest
private class ConfigurationDriftTest {
    @IsTest
    static void changedToolDuringRunRecordsConfigurationChanged() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'drifting_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        String startHash = AgentKernelTestFactory.getRun(started.runId).ConfigurationHash__c;
        System.assertNotEquals(null, startHash, 'The run records its configuration at start.');

        tool.Description__c = 'A changed description the model now sees.';
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();
        runModel(started);

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertNotEquals(startHash, run.ConfigurationHash__c);
        List<AgentEvent__c> changes = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :run.Id AND EventType__c = :AgentKernelModels.EVENT_CONFIGURATION_CHANGED
            WITH SYSTEM_MODE
        ];
        System.assertEquals(1, changes.size());
        System.assert(changes[0].Payload__c.contains(startHash));
        AgentInvocation__c invocation = [SELECT ConfigurationHash__c FROM AgentInvocation__c WHERE AgentRun__c = :run.Id WITH SYSTEM_MODE LIMIT 1];
        System.assertEquals(run.ConfigurationHash__c, invocation.ConfigurationHash__c);
    }

    @IsTest
    static void configurationChangedNamesWhatChanged() {
        KernelTestModelProvider.mode = 'final';
        KernelTestModelProvider.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 3);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'drifting_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentEvent__c start = [SELECT Payload__c FROM AgentEvent__c WHERE AgentRun__c = :started.runId AND Sequence__c = 1 WITH SYSTEM_MODE];
        System.assert(start.Payload__c.contains('"configuration"'), 'The run records the fingerprint a later change is compared against.');
        System.assert(!start.Payload__c.contains('Run the focused phase-one kernel tests.'), 'The fingerprint never stores the instructions.');

        definition.MaxToolCalls__c = 4;
        AgentKernelTestFactory.updateRecord(definition);
        tool.Description__c = 'A changed description the model now sees.';
        AgentKernelTestFactory.updateRecord(tool);
        AgentConfigService.clearCacheForTest();
        runModel(started);

        AgentEvent__c change = [
            SELECT Summary__c, Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_CONFIGURATION_CHANGED
            WITH SYSTEM_MODE
        ];
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(change.Payload__c);
        List<Object> changes = (List<Object>) payload.get('changes');
        System.assertEquals(2, changes.size(), 'Only the limit and the tool changed: ' + change.Payload__c);
        Map<String, Object> limitChange = (Map<String, Object>) changes[0];
        System.assertEquals('Max Tool Calls', limitChange.get('setting'));
        System.assertEquals(3, limitChange.get('before'));
        System.assertEquals(4, limitChange.get('after'));
        Map<String, Object> toolChange = (Map<String, Object>) changes[1];
        System.assertEquals('drifting_tool', toolChange.get('tool'));
        System.assertEquals('changed', toolChange.get('change'));
        System.assertEquals('Changed Max Tool Calls (3 to 4), changed tool drifting_tool.', change.Summary__c);
        System.assertNotEquals(null, payload.get('configuration'), 'The next change compares against this one.');
    }

    @IsTest
    static void unprovenBaselineRecordsTheChangeWithoutDetail() {
        KernelTestModelProvider.mode = 'final';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 3);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        // A run whose recorded hash no longer matches the start event's fingerprint, as after a protected or truncated payload.
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        run.ConfigurationHash__c = 'f'.repeat(64);
        AgentKernelTestFactory.updateRecord(run);

        definition.MaxToolCalls__c = 4;
        AgentKernelTestFactory.updateRecord(definition);
        AgentConfigService.clearCacheForTest();
        runModel(started);

        AgentEvent__c change = [
            SELECT Summary__c, Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_CONFIGURATION_CHANGED
            WITH SYSTEM_MODE
        ];
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(change.Payload__c);
        System.assert(!payload.containsKey('changes'), 'A baseline that does not match the run cannot prove what changed.');
        System.assertEquals('The agent configuration changed during the run.', change.Summary__c);
    }

    @IsTest
    static void unchangedConfigurationRecordsNoEvent() {
        KernelTestModelProvider.mode = 'final';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        runModel(started);

        System.assertEquals(
            0,
            [
                SELECT COUNT()
                FROM AgentEvent__c
                WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_CONFIGURATION_CHANGED
                WITH SYSTEM_MODE
            ]
        );
    }

    @IsTest
    static void bulkStartsValidateEachDefinitionOnce() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'validated_tool', '{"type":"object"}');
        KernelTestTool.validationCount = 0;
        List<AgentStartRunAction.StartRequest> requests = new List<AgentStartRunAction.StartRequest>();
        for (Integer index = 0; index < 3; index++) {
            AgentStartRunAction.StartRequest request = new AgentStartRunAction.StartRequest();
            request.agentDeveloperName = definition.DeveloperName__c;
            request.input = '{"index":' + index + '}';
            requests.add(request);
        }

        List<AgentStartRunAction.StartResult> results = AgentStartRunAction.start(requests);

        for (AgentStartRunAction.StartResult result : results) {
            System.assertEquals(true, result.started, 'Start failed: ' + result.errorMessage);
        }
        System.assertEquals(1, KernelTestTool.validationCount, 'A definition is validated once per transaction.');
    }

    private static void runModel(AgentKernelModels.StartResult started) {
        AgentCommand__c model = AgentKernelTestFactory.getCommand(started.commandId);
        model.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        model.LeaseToken__c = 'drift-lease';
        model.LeaseExpiresAt__c = System.now().addMinutes(5);
        model.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(model);
        new ModelCommandQueueable(started.runId, model.Id, started.revision, started.operationKey, 'drift-lease').execute(null);
    }
}
