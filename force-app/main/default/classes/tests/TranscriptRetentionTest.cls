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
private class TranscriptRetentionTest {
    private static final String FEEDBACK = '{"errorCode":"MODEL_OUTPUT_SCHEMA_MISMATCH","errorMessage":"Return JSON."}';

    @IsTest
    static void strictRetentionKeepsTranscriptTurnsReplayableUntilTheRunEnds() {
        useRetentionMode(PayloadProtectionService.MODE_METADATA_ONLY);
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'lookup', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        Id feedbackTurnId = rejectModelResponse(started.runId);
        requestTools(started.runId, 1);
        AgentCommand__c consumed = command(feedbackTurnId);
        System.assertEquals(FEEDBACK, consumed.Input__c, 'A consumed feedback turn stays replayable while the run is active.');
        System.assertEquals(false, consumed.PayloadProtected__c);
        System.assertNotEquals(null, consumed.Sequence__c);

        completeCurrentTool(started.runId);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(run.Id, run.CurrentCommand__c, run.Revision__c, command(run.CurrentCommand__c).OperationKey__c, '{"done":true}')
        );

        consumed = command(feedbackTurnId);
        System.assertEquals(true, consumed.PayloadProtected__c, 'The retention mode applies once the run ends.');
        System.assertEquals(null, consumed.Input__c, 'Hash Only keeps only the hash.');
        System.assertNotEquals(null, consumed.InputHash__c);
    }

    @IsTest
    static void turnsLeavingTheTranscriptWindowGetTheRetentionMode() {
        useRetentionMode(PayloadProtectionService.MODE_METADATA_ONLY);
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(20, 20);
        definition.TranscriptTurnLimit__c = 0;
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        // With no optional turns, the window holds one model turn's eight tool results plus one turn.
        Id oldestTurnId = rejectModelResponse(started.runId);
        rejectModelResponse(started.runId);
        List<AgentCommand__c> toolTurns = new List<AgentCommand__c>();
        for (Integer index = 0; index < AgentKernelModels.MAX_TOOL_CALLS_PER_TURN; index++) {
            toolTurns.add(
                new AgentCommand__c(
                    AgentRun__c = started.runId,
                    CommandType__c = AgentKernelModels.COMMAND_TYPE_TOOL,
                    Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                    ToolName__c = 'lookup',
                    Sequence__c = 100 + index,
                    ExpectedRunRevision__c = started.revision,
                    OperationKey__c = started.runId + ':' + (100 + index) + ':Tool:lookup',
                    DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                    Input__c = '{}',
                    Output__c = '{"found":true}',
                    AvailableAt__c = System.now(),
                    AttemptNumber__c = 1
                )
            );
        }
        AgentKernelTestFactory.insertRecords(toolTurns);
        System.assertEquals(false, command(oldestTurnId).PayloadProtected__c, 'The oldest turn is still inside the window.');

        rejectModelResponse(started.runId);

        AgentCommand__c overflowed = command(oldestTurnId);
        System.assertEquals(true, overflowed.PayloadProtected__c, 'The oldest turn leaves the window and gets the retention mode.');
        System.assertEquals(null, overflowed.Input__c);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM AgentCommand__c WHERE Id IN :toolTurns AND PayloadProtected__c = TRUE WITH SYSTEM_MODE],
            'Turns inside the window stay replayable.'
        );
    }

    private static void useRetentionMode(String mode) {
        AgentExecutionPolicyService.Policy policy = AgentKernelTestFactory.executionPolicyOverride();
        policy.payloadRetentionMode = mode;
        AgentKernelTestFactory.configureExecutionPolicy(policy);
    }

    /** Rejects the current model response, as the model worker does, adding a Model Feedback turn. */
    private static Id rejectModelResponse(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c current = command(run.CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueAfterModelFailure(
                run.Id,
                current.Id,
                run.Revision__c,
                current.OperationKey__c,
                'MODEL_OUTPUT_SCHEMA_MISMATCH',
                'Return JSON.',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, FEEDBACK, null)
            )
        );
        return AgentKernelTestFactory.getRun(runId).CurrentCommand__c;
    }

    private static void requestTools(Id runId, Integer count) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c current = command(run.CurrentCommand__c);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.continueWith(run.Id, current.Id, run.Revision__c, current.OperationKey__c, null, null);
        outcome.nextCommands = new List<AgentKernelModels.CommandSpec>();
        for (Integer index = 0; index < count; index++) {
            AgentKernelModels.CommandSpec spec = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'lookup');
            spec.toolCallId = 'call_' + index;
            outcome.nextCommands.add(spec);
        }
        if (count == 1) {
            outcome.nextCommand = outcome.nextCommands[0];
            outcome.nextCommands = null;
        }
        AgentKernelTestFactory.applyOutcome(outcome);
    }

    private static void completeCurrentTool(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c current = command(run.CurrentCommand__c);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                current.Id,
                run.Revision__c,
                current.OperationKey__c,
                '{"found":true}',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, '{"found":true}', null)
            )
        );
    }

    private static AgentCommand__c command(Id commandId) {
        return [
            SELECT Id, OperationKey__c, Input__c, InputHash__c, PayloadProtected__c, Sequence__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
        ];
    }
}
