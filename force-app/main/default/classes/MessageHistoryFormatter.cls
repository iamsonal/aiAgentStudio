/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Formats chat history, system prompt, and context into the message list format for LLM APIs.
 */
public inherited sharing class MessageHistoryFormatter {
    /** @description Exception for critical errors during message history formatting */
    public class MessageHistoryFormattingException extends LlmPayloadUtils.LlmPayloadException {
    }

    /**
     * @description Formats a list of ChatMessage__c records into the message list format required by LLM APIs.
     *              This method ONLY handles the conversation history, not the system prompt.
     * @param historySObjectsAsc The list of ChatMessage__c records to format, ordered ascending by time.
     * @param agentConfig The agent's configuration record (needed for potential future logic).
     * @param includeSystemPrompt If true, the system prompt will be added. (DEPRECATED but kept for signature compatibility, logic is now conditional).
     * @param loggingContext A logging prefix string.
     * @return A list of message maps, ready to be included in the LLM API request body.
     */
    public static List<Map<String, Object>> formatMessagesForApi(
        List<ChatMessage__c> historySObjectsAsc,
        AIAgentDefinition__c agentConfig,
        String injectedContextString,
        Boolean includeSystemPrompt,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[MsgHistFormatter] ';
        List<Map<String, Object>> finalPayload = new List<Map<String, Object>>();

        if (historySObjectsAsc == null || historySObjectsAsc.isEmpty()) {
            return finalPayload;
        }

        Set<Id> processedToolMessageIds = new Set<Id>();
        Map<Id, List<String>> assistantToToolCallIdsMap = new Map<Id, List<String>>();
        Map<String, ChatMessage__c> toolCallIdToMessageMap = new Map<String, ChatMessage__c>();
        Set<Id> assistantMsgIdsWithToolCalls = new Set<Id>();

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

        for (ChatMessage__c currentMsg : historySObjectsAsc) {
            String role = currentMsg.Role__c.toLowerCase();
            String msgKey = 'Msg ' + currentMsg.Id + ' (' + role + ')';

            if (role == AIAgentConstants.ROLE_TOOL && processedToolMessageIds.contains(currentMsg.Id)) {
                continue;
            }
            if (role == AIAgentConstants.ROLE_TOOL && !processedToolMessageIds.contains(currentMsg.Id)) {
                continue;
            }

            String finalContentForLlm = currentMsg.Content__c;
            if (
                role == AIAgentConstants.ROLE_TOOL &&
                String.isNotBlank(currentMsg.RecordContextId__c) &&
                String.isNotBlank(currentMsg.RecordContextData__c)
            ) {
                String contextHeader = String.format(
                    '[CONTEXT UPDATE: The last action created or referenced the following record (ID: {0}). This is the new, primary context for your next step.]\n',
                    new List<String>{ currentMsg.RecordContextId__c }
                );
                finalContentForLlm = contextHeader + currentMsg.RecordContextData__c;
            }

            if (
                role == AIAgentConstants.ROLE_USER ||
                (role == AIAgentConstants.ROLE_ASSISTANT && !assistantMsgIdsWithToolCalls.contains(currentMsg.Id))
            ) {
                LlmPayloadUtils.addMessageToPayload(finalPayload, role, finalContentForLlm, null, null, debugPrefix, msgKey);
            } else if (role == AIAgentConstants.ROLE_ASSISTANT && assistantMsgIdsWithToolCalls.contains(currentMsg.Id)) {
                List<Object> parsedToolCallsForPayload = parseToolCallsJsonForPayload(currentMsg.AssistantToolCalls__c, currentMsg.Id, debugPrefix);
                LlmPayloadUtils.addMessageToPayload(
                    finalPayload,
                    AIAgentConstants.ROLE_ASSISTANT,
                    finalContentForLlm,
                    parsedToolCallsForPayload,
                    null,
                    debugPrefix,
                    msgKey
                );

                List<String> requestedToolCallIds = assistantToToolCallIdsMap.get(currentMsg.Id);
                if (requestedToolCallIds != null && !requestedToolCallIds.isEmpty()) {
                    for (String toolCallId : requestedToolCallIds) {
                        ChatMessage__c toolResultMessage = toolCallIdToMessageMap.get(toolCallId);
                        if (toolResultMessage != null) {
                            String toolMsgKey = '  Tool Result Msg ' + toolResultMessage.Id + ' (for CallId ' + toolCallId + ')';

                            String finalToolContent = toolResultMessage.Content__c;
                            if (
                                String.isNotBlank(toolResultMessage.RecordContextId__c) && String.isNotBlank(toolResultMessage.RecordContextData__c)
                            ) {
                                String contextHeader = String.format(
                                    '[CONTEXT UPDATE: Your action created or referenced the following record (ID: {0}). This is now the primary context.]\n',
                                    new List<String>{ toolResultMessage.RecordContextId__c }
                                );
                                finalToolContent = contextHeader + toolResultMessage.RecordContextData__c;
                            }

                            LlmPayloadUtils.addMessageToPayload(
                                finalPayload,
                                AIAgentConstants.ROLE_TOOL,
                                finalToolContent,
                                null,
                                toolCallId,
                                debugPrefix,
                                toolMsgKey
                            );
                            processedToolMessageIds.add(toolResultMessage.Id);
                        } else {
                            throw new MessageHistoryFormattingException(
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

        return finalPayload;
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
            throw new MessageHistoryFormattingException('Could not parse tool call IDs from message ' + assistantMsgId, e);
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
            throw new MessageHistoryFormattingException('Corrupted AssistantToolCalls JSON detected for message ' + assistantMsgId);
        }
    }
}
