/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Trigger handler for AgentCapability__c records. Validates required fields,
 * implementation logic, JSON syntax, uniqueness, and propagates Tool Flow Graph
 * warnings to parent AIAgentDefinition__c records on capability mutations.
 */
public with sharing class AgentCapabilityTriggerHandler {
    public class ValidationException extends Exception {
    }

    private static final String IMPL_TYPE_APEX = 'Apex';
    private static final String IMPL_TYPE_FLOW = 'Flow';
    private static final String IMPL_TYPE_STANDARD = 'Standard';
    private static final String IMPL_TYPE_AGENT = 'Agent';
    private static final String EXPOSURE_DISABLED = 'Disabled';

    private static final Map<System.TriggerOperation, String> CAPABILITY_WARNING_MESSAGES = new Map<System.TriggerOperation, String>{
        System.TriggerOperation.AFTER_INSERT => 'One or more capabilities were added. Update the flow graph to include new tools.',
        System.TriggerOperation.AFTER_UPDATE => 'One or more capabilities were modified. Review and update the flow graph.',
        System.TriggerOperation.AFTER_DELETE => 'One or more capabilities were removed. Update the flow graph to remove stale tools.',
        System.TriggerOperation.AFTER_UNDELETE => 'One or more capabilities were restored. Review and update the flow graph.'
    };
    /**
     * Main entry point for AgentCapability__c trigger.
     *
     * @param newCapabilities List of AgentCapability__c records
     * @param oldCapabilityMap Map of old records (may be null)
     */
    public static void handleTrigger(List<AgentCapability__c> newCapabilities, Map<Id, AgentCapability__c> oldCapabilityMap) {
        if (newCapabilities == null || newCapabilities.isEmpty()) {
            return;
        }

        System.debug(LoggingLevel.INFO, 'AgentCapabilityTriggerHandler: Starting trigger handling for ' + newCapabilities.size() + ' record(s).');
        validateRecords(newCapabilities);
        validateUniqueness(newCapabilities, oldCapabilityMap);
        System.debug(LoggingLevel.INFO, 'AgentCapabilityTriggerHandler: Trigger handling complete.');
    }

    /**
     * Performs per-record validation for capabilities with bulk processing optimization.
     *
     * @param capabilities List of records to validate
     */
    private static void validateRecords(List<AgentCapability__c> capabilities) {
        // Bulk collect all agent IDs for HITL validation
        Set<Id> agentIds = new Set<Id>();
        Set<String> childAgentDeveloperNames = new Set<String>();
        for (AgentCapability__c cap : capabilities) {
            if (cap.AIAgentDefinition__c != null) {
                agentIds.add(cap.AIAgentDefinition__c);
            }
            if (cap.ImplementationType__c == IMPL_TYPE_AGENT && String.isNotBlank(cap.ImplementationDetail__c)) {
                childAgentDeveloperNames.add(cap.ImplementationDetail__c.trim());
            }
        }

        // Load agent definitions for HITL validation
        Map<Id, AIAgentDefinition__c> agentDefMap = new Map<Id, AIAgentDefinition__c>();
        if (!agentIds.isEmpty()) {
            for (AIAgentDefinition__c agentDef : [
                SELECT Id, RuntimeStrategy__c, DeveloperName__c
                FROM AIAgentDefinition__c
                WHERE Id IN :agentIds
            ]) {
                agentDefMap.put(agentDef.Id, agentDef);
            }
        }

        Map<String, AIAgentDefinition__c> childAgentDefByDeveloperName = new Map<String, AIAgentDefinition__c>();
        if (!childAgentDeveloperNames.isEmpty()) {
            for (AIAgentDefinition__c childAgentDef : [
                SELECT Id, DeveloperName__c, IsActive__c
                FROM AIAgentDefinition__c
                WHERE DeveloperName__c IN :childAgentDeveloperNames
            ]) {
                if (childAgentDef.IsActive__c == true && String.isNotBlank(childAgentDef.DeveloperName__c)) {
                    childAgentDefByDeveloperName.put(childAgentDef.DeveloperName__c.toLowerCase(), childAgentDef);
                }
            }
        }

        // Process each record
        for (AgentCapability__c cap : capabilities) {
            validateRequiredFields(cap);
            validateImplementationLogic(cap, agentDefMap.get(cap.AIAgentDefinition__c), childAgentDefByDeveloperName);
            validateJsonFields(cap);
            validateExecutionModeConfiguration(cap);
            validateHITLModeConfiguration(cap, agentDefMap.get(cap.AIAgentDefinition__c));
        }
    }

    /**
     * Helper method to add field error and log validation failure.
     *
     * @param record SObject record to add error to
     * @param fieldName Field API name to add error to
     * @param errorMessage Error message to display
     * @param logMessage Log message for debug output
     */
    private static void addFieldError(SObject record, String fieldName, String errorMessage, String logMessage) {
        record.addError(fieldName, errorMessage);
        System.debug(LoggingLevel.WARN, logMessage);
    }

    /**
     * Validates that all required fields are populated.
     *
     * @param cap Record to validate
     */
    private static void validateRequiredFields(AgentCapability__c cap) {
        if (String.isBlank(cap.CapabilityName__c)) {
            addFieldError(cap, 'CapabilityName__c', 'Capability Name is required.', 'Validation failed: Capability Name is required.');
        }
        if (String.isBlank(cap.Description__c)) {
            addFieldError(cap, 'Description__c', 'Description is required.', 'Validation failed: Description is required.');
        }
        // AIAgentDefinition__c is a master-detail, so it is always required by Salesforce.
    }

    /**
     * Validates implementation-specific field requirements based on Implementation Type.
     *
     * @param cap Record to validate
     */
    private static void validateImplementationLogic(
        AgentCapability__c cap,
        AIAgentDefinition__c parentAgentDef,
        Map<String, AIAgentDefinition__c> childAgentDefByDeveloperName
    ) {
        String implType = cap.ImplementationType__c;
        if (String.isBlank(implType)) {
            addFieldError(cap, 'ImplementationType__c', 'Implementation Type is required.', 'Validation failed: Implementation Type is required.');
            return; // Cannot proceed with further validation without knowing the type
        }

        if (implType == IMPL_TYPE_APEX || implType == IMPL_TYPE_FLOW) {
            if (String.isBlank(cap.ImplementationDetail__c)) {
                addFieldError(
                    cap,
                    'ImplementationDetail__c',
                    'Implementation Detail is required when Type is Apex or Flow.',
                    'Validation failed: Implementation Detail is required for Apex/Flow.'
                );
            }
            // Clear conflicting field for data consistency
            if (String.isNotBlank(cap.StandardActionType__c)) {
                System.debug(LoggingLevel.INFO, 'Clearing StandardActionType__c because ImplementationType__c is Apex/Flow.');
                cap.StandardActionType__c = null;
            }
        } else if (implType == IMPL_TYPE_AGENT) {
            if (String.isBlank(cap.ImplementationDetail__c)) {
                addFieldError(
                    cap,
                    'ImplementationDetail__c',
                    'Implementation Detail is required when Type is Agent.',
                    'Validation failed: Implementation Detail is required for Agent.'
                );
                return;
            }

            cap.ImplementationDetail__c = cap.ImplementationDetail__c.trim();

            if (String.isNotBlank(cap.StandardActionType__c)) {
                System.debug(LoggingLevel.INFO, 'Clearing StandardActionType__c because ImplementationType__c is Agent.');
                cap.StandardActionType__c = null;
            }

            if (
                parentAgentDef != null &&
                String.isNotBlank(parentAgentDef.DeveloperName__c) &&
                parentAgentDef.DeveloperName__c.equalsIgnoreCase(cap.ImplementationDetail__c)
            ) {
                addFieldError(
                    cap,
                    'ImplementationDetail__c',
                    'Agent capabilities cannot target the same agent that owns the capability.',
                    'Validation failed: Agent capability cannot self-reference the parent agent.'
                );
                return;
            }

            String childAgentKey = cap.ImplementationDetail__c.toLowerCase();
            if (childAgentDefByDeveloperName == null || !childAgentDefByDeveloperName.containsKey(childAgentKey)) {
                addFieldError(
                    cap,
                    'ImplementationDetail__c',
                    'Implementation Detail must reference an active child agent Developer Name.',
                    'Validation failed: Agent capability child agent was missing or inactive.'
                );
            }
        } else if (implType == IMPL_TYPE_STANDARD) {
            if (String.isBlank(cap.StandardActionType__c)) {
                addFieldError(
                    cap,
                    'StandardActionType__c',
                    'Standard Action Type is required when Type is Standard.',
                    'Validation failed: Standard Action Type is required for Standard.'
                );
            }
            // Clear conflicting field for data consistency
            if (String.isNotBlank(cap.ImplementationDetail__c)) {
                System.debug(LoggingLevel.INFO, 'Clearing ImplementationDetail__c because ImplementationType__c is Standard.');
                cap.ImplementationDetail__c = null;
            }
        }
    }

    /**
     * Validates JSON syntax for configuration fields.
     *
     * @param cap Record to validate
     */
    private static void validateJsonFields(AgentCapability__c cap) {
        // Parameters__c must be valid JSON, even if it's just an empty object.
        if (String.isBlank(cap.Parameters__c)) {
            addFieldError(
                cap,
                'Parameters__c',
                'Parameters cannot be blank. Use {"type":"object", "properties":{}} for no parameters.',
                'Validation failed: Parameters__c is blank.'
            );
        } else {
            validateJsonSyntax(cap, cap.Parameters__c, 'Parameters__c');
        }

        // BackendConfiguration__c is optional, but if provided, it must be valid JSON.
        if (String.isNotBlank(cap.BackendConfiguration__c)) {
            validateJsonSyntax(cap, cap.BackendConfiguration__c, 'BackendConfiguration__c');
        }
    }

    /**
     * Validates that execution mode configuration flags are mutually exclusive.
     * HITLMode = 'Approval' and RunAsynchronously__c cannot both be true because:
     * 1. Approval workflows require synchronous user interaction before execution
     * 2. Async tools execute in separate transactions without user interaction
     * 3. The framework's tool grouping logic would exclude such tools from all execution buckets
     *
     * @param cap Record to validate
     */
    private static void validateExecutionModeConfiguration(AgentCapability__c cap) {
        Boolean runAsync = cap.RunAsynchronously__c == true;

        // Check HITLMode field
        if (cap.HITLMode__c == 'Approval' && runAsync) {
            String errorMessage =
                'A capability cannot require both approval and asynchronous execution. ' +
                'HITLMode "Approval" requires synchronous user interaction, while RunAsynchronously executes ' +
                'in a separate transaction without user interaction. Please choose one execution mode.';

            addFieldError(
                cap,
                'HITLMode__c',
                errorMessage,
                'Validation failed: HITLMode Approval and RunAsynchronously__c are mutually exclusive for capability: ' + cap.CapabilityName__c
            );

            cap.addError('RunAsynchronously__c', errorMessage);
        }
    }

    /**
     * Validates HITLMode__c configuration based on agent type and other capability settings.
     *
     * Rules:
     * 1. HITLMode = 'Confirmation' is only valid for Conversational agents
     * 2. HITLMode = 'Confirmation' cannot be used with RunAsynchronously__c = true
     * 3. HITLMode = 'ConfirmationThenApproval' is only valid for Conversational agents
     * 4. HITLMode = 'ConfirmationThenApproval' cannot be used with RunAsynchronously__c = true
     * 5. HITLMode = 'Approval' is valid for all agent types
     *
     * @param cap Record to validate
     * @param agentDef The parent agent definition (may be null)
     */
    private static void validateHITLModeConfiguration(AgentCapability__c cap, AIAgentDefinition__c agentDef) {
        String hitlMode = cap.HITLMode__c;

        // No validation needed if HITLMode is blank (no HITL required)
        if (String.isBlank(hitlMode)) {
            return;
        }

        // Modes that require an interactive chat runtime
        Set<String> conversationalOnlyModes = new Set<String>{ 'Confirmation', 'ConfirmationThenApproval' };

        // Validation for Confirmation and ConfirmationThenApproval modes
        if (conversationalOnlyModes.contains(hitlMode)) {
            if (
                agentDef != null &&
                RuntimeRegistryService.getTraits(agentDef, RuntimeRegistryService.getInteractionChannel(agentDef, null)).supportsConfirmationHitl != true
            ) {
                String errorMessage =
                    'HITLMode "' +
                    hitlMode +
                    '" is only supported for interactive chat agents. ' +
                    'Agent "' +
                    agentDef.DeveloperName__c +
                    '" is strategy "' +
                    agentDef.RuntimeStrategy__c +
                    '". ' +
                    'Use HITLMode "Approval" instead, which works with all agent types.';

                addFieldError(
                    cap,
                    'HITLMode__c',
                    errorMessage,
                    'Validation failed: HITLMode ' + hitlMode + ' not supported for strategy ' + agentDef.RuntimeStrategy__c
                );
            }

            // Rule 2 & 4: These modes cannot be used with async tools
            if (cap.RunAsynchronously__c == true) {
                String errorMessage =
                    'HITLMode "' +
                    hitlMode +
                    '" cannot be used with asynchronous tools. ' +
                    'This mode requires synchronous user interaction in the chat. ' +
                    'Either set RunAsynchronously to false, or use HITLMode "Approval" instead.';

                addFieldError(
                    cap,
                    'HITLMode__c',
                    errorMessage,
                    'Validation failed: HITLMode ' + hitlMode + ' not compatible with RunAsynchronously for capability: ' + cap.CapabilityName__c
                );
            }
        }

        // Note: HITLMode = 'Approval' is valid for all agent types and execution modes
        // No additional validation needed for Approval mode
    }

    /**
     * Validates that JSON string is valid and represents a JSON object.
     *
     * @param record SObject to add errors to
     * @param jsonString JSON string to validate
     * @param fieldApiName Field API name for error reporting
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
     * Validates that CapabilityName__c is unique within its parent AIAgentDefinition__c.
     *
     * @param newCapabilities List of records to validate
     * @param oldCapabilityMap Map of old records (may be null)
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
            WHERE AIAgentDefinition__c IN :agentIds AND (ExposureLevel__c != :EXPOSURE_DISABLED OR ExposureLevel__c = NULL)
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
                addFieldError(
                    cap,
                    'CapabilityName__c',
                    'This Capability Name is already used by another capability for this Agent Definition.',
                    'Uniqueness validation failed: Capability Name "' +
                        cap.CapabilityName__c +
                        '" already exists for AgentDefinition ' +
                        cap.AIAgentDefinition__c
                );
            }

            // Check 2: Has this same name been used by another record *in this trigger batch*?
            if (processedKeysInTrigger.contains(currentKey)) {
                addFieldError(
                    cap,
                    'CapabilityName__c',
                    'This Capability Name is duplicated within the records being saved.',
                    'Uniqueness validation failed: Duplicate Capability Name "' +
                        cap.CapabilityName__c +
                        '" found in trigger batch for AgentDefinition ' +
                        cap.AIAgentDefinition__c
                );
            }

            processedKeysInTrigger.add(currentKey);
        }
    }

    // ── After-trigger: Tool Flow Graph warning propagation ──────────────────

    /**
     * After-trigger entry point. Sets a persistent ToolFlowGraphWarning__c on
     * parent AIAgentDefinition__c records when capabilities are mutated and the
     * parent has an active Tool Flow Graph.
     *
     * @param newRecords Trigger.new  (null on delete)
     * @param oldRecords Trigger.old  (null on insert/undelete)
     * @param operation  Trigger.operationType
     */
    public static void handleAfterTrigger(List<AgentCapability__c> newRecords, List<AgentCapability__c> oldRecords, System.TriggerOperation operation) {
        List<AgentCapability__c> relevantRecords = (newRecords != null) ? newRecords : oldRecords;
        if (relevantRecords == null || relevantRecords.isEmpty()) {
            return;
        }

        Set<Id> agentDefIds = new Set<Id>();
        for (AgentCapability__c cap : relevantRecords) {
            if (cap.AIAgentDefinition__c != null) {
                agentDefIds.add(cap.AIAgentDefinition__c);
            }
        }
        if (agentDefIds.isEmpty()) {
            return;
        }

        String warningMessage = CAPABILITY_WARNING_MESSAGES.get(operation);
        if (String.isBlank(warningMessage)) {
            return;
        }

        // ToolFlowGraph__c is LongTextArea and cannot be filtered in SOQL WHERE.
        // Query with the field in SELECT and apply the blank check in Apex.
        List<AIAgentDefinition__c> agentsToUpdate = new List<AIAgentDefinition__c>();
        for (AIAgentDefinition__c agentDef : [
            SELECT Id, ToolFlowGraph__c
            FROM AIAgentDefinition__c
            WHERE Id IN :agentDefIds AND EnableToolFlowGraph__c = TRUE
        ]) {
            if (String.isNotBlank(agentDef.ToolFlowGraph__c)) {
                agentsToUpdate.add(new AIAgentDefinition__c(Id = agentDef.Id, ToolFlowGraphWarning__c = warningMessage));
            }
        }

        if (!agentsToUpdate.isEmpty()) {
            update agentsToUpdate;
        }
    }
}
