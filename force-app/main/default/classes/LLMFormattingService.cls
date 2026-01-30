/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides comprehensive formatting utilities for converting Salesforce data objects into JSON maps suitable for LLM API consumption.
 */
public inherited sharing class LLMFormattingService {
    public virtual class LlmPayloadException extends AIAgentException {
    }

    public class ToolFormattingException extends LlmPayloadException {
    }

    public static final String TOOL_RATIONALE_PARAM_NAME = '_rationale';

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

    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, String loggingContext) {
        return formatToolsForApi(agentDefinitionId, null, null, loggingContext);
    }

    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, AIAgentDefinition__c agentConfig, String loggingContext) {
        return formatToolsForApi(agentDefinitionId, agentConfig, null, loggingContext);
    }

    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, AIAgentDefinition__c agentConfig, Id executionId, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[LLMFormattingService] ';
        List<Map<String, Object>> toolsPayload = new List<Map<String, Object>>();

        Boolean enableToolReasoning = agentConfig?.EnableToolReasoning__c == true;
        if (enableToolReasoning) {
            System.debug(LoggingLevel.INFO, debugPrefix + 'Tool reasoning enabled - will inject _rationale parameter into all tools.');
        }

        try {
            List<AgentCapability__c> allCapabilities = AIAgentConfigService.getCapabilitiesByAgentId(agentDefinitionId);

            List<AgentCapability__c> capabilities = new List<AgentCapability__c>();
            for (AgentCapability__c cap : allCapabilities) {
                if (cap.ExposureLevel__c == 'External') {
                    capabilities.add(cap);
                }
            }

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

                // Inject conditional approval parameters if ConditionalApproval mode
                if (hitlMode == HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL) {
                    injectConditionalApprovalParameters(paramSchema, capabilityName, debugPrefix);
                }

                // Inject confidence parameter if TrackConfidence is enabled
                if (cap.TrackConfidence__c == true) {
                    injectConfidenceParameter(paramSchema, capabilityName, debugPrefix);
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

    private static void injectRationaleParameter(Map<String, Object> paramSchema, String debugPrefix) {
        if (paramSchema == null) {
            return;
        }

        Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
        if (properties == null) {
            properties = new Map<String, Object>();
            paramSchema.put('properties', properties);
        }

        Map<String, Object> rationaleDef = new Map<String, Object>{
            'type' => 'string',
            'description' => 'REQUIRED: Explain step-by-step WHY you are selecting this specific tool and how it directly addresses the user\'s request. Be specific about what user need this tool fulfills.'
        };

        properties.put(TOOL_RATIONALE_PARAM_NAME, rationaleDef);

        List<Object> requiredFields = (List<Object>) paramSchema.get('required');
        if (requiredFields == null) {
            requiredFields = new List<Object>();
            paramSchema.put('required', requiredFields);
        }

        if (!requiredFields.contains(TOOL_RATIONALE_PARAM_NAME)) {
            if (requiredFields.isEmpty()) {
                requiredFields.add(TOOL_RATIONALE_PARAM_NAME);
            } else {
                List<Object> newRequiredFields = new List<Object>{ TOOL_RATIONALE_PARAM_NAME };
                newRequiredFields.addAll(requiredFields);
                paramSchema.put('required', newRequiredFields);
            }
        }

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Injected _rationale parameter into tool schema.');
    }

    /**
     * @description Injects _requiresApproval and _approvalReason parameters for ConditionalApproval HITL mode
     * @param paramSchema The parameter schema to inject into
     * @param capabilityName Name of the capability (for logging)
     * @param debugPrefix Debug prefix for logging
     */
    private static void injectConditionalApprovalParameters(Map<String, Object> paramSchema, String capabilityName, String debugPrefix) {
        if (paramSchema == null) {
            return;
        }

        Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
        if (properties == null) {
            properties = new Map<String, Object>();
            paramSchema.put('properties', properties);
        }

        // Add _requiresApproval parameter
        Map<String, Object> requiresApprovalDef = new Map<String, Object>{
            'type' => 'boolean',
            'description' => 'Set to true if this action requires manager approval based on the conditional approval rules in the capability description. Analyze the context data (account revenue, risk level, transaction amount, etc.) to determine if approval is needed per the rules specified.',
            'default' => false
        };
        properties.put('_requiresApproval', requiresApprovalDef);

        // Add _approvalReason parameter
        Map<String, Object> approvalReasonDef = new Map<String, Object>{
            'type' => 'string',
            'description' => 'REQUIRED when _requiresApproval=true. Provide a clear, specific explanation of why approval is needed, referencing the relevant approval rule and including concrete data points (e.g., "Enterprise account with $75M annual revenue exceeds $50M approval threshold. Strategic $500k deal with CEO engagement."). This explanation will be shown to the approver.'
        };
        properties.put('_approvalReason', approvalReasonDef);

        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix + 'Injected conditional approval parameters (_requiresApproval, _approvalReason) for capability: ' + capabilityName
        );
    }

    /**
     * @description Injects _confidence parameter when TrackConfidence is enabled on capability
     * @param paramSchema The parameter schema to inject into
     * @param capabilityName Name of the capability (for logging)
     * @param debugPrefix Debug prefix for logging
     */
    private static void injectConfidenceParameter(Map<String, Object> paramSchema, String capabilityName, String debugPrefix) {
        if (paramSchema == null) {
            return;
        }

        Map<String, Object> properties = (Map<String, Object>) paramSchema.get('properties');
        if (properties == null) {
            properties = new Map<String, Object>();
            paramSchema.put('properties', properties);
        }

        // Add _confidence parameter
        Map<String, Object> confidenceDef = new Map<String, Object>{
            'type' => 'number',
            'minimum' => 0,
            'maximum' => 100,
            'description' => 'REQUIRED: Your confidence score for this action (0-100). Consider: Do you have all needed data? Are the parameters clear and valid? Is this the right tool for the task? Are there any ambiguities? Rate your certainty: 90-100 (very confident, all clear), 70-89 (confident, minor gaps), 50-69 (uncertain, missing data), below 50 (not confident, should clarify).'
        };
        properties.put('_confidence', confidenceDef);

        // Add to required fields
        List<Object> requiredFields = (List<Object>) paramSchema.get('required');
        if (requiredFields != null) {
            if (!requiredFields.contains('_confidence')) {
                List<Object> newRequiredFields = new List<Object>{ '_confidence' };
                newRequiredFields.addAll(requiredFields);
                paramSchema.put('required', newRequiredFields);
            }
        } else {
            paramSchema.put('required', new List<String>{ '_confidence' });
        }

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Injected _confidence parameter for capability: ' + capabilityName);
    }

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
                        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Added enum values (' + picklistApiNames.size() + ') for parameter: ' + paramName);
                    }
                }
            }
        }
    }

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

            if ('ToolCall'.equals(currentStep.StepType__c) && 'Assistant'.equals(currentStep.StepRole__c)) {
                List<ExecutionStep__c> toolCallGroup = new List<ExecutionStep__c>();
                String currentTurnId = currentStep.TurnIdentifier__c;

                while (i < steps.size()) {
                    ExecutionStep__c nextStep = steps[i];
                    if ('ToolCall'.equals(nextStep.StepType__c) && 'Assistant'.equals(nextStep.StepRole__c) && nextStep.TurnIdentifier__c == currentTurnId) {
                        toolCallGroup.add(nextStep);
                        i++;
                    } else {
                        break;
                    }
                }

                Map<String, Object> groupedMessage = formatGroupedToolCalls(toolCallGroup, debugPrefix);
                if (groupedMessage != null) {
                    formattedMessages.add(groupedMessage);
                }
            } else {
                Map<String, Object> messageMap = formatSingleStep(currentStep, debugPrefix);
                if (messageMap != null) {
                    formattedMessages.add(messageMap);
                }
                i++;
            }
        }

        formattedMessages = ensureValidToolCallSequence(formattedMessages, debugPrefix);

        System.debug(LoggingLevel.DEBUG, debugPrefix + 'Formatted ' + formattedMessages.size() + ' messages for LLM API.');
        return formattedMessages;
    }

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

                Set<String> resolvedIds = new Set<String>();
                for (String toolCallId : pendingToolCallIds) {
                    if (pendingToolResults.containsKey(toolCallId)) {
                        reorderedMessages.add(pendingToolResults.get(toolCallId));
                        resolvedIds.add(toolCallId);
                    }
                }

                for (String resolvedId : resolvedIds) {
                    pendingToolResults.remove(resolvedId);
                    pendingToolCallIds.remove(resolvedId);
                }
            } else if ('tool'.equals(role)) {
                String toolCallId = (String) msg.get('tool_call_id');

                if (String.isNotBlank(toolCallId) && pendingToolCallIds.contains(toolCallId)) {
                    reorderedMessages.add(msg);
                    pendingToolCallIds.remove(toolCallId);
                } else {
                    if (String.isNotBlank(toolCallId)) {
                        pendingToolResults.put(toolCallId, msg);
                    } else {
                        reorderedMessages.add(msg);
                    }
                }
            } else {
                if (pendingToolCallIds.isEmpty()) {
                    reorderedMessages.add(msg);
                } else {
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

    private static Map<String, Object> formatGroupedToolCalls(List<ExecutionStep__c> toolCallSteps, String debugPrefix) {
        if (toolCallSteps == null || toolCallSteps.isEmpty()) {
            return null;
        }

        Map<String, Object> messageMap = new Map<String, Object>();
        messageMap.put('role', 'assistant');

        List<Map<String, Object>> toolCalls = new List<Map<String, Object>>();
        String content = null;

        for (ExecutionStep__c step : toolCallSteps) {
            if (String.isNotBlank(step.ToolName__c) && String.isNotBlank(step.ToolArguments__c)) {
                Map<String, Object> toolCall = new Map<String, Object>{
                    'id' => step.ToolCallId__c,
                    'type' => 'function',
                    'function' => new Map<String, Object>{ 'name' => step.ToolName__c, 'arguments' => step.ToolArguments__c }
                };
                toolCalls.add(toolCall);

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

        if (String.isNotBlank(content)) {
            messageMap.put('content', content);
        }

        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix + 'Grouped ' + toolCallSteps.size() + ' ToolCall steps into single assistant message with ' + toolCalls.size() + ' tool_calls'
        );

        return messageMap;
    }

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

        if ('UserInput'.equals(step.StepType__c) || 'AgentResponse'.equals(step.StepType__c)) {
            if (String.isBlank(step.Content__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ' + step.StepType__c + ' step with blank content');
                return null;
            }
            messageMap.put('content', step.Content__c);
        } else if ('ToolCall'.equals(step.StepType__c)) {
            if (String.isNotBlank(step.ToolName__c) && String.isNotBlank(step.ToolArguments__c)) {
                List<Map<String, Object>> toolCalls = new List<Map<String, Object>>();
                Map<String, Object> toolCall = new Map<String, Object>{
                    'id' => step.ToolCallId__c,
                    'type' => 'function',
                    'function' => new Map<String, Object>{ 'name' => step.ToolName__c, 'arguments' => step.ToolArguments__c }
                };
                toolCalls.add(toolCall);
                messageMap.put('tool_calls', toolCalls);

                if (String.isNotBlank(step.Content__c)) {
                    messageMap.put('content', step.Content__c);
                }
            } else {
                if (String.isBlank(step.Content__c)) {
                    System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ToolCall step with incomplete tool details and blank content');
                    return null;
                }
                messageMap.put('content', step.Content__c);
            }
        } else if ('ToolResult'.equals(step.StepType__c)) {
            if (String.isBlank(step.ToolResult__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping ToolResult step with blank result');
                return null;
            }
            messageMap.put('content', step.ToolResult__c);
            if (String.isNotBlank(step.ToolCallId__c)) {
                messageMap.put('tool_call_id', step.ToolCallId__c);
            }
        } else {
            if (String.isBlank(step.Content__c)) {
                System.debug(LoggingLevel.DEBUG, debugPrefix + 'Skipping step type ' + step.StepType__c + ' with blank content');
                return null;
            }
            messageMap.put('content', step.Content__c);
        }

        return messageMap;
    }

    private static String mapStepRoleToLlmRole(String stepRole) {
        if (String.isBlank(stepRole)) {
            return null;
        }

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
                return null;
            }
        }
    }
}
