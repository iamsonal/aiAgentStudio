/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Utility class providing common functionality for LLM API payload construction and validation.
 * Standardizes message formatting, role validation, and payload structure for LLM API requests.
 */
public inherited sharing class LlmPayloadUtils {
    public virtual class LlmPayloadException extends AIAgentException {
    }

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
                (debugPrefix ?? '[LlmPayloadUtils]') + 'Message role is blank. Skipping message. Context: ' + logContext
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
                (debugPrefix ?? '[LlmPayloadUtils]') + 'Non-standard message role: ' + lowerCaseRole + '. Context: ' + logContext
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
                    (debugPrefix ?? '[LlmPayloadUtils]') +
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
                    (debugPrefix ?? '[LlmPayloadUtils]') +
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
                (debugPrefix ?? '[LlmPayloadUtils]') + 'Skipping empty or incomplete message for role: ' + role + '. Context: ' + logContext
            );
        }
    }
}
