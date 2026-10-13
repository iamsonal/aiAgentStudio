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
private class ContextProviderServiceTest {
    @IsTest
    static void preservesConfigurationOrderAndAppliesTotalBudget() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy contextPolicy = AgentExecutionPolicyService.defaults();
        contextPolicy.contextCharacterBudget = 6;
        AgentKernelTestFactory.configureExecutionPolicy(contextPolicy);
        update definition;
        AgentContextProvider__c alpha = AgentKernelTestFactory.createContextProvider(definition.Id, 'alpha', 'KernelTestContextProviderAlpha');
        AgentContextProvider__c beta = AgentKernelTestFactory.createContextProvider(definition.Id, 'beta', 'KernelTestContextProviderBeta');
        alpha.SortOrder__c = 1;
        alpha.ImplementationConfiguration__c = '{"scope":"private"}';
        beta.SortOrder__c = 2;
        AgentKernelTestFactory.updateRecords(new List<SObject>{ alpha, beta });
        Account anchor = new Account(Name = 'Context anchor');
        insert anchor;

        ContextProviderService.CollectionResult result = ContextProviderService.collect(
            definition,
            null,
            new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, null, anchor.Id, null),
            'operation',
            'original',
            'current'
        );

        System.assertEquals(2, result.contexts.size());
        System.assertEquals('{"scope":"private"}', KernelTestContextProviderAlpha.lastRequest.implementationConfiguration);
        System.assertEquals(anchor.Id, KernelTestContextProviderAlpha.lastRequest.anchorRecordId);
        System.assertEquals('Alpha', result.contexts[0].sourceName);
        System.assertEquals('AAAA', result.contexts[0].content);
        System.assertEquals(false, result.contexts[0].truncated);
        System.assertEquals('Beta', result.contexts[1].sourceName);
        System.assertEquals('BB', result.contexts[1].content);
        System.assertEquals(true, result.contexts[1].truncated);
        System.assertEquals('Truncated', ((Map<String, Object>) result.sourceMetadata[1]).get('status'));
    }

    @IsTest
    static void oversizedRecordSetsKeepTheirLeadingWholeRecords() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy contextPolicy = AgentExecutionPolicyService.defaults();
        contextPolicy.contextCharacterBudget = 5000;
        AgentKernelTestFactory.configureExecutionPolicy(contextPolicy);
        update definition;
        AgentKernelTestFactory.createContextProvider(definition.Id, 'beta', 'KernelTestContextProviderBeta');
        List<Account> accounts = new List<Account>();
        for (Integer index = 0; index < 5; index++) {
            accounts.add(new Account(Name = 'Conversation ' + index, Description = ''.leftPad(1500, 'd')));
        }
        insert accounts;
        KernelTestContextProviderBeta.recordSets = new Map<String, List<SObject>>{
            'Account' => [SELECT Id, Name, Description FROM Account WHERE Id IN :accounts ORDER BY Name ASC]
        };

        ContextProviderService.CollectionResult result = ContextProviderService.collect(definition, null, null, 'operation', 'original', 'current');

        System.assertEquals(1, result.contexts.size(), 'The source is shortened, not dropped.');
        String content = result.contexts[0].content;
        System.assert(content.length() <= 5000);
        System.assert(content.contains(accounts[0].Id), 'The leading record is kept whole.');
        System.assert(!content.contains(accounts[4].Id), 'Trailing records are dropped first.');
        System.assertEquals(true, result.contexts[0].truncated);
        Map<String, Object> metadata = (Map<String, Object>) result.sourceMetadata[0];
        System.assertEquals('Truncated', metadata.get('status'));
        System.assertEquals(content.length(), metadata.get('includedCharacters'));
        JSON.deserializeUntyped(content);
    }

    @IsTest
    static void providerFailureIsOmittedAndTraceVisible() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy contextPolicy = AgentExecutionPolicyService.defaults();
        contextPolicy.contextCharacterBudget = 100;
        AgentKernelTestFactory.configureExecutionPolicy(contextPolicy);
        update definition;
        AgentContextProvider__c failing = AgentKernelTestFactory.createContextProvider(definition.Id, 'failing', 'KernelTestContextProviderFailing');
        AgentContextProvider__c alpha = AgentKernelTestFactory.createContextProvider(definition.Id, 'alpha', 'KernelTestContextProviderAlpha');
        failing.SortOrder__c = 1;
        alpha.SortOrder__c = 2;
        AgentKernelTestFactory.updateRecords(new List<SObject>{ failing, alpha });

        ContextProviderService.CollectionResult result = ContextProviderService.collect(definition, null, null, 'operation', 'original', 'current');

        System.assertEquals(1, result.contexts.size());
        System.assertEquals('Alpha', result.contexts[0].sourceName);
        System.assertEquals('Failed', ((Map<String, Object>) result.sourceMetadata[0]).get('status'));
        System.assertEquals(0, ((Map<String, Object>) result.sourceMetadata[0]).get('includedCharacters'));
    }

    @IsTest
    static void validationRejectsWrongInterfaceDuplicateAndOversizedBudget() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentContextProvider__c wrong = new AgentContextProvider__c(
            Name = 'Wrong context adapter',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'wrong',
            ImplementationType__c = 'Apex',
            ImplementationReference__c = 'KernelTestTool',
            IsActive__c = true
        );
        try {
            insert wrong;
            System.assert(false, 'Wrong interface must fail on save.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('interface'));
        }

        definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy contextPolicy = AgentExecutionPolicyService.defaults();
        contextPolicy.contextCharacterBudget = AgentConfigService.MAX_CONTEXT_CHARACTERS + 1;
        AgentKernelTestFactory.configureExecutionPolicy(contextPolicy);
        update definition;
        assertInvalid(definition, 'whole number');
    }

    @IsTest
    static void modelOutcomePersistsBoundedContextMetadataOnly() {
        KernelTestModelProvider.mode = 'final';
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionPolicyService.Policy contextPolicy = AgentExecutionPolicyService.defaults();
        contextPolicy.contextCharacterBudget = 100;
        AgentKernelTestFactory.configureExecutionPolicy(contextPolicy);
        update definition;
        AgentContextProvider__c failing = AgentKernelTestFactory.createContextProvider(definition.Id, 'failing', 'KernelTestContextProviderFailing');
        AgentContextProvider__c alpha = AgentKernelTestFactory.createContextProvider(definition.Id, 'alpha', 'KernelTestContextProviderAlpha');
        failing.SortOrder__c = 1;
        alpha.SortOrder__c = 2;
        AgentKernelTestFactory.updateRecords(new List<SObject>{ failing, alpha });
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'context-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);

        new ModelCommandQueueable(started.runId, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, command.LeaseToken__c).execute(null);

        AgentEvent__c completed = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :started.runId AND EventType__c = :AgentKernelModels.EVENT_RUN_COMPLETED
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assert(completed.Payload__c.contains('"status":"Failed"'));
        System.assert(completed.Payload__c.contains('"sourceName":"Alpha"'));
        System.assertEquals(false, completed.Payload__c.contains('AAAA'), 'Trace metadata must not persist raw context.');
    }

    private static void assertInvalid(AgentDefinition__c definition, String expectedMessagePart) {
        try {
            AgentConfigService.validate(definition);
            System.assert(false, 'Expected invalid context provider configuration.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().toLowerCase().contains(expectedMessagePart), expected.getMessage());
        }
    }
}
