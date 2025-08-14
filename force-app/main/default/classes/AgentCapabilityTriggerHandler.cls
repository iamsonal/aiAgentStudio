/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Trigger handler for AgentCapability__c records. This class centralizes all validation and consistency checks
 * required to maintain the integrity of agent capability definitions within the framework. Responsibilities include:
 *   - Enforcing required field population and logical consistency based on implementation type
 *   - Validating JSON configuration fields for correct syntax and structure
 *   - Ensuring uniqueness of capability names within each agent definition
 *   - Providing clear error messages to prevent invalid or conflicting configurations from being saved
 *   - Emitting debug output to aid in troubleshooting and understanding trigger execution flow
 *
 * This handler is designed for maintainability and extensibility, serving as the single point of truth for all
 * business rules related to AgentCapability__c records.
 */
public with sharing class AgentCapabilityTriggerHandler {
    /**
     * Main entry point for the AgentCapability__c trigger.
     * Orchestrates all validation and consistency checks for incoming records.
     *
     * @param newCapabilities List of AgentCapability__c records from Trigger.new.
     * @param oldCapabilityMap Map of AgentCapability__c records from Trigger.oldMap (may be null in before insert).
     * @throws Adds errors to records to prevent DML if validation fails.
     */
    public static void handleTrigger(List<AgentCapability__c> newCapabilities, Map<Id, AgentCapability__c> oldCapabilityMap) {
        System.debug(LoggingLevel.INFO, 'AgentCapabilityTriggerHandler: Starting trigger handling for ' + newCapabilities.size() + ' record(s).');
        validateRecords(newCapabilities);
        validateUniqueness(newCapabilities, oldCapabilityMap);
        System.debug(LoggingLevel.INFO, 'AgentCapabilityTriggerHandler: Trigger handling complete.');
    }

    /**
     * Performs all per-record validation steps for a list of AgentCapability__c records.
     * This includes required field checks, implementation logic validation, and JSON field validation.
     *
     * @param capabilities List of AgentCapability__c records to validate.
     */
    private static void validateRecords(List<AgentCapability__c> capabilities) {
        for (AgentCapability__c cap : capabilities) {
            validateRequiredFields(cap);
            validateImplementationLogic(cap);
            validateJsonFields(cap);
        }
    }

    /**
     * Validates that all required fields for the framework are populated.
     * Adds errors to the record if any required field is missing.
     *
     * @param cap The AgentCapability__c record to validate.
     */
    private static void validateRequiredFields(AgentCapability__c cap) {
        if (String.isBlank(cap.CapabilityName__c)) {
            cap.CapabilityName__c.addError('Capability Name is required.');
            System.debug(LoggingLevel.WARN, 'Validation failed: Capability Name is required.');
        }
        if (String.isBlank(cap.Description__c)) {
            cap.Description__c.addError('Description is required.');
            System.debug(LoggingLevel.WARN, 'Validation failed: Description is required.');
        }
        // AIAgentDefinition__c is a master-detail, so it is always required by Salesforce.
    }

    /**
     * Validates implementation-specific field requirements and ensures proper field
     * population based on the selected Implementation Type. Automatically clears
     * conflicting fields to maintain data consistency.
     *
     * @param cap The AgentCapability__c record to validate.
     * @throws Adds errors to fields if validation fails.
     * @sideeffect May null out conflicting fields for consistency.
     */
    private static void validateImplementationLogic(AgentCapability__c cap) {
        String implType = cap.ImplementationType__c;
        if (String.isBlank(implType)) {
            cap.ImplementationType__c.addError('Implementation Type is required.');
            System.debug(LoggingLevel.WARN, 'Validation failed: Implementation Type is required.');
            return; // Cannot proceed with further validation without knowing the type
        }

        if (implType == 'Apex' || implType == 'Flow') {
            if (String.isBlank(cap.ImplementationDetail__c)) {
                cap.ImplementationDetail__c.addError('Implementation Detail is required when Type is Apex or Flow.');
                System.debug(LoggingLevel.WARN, 'Validation failed: Implementation Detail is required for Apex/Flow.');
            }
            // Clear conflicting field for data consistency
            if (String.isNotBlank(cap.StandardActionType__c)) {
                System.debug(LoggingLevel.INFO, 'Clearing StandardActionType__c because ImplementationType__c is Apex/Flow.');
                cap.StandardActionType__c = null;
            }
        } else if (implType == 'Standard') {
            if (String.isBlank(cap.StandardActionType__c)) {
                cap.StandardActionType__c.addError('Standard Action Type is required when Type is Standard.');
                System.debug(LoggingLevel.WARN, 'Validation failed: Standard Action Type is required for Standard.');
            }
            // Clear conflicting field for data consistency
            if (String.isNotBlank(cap.ImplementationDetail__c)) {
                System.debug(LoggingLevel.INFO, 'Clearing ImplementationDetail__c because ImplementationType__c is Standard.');
                cap.ImplementationDetail__c = null;
            }
        }
    }

    /**
     * Validates the syntax and structure of JSON-based configuration fields.
     * Ensures Parameters__c is always present and valid, and BackendConfiguration__c is valid if provided.
     *
     * @param cap The AgentCapability__c record to validate.
     */
    private static void validateJsonFields(AgentCapability__c cap) {
        // Parameters__c must be valid JSON, even if it's just an empty object.
        if (String.isBlank(cap.Parameters__c)) {
            cap.Parameters__c.addError('Parameters cannot be blank. Use {"type":"object", "properties":{}} for no parameters.');
            System.debug(LoggingLevel.WARN, 'Validation failed: Parameters__c is blank.');
        } else {
            validateJsonSyntax(cap, cap.Parameters__c, 'Parameters__c');
        }

        // BackendConfiguration__c is optional, but if provided, it must be valid JSON.
        if (String.isNotBlank(cap.BackendConfiguration__c)) {
            validateJsonSyntax(cap, cap.BackendConfiguration__c, 'BackendConfiguration__c');
        }
    }

    /**
     * Validates that a given string is valid JSON and represents a JSON object (not array or primitive).
     * Adds errors to the record if validation fails.
     *
     * @param record The SObject record to add validation errors to.
     * @param jsonString The JSON string to validate.
     * @param fieldApiName The API name of the field being validated (for error reporting).
     */
    private static void validateJsonSyntax(SObject record, String jsonString, String fieldApiName) {
        try {
            Object parsed = JSON.deserializeUntyped(jsonString);
            // Enforce JSON object structure for consistency across the framework
            if (!(parsed instanceof Map<String, Object>)) {
                record.addError(fieldApiName, 'JSON content must be a valid JSON Object (e.g., {...}), not an array or primitive value.');
                System.debug(LoggingLevel.WARN, 'Validation failed: ' + fieldApiName + ' is not a JSON object.');
            }
        } catch (System.JSONException e) {
            record.addError(fieldApiName, 'Invalid JSON syntax: ' + e.getMessage());
            System.debug(LoggingLevel.WARN, 'Validation failed: ' + fieldApiName + ' has invalid JSON syntax: ' + e.getMessage());
        }
    }

    /**
     * Validates that CapabilityName__c is unique within the scope of its parent AIAgentDefinition__c.
     * Checks both existing database records and records in the current trigger batch.
     *
     * @param newCapabilities List of AgentCapability__c records from Trigger.new.
     * @param oldCapabilityMap Map of AgentCapability__c records from Trigger.oldMap (may be null).
     * @throws Adds errors to records if uniqueness is violated.
     */
    private static void validateUniqueness(List<AgentCapability__c> newCapabilities, Map<Id, AgentCapability__c> oldCapabilityMap) {
        Set<Id> agentIds = new Set<Id>();
        for (AgentCapability__c cap : newCapabilities) {
            // Also consider the old parent if the agent definition itself is changing on update
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

        if (agentIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'No agent definitions found for uniqueness validation. Skipping uniqueness check.');
            return;
        }

        // Key: lower(AgentId + ':' + CapabilityName) -> Value: ID of the existing capability
        Map<String, Id> existingCapabilityNames = new Map<String, Id>();

        // Query all existing capabilities for the affected agents
        for (AgentCapability__c existingCap : [
            SELECT Id, AIAgentDefinition__c, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c IN :agentIds AND ExposureLevel__c != 'Disabled'
        ]) {
            if (String.isNotBlank(existingCap.CapabilityName__c)) {
                String key = existingCap.AIAgentDefinition__c + ':' + existingCap.CapabilityName__c.toLowerCase();
                existingCapabilityNames.put(key, existingCap.Id);
            }
        }

        Set<String> processedKeysInTrigger = new Set<String>();

        for (AgentCapability__c cap : newCapabilities) {
            if (String.isBlank(cap.CapabilityName__c))
                continue; // Already handled by required check

            String currentKey = cap.AIAgentDefinition__c + ':' + cap.CapabilityName__c.toLowerCase();

            // Check 1: Does this name already exist in the database for this agent, and it's not this same record?
            if (existingCapabilityNames.containsKey(currentKey) && existingCapabilityNames.get(currentKey) != cap.Id) {
                cap.CapabilityName__c.addError('This Capability Name is already used by another capability for this Agent Definition.');
                System.debug(
                    LoggingLevel.WARN,
                    'Uniqueness validation failed: Capability Name "' +
                        cap.CapabilityName__c +
                        '" already exists for AgentDefinition ' +
                        cap.AIAgentDefinition__c
                );
            }

            // Check 2: Has this same name been used by another record *in this trigger batch*?
            if (processedKeysInTrigger.contains(currentKey)) {
                cap.CapabilityName__c.addError('This Capability Name is duplicated within the records being saved.');
                System.debug(
                    LoggingLevel.WARN,
                    'Uniqueness validation failed: Duplicate Capability Name "' +
                        cap.CapabilityName__c +
                        '" found in trigger batch for AgentDefinition ' +
                        cap.AIAgentDefinition__c
                );
            }

            processedKeysInTrigger.add(currentKey);
        }
    }
}
