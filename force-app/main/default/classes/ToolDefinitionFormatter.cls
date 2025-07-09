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
    public static final String SUBMISSION_COMMENT_PARAM_NAME = 'submission_comment';

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
            List<AgentCapability__c> capabilities = [
                SELECT
                    Id,
                    CapabilityName__c,
                    Description__c,
                    Parameters__c,
                    RequiresConfirmation__c,
                    RequiresApproval__c,
                    ImplementationType__c,
                    StandardActionType__c,
                    BackendConfiguration__c
                FROM AgentCapability__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE
                ORDER BY ExecutionPriority__c ASC NULLS LAST, CapabilityName__c ASC
            ];

            if (capabilities.isEmpty()) {
                return toolsPayload;
            }

            for (AgentCapability__c cap : capabilities) {
                String capabilityName = cap.CapabilityName__c;
                String capabilityDesc = cap.Description__c;
                String capabilityInputSchemaJson = cap.Parameters__c;
                Boolean needsConfirmation = cap.RequiresConfirmation__c;

                if (needsConfirmation) {
                    capabilityDesc += '\n\nIMPORTANT: This is a sensitive action. Before calling this tool, you MUST first ask the user for confirmation with a simple "Are you sure?" style question. Do not call the tool until the user responds affirmatively.';
                }

                if (String.isBlank(capabilityName) || String.isBlank(capabilityDesc)) {
                    continue;
                }
                if (String.isBlank(capabilityInputSchemaJson)) {
                    capabilityInputSchemaJson = '{"type":"object", "properties":{}}';
                }

                Map<String, Object> paramSchema = parseAndValidateInputSchemaJson(capabilityInputSchemaJson, capabilityName, debugPrefix);
                if (paramSchema == null)
                    continue;

                if (cap.RequiresApproval__c) {
                    Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
                    if (properties == null) {
                        properties = new Map<String, Object>();
                        paramSchema.put('properties', properties);
                    }

                    Map<String, Object> confirmationParam = new Map<String, Object>{
                        'type' => 'string',
                        'description' => 'A concise but clear justification for this request. This message will be sent to the manager for approval.'
                    };

                    properties.put(ToolDefinitionFormatter.SUBMISSION_COMMENT_PARAM_NAME, confirmationParam);

                    Object requiredObj = paramSchema.get('required');
                    List<Object> requiredList = (requiredObj instanceof List<Object>) ? (List<Object>) requiredObj : new List<Object>();

                    if (!requiredList.contains(ToolDefinitionFormatter.SUBMISSION_COMMENT_PARAM_NAME)) {
                        requiredList.add(ToolDefinitionFormatter.SUBMISSION_COMMENT_PARAM_NAME);
                    }
                    paramSchema.put('required', requiredList);
                }

                String sObjectApiName = getObjectApiNameFromConfig(cap);
                if (String.isNotBlank(sObjectApiName)) {
                    SObjectType sObjType = SchemaUtils.getSObjectType(sObjectApiName);
                    if (sObjType != null) {
                        enrichSchemaWithFieldDetails(paramSchema, sObjType, debugPrefix);
                    }
                }

                Map<String, Object> functionDef = new Map<String, Object>{
                    'name' => capabilityName,
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

    private static String getObjectApiNameFromConfig(AgentCapability__c cap) {
        Set<String> objectAwareActions = new Set<String>{ 'CreateRecord', 'UpdateRecord', 'GetRecords' };
        if (
            'Standard'.equalsIgnoreCase(cap.ImplementationType__c) &&
            objectAwareActions.contains(cap.StandardActionType__c) &&
            String.isNotBlank(cap.BackendConfiguration__c)
        ) {
            try {
                Map<String, Object> backendConfig = (Map<String, Object>) JSON.deserializeUntyped(cap.BackendConfiguration__c);
                if (backendConfig.containsKey('objectApiName') && backendConfig.get('objectApiName') instanceof String) {
                    return (String) backendConfig.get('objectApiName');
                }
            } catch (Exception e) {
            }
        }
        return null;
    }

    private static void enrichSchemaWithFieldDetails(Map<String, Object> paramSchema, SObjectType sObjType, String debugPrefix) {
        if (paramSchema == null || !paramSchema.containsKey('properties'))
            return;

        Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
        Map<String, SObjectField> objectFields = SchemaUtils.getObjectFields(sObjType);

        for (String paramName : properties.keySet()) {
            SObjectField fieldToken = objectFields.get(paramName.toLowerCase());
            if (fieldToken != null) {
                DescribeFieldResult dfr = fieldToken.getDescribe();
                Map<String, Object> paramDefinition = (Map<String, Object>) properties.get(paramName);

                String currentDesc = (String) paramDefinition.get('description');
                paramDefinition.put('description', (dfr.getLabel() + (String.isNotBlank(currentDesc) ? '. ' + currentDesc : '')));

                if (dfr.getType() == DisplayType.PICKLIST) {
                    List<String> picklistApiNames = new List<String>();
                    for (PicklistEntry entry : dfr.getPicklistValues()) {
                        if (entry.isActive()) {
                            picklistApiNames.add(entry.getValue());
                        }
                    }
                    if (!picklistApiNames.isEmpty()) {
                        paramDefinition.put('enum', picklistApiNames);
                    }
                }
            }
        }
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
}
