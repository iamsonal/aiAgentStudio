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
private class FieldSetContextProviderTest {
    @IsTest
    static void returnsConfiguredFieldsForAnchorRecord() {
        Account account = new Account(Name = 'Field Set Context Test');
        insert account;
        AgentKernelModels.ContextRequest request = new AgentKernelModels.ContextRequest();
        request.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, null, account.Id, null);
        request.objectApiName = 'Account';
        request.fieldSetName = 'AgentContextAdapterTest';
        request.contextSubject = 'Anchor Record';

        AgentKernelModels.ContextResponse response = new FieldSetContextProvider().provide(request);

        System.assertEquals(null, response.sourceName);
        System.assertEquals(1, response.recordSets.get('Account').size());
        System.assertEquals(account.Name, (String) response.recordSets.get('Account')[0].get('Name'));
    }

    @IsTest
    static void rejectsMissingOrMismatchedAnchorRecord() {
        Contact contact = new Contact(LastName = 'Wrong type');
        insert contact;
        AgentKernelModels.ContextRequest request = new AgentKernelModels.ContextRequest();
        request.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, null, null, null);
        request.objectApiName = 'Account';
        request.fieldSetName = 'AgentContextAdapterTest';
        request.contextSubject = 'Anchor Record';

        try {
            new FieldSetContextProvider().provide(request);
            System.assert(false, 'Expected a missing anchor record failure.');
        } catch (FieldSetContextProvider.RecordUnavailableException expected) {
            System.assert(expected.getMessage().contains('unavailable'));
        }

        request.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, null, contact.Id, null);
        try {
            new FieldSetContextProvider().provide(request);
            System.assert(false, 'Expected a record-type mismatch.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('does not match'));
        }
    }

    @IsTest
    static void rejectsInvalidConfigurationWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentContextProvider__c provider = new AgentContextProvider__c(
            Name = 'Invalid Field Set',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'invalid_field_set',
            ImplementationType__c = 'Field Set',
            ContextSubject__c = 'Global',
            ObjectApiName__c = 'Account',
            FieldSetName__c = 'AgentContextAdapterTest',
            IsActive__c = true
        );
        try {
            insert provider;
            System.assert(false, 'Expected invalid Field Set configuration.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('Context Subject'));
        }
    }

    @IsTest
    static void acceptsTypedFieldSetConfigurationWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentContextProvider__c provider = new AgentContextProvider__c(
            Name = 'Account Context',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'account_context',
            ImplementationType__c = 'Field Set',
            ContextSubject__c = 'Anchor Record',
            ObjectApiName__c = 'Account',
            FieldSetName__c = 'AgentContextAdapterTest',
            IsActive__c = true
        );
        insert provider;
        System.assertNotEquals(null, provider.Id);
    }

    @IsTest
    static void collectsTypedFieldSetAndReportsMissingRecord() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentContextProvider__c provider = new AgentContextProvider__c(
            Name = 'Account Context',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'account_context',
            ImplementationType__c = 'Field Set',
            ContextSubject__c = 'Anchor Record',
            ObjectApiName__c = 'Account',
            FieldSetName__c = 'AgentContextAdapterTest',
            IsActive__c = true
        );
        insert provider;
        Account account = new Account(Name = 'Visible Context');
        insert account;
        AgentKernelModels.ExecutionPrincipal principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, null, account.Id, null);
        ContextProviderService.CollectionResult included = ContextProviderService.collect(definition, null, principal, 'op', 'input', 'input');
        System.assertEquals(1, included.contexts.size());
        System.assert(included.contexts[0].content.contains('Visible Context'));

        delete account;
        AgentConfigService.clearCacheForTest();
        ContextProviderService.CollectionResult unavailable = ContextProviderService.collect(definition, null, principal, 'op', 'input', 'input');
        System.assertEquals(0, unavailable.contexts.size());
        System.assertEquals('RecordUnavailable', ((Map<String, Object>) unavailable.sourceMetadata[0]).get('status'));
    }
}
