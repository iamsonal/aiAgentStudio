/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * ToolDefinitionFormatter is responsible for converting Agent Capability metadata into tool definitions
 * that are consumable by LLM APIs. It ensures that each tool definition is complete, validated, and
 * enriched with schema and field-level details as needed for robust LLM integration.
 *
 * Core responsibilities:
 *   - Validates and normalizes parameter schemas for each agent capability.
 *   - Integrates approval and confirmation requirements into tool definitions.
 *   - Enriches tool parameter schemas with SObject field metadata for enhanced LLM guidance.
 *   - Provides clear debug output and error handling to support maintainability and troubleshooting.
 *
 * This class is central to the agent framework's ability to expose safe, auditable, and well-described
 * tool interfaces to LLMs, supporting both standard and custom agent actions.
 */
public inherited sharing class ToolDefinitionFormatter {
    /**
     * Exception thrown when tool definition formatting encounters critical errors.
     * Used to signal unrecoverable issues in schema or capability processing.
     */
    public class ToolFormattingException extends LlmPayloadUtils.LlmPayloadException {
    }
    public static final String SUBMISSION_COMMENT_PARAM_NAME = 'submission_comment';

    /**
     * Converts all AgentCapability__c records for a given agent definition into a list of LLM-compatible tool definitions.
     *
     * Each tool definition includes parameter schemas, approval/confirmation requirements, and SObject field enrichment as needed.
     *
     * @param agentDefinitionId The Id of the agent definition whose capabilities should be exposed as tools.
     * @param loggingContext Optional string prefix for log output.
     * @return List<Map<String, Object>> of tool definitions ready for LLM API consumption.
     * @throws ToolFormattingException if schema validation or formatting fails critically.
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
                WHERE AIAgentDefinition__c = :agentDefinitionId AND ExposureLevel__c = 'External'
                ORDER BY CapabilityName__c ASC
            ];

            if (capabilities.isEmpty()) {
                System.debug(LoggingLevel.INFO, debugPrefix + 'No external capabilities found for Agent Definition: ' + agentDefinitionId);
                return toolsPayload;
            }
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Preparing ' + capabilities.size() + ' capabilities for LLM tool formatting.');

            for (AgentCapability__c cap : capabilities) {
                String capabilityName = cap.CapabilityName__c;
                String capabilityDesc = cap.Description__c;
                String capabilityInputSchemaJson = cap.Parameters__c;
                Boolean needsConfirmation = cap.RequiresConfirmation__c;

                if (needsConfirmation) {
                    // Add explicit confirmation instruction for LLMs to the tool description
                    capabilityDesc += '\n\nIMPORTANT: This is a sensitive action. Before calling this tool, you MUST first ask the user for confirmation with a simple "Are you sure?" style question. Do not call the tool until the user responds affirmatively.';
                    System.debug(LoggingLevel.INFO, debugPrefix + 'Added confirmation instruction to tool description: ' + capabilityName);
                }

                if (String.isBlank(capabilityName) || String.isBlank(capabilityDesc)) {
                    System.debug(LoggingLevel.WARN, debugPrefix + 'Skipping capability (ID: ' + cap.Id + ') due to missing name or description.');
                    continue;
                }
                if (String.isBlank(capabilityInputSchemaJson)) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix + 'Capability "' + capabilityName + '" missing Parameters__c. Using default empty schema.'
                    );
                    capabilityInputSchemaJson = '{"type":"object", "properties":{}}';
                }

                Map<String, Object> paramSchema = parseAndValidateInputSchemaJson(capabilityInputSchemaJson, capabilityName, debugPrefix);
                if (paramSchema == null) {
                    System.debug(LoggingLevel.WARN, debugPrefix + 'Skipping capability "' + capabilityName + '" due to invalid parameter schema.');
                    continue;
                }

                if (cap.RequiresApproval__c) {
                    System.debug(
                        LoggingLevel.INFO,
                        debugPrefix + 'Capability "' + capabilityName + '" requires approval. Adding submission_comment parameter.'
                    );

                    // Inject submission comment parameter for approval workflow
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

                    // Ensure submission comment is required for approval actions
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
                        System.debug(
                            LoggingLevel.DEBUG,
                            debugPrefix +
                                'Enriching tool schema for capability "' +
                                cap.CapabilityName__c +
                                '" with SObject field metadata: ' +
                                sObjectApiName
                        );
                        enrichSchemaWithFieldDetails(paramSchema, sObjType, debugPrefix);
                    } else {
                        System.debug(LoggingLevel.WARN, debugPrefix + 'SObjectType not found for API name: ' + sObjectApiName);
                    }
                }

                Map<String, Object> functionDef = new Map<String, Object>{
                    'name' => capabilityName,
                    'description' => capabilityDesc,
                    'parameters' => paramSchema
                };
                toolsPayload.add(new Map<String, Object>{ 'type' => 'function', 'function' => functionDef });
            }
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Successfully formatted ' + toolsPayload.size() + ' tools for LLM API.');
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                debugPrefix + 'Exception during tool formatting for Agent Definition ' + agentDefinitionId + ': ' + e.getMessage()
            );
            throw new ToolFormattingException('Failed to format tools payload: ' + e.getMessage(), e);
        }
        return toolsPayload;
    }

    /**
     * Extracts the SObject API name from the backend configuration of a capability, if present and applicable.
     * Only applies to standard actions that are object-aware (e.g., CreateRecord, UpdateRecord, GetRecords).
     *
     * @param cap The AgentCapability__c record to inspect.
     * @return The SObject API name as a string, or null if not found or not applicable.
     */
    private static String getObjectApiNameFromConfig(AgentCapability__c cap) {
        Set<String> objectAwareActions = new Set<String>{ 'CreateRecord', 'UpdateRecord', 'GetRecords' };
        if (
            'Standard'.equalsIgnoreCase(cap.ImplementationType__c) &&
            objectAwareActions.contains(cap.StandardActionType__c) &&
            String.isNotBlank(cap.BackendConfiguration__c)
        ) {
            try {
                Map<String, Object> backendConfig = (Map<String, Object>) JSON.deserializeUntyped(cap.BackendConfiguration__c);
                Object objectApiNameValue = backendConfig.get('objectApiName');
                return (objectApiNameValue != null && objectApiNameValue instanceof String) ? (String) objectApiNameValue : null;
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ToolDefFormatter] Failed to parse objectApiName from BackendConfiguration for capability ID ' + cap.Id
                );
            }
        }
        return null;
    }

    /**
     * Enriches a parameter schema map with SObject field metadata, such as field labels and picklist values.
     *
     * @param paramSchema The parameter schema map to enrich.
     * @param sObjType The SObjectType to use for field metadata.
     * @param debugPrefix String prefix for log output.
     */
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

                // Add field label to parameter description for LLM clarity
                String currentDesc = (String) paramDefinition.get('description');
                paramDefinition.put('description', (dfr.getLabel() + (String.isNotBlank(currentDesc) ? '. ' + currentDesc : '')));

                // If field is a picklist, add enum values for LLM validation
                if (dfr.getType() == DisplayType.PICKLIST) {
                    List<String> picklistApiNames = new List<String>();
                    for (PicklistEntry entry : dfr.getPicklistValues()) {
                        if (entry.isActive()) {
                            picklistApiNames.add(entry.getValue());
                        }
                    }
                    if (!picklistApiNames.isEmpty()) {
                        paramDefinition.put('enum', picklistApiNames);
                        System.debug(
                            LoggingLevel.DEBUG,
                            debugPrefix + 'Added enum values (' + picklistApiNames.size() + ') for parameter: ' + paramName
                        );
                    }
                }
            }
        }
    }

    /**
     * Validates and normalizes a capability parameter schema JSON string.
     * Ensures the schema is a JSON object with type 'object' and a valid 'properties' map.
     *
     * @param schemaJson The JSON string representing the parameter schema.
     * @param capabilityDevName The developer name of the capability (for error context).
     * @param debugPrefix String prefix for log output.
     * @return Map<String, Object> representing the normalized parameter schema, or null if invalid.
     */
    private static Map<String, Object> parseAndValidateInputSchemaJson(String schemaJson, String capabilityDevName, String debugPrefix) {
        try {
            Object parsedSchemaObj = JSON.deserializeUntyped(schemaJson);
            if (!(parsedSchemaObj instanceof Map<String, Object>)) {
                throw new ToolFormattingException('InputSchema for ' + capabilityDevName + ' must be a JSON Object.');
            }
            Map<String, Object> paramSchema = (Map<String, Object>) parsedSchemaObj;
            if (!paramSchema.containsKey('type') || !'object'.equalsIgnoreCase(String.valueOf(paramSchema.get('type')))) {
                System.debug(
                    LoggingLevel.WARN,
                    debugPrefix + 'InputSchema for ' + capabilityDevName + ' missing or invalid root type. Setting type="object".'
                );
                paramSchema.put('type', 'object');
            }
            if (!paramSchema.containsKey('properties') || !(paramSchema.get('properties') instanceof Map<String, Object>)) {
                System.debug(
                    LoggingLevel.WARN,
                    debugPrefix + 'InputSchema for ' + capabilityDevName + ' missing or invalid "properties". Initializing empty map.'
                );
                paramSchema.put('properties', new Map<String, Object>());
            }
            return paramSchema;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                debugPrefix + 'Failed to parse or validate InputSchema JSON for ' + capabilityDevName + ': ' + e.getMessage()
            );
            return null;
        }
    }
}
