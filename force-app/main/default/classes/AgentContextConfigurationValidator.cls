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

/** Shared authoring and execution validation for typed context sources. */
public inherited sharing class AgentContextConfigurationValidator {
    public static final Integer MAX_FIELD_SET_FIELDS = 30;

    public static String error(AgentContextProvider__c provider) {
        if (provider == null || String.isBlank(provider.DeveloperName__c)) {
            return 'A context provider developer name is required.';
        }
        if (provider.ImplementationType__c == 'Field Set') {
            if (!String.isBlank(provider.ImplementationReference__c) || !String.isBlank(provider.ImplementationConfiguration__c)) {
                return 'Field Set providers cannot use Implementation Reference or Implementation Configuration.';
            }
            try {
                assertFieldSet(provider.ObjectApiName__c, provider.FieldSetName__c, provider.ContextSubject__c);
            } catch (Exception invalid) {
                return invalid.getMessage();
            }
            return null;
        }
        if (provider.ImplementationType__c != 'Apex') {
            return 'Context implementation type must be Apex or Field Set.';
        }
        if (!String.isBlank(provider.ObjectApiName__c) || !String.isBlank(provider.FieldSetName__c)) {
            return 'Object API Name and Field Set API Name apply only to Field Set providers.';
        }
        if (
            !String.isBlank(provider.ContextSubject__c) && !new Set<String>{ 'Anchor Record', 'Initiating User', 'Global' }.contains(provider.ContextSubject__c)
        ) {
            return 'Context Subject is invalid.';
        }
        if (String.isBlank(provider.ImplementationReference__c)) {
            return 'An Apex context provider class is required.';
        }
        if (!String.isBlank(provider.ImplementationConfiguration__c)) {
            if (provider.ImplementationConfiguration__c.length() > AgentConfigService.MAX_CONTEXT_CONFIGURATION_CHARACTERS) {
                return 'Context provider implementation configuration exceeds 8000 characters.';
            }
            try {
                if (!(JSON.deserializeUntyped(provider.ImplementationConfiguration__c) instanceof Map<String, Object>)) {
                    return 'Context provider implementation configuration must be a JSON object.';
                }
            } catch (Exception invalidJson) {
                return 'Context provider implementation configuration must be valid JSON.';
            }
        }
        try {
            AgentConfigService.newContextProvider(provider);
        } catch (Exception invalidClass) {
            return invalidClass.getMessage();
        }
        return null;
    }

    public static void assertFieldSet(String objectApiName, String fieldSetName, String subject) {
        if (String.isBlank(objectApiName) || String.isBlank(fieldSetName)) {
            throw new AgentKernelException.ConfigurationException('Object API Name and Field Set API Name are required.');
        }
        if (subject != 'Anchor Record' && subject != 'Initiating User') {
            throw new AgentKernelException.ConfigurationException('Field Set Context Subject must be Anchor Record or Initiating User.');
        }
        if (subject == 'Initiating User' && objectApiName != 'User') {
            throw new AgentKernelException.ConfigurationException('Initiating User context requires the User object.');
        }
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectApiName);
        if (objectType == null || !objectType.getDescribe().isQueryable()) {
            throw new AgentKernelException.ConfigurationException('Configured context object was not found or is not queryable.');
        }
        Schema.FieldSet fieldSet = objectType.getDescribe().fieldSets.getMap().get(fieldSetName);
        if (fieldSet == null) {
            throw new AgentKernelException.ConfigurationException('Configured context Field Set was not found on the object.');
        }
        List<Schema.FieldSetMember> members = fieldSet.getFields();
        if (members.isEmpty() || members.size() > MAX_FIELD_SET_FIELDS) {
            throw new AgentKernelException.ConfigurationException('Context Field Set must contain 1 through 30 fields.');
        }
        for (Schema.FieldSetMember member : members) {
            String path = member.getFieldPath();
            if (String.isBlank(path) || path.contains('.')) {
                throw new AgentKernelException.ConfigurationException('Context Field Set supports direct object fields only.');
            }
        }
    }
}
