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
private class AgentKernelValidationTest {
    @IsTest
    static void duplicateActiveToolNamesAreRejectedCaseInsensitively() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'lookup_customer', '{"type":"object"}');
        AgentKernelTestFactory.createTool(definition.Id, 'LOOKUP_CUSTOMER', '{"type":"object"}');

        Boolean rejected = false;
        try {
            AgentConfigService.validate(definition);
        } catch (AgentKernelException.ConfigurationException e) {
            rejected = true;
            System.assert(e.getMessage().contains('unique'), 'The error should identify duplicate active tool names.');
        }
        System.assert(rejected, 'Duplicate active tool developer names must be rejected.');
    }

    @IsTest
    static void malformedAgentOutputSchemaIsRejected() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.OutputSchema__c = '{"type":';
        update definition;

        Boolean rejected = false;
        try {
            AgentConfigService.validate(definition);
        } catch (AgentKernelException.ConfigurationException e) {
            rejected = true;
            System.assert(e.getMessage().contains('valid JSON'), e.getMessage());
        }
        System.assert(rejected, 'Malformed agent output JSON must be rejected.');
    }

    @IsTest
    static void malformedToolInputSchemaIsRejectedAtSave() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'bad_schema_tool', '{"type":"object"}');
        tool.InputSchema__c = '{"type":';

        Database.SaveResult saved = Database.update(new AgentTool__c(Id = tool.Id, InputSchema__c = tool.InputSchema__c), false);
        Boolean rejected = !saved.isSuccess();
        if (rejected) {
            System.assert(saved.getErrors()[0].getMessage().contains('valid JSON'), saved.getErrors()[0].getMessage());
        }
        System.assert(rejected, 'Malformed tool input JSON must be rejected when the record is saved.');
        System.assertNotEquals('{"type":', [SELECT InputSchema__c FROM AgentTool__c WHERE Id = :tool.Id].InputSchema__c);

        Boolean runtimeRejected = false;
        for (
            AgentConfigurationValidator.Finding finding : AgentConfigurationValidator.collectErrors(
                definition,
                new List<AgentTool__c>{ tool },
                new List<AgentContextProvider__c>()
            )
        ) {
            if (finding.code == 'TOOL_INPUT_SCHEMA_INVALID')
                runtimeRejected = true;
        }
        System.assert(runtimeRejected, 'Runtime validation must also reject a malformed in-memory tool.');
    }

    @IsTest
    static void toolTypeWithMissingClassIsRejected() {
        AgentToolTypeService.registerForTest('MissingAdapterType', 'MissingToolAdapter', AgentToolTypeService.EFFECTS_IN_ORG);
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unsupported_tool', '{"type":"object"}');
        tool.ToolType__c = 'MissingAdapterType';

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );

        Boolean foundImplementationError = false;
        for (AgentConfigurationValidator.Finding finding : findings) {
            if (finding.code == 'TOOL_IMPLEMENTATION_INVALID') {
                foundImplementationError = true;
            }
        }
        System.assert(foundImplementationError, 'Core must reject unknown tool adapters.');

        try {
            AgentConfigService.newTool(tool);
            System.assert(false, 'The runtime factory must reject unknown adapters.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('was not found'), 'Unexpected message: ' + expected.getMessage());
        }
    }

    @IsTest
    static void newToolResolvesTheToolTypesClass() {
        AgentTool__c tool = new AgentTool__c(ToolType__c = AgentToolTypeTestFixtures.IN_ORG);
        System.assert(AgentConfigService.newTool(tool) instanceof KernelTestTool);
    }

    @IsTest
    static void newToolRejectsAnUnknownToolType() {
        try {
            AgentConfigService.newTool(new AgentTool__c(ToolType__c = 'NoSuchToolType'));
            System.assert(false, 'An unknown tool type must be rejected.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('NoSuchToolType'), expected.getMessage());
        }
    }

    @IsTest
    static void standardToolTypesShipWithCore() {
        Map<String, String> expected = new Map<String, String>{
            'QueryRecords' => 'StandardQueryRecordsTool',
            'CreateRecord' => 'StandardCreateRecordTool',
            'UpdateRecord' => 'StandardUpdateRecordTool',
            'RunFlow' => 'StandardRunFlowTool',
            'RunFlowWithExternalEffects' => 'StandardRunFlowTool',
            'PostChatter' => 'StandardPostChatterTool'
        };
        for (String developerName : expected.keySet()) {
            AgentToolType__mdt toolType = AgentToolTypeService.toolType(developerName);
            System.assertNotEquals(null, toolType, developerName);
            System.assertEquals(expected.get(developerName), toolType.ToolClass__c);
            System.assertEquals(
                developerName == 'RunFlowWithExternalEffects' ? AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE : AgentToolTypeService.EFFECTS_IN_ORG,
                toolType.Effects__c,
                developerName
            );
            System.assertEquals(
                !developerName.startsWith('Run'),
                AgentConfigService.newTool(new AgentTool__c(ToolType__c = developerName)) instanceof IRequesterFilteredTool,
                'Only Run Flow text is withheld on attended runs: ' + developerName
            );
            System.assertEquals(developerName.startsWith('RunFlow') ? 'Flow' : 'Standard', toolType.ImplementationType__c, developerName);
            System.assertEquals(new Set<String>{ 'CreateRecord', 'UpdateRecord' }.contains(developerName), toolType.RequiresObject__c, developerName);
            System.assert(AgentConfigService.newTool(new AgentTool__c(ToolType__c = developerName)) != null, developerName);
        }
    }

    @IsTest
    static void implementationTypeFollowsTheToolType() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c custom = AgentKernelTestFactory.createTool(definition.Id, 'custom_tool', '{"type":"object"}');
        System.assertEquals('Apex', [SELECT ImplementationType__c FROM AgentTool__c WHERE Id = :custom.Id].ImplementationType__c);

        AgentTool__c standard = new AgentTool__c(ToolType__c = 'UpdateRecord');
        AgentTool__c flow = new AgentTool__c(ToolType__c = 'RunFlow');
        AgentTool__c unknown = new AgentTool__c(ToolType__c = 'NoSuchToolType');
        AgentToolTypeService.stampImplementationType(new List<AgentTool__c>{ standard, flow, unknown });
        System.assertEquals('Standard', standard.ImplementationType__c);
        System.assertEquals('Flow', flow.ImplementationType__c);
        System.assertEquals(null, unknown.ImplementationType__c);
    }

    @IsTest
    static void objectToolTypeRequiresAnObjectAtSave() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'object_tool', '{"type":"object"}');
        tool.ToolType__c = 'UpdateRecord';
        tool.ImplementationConfiguration__c = '{"fields":["Name"]}';
        try {
            AgentKernelTestFactory.updateRecord(tool);
            System.assert(false, 'An UpdateRecord tool without an object must be rejected.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('objectApiName'), expected.getMessage());
        }
    }

    @IsTest
    static void derivedSchemaFollowsTheWritableFields() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = new AgentTool__c(
            Name = 'set_case',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'set_case',
            Description__c = 'Updates a case.',
            ToolType__c = 'UpdateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority"]}',
            IsActive__c = true
        );
        AgentKernelTestFactory.insertRecord(tool);
        AgentKernelTestFactory.updateRecord(
            new AgentTool__c(Id = tool.Id, ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority","Status"]}')
        );

        AgentTool__c saved = savedTool(tool.Id);
        System.assertEquals(null, saved.InputSchema__c, 'A standard tool stores no schema; Core builds it on each run.');
        String schema = ToolSchemaService.effectiveSchema(saved).schema;
        System.assert(schema.contains('"Status"'), 'A field added to fields reaches the model: ' + schema);
    }

    @IsTest
    static void derivedSchemaFollowsTheQuery() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = new AgentTool__c(
            Name = 'find_cases',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'find_cases',
            Description__c = 'Finds cases.',
            ToolType__c = 'QueryRecords',
            ImplementationConfiguration__c = '{"query":"SELECT Subject FROM Case WHERE Status = :status LIMIT 10"}',
            IsActive__c = true
        );
        AgentKernelTestFactory.insertRecord(tool);
        System.assert(ToolSchemaService.effectiveSchema(savedTool(tool.Id)).schema.contains('"status"'));

        AgentKernelTestFactory.updateRecord(
            new AgentTool__c(Id = tool.Id, ImplementationConfiguration__c = '{"query":"SELECT Subject FROM Case WHERE Priority = :priority LIMIT 10"}')
        );

        String schema = ToolSchemaService.effectiveSchema(savedTool(tool.Id)).schema;
        System.assert(schema.contains('"priority"') && !schema.contains('"status"'), 'A changed bind reaches the model: ' + schema);
    }

    @IsTest
    static void aStoredSchemaOnAToolThatBuildsItsInputsIsRejected() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = new AgentTool__c(
            Name = 'set_case',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'set_case',
            Description__c = 'Updates a case.',
            ToolType__c = 'UpdateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority","Status"]}',
            InputSchema__c = '{"type":"object","properties":{"recordId":{"type":"string"},"recordData":{"type":"object","properties":{"Priority":{"type":"string","description":"How urgent."}},"additionalProperties":false}},"required":["recordId","recordData"],"additionalProperties":false}',
            IsActive__c = true
        );
        Database.SaveResult saved = Database.insert(tool, false);

        System.assertEquals(false, saved.isSuccess());
        System.assert(saved.getErrors()[0].getMessage().contains('Clear the Input Schema'), saved.getErrors()[0].getMessage());
    }

    @IsTest
    static void editsThatWidenAToolAreRejectedAtSave() {
        AgentTool__c tool = new AgentTool__c(
            Name = 'set_case',
            AgentDefinition__c = AgentKernelTestFactory.createDefinition().Id,
            DeveloperName__c = 'set_case',
            Description__c = 'Updates a case.',
            ToolType__c = 'UpdateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority"],"inputOverrides":{"recordData.Status":{"description":"Where the case is."}}}',
            IsActive__c = true
        );
        Database.SaveResult saved = Database.insert(tool, false);

        System.assertEquals(false, saved.isSuccess());
        System.assert(saved.getErrors()[0].getMessage().contains('recordData.Status'), saved.getErrors()[0].getMessage());
    }

    @IsTest
    static void anInactiveToolMaySaveBeforeItCanBuildItsInputs() {
        AgentTool__c tool = new AgentTool__c(
            Name = 'set_case',
            AgentDefinition__c = AgentKernelTestFactory.createDefinition().Id,
            DeveloperName__c = 'set_case',
            Description__c = 'Updates a case.',
            ToolType__c = 'UpdateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case"}',
            IsActive__c = false
        );
        System.assert(Database.insert(tool, false).isSuccess(), 'An admin can finish an inactive tool later.');
        System.assertNotEquals(null, ToolSchemaService.effectiveSchema(savedTool(tool.Id)).problem);
    }

    @IsTest
    static void anActiveToolWhoseTypeDoesNotBuildInputsNeedsASchemaAtSave() {
        AgentTool__c tool = new AgentTool__c(
            Name = 'lookup_order',
            AgentDefinition__c = AgentKernelTestFactory.createDefinition().Id,
            DeveloperName__c = 'lookup_order',
            Description__c = 'Looks up an order.',
            ToolType__c = AgentToolTypeTestFixtures.IN_ORG,
            IsActive__c = true
        );
        Database.SaveResult saved = Database.insert(tool, false);
        System.assertEquals(false, saved.isSuccess());
        System.assert(saved.getErrors()[0].getMessage().contains('needs an Input Schema'), saved.getErrors()[0].getMessage());
    }

    @IsTest
    static void aBuiltEmailInputNeedsTheEmailCategoryAtSave() {
        AgentTool__c tool = new AgentTool__c(
            Name = 'open_case',
            AgentDefinition__c = AgentKernelTestFactory.createDefinition().Id,
            DeveloperName__c = 'open_case',
            Description__c = 'Opens a case.',
            ToolType__c = 'CreateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Subject","SuppliedEmail"]}',
            IsActive__c = true
        );
        Database.SaveResult saved = Database.insert(tool, false);
        System.assertEquals(false, saved.isSuccess());
        System.assert(saved.getErrors()[0].getMessage().contains('Allow the Email category'), saved.getErrors()[0].getMessage());
    }

    private static AgentTool__c savedTool(Id toolId) {
        return [SELECT Id, DeveloperName__c, ToolType__c, ImplementationConfiguration__c, InputSchema__c FROM AgentTool__c WHERE Id = :toolId];
    }

    @IsTest
    static void apexConfigurationPassesThrough() {
        AgentTool__c apex = new AgentTool__c(ImplementationConfiguration__c = '{"a":1}');
        System.assertEquals('{"a":1}', AgentConfigService.toolConfiguration(apex), 'Apex configuration passes through verbatim.');
    }

    @IsTest
    static void modelFacingToolFailureCarriesTheToolsBoundedError() {
        String payload = AgentKernelModels.toolFailurePayload('UNKNOWN_FIELD', 'Unknown field: Case.Priorty.');
        System.assert(payload.contains('UNKNOWN_FIELD'), 'The model needs the tool\'s code to correct the call.');
        System.assert(payload.contains('Unknown field: Case.Priorty.'));
        String oversized = AgentKernelModels.toolFailurePayload('TOOL_ERROR', ''.leftPad(AgentKernelModels.MAX_TOOL_ERROR_MESSAGE_CHARACTERS + 500, 'x'));
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(oversized);
        System.assertEquals(AgentKernelModels.MAX_TOOL_ERROR_MESSAGE_CHARACTERS, ((String) parsed.get('errorMessage')).length());
    }

    @IsTest
    static void dynamicTypeResolutionSupportsUnqualifiedImplementations() {
        Type resolved = AgentConfigService.resolveImplementationType('KernelTestModelProvider');

        System.assertNotEquals(null, resolved);
        System.assert(resolved.newInstance() instanceof IModelProvider);
    }

    @IsTest
    static void activeDefinitionSelectorSharesProjectionAndCacheAcrossKeys() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createContextProvider(definition.Id, 'shared_selector_context', 'KernelTestContextProviderAlpha');
        Integer queriesBeforeLoad = Limits.getQueries();

        AgentDefinition__c selectedByName = AgentConfigService.getActiveDefinition('  ' + definition.DeveloperName__c + '  ');

        System.assertEquals(queriesBeforeLoad + 1, Limits.getQueries(), 'A cache miss should use one selector query.');
        System.assertEquals(definition.Id, selectedByName.Id);
        System.assertEquals(1, selectedByName.ContextProviders__r.size());

        AgentDefinition__c selectedById = AgentConfigService.getActiveDefinition(definition.Id);

        System.assertEquals(selectedByName.Id, selectedById.Id);
        System.assertEquals(queriesBeforeLoad + 1, Limits.getQueries(), 'Either lookup key should reuse the same cached projection.');
    }

    @IsTest
    static void dynamicTypeResolutionRejectsNonClassSyntax() {
        Boolean rejected = false;
        try {
            AgentConfigService.resolveImplementationType('bad-name;execute');
        } catch (AgentKernelException.ConfigurationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Only an Apex namespace and class identifier are accepted.');
    }

    @IsTest
    static void queueableCostAllows100JobsAndRejects101() {
        AgentDefinition__c supported = AgentKernelTestFactory.createDefinition(100, 0, 0);
        System.assertEquals(0, AgentConfigurationValidator.collectErrors(supported, new List<AgentTool__c>(), new List<AgentContextProvider__c>()).size());
        AgentConfigService.validate(supported);

        AgentDefinition__c unsupported = AgentKernelTestFactory.createDefinition(1, 50, 0);
        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            unsupported,
            new List<AgentTool__c>(),
            new List<AgentContextProvider__c>()
        );
        System.assertEquals(1, findings.size());
        System.assertEquals('ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM', findings[0].code);
        System.assert(findings[0].message.contains('101 jobs'));
        System.assert(findings[0].message.contains('maximum of 100'));
    }

    @IsTest
    static void agentRunServiceRejectsUnsupportedQueueableCostBeforePersistence() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(1, 50, 0);

        try {
            AgentRunService.start(AgentKernelTestFactory.startRequest(definition, '{}'));
            System.assert(false, 'Expected the unsupported per-run Queueable cost to be rejected.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('101 jobs'));
            System.assert(expected.getMessage().contains('maximum of 100'));
        }

        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }
}
