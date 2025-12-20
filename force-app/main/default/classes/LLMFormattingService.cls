/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * LLMFormattingService provides comprehensive formatting utilities for converting Salesforce data objects
 * into JSON maps suitable for LLM API consumption. This service consolidates all LLM input/output
 * formatting logic in one place.
 *
 * Core responsibilities:
 *   - Message payload construction and validation for LLM APIs
 *   - Tool definition formatting from AgentCapability__c records
 *   - Execution step history conversion to LLM message format
 *   - Schema enrichment with SObject field metadata
 *   - Role validation and standardization
 *
 * This class replaces and consolidates:
 *   - LlmPayloadUtils
 *   - ToolDefinitionFormatter
 *   - ExecutionStepHistoryFormatter
 */
public inherited sharing class LLMFormattingService {
    // =============================================================================
    // EXCEPTION CLASSES
    // =============================================================================

    public virtual class LlmPayloadException extends AIAgentException {
    }

    public class ToolFormattingException extends LlmPayloadException {
    }

    // =============================================================================
    // CONSTANTS
    // =============================================================================

    public static final String SUBMISSION_COMMENT_PARAM_NAME = 'submission_comment';

    // =============================================================================
    // MESSAGE PAYLOAD UTILITIES
    // =============================================================================

    /**
     * Adds a properly formatted message to the LLM payload list, with validation and role standardization.
     *
     * - Validates the message role and logs warnings for non-standard or mismatched usage
     * - Adds content, tool calls, and tool call IDs as appropriate for the role
     * - Skips empty or incomplete messages, logging a warning
     *
     * @param payloadList  The list to add the message to (mutated in place)
     * @param role         The message role (system, user, assistant, tool)
     * @param content      The message content
     * @param toolCalls    List of tool calls for assistant messages
     * @param toolCallId   Tool call ID for tool response messages
     * @param debugPrefix  Logging prefix for debug messages
     * @param logContext   Context description for logging
     */
    public static void addMessageToPayload(
        List<Map<String, Object>> payloadList,
        String role,
        String content,
        List<Object> toolCalls,
        String toolCallId,
        String debugPrefix,
        String logContext
    ) {
        if (String.isBlank(role)) {
            System.debug(
                LoggingLevel.ERROR,
                (debugPrefix ?? '[LLMFormattingService]') + 'Message role is blank. Skipping message. Context: ' + logContext
            );
            return;
        }
        String lowerCaseRole = role.toLowerCase().trim();
        Map<String, Object> messageMap = new Map<String, Object>{ 'role' => lowerCaseRole };
        Boolean addedData = false;
        Set<String> standardRoles = new Set<String>{ 'system', 'user', 'assistant', 'tool' };
        if (!standardRoles.contains(lowerCaseRole)) {
            System.debug(
                LoggingLevel.WARN,
                (debugPrefix ?? '[LLMFormattingService]') + 'Non-standard message role: ' + lowerCaseRole + '. Context: ' + logContext
            );
        }
        if (content != null) {
            messageMap.put('content', content);
            addedData = true;
        }
        if (toolCalls != null && !toolCalls.isEmpty()) {
            if (lowerCaseRole != AIAgentConstants.ROLE_ASSISTANT) {
                System.debug(
                    LoggingLevel.WARN,
                    (debugPrefix ?? '[LLMFormattingService]') +
                        'Tool calls present for non-assistant role: ' +
                        lowerCaseRole +
                        '. This may cause API errors. Context: ' +
                        logContext
                );
            }
            messageMap.put('tool_calls', toolCalls);
            addedData = true;
        }
        if (String.isNotBlank(toolCallId)) {
            if (lowerCaseRole != AIAgentConstants.ROLE_TOOL) {
                System.debug(
                    LoggingLevel.WARN,
                    (debugPrefix ?? '[LLMFormattingService]') +
                        'Tool call ID present for non-tool role: ' +
                        lowerCaseRole +
                        '. This may cause API errors. Context: ' +
                        logContext
                );
            }
            messageMap.put('tool_call_id', toolCallId);
            addedData = true;
        }
        if (addedData || (content == null && toolCalls == null && String.isBlank(toolCallId))) {
            payloadList.add(messageMap);
        } else {
            System.debug(
                LoggingLevel.WARN,
                (debugPrefix ?? '[LLMFormattingService]') + 'Skipping empty or incomplete message for role: ' + role + '. Context: ' + logContext
            );
        }
    }

    // =============================================================================
    // TOOL DEFINITION FORMATTING
    // =============================================================================

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
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[LLMFormattingService] ';
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

                    properties.put(LLMFormattingService.SUBMISSION_COMMENT_PARAM_NAME, confirmationParam);

                    // Ensure submission comment is required for approval actions
                    Object requiredObj = paramSchema.get('required');
                    List<Object> requiredList = (requiredObj instanceof List<Object>) ? (List<Object>) requiredObj : new List<Object>();

                    if (!requiredList.contains(LLMFormattingService.SUBMISSION_COMMENT_PARAM_NAME)) {
                        requiredList.add(LLMFormattingService.SUBMISSION_COMMENT_PARAM_NAME);
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
                    '[LLMFormattingService] Failed to parse objectApiName from BackendConfiguration for capability ID ' + cap.Id
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

    // =============================================================================
    // EXECUTION STEP HISTORY FORMATTING
    // =============================================================================

    /**
     * Formats a list of ExecutionStep__c records into LLM API message format.
     *
     * @param steps List of ExecutionStep__c records to format
     * @param agentConfig Agent configuration for formatting preferences
     * @param loggingPrefix Optional logging prefix for debug output
     * @return List of formatted message maps ready for LLM API consumption
     */
    public static List<Map<String, Object>> formatStepsForApi(List<ExecutionStep__c> steps, AIAgentDefinition__c agentConfig, String loggingPrefix) {
        List<Map<String, Object>> formattedMessages = new List<Map<String, Object>>();
        String debugPrefix = String.isNotBlank(loggingPrefix) ? loggingPrefix : '[LLMFormattingService] ';

        if (steps == null || steps.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'No execution steps to format.');
            return formattedMessages;
        }

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Formatting ' + steps.size() + ' execution steps for LLM API.');

        Integer i = 0;
        while (i < steps.size()) {
            ExecutionStep__c currentStep = steps[i];

            // Check if this is a ToolCall step that might need grouping
            if ('ToolCall'.equals(currentStep.StepType__c) && 'Assistant'.equals(currentStep.StepRole__c)) {
                // Group consecutive ToolCall steps from the same turn
                List<ExecutionStep__c> toolCallGroup = new List<ExecutionStep__c>();
                String currentTurnId = currentStep.TurnIdentifier__c;

                // Collect all consecutive ToolCall steps with the same TurnIdentifier
                while (i < steps.size()) {
                    ExecutionStep__c nextStep = steps[i];
                    if (
                        'ToolCall'.equals(nextStep.StepType__c) &&
                        'Assistant'.equals(nextStep.StepRole__c) &&
                        nextStep.TurnIdentifier__c == currentTurnId
                    ) {
                        toolCallGroup.add(nextStep);
                        i++;
                    } else {
                        break;
                    }
                }

                // Format the grouped tool calls as a single assistant message
                Map<String, Object> groupedMessage = formatGroupedToolCalls(toolCallGroup, debugPrefix);
                if (groupedMessage != null) {
                    formattedMessages.add(groupedMessage);
                }
            } else {
                // Process non-ToolCall steps individually
                Map<String, Object> messageMap = formatSingleStep(currentStep, debugPrefix);
                if (messageMap != null) {
                    formattedMessages.add(messageMap);
                }
                i++;
            }
        }

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Formatted ' + formattedMessages.size() + ' messages for LLM API.');
        return formattedMessages;
    }

    /**
     * Formats a group of ToolCall ExecutionStep__c records from the same turn into a single assistant message.
     * This ensures parallel tool calls are properly represented as one assistant message with multiple tool_calls.
     *
     * @param toolCallSteps List of ToolCall ExecutionStep__c records from the same turn
     * @param debugPrefix Debug logging prefix
     * @return Formatted message map with all tool_calls or null if group is invalid
     */
    private static Map<String, Object> formatGroupedToolCalls(List<ExecutionStep__c> toolCallSteps, String debugPrefix) {
        if (toolCallSteps == null || toolCallSteps.isEmpty()) {
            return null;
        }

        Map<String, Object> messageMap = new Map<String, Object>();
        messageMap.put('role', 'assistant');

        List<Map<String, Object>> toolCalls = new List<Map<String, Object>>();
        String content = null;

        // Build the tool_calls array from all steps in the group
        for (ExecutionStep__c step : toolCallSteps) {
            if (String.isNotBlank(step.ToolName__c) && String.isNotBlank(step.ToolArguments__c)) {
                Map<String, Object> toolCall = new Map<String, Object>{
                    'id' => step.ToolCallId__c,
                    'type' => 'function',
                    'function' => new Map<String, Object>{ 'name' => step.ToolName__c, 'arguments' => step.ToolArguments__c }
                };
                toolCalls.add(toolCall);

                // Use content from the first step that has it
                if (content == null && String.isNotBlank(step.Content__c)) {
                    content = step.Content__c;
                }
            }
        }

        if (toolCalls.isEmpty()) {
            System.debug(LoggingLevel.WARN, debugPrefix + 'No valid tool calls found in group of ' + toolCallSteps.size() + ' steps');
            return null;
        }

        messageMap.put('tool_calls', toolCalls);

        // Include content if available, otherwise set to null (required by some LLM APIs)
        if (String.isNotBlank(content)) {
            messageMap.put('content', content);
        } else {
            messageMap.put('content', null);
        }

        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix + 'Grouped ' + toolCallSteps.size() + ' ToolCall steps into single assistant message with ' + toolCalls.size() + ' tool_calls'
        );

        return messageMap;
    }

    /**
     * Formats a single ExecutionStep__c record into LLM API message format.
     *
     * @param step The ExecutionStep__c record to format
     * @param debugPrefix Debug logging prefix
     * @return Formatted message map or null if step should be skipped
     */
    private static Map<String, Object> formatSingleStep(ExecutionStep__c step, String debugPrefix) {
        if (step == null) {
            return null;
        }

        // Map ExecutionStep roles to LLM API roles
        String llmRole = mapStepRoleToLlmRole(step.StepRole__c);
        if (llmRole == null) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping step with unmappable role: ' + step.StepRole__c);
            return null;
        }

        Map<String, Object> messageMap = new Map<String, Object>();
        messageMap.put('role', llmRole);

        // Handle content based on step type
        if ('UserInput'.equals(step.StepType__c) || 'AgentResponse'.equals(step.StepType__c)) {
            // Direct content for user input and agent responses
            messageMap.put('content', step.Content__c);
        } else if ('ToolCall'.equals(step.StepType__c)) {
            // Format tool calls similar to ChatMessage format
            if (String.isNotBlank(step.ToolName__c) && String.isNotBlank(step.ToolArguments__c)) {
                List<Map<String, Object>> toolCalls = new List<Map<String, Object>>();
                Map<String, Object> toolCall = new Map<String, Object>{
                    'id' => step.ToolCallId__c,
                    'type' => 'function',
                    'function' => new Map<String, Object>{ 'name' => step.ToolName__c, 'arguments' => step.ToolArguments__c }
                };
                toolCalls.add(toolCall);
                messageMap.put('tool_calls', toolCalls);

                // Include content if available
                if (String.isNotBlank(step.Content__c)) {
                    messageMap.put('content', step.Content__c);
                } else {
                    messageMap.put('content', null); // Required by some LLM APIs
                }
            } else {
                // Fallback to content if tool call details are incomplete
                messageMap.put('content', step.Content__c);
            }
        } else if ('ToolResult'.equals(step.StepType__c)) {
            // Format tool results
            messageMap.put('content', step.ToolResult__c);
            if (String.isNotBlank(step.ToolCallId__c)) {
                messageMap.put('tool_call_id', step.ToolCallId__c);
            }
        } else {
            // Default to content for other step types
            messageMap.put('content', step.Content__c);
        }

        return messageMap;
    }

    /**
     * Maps ExecutionStep__c StepRole__c values to LLM API role values.
     *
     * @param stepRole The StepRole__c value from ExecutionStep__c
     * @return The corresponding LLM API role or null if unmappable
     */
    private static String mapStepRoleToLlmRole(String stepRole) {
        if (String.isBlank(stepRole)) {
            return null;
        }

        // Map ExecutionStep roles to standard LLM API roles
        switch on stepRole.toLowerCase() {
            when 'user' {
                return 'user';
            }
            when 'assistant' {
                return 'assistant';
            }
            when 'tool' {
                return 'tool';
            }
            when 'system' {
                return 'system';
            }
            when 'email' {
                return 'user';
            }
            when else {
                return null; // Skip unknown roles
            }
        }
    }
}

