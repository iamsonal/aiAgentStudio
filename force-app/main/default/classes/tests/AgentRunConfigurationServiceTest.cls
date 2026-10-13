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
private class AgentRunConfigurationServiceTest {
    @IsTest
    static void resolvesActiveConfigurationForRun() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(
            definition.Id,
            'configured_tool',
            '{"type":"object","properties":{},"additionalProperties":false}'
        );
        tool.ImplementationConfiguration__c = '{"objectApiName":"Case"}';
        tool.AllowedSensitiveDataCategories__c = 'Email';
        AgentKernelTestFactory.updateRecord(tool);
        AgentContextProvider__c contextProvider = AgentKernelTestFactory.createContextProvider(
            definition.Id,
            'configured_context',
            'KernelTestContextProviderAlpha'
        );
        contextProvider.ImplementationConfiguration__c = '{"mode":"active"}';
        AgentKernelTestFactory.updateRecord(contextProvider);

        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentDefinition__c resolvedDefinition = AgentRunConfigurationService.getDefinition(started.runId);
        AgentTool__c resolvedTool = AgentRunConfigurationService.getTool(started.runId, 'configured_tool');
        AgentContextProvider__c resolvedContext = AgentRunConfigurationService.getContextProviders(started.runId)[0];
        AgentExecutionPolicyService.Policy resolvedPolicy = AgentRunConfigurationService.getExecutionPolicy(started.runId);

        System.assertEquals(definition.Id, resolvedDefinition.Id);
        System.assertEquals(tool.Id, resolvedTool.Id);
        System.assertEquals('{"objectApiName":"Case"}', resolvedTool.ImplementationConfiguration__c);
        System.assertEquals('Email', resolvedTool.AllowedSensitiveDataCategories__c);
        System.assertEquals(contextProvider.Id, resolvedContext.Id);
        System.assertEquals('{"mode":"active"}', resolvedContext.ImplementationConfiguration__c);
        System.assertEquals(2, resolvedPolicy.maxRetries);
    }

    @IsTest
    static void absentOverridesUseCoreDefaultsAndSnapshotThem() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.MaxRetries__c = null;
        update definition;

        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentRun__c run = [
            SELECT MaxRetries__c, PayloadRetentionMode__c, PayloadRetentionDays__c, RecordRetentionDays__c
            FROM AgentRun__c
            WHERE Id = :started.runId
            WITH SYSTEM_MODE
        ];

        System.assertEquals(AgentExecutionPolicyService.DEFAULT_MAX_RETRIES, run.MaxRetries__c);
        System.assertEquals(PayloadProtectionService.MODE_REDACTED, run.PayloadRetentionMode__c);
        System.assertEquals(AgentExecutionPolicyService.DEFAULT_PAYLOAD_RETENTION_DAYS, run.PayloadRetentionDays__c);
        System.assertEquals(null, run.RecordRetentionDays__c);
    }

    @IsTest
    static void runKeepsCapturedRetryBudgetAfterDefinitionChanges() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 10, 1);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        definition.MaxRetries__c = 8;
        update definition;

        AgentExecutionPolicyService.Policy resolvedPolicy = AgentRunConfigurationService.getExecutionPolicy(started.runId);

        System.assertEquals(1, resolvedPolicy.maxRetries);
        System.assertEquals(1, [SELECT MaxRetries__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE].MaxRetries__c);
    }

    @IsTest
    static void missingToolFailsClosed() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        try {
            AgentRunConfigurationService.getTool(started.runId, 'not_configured');
            System.assert(false, 'Expected an unconfigured tool to be rejected.');
        } catch (AgentKernelException.NotFoundException expected) {
            System.assert(expected.getMessage().contains('active run configuration'));
        }
    }

    @IsTest
    static void extensionModelUsesNeutralRecords() {
        AgentKernelModels.ModelRequest request = new AgentKernelModels.ModelRequest();
        request.tools = new List<AgentKernelModels.ToolDefinition>{ new AgentKernelModels.ToolDefinition() };
        System.assertEquals(1, request.tools.size());
    }

    @IsTest
    static void repeatedConfigurationReadsUseTransactionCaches() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'cached_tool', '{"type":"object"}');
        AgentKernelTestFactory.createContextProvider(definition.Id, 'cached_context', 'KernelTestContextProviderAlpha');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        AgentRunConfigurationService.getDefinition(started.runId);
        AgentRunConfigurationService.getContextProviders(started.runId);
        AgentRunConfigurationService.getDefinition(started.runId);
        AgentRunConfigurationService.getTools(started.runId);
        AgentRunConfigurationService.getTools(started.runId);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        System.assertEquals(1, queriesUsed, 'The run-to-definition lookup should be queried only once per transaction.');
    }
}
