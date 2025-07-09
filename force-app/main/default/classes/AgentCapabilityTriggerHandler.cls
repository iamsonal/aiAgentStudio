/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Trigger handler for the AgentCapability__c object.
 *              Performs all necessary validation before records are committed to the database.
 * @author AI Agent Framework Team
 * @date 2025-06-20
 */
public with sharing class AgentCapabilityTriggerHandler {
    /**
     * @description Main entry point called by the trigger. Orchestrates validation steps.
     * @param newCapabilities The list of AgentCapability__c records from Trigger.new.
     * @param oldCapabilityMap The map of old AgentCapability__c records from Trigger.oldMap.
     */
    public static void handleTrigger(List<AgentCapability__c> newCapabilities, Map<Id, AgentCapability__c> oldCapabilityMap) {
        validateRecords(newCapabilities);
        validateUniqueness(newCapabilities, oldCapabilityMap);
    }

    /**
     * @description Iterates through records to perform field-level and logic validation.
     * @param capabilities The list of capabilities to validate.
     */
    private static void validateRecords(List<AgentCapability__c> capabilities) {
        for (AgentCapability__c cap : capabilities) {
            validateRequiredFields(cap);
            validateImplementationLogic(cap);
            validateJsonFields(cap);
        }
    }

    /**
     * @description Validates that fields required by the framework are populated.
     * @param cap The capability record to validate.
     */
    private static void validateRequiredFields(AgentCapability__c cap) {
        if (String.isBlank(cap.CapabilityName__c)) {
            cap.CapabilityName__c.addError('Capability Name is required.');
        }
        if (String.isBlank(cap.Description__c)) {
            cap.Description__c.addError('Description is required.');
        }
    }

    /**
     * @description Validates the implementation-related fields based on the chosen Implementation Type.
     * @param cap The capability record to validate.
     */
    private static void validateImplementationLogic(AgentCapability__c cap) {
        String implType = cap.ImplementationType__c;
        if (String.isBlank(implType)) {
            cap.ImplementationType__c.addError('Implementation Type is required.');
            return;
        }

        if (implType == 'Apex' || implType == 'Flow') {
            if (String.isBlank(cap.ImplementationDetail__c)) {
                cap.ImplementationDetail__c.addError('Implementation Detail is required when Type is Apex or Flow.');
            }

            if (String.isNotBlank(cap.StandardActionType__c)) {
                cap.StandardActionType__c = null;
            }
        } else if (implType == 'Standard') {
            if (String.isBlank(cap.StandardActionType__c)) {
                cap.StandardActionType__c.addError('Standard Action Type is required when Type is Standard.');
            }

            if (String.isNotBlank(cap.ImplementationDetail__c)) {
                cap.ImplementationDetail__c = null;
            }
        }
    }

    /**
     * @description Validates the syntax of JSON-based configuration fields.
     * @param cap The capability record to validate.
     */
    private static void validateJsonFields(AgentCapability__c cap) {
        if (String.isBlank(cap.Parameters__c)) {
            cap.Parameters__c.addError('Parameters cannot be blank. Use {"type":"object", "properties":{}} for no parameters.');
        } else {
            validateJsonSyntax(cap, cap.Parameters__c, 'Parameters__c');
        }

        if (String.isNotBlank(cap.BackendConfiguration__c)) {
            validateJsonSyntax(cap, cap.BackendConfiguration__c, 'BackendConfiguration__c');
        }
    }

    /**
     * @description Helper to check if a string is well-formed JSON. Adds an error to the record if not.
     * @param record The SObject record to add the error to.
     * @param jsonString The string to validate.
     * @param fieldApiName The API name of the field being validated.
     */
    private static void validateJsonSyntax(SObject record, String jsonString, String fieldApiName) {
        try {
            Object parsed = JSON.deserializeUntyped(jsonString);

            if (!(parsed instanceof Map<String, Object>)) {
                record.addError(fieldApiName, 'JSON content must be a valid JSON Object (e.g., {...}).');
            }
        } catch (System.JSONException e) {
            record.addError(fieldApiName, 'Invalid JSON Syntax: ' + e.getMessage());
        }
    }

    /**
     * @description Validates that CapabilityName__c is unique within the scope of its parent AIAgentDefinition__c.
     * @param newCapabilities The list of capabilities from Trigger.new.
     * @param oldCapabilityMap The map of old capabilities from Trigger.oldMap.
     */
    private static void validateUniqueness(List<AgentCapability__c> newCapabilities, Map<Id, AgentCapability__c> oldCapabilityMap) {
        Set<Id> agentIds = new Set<Id>();
        for (AgentCapability__c cap : newCapabilities) {
            if (cap.AIAgentDefinition__c != null) {
                agentIds.add(cap.AIAgentDefinition__c);
            }
            if (oldCapabilityMap != null && oldCapabilityMap.containsKey(cap.Id)) {
                Id oldAgentId = oldCapabilityMap.get(cap.Id).AIAgentDefinition__c;
                if (oldAgentId != null) {
                    agentIds.add(oldAgentId);
                }
            }
        }

        if (agentIds.isEmpty())
            return;

        Map<String, Id> existingCapabilityNames = new Map<String, Id>();

        for (AgentCapability__c existingCap : [
            SELECT Id, AIAgentDefinition__c, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c IN :agentIds
        ]) {
            if (String.isNotBlank(existingCap.CapabilityName__c)) {
                String key = existingCap.AIAgentDefinition__c + ':' + existingCap.CapabilityName__c.toLowerCase();
                existingCapabilityNames.put(key, existingCap.Id);
            }
        }

        Set<String> processedKeysInTrigger = new Set<String>();

        for (AgentCapability__c cap : newCapabilities) {
            if (String.isBlank(cap.CapabilityName__c))
                continue;

            String currentKey = cap.AIAgentDefinition__c + ':' + cap.CapabilityName__c.toLowerCase();

            if (existingCapabilityNames.containsKey(currentKey) && existingCapabilityNames.get(currentKey) != cap.Id) {
                cap.CapabilityName__c.addError('This Capability Name is already used by another capability for this Agent Definition.');
            }

            if (processedKeysInTrigger.contains(currentKey)) {
                cap.CapabilityName__c.addError('This Capability Name is duplicated within the records being saved.');
            }

            processedKeysInTrigger.add(currentKey);
        }
    }
}
