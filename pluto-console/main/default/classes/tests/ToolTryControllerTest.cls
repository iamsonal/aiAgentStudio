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
private class ToolTryControllerTest {
    private static final String CASE_SCHEMA = '{"type":"object","properties":{"subject":{"type":"string","description":"Case subject."}},"required":["subject"],"additionalProperties":false}';

    private static AgentTool__c tool(String toolType) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c created = AgentKernelTestFactory.createTool(definition.Id, 'dry_run_tool', CASE_SCHEMA);
        created.ToolType__c = toolType;
        AgentKernelTestFactory.updateRecord(created);
        return created;
    }

    /** Calls tryTool, which always throws, and returns the result it carries; null for a plain error. */
    private static ToolTryController.TryResult dryRun(Id toolId, String input, Id recordId) {
        String message;
        try {
            ToolTryController.tryTool(toolId, input, recordId);
        } catch (AuraHandledException answer) {
            message = answer.getMessage();
        }
        System.assertNotEquals(null, message, 'tryTool must always end in an error, so the platform drops all of the tool\'s work.');
        if (!message.startsWith(ToolTryController.RESULT_MARKER)) {
            return null;
        }
        return (ToolTryController.TryResult) JSON.deserialize(message.substring(ToolTryController.RESULT_MARKER.length()), ToolTryController.TryResult.class);
    }

    @IsTest
    static void aDryRunShowsTheResultAndUndoesTheToolsRecordChanges() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.IN_ORG);
        Account anchor = new Account(Name = 'Anchor for dry run');
        insert anchor;
        KernelTestTool.insertAccountName = 'Written by a dry run';

        ToolTryController.TryResult result = dryRun(created.Id, '{"subject":"Broken printer"}', anchor.Id);

        System.assertEquals(true, result.success, 'Tool error: ' + result.errorMessage);
        System.assertEquals('{"result":"test tool output"}', result.output);
        System.assertEquals(1, result.undoneRecordChanges);
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = 'Written by a dry run'], 'Nothing the tool wrote may be kept.');
        System.assert(result.notUndone.isEmpty());
        AgentKernelModels.ToolRequest sent = KernelTestTool.lastRequest;
        System.assertEquals(null, sent.runId, 'A dry run is not an agent run.');
        System.assertEquals('{"subject":"Broken printer"}', sent.input);
        System.assertEquals(UserInfo.getUserId(), sent.principal.initiatingUserId, 'It runs as the admin.');
        System.assertEquals(UserInfo.getName(), result.ranAs);
        System.assertEquals(anchor.Id, sent.principal.anchorRecordId);
    }

    @IsTest
    static void inputThatBreaksTheSchemaNeverReachesTheTool() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.IN_ORG);

        System.assertNotEquals(null, dryRun(created.Id, '{}', null).inputProblem, 'subject is required.');
        System.assertEquals('Tool input is not valid JSON.', dryRun(created.Id, '{not json', null).inputProblem);
        System.assertEquals('Tool input must be a JSON object.', dryRun(created.Id, '[]', null).inputProblem);
        System.assertEquals(0, KernelTestTool.invocationCount);
    }

    @IsTest
    static void reportsAFailureAndAnEffectThatCannotBeUndone() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.IN_ORG);
        KernelTestTool.publishImmediate = true;
        KernelTestTool.throwUnexpected = true;

        ToolTryController.TryResult result = dryRun(created.Id, '{"subject":"x"}', null);

        System.assertEquals(false, result.success);
        System.assertEquals('Unexpected test tool failure.', result.errorMessage);
        System.assertEquals(1, result.notUndone.size());
        System.assert(result.notUndone[0].contains('immediate platform event'), result.notUndone[0]);
    }

    @IsTest
    static void aToolThatReachesOutsideSalesforceCannotBeTried() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.EXTERNAL);

        ToolTryController.TryState state = ToolTryController.getTryState(created.Id);
        System.assertEquals(false, state.canTry);
        System.assert(state.reason.contains('outside Salesforce'), state.reason);
        System.assertEquals(null, dryRun(created.Id, '{"subject":"x"}', null), 'The refusal is a plain error, not a result.');
        System.assertEquals(0, KernelTestTool.invocationCount);
    }

    @IsTest
    static void refusesAUserWhoCannotEditTools() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.IN_ORG);
        User reader = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        System.runAs(AgentKernelTestFactory.self()) {
            reader.ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
            update reader;
        }

        Boolean stateRefused = false;
        ToolTryController.TryResult result;
        System.runAs(reader) {
            try {
                ToolTryController.getTryState(created.Id);
            } catch (AuraHandledException refused) {
                stateRefused = refused.getMessage().contains('permission to edit Agent Tools');
            }
            result = dryRun(created.Id, '{"subject":"x"}', null);
        }

        System.assert(stateRefused, 'A user who can only read tools must be refused.');
        System.assertEquals(null, result, 'The refusal is a plain error, not a result.');
        System.assertEquals(0, KernelTestTool.invocationCount, 'The tool must never run for that user.');
    }

    @IsTest
    static void givesTheEditorTheSchemaAndAsksForARecordOnlyWhenTheToolUsesOne() {
        AgentTool__c created = tool(AgentToolTypeTestFixtures.IN_ORG);

        ToolTryController.TryState state = ToolTryController.getTryState(created.Id);
        System.assertEquals(true, state.canTry);
        System.assertEquals(CASE_SCHEMA, state.inputSchema);
        System.assertEquals(false, state.needsRecord, 'A custom tool says nothing about the record the agent is on.');

        created.ImplementationConfiguration__c = '{"anchorRecordOnly":true}';
        AgentKernelTestFactory.updateRecord(created);
        state = ToolTryController.getTryState(created.Id);
        System.assertEquals(true, state.needsRecord);
        System.assert(state.recordHelp.contains('record the agent is working on'), state.recordHelp);

        for (String usesRecord : new List<String>{ '{"anchorRecordOnly":true}', '{"defaultFieldValues":{"WhatId":":anchorId"}}' }) {
            created.ImplementationConfiguration__c = usesRecord;
            AgentKernelTestFactory.updateRecord(created);
            System.assertEquals(true, ToolTryController.getTryState(created.Id).needsRecord, usesRecord);
        }
    }
}
