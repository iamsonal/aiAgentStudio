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

/**
 * Resolves the org's approved Agent Model records and calculates optional USD
 * estimates from provider-reported token usage at each model's current prices.
 */
public inherited sharing class AgentModelService {
    @TestVisible
    private static List<AgentModel__mdt> testModels;
    private static Map<String, AgentModel__mdt> modelsByName;

    public class Estimate {
        public Decimal amountUsd;
        public Decimal inputPricePerMillion;
        public Decimal outputPricePerMillion;
    }

    /** Returns the named model when it is active and complete, or null. */
    public static AgentModel__mdt activeModel(String developerName) {
        AgentModel__mdt model = String.isBlank(developerName) ? null : models().get(developerName.trim().toLowerCase());
        if (
            model == null ||
            model.IsActive__c != true ||
            String.isBlank(model.ModelAdapterClass__c) ||
            String.isBlank(model.ModelIdentifier__c) ||
            String.isBlank(model.NamedCredential__c)
        ) {
            return null;
        }
        return model;
    }

    /** Returns every active, complete model. */
    public static List<AgentModel__mdt> activeModels() {
        List<AgentModel__mdt> result = new List<AgentModel__mdt>();
        for (AgentModel__mdt model : models().values()) {
            if (activeModel(model.DeveloperName) != null) {
                result.add(model);
            }
        }
        return result;
    }

    public static String unavailableMessage(String developerName) {
        return String.isBlank(developerName)
            ? 'A model is required: enter the API name of an active Agent Model record.'
            : 'Model ' + developerName + ' must name an active Agent Model record with a model adapter class, Named Credential, and model identifier.';
    }

    /** Active definitions must name a usable model; checked only when the model or activation changes. */
    public static void validateDefinitions(List<AgentDefinition__c> records, Map<Id, AgentDefinition__c> previousById) {
        for (AgentDefinition__c record : records) {
            AgentDefinition__c previous = previousById == null ? null : previousById.get(record.Id);
            Boolean touched = previous == null || previous.Model__c != record.Model__c || previous.IsActive__c != record.IsActive__c;
            Boolean needsModel = record.IsActive__c == true || !String.isBlank(record.Model__c);
            if (touched && needsModel && activeModel(record.Model__c) == null) {
                record.addError(AgentDefinition__c.Model__c, unavailableMessage(record.Model__c));
            }
        }
    }

    public static Estimate estimate(AgentModel__mdt model, Long inputTokens, Long outputTokens) {
        if (
            model == null ||
            inputTokens == null ||
            outputTokens == null ||
            inputTokens < 0 ||
            outputTokens < 0 ||
            model.InputPricePerMillion__c == null ||
            model.OutputPricePerMillion__c == null ||
            model.InputPricePerMillion__c < 0 ||
            model.OutputPricePerMillion__c < 0
        ) {
            return null;
        }
        Decimal amount;
        try {
            Decimal million = 1000000;
            amount =
                (Decimal.valueOf(String.valueOf(inputTokens)) * model.InputPricePerMillion__c +
                Decimal.valueOf(String.valueOf(outputTokens)) * model.OutputPricePerMillion__c) / million;
        } catch (Exception arithmeticFailure) {
            return null;
        }
        if (amount > 9999999999.99999999) {
            return null;
        }
        Estimate result = new Estimate();
        result.amountUsd = amount;
        result.inputPricePerMillion = model.InputPricePerMillion__c;
        result.outputPricePerMillion = model.OutputPricePerMillion__c;
        return result;
    }

    private static Map<String, AgentModel__mdt> models() {
        if (modelsByName == null) {
            List<AgentModel__mdt> records = testModels != null
                ? testModels
                : [
                      SELECT
                          DeveloperName,
                          MasterLabel,
                          ModelAdapterClass__c,
                          NamedCredential__c,
                          ModelIdentifier__c,
                          IsActive__c,
                          InputPricePerMillion__c,
                          OutputPricePerMillion__c,
                          MaxOutputTokens__c
                      FROM AgentModel__mdt
                      WITH SYSTEM_MODE
                  ];
            modelsByName = new Map<String, AgentModel__mdt>();
            for (AgentModel__mdt model : records) {
                modelsByName.put(model.DeveloperName.toLowerCase(), model);
            }
        }
        return modelsByName;
    }

    @TestVisible
    private static void setTestModels(List<AgentModel__mdt> models) {
        testModels = models;
        modelsByName = null;
    }
}
