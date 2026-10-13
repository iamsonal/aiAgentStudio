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
private class PlutoImplementationDiscoveryServiceTest {
    @IsTest
    static void listsContextProviders() {
        List<PlutoImplementationDiscoveryService.ClassOption> options = PlutoImplementationDiscoveryService.getClassOptions('IContextProvider');

        Assert.isFalse(options.isEmpty(), 'Core ships at least one IContextProvider.');
        Set<String> names = new Set<String>();
        for (PlutoImplementationDiscoveryService.ClassOption option : options) {
            names.add(option.value);
        }
        Assert.isTrue(names.contains('FieldSetContextProvider'), 'Built-in FieldSetContextProvider is offered.');
    }

    @IsTest
    static void listsActiveAgentModelsByApiName() {
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ model('Support_Model', true), model('Retired_Model', false) });

        List<PlutoImplementationDiscoveryService.ModelOption> options = PlutoImplementationDiscoveryService.getModelOptions();

        Assert.areEqual(1, options.size(), 'Only active models are offered.');
        Assert.areEqual('Support_Model', options[0].value, 'The option value is the Agent Model API name.');
        Assert.isTrue(options[0].label.contains('model-a'), 'The label shows the provider model identifier.');
    }

    @IsTest
    static void rejectsInterfacesOutsideAllowlist() {
        Boolean rejected = false;
        try {
            PlutoImplementationDiscoveryService.getClassOptions('Queueable');
        } catch (AuraHandledException e) {
            rejected = true;
        }
        Assert.isTrue(rejected, 'Arbitrary interfaces must be rejected.');
    }

    @IsTest
    static void listsOnlyQueuesSupportingAgentApproval() {
        Group approverQueue = new Group(Name = 'Review Team', DeveloperName = 'Pluto_Review_Team', Type = 'Queue');
        Group unrelatedQueue = new Group(Name = 'Unrelated Team', DeveloperName = 'Pluto_Unrelated_Team', Type = 'Queue');
        insert new List<Group>{ approverQueue, unrelatedQueue };
        insert new List<QueueSobject>{
            new QueueSobject(QueueId = approverQueue.Id, SobjectType = 'AgentApproval__c'),
            new QueueSobject(QueueId = unrelatedQueue.Id, SobjectType = 'Case')
        };

        Integer beforeQueries = Limits.getQueries();
        List<PlutoImplementationDiscoveryService.ClassOption> options = PlutoImplementationDiscoveryService.getApproverQueueOptions();
        Assert.areEqual(1, Limits.getQueries() - beforeQueries, 'Queue discovery uses one bounded query.');
        Boolean found = false;
        for (PlutoImplementationDiscoveryService.ClassOption option : options) {
            Assert.areNotEqual('Pluto_Unrelated_Team', option.value, 'Queues without Agent Approval are excluded.');
            if (option.value == 'Pluto_Review_Team') {
                found = true;
                Assert.areEqual('Review Team (Pluto_Review_Team)', option.label, 'Display the label and store the API name Core expects.');
            }
        }
        Assert.isTrue(found, 'The approval queue is discoverable.');
    }

    @IsTest
    static void listsSetupChoices() {
        List<PlutoImplementationDiscoveryService.ClassOption> credentials = PlutoImplementationDiscoveryService.getNamedCredentialOptions();
        Assert.isTrue(credentials.size() <= 500, 'Named Credential options are bounded.');
        for (PlutoImplementationDiscoveryService.ClassOption option : credentials) {
            Assert.isFalse(String.isBlank(option.value), 'The API name is the stored value.');
        }

        Boolean foundFieldSet = false;
        for (PlutoImplementationDiscoveryService.ClassOption option : PlutoImplementationDiscoveryService.getFieldSetOptions('Account')) {
            foundFieldSet = foundFieldSet || option.value == 'AgentContextAdapterTest';
        }
        Assert.isTrue(foundFieldSet, 'Field Sets on the selected object are offered by API name.');
        Assert.areEqual(0, PlutoImplementationDiscoveryService.getFieldSetOptions('NotAnObject').size(), 'Unknown objects have no Field Sets.');
    }

    private static AgentModel__mdt model(String name, Boolean active) {
        return new AgentModel__mdt(
            DeveloperName = name,
            MasterLabel = name,
            ModelAdapterClass__c = 'ProviderA',
            NamedCredential__c = 'ProviderA_Credential',
            ModelIdentifier__c = 'model-a',
            IsActive__c = active
        );
    }
}
