/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Formats tool definitions for LLM APIs based on Agent Capabilities.
 */
public inherited sharing class ToolDefinitionFormatter {
    /** @description Exception for critical errors during tool definition formatting */
    public class ToolFormattingException extends LlmPayloadUtils.LlmPayloadException {
    }
    public static final String CONFIRMATION_PARAM_NAME = 'confirmation_message';

    /**
     * Formats the tool definition payload based on active Agent Capabilities.
     * @param agentDefinitionId The ID of the agent definition.
     * @param loggingContext Logging prefix.
     * @return List<Map<String, Object>> Formatted tool list for LLM API.
     * @throws ToolFormattingException If bindings or schemas are critically invalid.
     */
    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[ToolDefFormatter] ';
        List<Map<String, Object>> toolsPayload = new List<Map<String, Object>>();

        try {
            List<AgentCapabilityBinding__c> capabilities = [
                SELECT Id, DeveloperName__c, Description__c, InputSchema__c, RequiresHumanApproval__c, ActionDefinition__r.IsActive__c
                FROM AgentCapabilityBinding__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE AND ActionDefinition__r.IsActive__c = TRUE
                ORDER BY ExecutionOrder__c ASC NULLS LAST, Name ASC
            ];

            if (capabilities.isEmpty()) {
                return toolsPayload;
            }

            for (AgentCapabilityBinding__c binding : capabilities) {
                String capabilityDevName = binding.DeveloperName__c;
                String capabilityDesc = binding.Description__c;
                String capabilityInputSchemaJson = binding.InputSchema__c;
                Boolean needsConfirmation = binding.RequiresHumanApproval__c == true;

                if (String.isBlank(capabilityDevName)) {
                    continue;
                }
                if (String.isBlank(capabilityDesc)) {
                    continue;
                }
                if (String.isBlank(capabilityInputSchemaJson)) {
                    capabilityInputSchemaJson = '{"type":"object", "properties":{}}';
                }

                Map<String, Object> paramSchema = parseAndValidateInputSchemaJson(capabilityInputSchemaJson, capabilityDevName, debugPrefix);
                if (paramSchema == null) {
                    continue;
                }

                if (needsConfirmation) {
                    paramSchema = addConfirmationParameterToSchema(paramSchema, capabilityDevName, debugPrefix);
                    if (paramSchema == null) {
                        continue;
                    }
                }

                Map<String, Object> functionDef = new Map<String, Object>{
                    'name' => capabilityDevName,
                    'description' => capabilityDesc,
                    'parameters' => paramSchema
                };
                toolsPayload.add(new Map<String, Object>{ 'type' => 'function', 'function' => functionDef });
            }
        } catch (Exception e) {
            throw new ToolFormattingException('Failed to format tools payload: ' + e.getMessage(), e);
        }
        return toolsPayload;
    }

    /** Parses and validates the binding's InputSchema__c JSON */
    private static Map<String, Object> parseAndValidateInputSchemaJson(String schemaJson, String capabilityDevName, String debugPrefix) {
        try {
            Object parsedSchemaObj = JSON.deserializeUntyped(schemaJson);
            if (!(parsedSchemaObj instanceof Map<String, Object>)) {
                throw new ToolFormattingException('InputSchema for ' + capabilityDevName + ' must be a JSON Object.');
            }
            Map<String, Object> paramSchema = (Map<String, Object>) parsedSchemaObj;
            if (!paramSchema.containsKey('type') || !'object'.equalsIgnoreCase(String.valueOf(paramSchema.get('type')))) {
                paramSchema.put('type', 'object');
            }
            if (!paramSchema.containsKey('properties') || !(paramSchema.get('properties') instanceof Map<String, Object>)) {
                paramSchema.put('properties', new Map<String, Object>());
            }
            return paramSchema;
        } catch (Exception e) {
            return null;
        }
    }

    /** Adds the confirmation_message parameter to an existing schema map. */
    private static Map<String, Object> addConfirmationParameterToSchema(
        Map<String, Object> originalSchema,
        String capabilityDevName,
        String logPrefix
    ) {
        try {
            Map<String, Object> modifiedSchema = originalSchema;
            Map<String, Object> confirmationParamDef = new Map<String, Object>{
                'type' => 'string',
                'description' => 'Required. A human-readable message describing what this function will do. This will be shown to the user for confirmation before executing.'
            };
            Map<String, Object> properties = (Map<String, Object>) modifiedSchema.get('properties');
            properties.put(CONFIRMATION_PARAM_NAME, confirmationParamDef);

            if (modifiedSchema.containsKey('required') && modifiedSchema.get('required') instanceof List<Object>) {
                List<Object> requiredList = (List<Object>) modifiedSchema.get('required');
                Boolean found = false;
                for (Object reqItem : requiredList) {
                    if (reqItem instanceof String && ((String) reqItem) == CONFIRMATION_PARAM_NAME) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    requiredList.add(CONFIRMATION_PARAM_NAME);
                }
            } else {
                modifiedSchema.put('required', new List<String>{ CONFIRMATION_PARAM_NAME });
            }
            return modifiedSchema;
        } catch (Exception e) {
            return null;
        }
    }
}
