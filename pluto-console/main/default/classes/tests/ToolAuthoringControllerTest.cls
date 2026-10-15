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
private class ToolAuthoringControllerTest {
    private static final String HAND_WRITTEN = '{"type":"object","properties":{"subject":{"type":"string","description":"Case subject."}},"required":["subject"],"additionalProperties":false}';

    @IsTest
    static void aDraftShowsTheBuiltInputsWithTheAdminsEdits() {
        String priority = firstPriority();
        ToolAuthoringController.DraftView view = ToolAuthoringController.describeDraft(
            'CreateRecord',
            '{"objectApiName":"Case","fields":["Subject","Priority"],"inputOverrides":{' +
                '"recordData.Subject":{"description":"One line naming the product."},' +
                '"recordData.Priority":{"allowedValues":["' +
                priority +
                '"]}}}',
            null
        );

        System.assert(view.buildsInputs);
        System.assertEquals(new List<String>{ 'object', 'recordType', 'fields', 'fieldValues' }, settingTypes(view));
        Map<String, ToolAuthoringController.InputRow> rows = byPath(view);
        ToolAuthoringController.InputRow subject = rows.get('recordData.Subject');
        System.assert(subject.edited);
        System.assertEquals('One line naming the product.', subject.description);
        System.assertEquals('Subject of the Case.', subject.toolDescription, 'Reset goes back to what the tool builds.');
        ToolAuthoringController.InputRow limited = rows.get('recordData.Priority');
        System.assertEquals(new List<String>{ priority }, limited.allowedValues);
        System.assert(limited.offeredValues.size() > 1, 'The admin can still choose from every value the field offers.');
        System.assert(view.schemaJson.contains('One line naming the product.'), 'Show JSON is the exact schema the model is sent.');
        System.assert(view.problems.isEmpty(), String.valueOf(view.problems));
    }

    @IsTest
    static void aWideningEditIsShownOnTheInputItNames() {
        ToolAuthoringController.DraftView view = ToolAuthoringController.describeDraft(
            'UpdateRecord',
            '{"objectApiName":"Case","fields":["Priority"],"inputOverrides":{"recordData.Status":{"description":"Where it is."}}}',
            null
        );
        Boolean found = false;
        for (ToolAuthoringController.Problem problem : view.problems) {
            found = found || (problem.target == 'recordData.Status' && problem.message.contains('names an input this tool does not have'));
        }
        System.assert(found, String.valueOf(view.problems));
    }

    @IsTest
    static void aHandWrittenSchemaIsShownReadOnlyAndRequired() {
        ToolAuthoringController.DraftView view = ToolAuthoringController.describeDraft(AgentToolTypeTestFixtures.IN_ORG, null, HAND_WRITTEN);
        System.assert(!view.buildsInputs);
        System.assertEquals(1, view.inputs.size());
        System.assertEquals(false, view.inputs[0].editable, 'A hand-written schema is edited as JSON.');

        ToolAuthoringController.DraftView missing = ToolAuthoringController.describeDraft(AgentToolTypeTestFixtures.IN_ORG, null, null);
        System.assertEquals('inputSchema', missing.problems[0].target);
    }

    @IsTest
    static void listsEveryToolTypeWithItsImplementationTypeWithoutRunningItsCode() {
        Map<String, String> implementation = new Map<String, String>();
        Integer dmlBefore = Limits.getDmlStatements();
        for (ToolAuthoringController.ToolTypeOption option : ToolAuthoringController.getToolTypes()) {
            implementation.put(option.value, option.implementationType);
        }
        // Cacheable methods may not write, so listing the types runs no describe.
        System.assertEquals(dmlBefore, Limits.getDmlStatements());
        System.assertEquals('Standard', implementation.get('CreateRecord'));
        System.assertEquals('Flow', implementation.get('RunFlow'));
        System.assertEquals('Apex', implementation.get(AgentToolTypeTestFixtures.IN_ORG));
    }

    @IsTest
    static void fieldOptionsSayHowManyObjectsALookupReaches() {
        Map<String, ToolAuthoringController.FieldOption> byName = new Map<String, ToolAuthoringController.FieldOption>();
        for (ToolAuthoringController.FieldOption option : ToolAuthoringController.getFieldOptions('Task')) {
            byName.put(option.value, option);
        }
        System.assertEquals(1, byName.get('AccountId').referenceCount, 'A lookup to one object gets a record picker.');
        System.assert(byName.get('WhatId').referenceCount > 1, 'A lookup to many objects takes an Id.');
        System.assertEquals(0, byName.get('Subject').referenceCount);
    }

