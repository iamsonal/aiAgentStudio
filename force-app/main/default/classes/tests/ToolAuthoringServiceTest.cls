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
private class ToolAuthoringServiceTest {
    @IsTest
    static void onlyToolsThatDescribeThemselvesBuildTheirInputs() {
        System.assert(ToolAuthoringService.buildsInputs(new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.AUTHORING)));
        System.assert(!ToolAuthoringService.buildsInputs(new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.IN_ORG)));
        System.assert(!ToolAuthoringService.buildsInputs(new AgentTool__c(ToolType__c = 'NoSuchToolType')));
    }

    @IsTest
    static void leavesToolsWithoutADescriptionToTheAdmin() {
        System.assertEquals(null, ToolAuthoringService.describe(new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.IN_ORG)));
        System.assertEquals(null, ToolAuthoringService.previewSchema(AgentToolTypeTestFixtures.IN_ORG, '{}'));
        System.assertEquals(null, ToolAuthoringService.previewSchema('NoSuchToolType', null));
    }

    @IsTest
    static void aDescriptionThatWritesIsRefusedAndUndone() {
        AgentKernelModels.ToolAuthoring authoring = describe('{"misbehave":"write","inputs":["orderId"]}');
        System.assertEquals(null, authoring.inputSchema);
        System.assert(authoring.problem.contains('without changing records'), authoring.problem);
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = 'Written while describing']);
    }

    @IsTest
    static void aDescriptionThatThrowsReportsItsMessage() {
        System.assertEquals('Name at least one input.', describe('{"misbehave":"throw"}').problem);
        try {
            ToolAuthoringService.previewSchema(AgentToolTypeTestFixtures.AUTHORING, '{}');
            System.assert(false, 'A preview of settings that cannot build a schema says why.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assertEquals('List the inputs in inputs.', expected.getMessage());
        }
    }

    @IsTest
    static void standardToolsDescribeTheirSettings() {
        System.assertEquals(
            new List<String>{ 'objectApiName', 'recordTypeDeveloperName', 'fields', 'defaultFieldValues' },
            settingNames(describeStandard('CreateRecord', '{"objectApiName":"Account","fields":["Name"]}'))
        );
        AgentKernelModels.ToolAuthoring creating = describeStandard('CreateRecord', '{"objectApiName":"Account","fields":["Name"]}');
        System.assertEquals(new List<String>{ 'object', 'recordType', 'fields', 'fieldValues' }, settingTypes(creating));
        System.assertEquals(null, creating.settings[0].objectSetting);
        for (Integer index = 1; index < creating.settings.size(); index++) {
            System.assertEquals('objectApiName', creating.settings[index].objectSetting, 'Field settings name the object they belong to.');
        }
        AgentKernelModels.ToolAuthoring updating = describeStandard('UpdateRecord', '{}');
        System.assertEquals(new List<String>{ 'objectApiName', 'fields', 'defaultFieldValues', 'anchorRecordOnly' }, settingNames(updating));
        System.assertEquals('boolean', updating.settings[3].type);
        System.assert(updating.problem.contains('objectApiName'), 'Settings show even before a schema can be built: ' + updating.problem);
        AgentKernelModels.ToolAuthoring query = describeStandard('QueryRecords', '{"query":"SELECT Id FROM Case WHERE Status = :status LIMIT 10"}');
        System.assertEquals('query', query.settings[0].type);
        System.assertEquals(new Set<String>{ 'status' }, properties(query.inputSchema));
        System.assertEquals(new Set<String>{ 'messageText' }, properties(describeStandard('PostChatter', null).inputSchema));
    }

    private static AgentKernelModels.ToolAuthoring describe(String configuration) {
        return ToolAuthoringService.describe(
            new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.AUTHORING, ImplementationConfiguration__c = configuration)
        );
    }

    private static AgentKernelModels.ToolAuthoring describeStandard(String toolType, String configuration) {
        return ToolAuthoringService.describe(new AgentTool__c(ToolType__c = toolType, ImplementationConfiguration__c = configuration));
    }

    private static Set<String> properties(String schema) {
        return ((Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(schema)).get('properties')).keySet();
    }

    private static List<String> settingTypes(AgentKernelModels.ToolAuthoring authoring) {
        List<String> types = new List<String>();
        for (AgentKernelModels.ToolSetting setting : authoring.settings) {
            types.add(setting.type);
        }
        return types;
    }

    private static List<String> settingNames(AgentKernelModels.ToolAuthoring authoring) {
        List<String> names = new List<String>();
        for (AgentKernelModels.ToolSetting setting : authoring.settings) {
            names.add(setting.name);
        }
        return names;
    }
}
