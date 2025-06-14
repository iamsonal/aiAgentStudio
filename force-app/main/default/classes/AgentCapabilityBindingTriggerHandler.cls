/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-04-14.
 */

public with sharing class AgentCapabilityBindingTriggerHandler {
    public static void handleTrigger(
        List<AgentCapabilityBinding__c> newRecords,
        List<AgentCapabilityBinding__c> oldRecords,
        System.TriggerOperation triggerOperation
    ) {
        switch on triggerOperation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                validateRecords(newRecords);
            }
        }
    }

    private static void validateRecords(List<AgentCapabilityBinding__c> records) {
        validateRequiredFields(records);
        validateJsonFields(records);
        validateUniqueness(records);
    }

    /** Validates required fields that aren't automatically enforced by Lookup/MD */
    private static void validateRequiredFields(List<AgentCapabilityBinding__c> records) {
        for (AgentCapabilityBinding__c record : records) {
            if (String.isBlank(record.DeveloperName__c)) {
                handleValidationError(record, 'DeveloperName__c', 'Capability Developer Name is required.');
            }
            if (String.isBlank(record.Description__c)) {
                handleValidationError(record, 'Description__c', 'Capability Description for LLM is required.');
            }
            if (String.isBlank(record.InputSchema__c)) {
                handleValidationError(
                    record,
                    'InputSchema__c',
                    'Capability Input Schema for LLM is required (can be minimal \'{"type":"object", "properties":{}}\').'
                );
            }
        }
    }

    /** Validates JSON syntax for relevant fields */
    private static void validateJsonFields(List<AgentCapabilityBinding__c> records) {
        for (AgentCapabilityBinding__c record : records) {
            validateJsonSyntax(record, record.InputSchema__c, 'InputSchema__c', true);
            validateJsonSyntax(record, record.ActionConfiguration__c, 'ActionConfiguration__c', true);
        }
    }

    /** Validates that a string is well-formed JSON and optionally checks if it's an object */
    private static void validateJsonSyntax(AgentCapabilityBinding__c record, String jsonString, String fieldName, Boolean requireObject) {
        if (String.isNotBlank(jsonString)) {
            try {
                Object parsed = JSON.deserializeUntyped(jsonString);
                if (requireObject && !(parsed instanceof Map<String, Object>)) {
                    handleValidationError(record, fieldName, 'JSON content must be a valid JSON Object (e.g., {...}).');
                }
            } catch (System.JSONException e) {
                handleValidationError(record, fieldName, 'Invalid JSON Syntax: ' + e.getMessage());
            } catch (Exception ex) {
                handleValidationError(record, fieldName, 'Unexpected error validating JSON: ' + ex.getMessage());
            }
        } else if (fieldName == 'InputSchema__c') {
            handleValidationError(record, fieldName, 'Capability Input Schema for LLM cannot be blank.');
        }
    }

    /** Check uniqueness of DeveloperName__c within the scope of the parent AIAgentDefinition__c */
    private static void validateUniqueness(List<AgentCapabilityBinding__c> recordsToCheck) {
        Set<Id> agentIds = new Set<Id>();
        for (AgentCapabilityBinding__c rec : recordsToCheck) {
            agentIds.add(rec.AIAgentDefinition__c);
        }
        validateUniqueness(recordsToCheck, agentIds);
    }
    /** Overload for update scenario where relevant Agent IDs might be broader */
    private static void validateUniqueness(List<AgentCapabilityBinding__c> recordsToCheck, Set<Id> relevantAgentIds) {
        if (recordsToCheck.isEmpty() || relevantAgentIds.isEmpty())
            return;

        Map<String, Id> existingNamesMap = new Map<String, Id>();

        try {
            for (AgentCapabilityBinding__c existing : [
                SELECT Id, AIAgentDefinition__c, DeveloperName__c
                FROM AgentCapabilityBinding__c
                WHERE AIAgentDefinition__c IN :relevantAgentIds
            ]) {
                if (String.isNotBlank(existing.DeveloperName__c)) {
                    String key = existing.AIAgentDefinition__c + ':' + existing.DeveloperName__c.toLowerCase();
                    existingNamesMap.put(key, existing.Id);
                }
            }
        } catch (Exception e) {
            return;
        }

        Set<String> processedKeysInTrigger = new Set<String>();
        for (AgentCapabilityBinding__c record : recordsToCheck) {
            if (String.isBlank(record.DeveloperName__c))
                continue;

            String currentKey = record.AIAgentDefinition__c + ':' + record.DeveloperName__c.toLowerCase();

            if (existingNamesMap.containsKey(currentKey) && existingNamesMap.get(currentKey) != record.Id) {
                handleValidationError(
                    record,
                    'DeveloperName__c',
                    'This Capability Developer Name is already used by another binding (' +
                        existingNamesMap.get(currentKey) +
                        ') for this Agent Definition.'
                );
            }

            if (processedKeysInTrigger.contains(currentKey)) {
                handleValidationError(
                    record,
                    'DeveloperName__c',
                    'This Capability Developer Name is duplicated within the records being saved for this Agent Definition.'
                );
            }
            processedKeysInTrigger.add(currentKey);
        }
    }

    private static void handleValidationError(AgentCapabilityBinding__c record, String fieldName, String errorMessage) {
        if (record.Id == null)
            record.addError(fieldName, errorMessage);
        else
            Trigger.newMap.get(record.Id).addError(fieldName, errorMessage);
    }
}
