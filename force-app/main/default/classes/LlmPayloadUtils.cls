/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Utilities for LLM API payloads. Primarily holds the base exception
 *              and generic helper methods used by more specific formatters.
 */
public inherited sharing class LlmPayloadUtils {
    /** @description General Exception class for this utility - MUST BE VIRTUAL */
    public virtual class LlmPayloadException extends AIAgentException {
    }

    /** Adds a single message map to the payload list - generic helper */
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
            return;
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
}
