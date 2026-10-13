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
private class AgentModelServiceTest {
    @IsTest
    static void resolvesOnlyActiveCompleteModelsByApiName() {
        AgentModel__mdt incomplete = model('Incomplete', true, null, null);
        incomplete.NamedCredential__c = null;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ model('Approved', true, null, null), model('Inactive', false, null, null), incomplete });

        System.assertEquals('model-a', AgentModelService.activeModel('Approved').ModelIdentifier__c);
        System.assertEquals('model-a', AgentModelService.activeModel(' approved ').ModelIdentifier__c);
        System.assertEquals(null, AgentModelService.activeModel('Inactive'));
        System.assertEquals(null, AgentModelService.activeModel('Incomplete'));
        System.assertEquals(null, AgentModelService.activeModel('Missing'));
        System.assertEquals(null, AgentModelService.activeModel(null));
    }

    @IsTest
    static void estimatesFromTheModelsCurrentPrices() {
        AgentModel__mdt priced = model('Approved', true, 3, 4);

        AgentModelService.Estimate estimate = AgentModelService.estimate(priced, 1000, 500);
        System.assertEquals(0.005, estimate.amountUsd);
        System.assertEquals(3, estimate.inputPricePerMillion);
        System.assertEquals(4, estimate.outputPricePerMillion);
        System.assertEquals(null, AgentModelService.estimate(priced, null, 500));
        System.assertEquals(null, AgentModelService.estimate(priced, -1, 500));
        System.assertEquals(null, AgentModelService.estimate(null, 1000, 500));
    }

    @IsTest
    static void leavesMissingOrInvalidPricesUnknown() {
        System.assertEquals(null, AgentModelService.estimate(model('Unpriced', true, null, null), 1000, 500));
        System.assertEquals(null, AgentModelService.estimate(model('HalfPriced', true, 3, null), 1000, 500));
        System.assertEquals(null, AgentModelService.estimate(model('Negative', true, -1, 4), 1000, 500));
    }

    @IsTest
    static void activeDefinitionsNeedAnActiveModelWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentDefinition__c draft = new AgentDefinition__c(
            Name = 'Draft agent',
            DeveloperName__c = 'draft_model_agent',
            IsActive__c = false,
            Instructions__c = 'Draft.'
        );
        insert draft;

        draft.IsActive__c = true;
        Database.SaveResult activation = Database.update(draft, false);
        System.assertEquals(false, activation.isSuccess());
        System.assert(activation.getErrors()[0].getMessage().contains('A model is required'));

        AgentModel__mdt deactivated = AgentKernelTestFactory.kernelTestModel();
        deactivated.IsActive__c = false;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ deactivated });
        definition.Instructions__c = 'Edits that leave the model alone still save.';
        update definition;
    }

    private static AgentModel__mdt model(String name, Boolean active, Decimal inputPrice, Decimal outputPrice) {
        return new AgentModel__mdt(
            DeveloperName = name,
            ModelAdapterClass__c = 'ProviderA',
            NamedCredential__c = 'ProviderA_Credential',
            ModelIdentifier__c = 'model-a',
            IsActive__c = active,
            InputPricePerMillion__c = inputPrice,
            OutputPricePerMillion__c = outputPrice
        );
    }
}
