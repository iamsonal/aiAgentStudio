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

trigger AgentContextProviderValidationTrigger on AgentContextProvider__c(before insert, before update) {
    Set<Id> definitionIds = new Set<Id>();
    Set<Id> incomingIds = new Set<Id>();
    ExtensionExecutionGuard.Boundary validationBoundary = ExtensionExecutionGuard.open();
    for (AgentContextProvider__c provider : Trigger.new) {
        definitionIds.add(provider.AgentDefinition__c);
        if (provider.Id != null) {
            incomingIds.add(provider.Id);
        }
        String error = AgentContextConfigurationValidator.error(provider);
        if (error != null) {
            provider.addError(error);
        }
    }
    ExtensionExecutionGuard.Result validationIsolation = ExtensionExecutionGuard.close(validationBoundary);
    if (
        validationIsolation.performedDml ||
        validationIsolation.performedCallout ||
        validationIsolation.performedProhibitedAsync() ||
        validationIsolation.budgetExceeded
    ) {
        for (AgentContextProvider__c provider : Trigger.new) {
            provider.addError('Context provider initialization must remain query-only.');
        }
    }
    Map<Id, Set<String>> namesByDefinition = new Map<Id, Set<String>>();
    Map<Id, Integer> countsByDefinition = new Map<Id, Integer>();
    for (AgentContextProvider__c existing : [
        SELECT Id, AgentDefinition__c, DeveloperName__c
        FROM AgentContextProvider__c
        WHERE AgentDefinition__c IN :definitionIds AND IsActive__c = TRUE AND Id NOT IN :incomingIds
        WITH SYSTEM_MODE
    ]) {
        if (!namesByDefinition.containsKey(existing.AgentDefinition__c)) {
            namesByDefinition.put(existing.AgentDefinition__c, new Set<String>());
        }
        namesByDefinition.get(existing.AgentDefinition__c).add(existing.DeveloperName__c.toLowerCase());
        countsByDefinition.put(
            existing.AgentDefinition__c,
            (countsByDefinition.containsKey(existing.AgentDefinition__c) ? countsByDefinition.get(existing.AgentDefinition__c) : 0) + 1
        );
    }
    for (AgentContextProvider__c provider : Trigger.new) {
        if (provider.IsActive__c != true || provider.AgentDefinition__c == null) {
            continue;
        }
        if (!namesByDefinition.containsKey(provider.AgentDefinition__c)) {
            namesByDefinition.put(provider.AgentDefinition__c, new Set<String>());
        }
        String normalizedName = String.isBlank(provider.DeveloperName__c) ? '' : provider.DeveloperName__c.trim().toLowerCase();
        if (namesByDefinition.get(provider.AgentDefinition__c).contains(normalizedName)) {
            provider.addError('Active context provider developer names must be unique within an agent.');
        }
        namesByDefinition.get(provider.AgentDefinition__c).add(normalizedName);
        Integer count = (countsByDefinition.containsKey(provider.AgentDefinition__c) ? countsByDefinition.get(provider.AgentDefinition__c) : 0) + 1;
        countsByDefinition.put(provider.AgentDefinition__c, count);
        if (count > AgentConfigService.MAX_CONTEXT_PROVIDER_COUNT) {
            provider.addError('An agent can have at most 10 active context providers.');
        }
    }
}