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
private class ToolSchemaServiceTest {
    private static final String HAND_WRITTEN = '{"type":"object","properties":{"orderId":{"type":"string"}},"additionalProperties":false}';

    @IsTest
    static void buildsEachToolOncePerTransaction() {
        AgentTool__c tool = authoringTool('{"inputs":["orderId"]}');
        KernelTestAuthoringTool.describeCount = 0;
        ToolSchemaService.Resolution first = ToolSchemaService.effectiveSchema(tool);
        ToolSchemaService.Resolution second = ToolSchemaService.effectiveSchema(tool);
        System.assertEquals(1, KernelTestAuthoringTool.describeCount, 'One build serves the request and the checks.');
        System.assertEquals(first.schema, second.schema);
        System.assert(first.built);

        ToolSchemaService.forgetResolved();
        ToolSchemaService.effectiveSchema(tool);
        System.assertEquals(2, KernelTestAuthoringTool.describeCount, 'A later transaction builds again.');
    }

    @IsTest
    static void settingsChangesAreBuiltAgain() {
        AgentTool__c tool = authoringTool('{"inputs":["orderId"]}');
        ToolSchemaService.effectiveSchema(tool);
        tool.ImplementationConfiguration__c = '{"inputs":["orderId","amount"]}';
        System.assertEquals(new Set<String>{ 'orderId', 'amount' }, properties(ToolSchemaService.effectiveSchema(tool).schema));
    }

    @IsTest
    static void appliesTheAdminsEdits() {
        AgentTool__c tool = authoringTool('{"inputs":["orderId","amount"],"inputOverrides":{"orderId":{"required":true,"description":"The order number."}}}');
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(ToolSchemaService.effectiveSchema(tool).schema);
        System.assertEquals('The order number.', ToolSchemaRows.nodeAt(schema, 'orderId').get('description'));
        System.assertEquals(new Set<String>{ 'orderId' }, ToolSchemaRows.requiredNames(schema));
    }

    @IsTest
    static void refusesAStoredSchemaOnAToolThatBuildsItsInputs() {
        AgentTool__c tool = authoringTool('{"inputs":["orderId"]}');
        tool.InputSchema__c = HAND_WRITTEN;
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(tool);
        System.assertEquals(null, resolution.schema, 'A stored schema may hold narrowed values, so it is never ignored silently.');
        System.assert(resolution.problem.contains('Clear the Input Schema'), resolution.problem);
    }

    @IsTest
    static void usesAHandWrittenSchemaAsStored() {
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(
            new AgentTool__c(DeveloperName__c = 'lookup_order', ToolType__c = AgentToolTypeTestFixtures.IN_ORG, InputSchema__c = HAND_WRITTEN)
        );
        System.assertEquals(HAND_WRITTEN, resolution.schema);
        System.assert(!resolution.built);
    }

    @IsTest
    static void aToolThatDoesNotBuildItsInputsNeedsASchema() {
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(
            new AgentTool__c(DeveloperName__c = 'lookup_order', ToolType__c = AgentToolTypeTestFixtures.IN_ORG)
        );
        System.assertEquals('Tool lookup_order needs an Input Schema, because its tool type does not build its inputs.', resolution.problem);
    }

    @IsTest
    static void aToolThatDescribesOnlyItsSettingsUsesTheAdminsSchema() {
        KernelTestAuthoringTool.inputsWrittenByAdmin = true;
        AgentTool__c tool = authoringTool('{}');
        System.assert(!ToolAuthoringService.buildsInputs(tool));
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(tool);
        System.assert(!resolution.built);
        System.assertEquals(1, resolution.authoring.settings.size(), 'The settings are still described for the editor.');
        System.assert(resolution.problem.contains('needs an Input Schema'), resolution.problem);

        tool.InputSchema__c = HAND_WRITTEN;
        System.assertEquals(HAND_WRITTEN, ToolSchemaService.effectiveSchema(tool).schema);
    }

    @IsTest
    static void reportsWhySettingsCannotBuildASchema() {
        System.assertEquals('List the inputs in inputs.', ToolSchemaService.effectiveSchema(authoringTool('{}')).problem);
    }

    private static AgentTool__c authoringTool(String configuration) {
        return new AgentTool__c(
            DeveloperName__c = 'authoring_test_tool',
            ToolType__c = AgentToolTypeTestFixtures.AUTHORING,
            ImplementationConfiguration__c = configuration
        );
    }

    private static Set<String> properties(String schema) {
        return ((Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(schema)).get('properties')).keySet();
    }
}
