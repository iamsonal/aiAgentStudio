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

    public static final String TOOL_RATIONALE_PARAM_NAME = '_rationale';

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
            System.debug(LoggingLevel.ERROR, (debugPrefix ?? '[LLMFormattingService]') + 'Message role is blank. Skipping message. Context: ' + logContext);
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
     * This overload does not inject rationale parameters. Use the overload with agentConfig for tool reasoning support.
     *
     * Each tool definition includes parameter schemas, approval/confirmation requirements, and SObject field enrichment as needed.
     *
     * @param agentDefinitionId The Id of the agent definition whose capabilities should be exposed as tools.
     * @param loggingContext Optional string prefix for log output.
     * @return List<Map<String, Object>> of tool definitions ready for LLM API consumption.
     * @throws ToolFormattingException if schema validation or formatting fails critically.
     */
    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, String loggingContext) {
        return formatToolsForApi(agentDefinitionId, null, loggingContext);
    }

    /**
     * Converts all AgentCapability__c records for a given agent definition into a list of LLM-compatible tool definitions.
     * When agentConfig.EnableToolReasoning__c is true, injects a required _rationale parameter into each tool schema.
     *
     * Each tool definition includes parameter schemas, approval/confirmation requirements, and SObject field enrichment as needed.
     *
     * @param agentDefinitionId The Id of the agent definition whose capabilities should be exposed as tools.
     * @param agentConfig The agent configuration record (optional). When provided and EnableToolReasoning__c is true,
     *                    injects _rationale parameter into all tool schemas.
     * @param loggingContext Optional string prefix for log output.
     * @return List<Map<String, Object>> of tool definitions ready for LLM API consumption.
     * @throws ToolFormattingException if schema validation or formatting fails critically.
     */
    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, AIAgentDefinition__c agentConfig, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[LLMFormattingService] ';
        List<Map<String, Object>> toolsPayload = new List<Map<String, Object>>();

        // Determine if tool reasoning is enabled
        Boolean enableToolReasoning = agentConfig?.EnableToolReasoning__c == true;
        if (enableToolReasoning) {
            System.debug(LoggingLevel.INFO, debugPrefix + 'Tool reasoning enabled - will inject _rationale parameter into all tools.');
        }

        try {
            List<AgentCapability__c> capabilities = [
                SELECT Id, CapabilityName__c, Description__c, Parameters__c, HITLMode__c, ImplementationType__c, StandardActionType__c, BackendConfiguration__c
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

                if (String.isBlank(capabilityName) || String.isBlank(capabilityDesc)) {
                    System.debug(LoggingLevel.WARN, debugPrefix + 'Skipping capability (ID: ' + cap.Id + ') due to missing name or description.');
                    continue;
                }

                // Inject confirmation prompt for HITL Confirmation and ConfirmationThenApproval modes
                // This tells the LLM to ask the user for confirmation before executing
                String hitlMode = cap.HITLMode__c;
                if (hitlMode == HITLGatewayService.HITL_MODE_CONFIRMATION || hitlMode == HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                    String confirmationSuffix = '\n\nRequires user confirmation before execution.';
                    if (!capabilityDesc.containsIgnoreCase('confirm') && !capabilityDesc.containsIgnoreCase('approval')) {
                        capabilityDesc += confirmationSuffix;
                        System.debug(
                            LoggingLevel.DEBUG,
                            debugPrefix + 'Injected confirmation prompt for capability: ' + capabilityName + ' (HITLMode=' + hitlMode + ')'
                        );
                    }
                }

                if (String.isBlank(capabilityInputSchemaJson)) {
                    System.debug(LoggingLevel.WARN, debugPrefix + 'Capability "' + capabilityName + '" missing Parameters__c. Using default empty schema.');
                    capabilityInputSchemaJson = '{"type":"object", "properties":{}}';
                }

                Map<String, Object> paramSchema = parseAndValidateInputSchemaJson(capabilityInputSchemaJson, capabilityName, debugPrefix);
                if (paramSchema == null) {
                    System.debug(LoggingLevel.WARN, debugPrefix + 'Skipping capability "' + capabilityName + '" due to invalid parameter schema.');
                    continue;
                }

                String sObjectApiName = getObjectApiNameFromConfig(cap);
                if (String.isNotBlank(sObjectApiName)) {
                    SObjectType sObjType = SchemaUtils.getSObjectType(sObjectApiName);
                    if (sObjType != null) {
                        System.debug(
                            LoggingLevel.DEBUG,
                            debugPrefix + 'Enriching tool schema for capability "' + cap.CapabilityName__c + '" with SObject field metadata: ' + sObjectApiName
                        );
                        enrichSchemaWithFieldDetails(paramSchema, sObjType, debugPrefix);
                    } else {
                        System.debug(LoggingLevel.WARN, debugPrefix + 'SObjectType not found for API name: ' + sObjectApiName);
                    }
                }

                // Inject _rationale parameter if tool reasoning is enabled
                if (enableToolReasoning) {
                    injectRationaleParameter(paramSchema, debugPrefix);
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
                System.debug(LoggingLevel.WARN, '[LLMFormattingService] Failed to parse objectApiName from BackendConfiguration for capability ID ' + cap.Id);
            }
        }
        return null;
    }

    /**
     * Injects a required _rationale parameter into a tool's parameter schema.
     * This forces the LLM to provide reasoning for why it selected this tool.
     *
     * @param paramSchema The parameter schema map to modify.
     * @param debugPrefix String prefix for log output.
     */
    private static void injectRationaleParameter(Map<String, Object> paramSchema, String debugPrefix) {
        if (paramSchema == null) {
            return;
        }

        Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
        if (properties == null) {
            properties = new Map<String, Object>();
            paramSchema.put('properties', properties);
        }

        // Define the rationale meta-parameter with clear instructions
        Map<String, Object> rationaleDef = new Map<String, Object>{
            'type' => 'string',
            'description' => 'REQUIRED: Explain step-by-step WHY you are selecting this specific tool and how it directly addresses the user\'s request. Be specific about what user need this tool fulfills.'
        };

        properties.put(TOOL_RATIONALE_PARAM_NAME, rationaleDef);

        // Make it required to force the LLM to provide reasoning
        List<Object> requiredFields = (List<Object>) paramSchema.get('required');
        if (requiredFields == null) {
            requiredFields = new List<Object>();
            paramSchema.put('required', requiredFields);
        }

        // Add _rationale to required list if not already present
        // Insert at beginning to prioritize it (if list has items), otherwise just add
        if (!requiredFields.contains(TOOL_RATIONALE_PARAM_NAME)) {
            if (requiredFields.isEmpty()) {
                requiredFields.add(TOOL_RATIONALE_PARAM_NAME);
            } else {
                // Create new list with _rationale first, then existing items
                List<Object> newRequiredFields = new List<Object>{ TOOL_RATIONALE_PARAM_NAME };
                newRequiredFields.addAll(requiredFields);
                paramSchema.put('required', newRequiredFields);
            }
        }

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Injected _rationale parameter into tool schema.');
    }

    /**
     * Extracts and removes the _rationale parameter from tool arguments JSON.
     * Returns the rationale string and modifies the arguments map in place.
     *
     * @param toolArguments The JSON string of tool arguments.
     * @param debugPrefix String prefix for log output.
     * @return A map containing 'rationale' (String, may be null) and 'cleanedArguments' (String).
     */
    public static Map<String, String> extractAndStripRationale(String toolArguments, String debugPrefix) {
        Map<String, String> result = new Map<String, String>{ 'rationale' => null, 'cleanedArguments' => toolArguments };

        if (String.isBlank(toolArguments)) {
            return result;
        }

        try {
            Map<String, Object> argsMap = (Map<String, Object>) JSON.deserializeUntyped(toolArguments);

            if (argsMap.containsKey(TOOL_RATIONALE_PARAM_NAME)) {
                Object rationaleValue = argsMap.get(TOOL_RATIONALE_PARAM_NAME);
                if (rationaleValue != null) {
                    result.put('rationale', String.valueOf(rationaleValue));
                }
                argsMap.remove(TOOL_RATIONALE_PARAM_NAME);
                result.put('cleanedArguments', JSON.serialize(argsMap));

                System.debug(LoggingLevel.DEBUG, (debugPrefix ?? '[LLMFormattingService] ') + 'Extracted and stripped _rationale from tool arguments.');
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                (debugPrefix ?? '[LLMFormattingService] ') + 'Could not parse arguments for rationale extraction: ' + e.getMessage()
            );
        }

        return result;
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
                        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Added enum values (' + picklistApiNames.size() + ') for parameter: ' + paramName);
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
                System.debug(LoggingLevel.WARN, debugPrefix + 'InputSchema for ' + capabilityDevName + ' missing or invalid root type. Setting type="object".');
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
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to parse or validate InputSchema JSON for ' + capabilityDevName + ': ' + e.getMessage());
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
                    if ('ToolCall'.equals(nextStep.StepType__c) && 'Assistant'.equals(nextStep.StepRole__c) && nextStep.TurnIdentifier__c == currentTurnId) {
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

        // Post-process to ensure valid tool_call → tool_result sequence for OpenAI API
        formattedMessages = ensureValidToolCallSequence(formattedMessages, debugPrefix);

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Formatted ' + formattedMessages.size() + ' messages for LLM API.');
        return formattedMessages;
    }

    /**
     * Ensures valid message sequence for OpenAI API by reordering messages so that
     * assistant messages with tool_calls are immediately followed by their corresponding tool results.
     *
     * OpenAI requirement: An assistant message with 'tool_calls' must be immediately
     * followed by tool messages responding to each 'tool_call_id'.
     *
     * This fixes ordering issues where assistant messages appear between tool_calls and tool_results
     * due to database timestamp/ID ordering, regardless of when ExecutionStep__c records were created.
     *
     * @param messages The list of formatted messages
     * @param debugPrefix Debug logging prefix
     * @return Reordered list of messages with valid tool_call → tool_result sequence
     */
    private static List<Map<String, Object>> ensureValidToolCallSequence(List<Map<String, Object>> messages, String debugPrefix) {
        if (messages == null || messages.size() < 2) {
            return messages;
        }

        List<Map<String, Object>> reorderedMessages = new List<Map<String, Object>>();
        Map<String, Map<String, Object>> pendingToolResults = new Map<String, Map<String, Object>>();
        Set<String> pendingToolCallIds = new Set<String>();

        for (Integer i = 0; i < messages.size(); i++) {
            Map<String, Object> msg = messages[i];
            String role = (String) msg.get('role');

            if ('assistant'.equals(role) && msg.containsKey('tool_calls')) {
                // Assistant message with tool_calls - add it and track the tool_call_ids
                reorderedMessages.add(msg);

                List<Object> toolCalls = (List<Object>) msg.get('tool_calls');
                if (toolCalls != null) {
                    for (Object tc : toolCalls) {
                        Map<String, Object> toolCall = (Map<String, Object>) tc;
                        String toolCallId = (String) toolCall.get('id');
                        if (String.isNotBlank(toolCallId)) {
                            pendingToolCallIds.add(toolCallId);
                        }
                    }
                }

                // Immediately add any pending tool results that match these tool_call_ids
                Set<String> resolvedIds = new Set<String>();
                for (String toolCallId : pendingToolCallIds) {
                    if (pendingToolResults.containsKey(toolCallId)) {
                        reorderedMessages.add(pendingToolResults.get(toolCallId));
                        resolvedIds.add(toolCallId);
                    }
                }

                // Remove resolved tool results from pending
                for (String resolvedId : resolvedIds) {
                    pendingToolResults.remove(resolvedId);
                    pendingToolCallIds.remove(resolvedId);
                }
            } else if ('tool'.equals(role)) {
                // Tool result message
                String toolCallId = (String) msg.get('tool_call_id');

                if (String.isNotBlank(toolCallId) && pendingToolCallIds.contains(toolCallId)) {
                    // This tool result matches a pending tool_call - add it immediately
                    reorderedMessages.add(msg);
                    pendingToolCallIds.remove(toolCallId);
                } else {
                    // No matching pending tool_call - store for later
                    if (String.isNotBlank(toolCallId)) {
                        pendingToolResults.put(toolCallId, msg);
                    } else {
                        // Tool result without tool_call_id - add it normally
                        reorderedMessages.add(msg);
                    }
                }
            } else {
                // Regular message (user, assistant without tool_calls, system)
                if (pendingToolCallIds.isEmpty()) {
                    // No pending tool_calls - add message normally
                    reorderedMessages.add(msg);
                } else {
                    // There are pending tool_calls - this message might be interrupting the sequence
                    // Check if any of the remaining messages are tool results for pending tool_calls
                    Boolean foundMatchingToolResult = false;

                    for (Integer j = i + 1; j < messages.size(); j++) {
                        Map<String, Object> futureMsg = messages[j];
                        if ('tool'.equals(futureMsg.get('role'))) {
                            String futureToolCallId = (String) futureMsg.get('tool_call_id');
                            if (String.isNotBlank(futureToolCallId) && pendingToolCallIds.contains(futureToolCallId)) {
                                foundMatchingToolResult = true;
                                break;
                            }
                        }
                    }

                    if (foundMatchingToolResult) {
                        // Defer this message until after tool results are processed
                        System.debug(
                            LoggingLevel.INFO,
                            debugPrefix +
                                'Deferring ' +
                                role +
                                ' message to maintain tool_call → tool_result sequence. ' +
                                'Pending tool_call_ids: ' +
                                pendingToolCallIds
                        );
                        // We'll add this message later - for now, skip it
                        continue;
                    } else {
                        // No matching tool results found - add message normally
                        reorderedMessages.add(msg);
                    }
                }
            }
        }

        // Add any remaining pending tool results (shouldn't happen in normal flow)
        for (Map<String, Object> pendingResult : pendingToolResults.values()) {
            reorderedMessages.add(pendingResult);
        }

        if (reorderedMessages.size() != messages.size()) {
            System.debug(
                LoggingLevel.WARN,
                debugPrefix +
                    'Message reordering resulted in different count. Original: ' +
                    messages.size() +
                    ', Reordered: ' +
                    reorderedMessages.size() +
                    '. Some messages may have been deferred.'
            );
        } else if (reorderedMessages.size() == messages.size()) {
            // Check if any reordering actually happened
            Boolean wasReordered = false;
            for (Integer i = 0; i < messages.size(); i++) {
                if (messages[i] != reorderedMessages[i]) {
                    wasReordered = true;
                    break;
                }
            }

            if (wasReordered) {
                System.debug(LoggingLevel.INFO, debugPrefix + 'Reordered messages to ensure valid tool_call → tool_result sequence.');
            }
        }

        return reorderedMessages;
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

        // Include content if available, otherwise omit the field entirely
        // OpenAI API rejects null content - must either be a string or omitted
        if (String.isNotBlank(content)) {
            messageMap.put('content', content);
        }
        // If content is blank, omit the field - tool_calls are sufficient for assistant messages

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
            // User input and agent responses require content - skip if null/blank
            // OpenAI API rejects messages with null content
            if (String.isBlank(step.Content__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ' + step.StepType__c + ' step with blank content');
                return null; // Skip this message entirely
            }
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

                // Include content if available, otherwise omit the field entirely
                // OpenAI API rejects null content - tool_calls are sufficient without content
                if (String.isNotBlank(step.Content__c)) {
                    messageMap.put('content', step.Content__c);
                }
                // If content is blank, omit the field - tool_calls are sufficient for assistant messages
            } else {
                // Fallback to content if tool call details are incomplete
                // Skip if content is also blank
                if (String.isBlank(step.Content__c)) {
                    System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ToolCall step with incomplete tool details and blank content');
                    return null;
                }
                messageMap.put('content', step.Content__c);
            }
        } else if ('ToolResult'.equals(step.StepType__c)) {
            // Format tool results - content is required
            if (String.isBlank(step.ToolResult__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ToolResult step with blank result');
                return null; // Skip if no result content
            }
            messageMap.put('content', step.ToolResult__c);
            if (String.isNotBlank(step.ToolCallId__c)) {
                messageMap.put('tool_call_id', step.ToolCallId__c);
            }
        } else {
            // Default to content for other step types - skip if blank
            if (String.isBlank(step.Content__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping step type ' + step.StepType__c + ' with blank content');
                return null;
            }
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