    @IsTest
    static void searchesFlowsByLabelOrApiName() {
        for (ToolAuthoringController.Option flow : ToolAuthoringController.searchFlows('northwind')) {
            System.assert(flow.label.toLowerCase().contains('northwind'), flow.label);
        }
        System.assertEquals(0, ToolAuthoringController.searchFlows('no flow has this name 9f1c').size());
    }

    @IsTest
    static void savesSettingsAndNoSchemaForAToolThatBuildsItsInputs() {
        Id toolId = ToolAuthoringController.saveTool(
            header(true),
            'UpdateRecord',
            '{"objectApiName":"Case","fields":["Priority"],"inputOverrides":{"recordData.Priority":{"description":"How urgent."}}}',
            HAND_WRITTEN
        );
        AgentTool__c saved = [SELECT ToolType__c, ImplementationConfiguration__c, InputSchema__c FROM AgentTool__c WHERE Id = :toolId];
        System.assertEquals('UpdateRecord', saved.ToolType__c);
        System.assertEquals(null, saved.InputSchema__c, 'Core builds the schema on each run, so none is stored.');
        System.assert(saved.ImplementationConfiguration__c.contains('How urgent.'));

        ToolAuthoringController.ToolState state = ToolAuthoringController.loadTool(toolId);
        System.assertEquals('How urgent.', byPath(state.view).get('recordData.Priority').description);
    }

    @IsTest
    static void aRefusedSaveWritesNothingAndSaysWhy() {
        String message;
        try {
            ToolAuthoringController.saveTool(
                header(true),
                'UpdateRecord',
                '{"objectApiName":"Case","fields":["Priority"],"inputOverrides":{"recordData.Status":{"required":true}}}',
                null
            );
        } catch (AuraHandledException refused) {
            message = refused.getMessage();
        }
        System.assert(message != null && message.contains('recordData.Status'), message);
        System.assertEquals(0, [SELECT COUNT() FROM AgentTool__c WHERE DeveloperName__c = 'set_priority']);
    }

