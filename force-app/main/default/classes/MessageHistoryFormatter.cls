/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * MessageHistoryFormatter is responsible for transforming a sequence of ChatMessage__c records into a message payload
 * structure compatible with LLM (Large Language Model) APIs. It reconstructs conversation history, maps assistant tool calls
 * to their corresponding tool result messages, and validates message sequencing to ensure data consistency. The class is
 * designed to be robust against malformed or inconsistent message histories, providing clear error reporting and debug output
 * to aid in troubleshooting. Its scope is limited to formatting conversation history (not system prompts), and it is intended
 * to be easily extensible for future changes in message schema or LLM API requirements.
 */
public inherited sharing class MessageHistoryFormatter {
    /**
     * Exception thrown for critical errors encountered during message history formatting.
     * Used to signal unrecoverable issues such as data corruption or missing tool result mappings.
     */
    public class MessageHistoryFormattingException extends LlmPayloadUtils.LlmPayloadException {
    }

    /**
     * Formats a list of ChatMessage__c records into the message list format required by LLM APIs.
     *
     * This method processes only the conversation history (not the system prompt). It reconstructs the message sequence,
     * pairs assistant tool calls with their corresponding tool result messages, and validates the integrity of the mapping.
     *
     * @param historySObjectsAsc List of ChatMessage__c records, ordered ascending by time (oldest to newest).
     * @param agentConfig        The agent's configuration record (reserved for future logic; not currently used).
     * @param loggingContext     Optional string prefix for debug log output.
     * @return                   List of message maps, ready for inclusion in the LLM API request body.
     * @throws MessageHistoryFormattingException if a required tool result message is missing or if JSON parsing fails.
     *
     * Side effects: Emits debug logs at key processing steps and on error conditions.
     */
    public static List<Map<String, Object>> formatMessagesForApi(
        List<ChatMessage__c> historySObjectsAsc,
        AIAgentDefinition__c agentConfig,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[MsgHistFormatter] ';
        List<Map<String, Object>> finalPayload = new List<Map<String, Object>>();

        if (historySObjectsAsc == null || historySObjectsAsc.isEmpty()) {
            // No conversation history to format; return empty payload.
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'No conversation history provided. Returning empty payload.');
            return finalPayload;
        }

        // --- Pre-process: Build mappings for assistant tool calls and tool result messages ---
        Set<Id> processedToolMessageIds = new Set<Id>();
        Map<Id, List<String>> assistantToToolCallIdsMap = new Map<Id, List<String>>();
        Map<String, ChatMessage__c> toolCallIdToMessageMap = new Map<String, ChatMessage__c>();
        Set<Id> assistantMsgIdsWithToolCalls = new Set<Id>();

        for (ChatMessage__c msg : historySObjectsAsc) {
            String role = msg.Role__c?.toLowerCase();
            if (role == AIAgentConstants.ROLE_ASSISTANT && String.isNotBlank(msg.AssistantToolCalls__c)) {
                // Parse and record tool call IDs for each assistant message that issues tool calls.
                List<String> requestedIds = parseToolCallIdsFromAssistantJson(msg.AssistantToolCalls__c, msg.Id, debugPrefix);
                if (!requestedIds.isEmpty()) {
                    assistantToToolCallIdsMap.put(msg.Id, requestedIds);
                    assistantMsgIdsWithToolCalls.add(msg.Id);
                }
            } else if (role == AIAgentConstants.ROLE_TOOL && String.isNotBlank(msg.ToolCallId__c)) {
                // Map each tool result message by its ToolCallId for quick lookup.
                if (toolCallIdToMessageMap.containsKey(msg.ToolCallId__c)) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix +
                            'Duplicate ToolCallId detected: ' +
                            msg.ToolCallId__c +
                            '. Overwriting previous mapping with message ID: ' +
                            msg.Id
                    );
                }
                toolCallIdToMessageMap.put(msg.ToolCallId__c, msg);
            }
        }
        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix +
                'Preprocessing complete: ' +
                assistantMsgIdsWithToolCalls.size() +
                ' assistant message(s) with tool calls, ' +
                toolCallIdToMessageMap.size() +
                ' tool result mapping(s) established.'
        );

        // --- Main loop: Build the formatted message payload ---
        for (ChatMessage__c currentMsg : historySObjectsAsc) {
            String role = currentMsg.Role__c.toLowerCase();
            String msgKey = 'Msg ' + currentMsg.Id + ' (' + role + ')';

            // Skip tool messages that have already been included as part of an assistant's tool call turn.
            if (role == AIAgentConstants.ROLE_TOOL && processedToolMessageIds.contains(currentMsg.Id)) {
                continue;
            }
            // Warn and skip any tool message that is not referenced by an assistant tool call (orphaned tool result).
            if (role == AIAgentConstants.ROLE_TOOL && !processedToolMessageIds.contains(currentMsg.Id)) {
                System.debug(
                    LoggingLevel.WARN,
                    debugPrefix +
                        'Orphaned tool message skipped: ' +
                        msgKey +
                        '. No matching assistant tool call found. ToolCallId: ' +
                        currentMsg.ToolCallId__c
                );
                continue;
            }

            // Prepare message content for LLM. (Future: inject additional context if needed.)
            String finalContentForLlm = currentMsg.Content__c;

            // Format and add message to payload based on type and tool call involvement.
            if (
                role == AIAgentConstants.ROLE_USER ||
                (role == AIAgentConstants.ROLE_ASSISTANT && !assistantMsgIdsWithToolCalls.contains(currentMsg.Id))
            ) {
                // User message or assistant message without tool calls: add as a simple message.
                LlmPayloadUtils.addMessageToPayload(finalPayload, role, finalContentForLlm, null, null, debugPrefix, msgKey);
            } else if (role == AIAgentConstants.ROLE_ASSISTANT && assistantMsgIdsWithToolCalls.contains(currentMsg.Id)) {
                // Assistant message with tool calls: add assistant message, then append each corresponding tool result.
                List<Object> parsedToolCallsForPayload = parseToolCallsJsonForPayload(currentMsg.AssistantToolCalls__c, currentMsg.Id, debugPrefix);
                LlmPayloadUtils.addMessageToPayload(
                    finalPayload,
                    AIAgentConstants.ROLE_ASSISTANT,
                    finalContentForLlm, // Content may be null for tool-only responses.
                    parsedToolCallsForPayload,
                    null,
                    debugPrefix,
                    msgKey
                );

                // For each tool call ID, find and append the corresponding tool result message.
                List<String> requestedToolCallIds = assistantToToolCallIdsMap.get(currentMsg.Id);
                if (requestedToolCallIds != null && !requestedToolCallIds.isEmpty()) {
                    for (String toolCallId : requestedToolCallIds) {
                        ChatMessage__c toolResultMessage = toolCallIdToMessageMap.get(toolCallId);
                        if (toolResultMessage != null) {
                            String toolMsgKey = '  Tool Result Msg ' + toolResultMessage.Id + ' (for CallId ' + toolCallId + ')';
                            String finalToolContent = toolResultMessage.Content__c;
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
                            // Fail fast if a referenced tool result is missing: this is a data integrity error.
                            System.debug(
                                LoggingLevel.ERROR,
                                debugPrefix +
                                    'Missing tool result: ToolCallId ' +
                                    toolCallId +
                                    ' referenced by assistant message ' +
                                    currentMsg.Id +
                                    ' not found.'
                            );
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
                // Unhandled or unknown message type: log and skip.
                System.debug(LoggingLevel.WARN, debugPrefix + 'Skipped message with unhandled role or state: ' + msgKey);
            }
        }

        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix + 'Message history formatting complete. Final payload contains ' + finalPayload.size() + ' message(s).'
        );
        return finalPayload;
    }

    /**
     * Parses the AssistantToolCalls__c JSON string to extract tool call IDs.
     *
     * @param toolCallsJson   JSON string representing a list of tool call objects.
     * @param assistantMsgId  The ID of the assistant message for error context.
     * @param debugPrefix     Prefix for debug log output.
     * @return                List of tool call IDs (strings) found in the JSON.
     * @throws MessageHistoryFormattingException if the JSON is malformed or not a list.
     */
    private static List<String> parseToolCallIdsFromAssistantJson(String toolCallsJson, Id assistantMsgId, String debugPrefix) {
        List<String> ids = new List<String>();
        if (String.isBlank(toolCallsJson)) {
            return ids;
        }
        try {
            Object parsed = JSON.deserializeUntyped(toolCallsJson);
            if (!(parsed instanceof List<Object>)) {
                throw new JSONException('Tool calls JSON is not a List');
            }
            for (Object callObj : (List<Object>) parsed) {
                if (callObj instanceof Map<String, Object>) {
                    Map<String, Object> callMap = (Map<String, Object>) callObj;
                    Object idObj = callMap.get('id');
                    if (idObj instanceof String && String.isNotBlank((String) idObj)) {
                        ids.add((String) idObj);
                    } else {
                        System.debug(LoggingLevel.WARN, debugPrefix + 'Tool call object missing valid ID in assistant message ' + assistantMsgId);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                debugPrefix + 'Failed to parse tool call IDs from assistant message ' + assistantMsgId + '. Error: ' + e.getMessage()
            );
            throw new MessageHistoryFormattingException('Could not parse tool call IDs from message ' + assistantMsgId, e);
        }
        return ids;
    }

    /**
     * Parses the AssistantToolCalls__c JSON for inclusion in the next API request payload.
     *
     * @param toolCallsJson   JSON string representing a list of tool call objects.
     * @param assistantMsgId  The ID of the assistant message for error context.
     * @param debugPrefix     Prefix for debug log output.
     * @return                List of tool call objects (as untyped maps) for the payload.
     * @throws MessageHistoryFormattingException if the JSON is malformed or not a list.
     */
    private static List<Object> parseToolCallsJsonForPayload(String toolCallsJson, Id assistantMsgId, String debugPrefix) {
        if (String.isBlank(toolCallsJson)) {
            return new List<Object>();
        }
        try {
            Object parsed = JSON.deserializeUntyped(toolCallsJson);
            if (parsed instanceof List<Object>) {
                return (List<Object>) parsed;
            } else {
                throw new JSONException('Tool calls field was not a List');
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                debugPrefix + 'Failed to parse AssistantToolCalls JSON for message ' + assistantMsgId + '. Error: ' + e.getMessage()
            );
            throw new MessageHistoryFormattingException('Corrupted AssistantToolCalls JSON detected for message ' + assistantMsgId);
        }
    }
}
