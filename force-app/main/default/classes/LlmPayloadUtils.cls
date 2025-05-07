/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Utilities specifically for formatting payloads for and parsing responses from LLM APIs,
 *              following structures like OpenAI's Chat Completions API.
 */
public inherited sharing class LlmPayloadUtils {
    /** @description General Exception class for this utility - MUST BE VIRTUAL */
    public virtual class LlmPayloadException extends AIAgentException {
    }

    /** @description Exception for critical errors during payload formatting */
    public class PayloadFormattingException extends LlmPayloadException {
    }

    private static final String CONFIRMATION_PARAM_NAME = 'confirmation_message';

    /**
     * @description Formats chat history, system prompt, and context into the message list format required by LLM APIs.
     *              Handles correct sequencing of user, assistant, and tool messages.
     * @param historySObjectsAsc List<ChatMessage__c> PRE-FETCHED & sorted ASC by Timestamp. Requires Id, Role__c, Content__c, AssistantToolCalls__c, ToolCallId__c fields.
     * @param agentConfig The AIAgentDefinition__c containing system prompt settings. Requires IncludeSystemPromptInHistory__c, SystemPrompt__c fields.
     * @param injectedContextString Optional pre-formatted context string to inject (usually as a system message).
     * @param loggingContext A string for prepending log messages.
     * @return List<Map<String, Object>> The formatted message list ready for JSON serialization.
     * @throws PayloadFormattingException for critical errors during formatting (e.g., corrupted tool calls JSON, missing tool results).
     */
    public static List<Map<String, Object>> formatMessagesForApi(
        List<ChatMessage__c> historySObjectsAsc,
        AIAgentDefinition__c agentConfig,
        String injectedContextString,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[LlmPayloadUtils] ';

        if (agentConfig == null) {
            throw new PayloadFormattingException('Agent configuration cannot be null.');
        }

        List<Map<String, Object>> finalPayload = new List<Map<String, Object>>();
        Set<Id> processedToolMessageIds = new Set<Id>();
        Map<Id, List<String>> assistantToToolCallIdsMap = new Map<Id, List<String>>();
        Map<String, ChatMessage__c> toolCallIdToMessageMap = new Map<String, ChatMessage__c>();
        Set<Id> assistantMsgIdsWithToolCalls = new Set<Id>();

        if (historySObjectsAsc != null) {
            for (ChatMessage__c msg : historySObjectsAsc) {
                String role = msg.Role__c?.toLowerCase();
                if (role == AIAgentConstants.ROLE_ASSISTANT && String.isNotBlank(msg.AssistantToolCalls__c)) {
                    List<String> requestedIds = parseToolCallIdsFromAssistantJson(msg.AssistantToolCalls__c, msg.Id, debugPrefix);
                    if (!requestedIds.isEmpty()) {
                        assistantToToolCallIdsMap.put(msg.Id, requestedIds);
                        assistantMsgIdsWithToolCalls.add(msg.Id);
                    }
                } else if (role == AIAgentConstants.ROLE_TOOL && String.isNotBlank(msg.ToolCallId__c)) {
                    if (toolCallIdToMessageMap.containsKey(msg.ToolCallId__c)) {
                    }
                    toolCallIdToMessageMap.put(msg.ToolCallId__c, msg);
                }
            }
        }

        if (agentConfig.IncludeSystemPromptInHistory__c == true && String.isNotBlank(agentConfig.SystemPrompt__c)) {
            addMessageToPayload(finalPayload, AIAgentConstants.ROLE_SYSTEM, agentConfig.SystemPrompt__c, null, null, debugPrefix, 'System Prompt');
        }
        if (String.isNotBlank(injectedContextString)) {
            addMessageToPayload(finalPayload, AIAgentConstants.ROLE_SYSTEM, injectedContextString, null, null, debugPrefix, 'Injected Context');
        }

        if (historySObjectsAsc != null && !historySObjectsAsc.isEmpty()) {
            for (ChatMessage__c currentMsg : historySObjectsAsc) {
                String role = currentMsg.Role__c?.toLowerCase();
                String msgKey = 'Msg ' + currentMsg.Id + ' (' + role + ')';

                if (role == AIAgentConstants.ROLE_TOOL && processedToolMessageIds.contains(currentMsg.Id))
                    continue;
                if (role == AIAgentConstants.ROLE_TOOL && !processedToolMessageIds.contains(currentMsg.Id)) {
                    continue;
                }

                if (
                    role == AIAgentConstants.ROLE_USER ||
                    role == AIAgentConstants.ROLE_SYSTEM ||
                    (role == AIAgentConstants.ROLE_ASSISTANT && !assistantMsgIdsWithToolCalls.contains(currentMsg.Id))
                ) {
                    addMessageToPayload(finalPayload, role, currentMsg.Content__c, null, null, debugPrefix, msgKey);
                } else if (role == AIAgentConstants.ROLE_ASSISTANT && assistantMsgIdsWithToolCalls.contains(currentMsg.Id)) {
                    List<String> requestedToolCallIds = assistantToToolCallIdsMap.get(currentMsg.Id);
                    List<Object> parsedToolCallsForPayload = parseToolCallsJsonForPayload(
                        currentMsg.AssistantToolCalls__c,
                        currentMsg.Id,
                        debugPrefix
                    );

                    addMessageToPayload(
                        finalPayload,
                        AIAgentConstants.ROLE_ASSISTANT,
                        currentMsg.Content__c,
                        parsedToolCallsForPayload,
                        null,
                        debugPrefix,
                        msgKey
                    );

                    if (requestedToolCallIds != null && !requestedToolCallIds.isEmpty()) {
                        for (String toolCallId : requestedToolCallIds) {
                            ChatMessage__c toolResultMessage = toolCallIdToMessageMap.get(toolCallId);
                            if (toolResultMessage != null) {
                                String toolMsgKey = '  Tool Result Msg ' + toolResultMessage.Id + ' (for CallId ' + toolCallId + ')';
                                addMessageToPayload(
                                    finalPayload,
                                    AIAgentConstants.ROLE_TOOL,
                                    toolResultMessage.Content__c,
                                    null,
                                    toolCallId,
                                    debugPrefix,
                                    toolMsgKey
                                );
                                processedToolMessageIds.add(toolResultMessage.Id);
                            } else {
                                throw new PayloadFormattingException(
                                    'Data Consistency Error: Tool result message not found for requested ToolCallId: ' +
                                        toolCallId +
                                        ' from Assistant Message ' +
                                        currentMsg.Id
                                );
                            }
                        }
                    }
                } else {
                }
            }
        }

        if (
            finalPayload.isEmpty() &&
            !(agentConfig.IncludeSystemPromptInHistory__c == true && String.isNotBlank(agentConfig.SystemPrompt__c)) &&
            String.isBlank(injectedContextString)
        ) {
        }

        return finalPayload;
    }

    /**
     * Formats the tool definition payload based on active Agent Capabilities.
     * @param agentDefinitionId The ID of the agent definition.
     * @param loggingContext Logging prefix.
     * @return List<Map<String, Object>> Formatted tool list for LLM API. Returns empty list if no active capabilities.
     * @throws LlmPayloadException If bindings or schemas are critically invalid.
     */
    public static List<Map<String, Object>> formatToolsForApi(Id agentDefinitionId, String loggingContext) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[LlmPayloadUtils] ';
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
            throw new LlmPayloadException('Failed to format tools payload: ' + e.getMessage(), e);
        }
        return toolsPayload;
    }

    /** Parses the AssistantToolCalls__c JSON string specifically to get tool call IDs */
    private static List<String> parseToolCallIdsFromAssistantJson(String toolCallsJson, Id assistantMsgId, String debugPrefix) {
        List<String> ids = new List<String>();
        if (String.isBlank(toolCallsJson))
            return ids;
        try {
            Object parsed = JSON.deserializeUntyped(toolCallsJson);
            if (!(parsed instanceof List<Object>))
                throw new JSONException('Tool calls JSON is not a List');

            for (Object callObj : (List<Object>) parsed) {
                if (callObj instanceof Map<String, Object>) {
                    Map<String, Object> callMap = (Map<String, Object>) callObj;
                    Object idObj = callMap.get('id');
                    if (idObj instanceof String && String.isNotBlank((String) idObj)) {
                        ids.add((String) idObj);
                    } else {
                    }
                }
            }
        } catch (Exception e) {
            throw new PayloadFormattingException('Could not parse tool call IDs from message ' + assistantMsgId, e);
        }
        return ids;
    }

    /** Parses the AssistantToolCalls__c JSON for including in the *next* API request payload */
    private static List<Object> parseToolCallsJsonForPayload(String toolCallsJson, Id assistantMsgId, String debugPrefix) {
        if (String.isBlank(toolCallsJson))
            return new List<Object>();
        try {
            Object parsed = JSON.deserializeUntyped(toolCallsJson);
            if (parsed instanceof List<Object>) {
                return (List<Object>) parsed;
            } else {
                throw new JSONException('Tool calls field was not a List');
            }
        } catch (Exception e) {
            throw new PayloadFormattingException('Corrupted AssistantToolCalls JSON detected for message ' + assistantMsgId);
        }
    }

    /** Parses and validates the binding's InputSchema__c JSON */
    private static Map<String, Object> parseAndValidateInputSchemaJson(String schemaJson, String capabilityDevName, String debugPrefix) {
        try {
            Object parsedSchemaObj = JSON.deserializeUntyped(schemaJson);
            if (!(parsedSchemaObj instanceof Map<String, Object>)) {
                throw new LlmPayloadException('InputSchema for ' + capabilityDevName + ' must be a JSON Object.');
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

    /** Adds a single message map to the payload list */
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
            throw new PayloadFormattingException('Message role cannot be blank. Context: ' + logContext);
        }

        String lowerCaseRole = role.toLowerCase().trim();
        Map<String, Object> messageMap = new Map<String, Object>{ 'role' => lowerCaseRole };
        Boolean addedData = false;

        Set<String> standardRoles = new Set<String>{ 'system', 'user', 'assistant', 'tool' };
        if (!standardRoles.contains(lowerCaseRole)) {
        }

        if (content != null) {
            messageMap.put('content', content);
            addedData = true;
        }

        if (toolCalls != null && !toolCalls.isEmpty()) {
            if (lowerCaseRole != AIAgentConstants.ROLE_ASSISTANT) {
            }
            messageMap.put('tool_calls', toolCalls);
            addedData = true;
        }

        if (String.isNotBlank(toolCallId)) {
            if (lowerCaseRole != AIAgentConstants.ROLE_TOOL) {
            }
            messageMap.put('tool_call_id', toolCallId);
            addedData = true;
        }

        if (addedData || (content == null && toolCalls == null && String.isBlank(toolCallId))) {
            payloadList.add(messageMap);
        } else {
        }
    }

    /**
     * Helper to add the user_confirmation_prompt parameter to an existing schema map.
     * Returns the modified map or null on critical error.
     */
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

    /**
     * @description Safely extracts the value of the 'confirmation_message' parameter from action arguments JSON.
     * @param argumentsJson The JSON string of arguments returned by the LLM for a tool call.
     * @param capabilityDevName The capability name for logging context.
     * @param logPrefix Logging prefix.
     * @return String The extracted confirmation message, or null if not found, invalid JSON, or parameter missing/blank.
     */
    public static String extractConfirmationMessage(String argumentsJson, String capabilityDevName, String logPrefix) {
        if (String.isBlank(argumentsJson)) {
            return null;
        }

        try {
            Object parsedArgsObj = JSON.deserializeUntyped(argumentsJson);
            if (!(parsedArgsObj instanceof Map<String, Object>)) {
                return null;
            }
            Map<String, Object> argsMap = (Map<String, Object>) parsedArgsObj;

            Object confirmationObj = argsMap.get(CONFIRMATION_PARAM_NAME);
            if (confirmationObj instanceof String && String.isNotBlank((String) confirmationObj)) {
                return (String) confirmationObj;
            } else {
                return null;
            }
        } catch (Exception e) {
            return null;
        }
    }
}