    @IsTest
    static void refusesAUserWhoCannotEditTools() {
        Id toolId = ToolAuthoringController.saveTool(header(false), 'UpdateRecord', '{"objectApiName":"Case","fields":["Priority"]}', null);
        User reader = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        System.runAs(AgentKernelTestFactory.self()) {
            reader.ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1].Id;
            update reader;
        }
        Boolean refused = false;
        System.runAs(reader) {
            try {
                ToolAuthoringController.saveTool(
                    new AgentTool__c(Id = toolId),
                    'UpdateRecord',
                    '{"objectApiName":"Case","fields":["Priority","Status"]}',
                    null
                );
            } catch (AuraHandledException expected) {
                refused = true;
            }
        }
        System.assert(refused, 'A user who can only read tools must be refused.');
        System.assert(![SELECT ImplementationConfiguration__c FROM AgentTool__c WHERE Id = :toolId].ImplementationConfiguration__c.contains('Status'));
    }

    @IsTest
    static void pickersOfferBusinessObjectsAndTheirParts() {
        System.assert(ToolAuthoringController.searchSObjects('c').isEmpty(), 'A one-letter term searches nothing.');
        List<ToolAuthoringController.Option> objects = ToolAuthoringController.searchSObjects('Case');
        System.assertEquals('Case', objects[0].value, 'An exact match comes first.');

        System.assert(values(ToolAuthoringController.searchStandardTargetSObjects('Case', 'CreateRecord')).contains('Case'));
        System.assert(
            !values(ToolAuthoringController.searchStandardTargetSObjects('AgentTool', 'QueryRecords')).contains('AgentTool__c'),
            'Pluto Core objects are never offered to a tool.'
        );
        System.assert(ToolAuthoringController.searchStandardTargetSObjects(' ', 'UpdateRecord').isEmpty());

        List<String> starting = ToolAuthoringController.getStartingFields('Contact', 'CreateRecord');
        System.assert(starting.contains('LastName'), 'A required field starts on a new Create Record tool.');
        System.assert(ToolAuthoringController.getStartingFields('NotAnObject', 'CreateRecord').isEmpty());

        System.assert(values(ToolAuthoringController.getChildRelationshipOptions('Account')).contains('Contacts'));
        System.assert(ToolAuthoringController.getChildRelationshipOptions('NotAnObject').isEmpty());
        System.assert(ToolAuthoringController.getRecordTypeOptions('NotAnObject').isEmpty());
        for (ToolAuthoringController.Option recordType : ToolAuthoringController.getRecordTypeOptions('Case')) {
            System.assertNotEquals('Master', recordType.value);
        }
        System.assert(ToolAuthoringController.getFieldOptions('NotAnObject').isEmpty());

        System.assertNotEquals(null, ToolAuthoringController.getQueueOptions());
        System.assertNotEquals(null, ToolAuthoringController.getNamedCredentialOptions());
        System.assert(ToolAuthoringController.searchReports('r').isEmpty(), 'A one-letter term searches nothing.');
        System.assertNotEquals(null, ToolAuthoringController.searchReports('no report has this name 9f1c'));

        System.assertEquals('standard:account', ToolAuthoringController.sldsIconName('https://x/img/icon/t4v35/standard/account_120.png'));
        System.assertEquals(null, ToolAuthoringController.sldsIconName('https://x/img/other.png'));
        System.assertEquals(null, ToolAuthoringController.sldsIconName(null));
    }

    @IsTest
    static void refusesAnIncompleteDraftAndSaysWhatToFix() {
        System.assertEquals('A complete tool draft is required.', refusal(null, 'UpdateRecord', null));
        AgentTool__c sneaky = header(true);
        sneaky.InputSchema__c = HAND_WRITTEN;
        System.assertEquals(
            'The tool draft contains a field that cannot be edited here: InputSchema__c. Refresh the page and try again.',
            refusal(sneaky, 'UpdateRecord', null)
        );
        System.assertEquals('Choose a Tool Type.', refusal(header(true), ' ', null));
        System.assertEquals('Settings must be a JSON object.', refusal(header(true), 'UpdateRecord', 'not json'));
        System.assertEquals('Settings must be a JSON object.', refusal(header(true), 'UpdateRecord', '["Case"]'));
        System.assertEquals(0, [SELECT COUNT() FROM AgentTool__c]);

        String message;
        try {
            ToolAuthoringController.loadTool(null);
        } catch (AuraHandledException refused) {
            message = refused.getMessage();
        }
        System.assertEquals('A tool record is required.', message);

        ToolAuthoringController.DraftView untyped = ToolAuthoringController.describeDraft(null, null, null);
        System.assertEquals('toolType', untyped.problems[0].target);
    }

    private static String refusal(AgentTool__c draft, String toolType, String configuration) {
        try {
            ToolAuthoringController.saveTool(draft, toolType, configuration, null);
        } catch (AuraHandledException refused) {
            return refused.getMessage();
        }
        return null;
    }

    private static Set<String> values(List<ToolAuthoringController.Option> options) {
        Set<String> found = new Set<String>();
        for (ToolAuthoringController.Option option : options) {
            found.add(option.value);
        }
        return found;
    }

    private static AgentTool__c header(Boolean active) {
        return new AgentTool__c(
            Name = 'Set Priority',
            AgentDefinition__c = AgentKernelTestFactory.createDefinition().Id,
            DeveloperName__c = 'set_priority',
            Description__c = 'Sets a case priority.',
            IsActive__c = active,
            SortOrder__c = 1
        );
    }

    private static String firstPriority() {
        for (Schema.PicklistEntry entry : Case.Priority.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                return entry.getValue();
            }
        }
        return null;
    }

    private static Map<String, ToolAuthoringController.InputRow> byPath(ToolAuthoringController.DraftView view) {
        Map<String, ToolAuthoringController.InputRow> rows = new Map<String, ToolAuthoringController.InputRow>();
        for (ToolAuthoringController.InputRow row : view.inputs) {
            rows.put(row.path, row);
        }
        return rows;
    }

    private static List<String> settingTypes(ToolAuthoringController.DraftView view) {
        List<String> types = new List<String>();
        for (ToolAuthoringController.SettingView setting : view.settings) {
            types.add(setting.type);
        }
        return types;
    }
}
