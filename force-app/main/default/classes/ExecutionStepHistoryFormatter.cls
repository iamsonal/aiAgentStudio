/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ExecutionStepHistoryFormatter provides utilities to format ExecutionStep__c records
 * into the standardized message format required by LLM APIs for conversation history.
 *
 * This class parallels MessageHistoryFormatter but operates on the new unified ExecutionStep__c
 * data model.
 *
 * Responsibilities:
 *   - Converts ExecutionStep__c records to LLM API message format
 *   - Handles different step types (UserInput, AgentResponse, ToolCall, ToolResult)
 *   - Maintains compatibility with existing LLM API expectations
 *   - Provides consistent formatting for memory management strategies
 *
 * This class is not intended for direct use outside the memory management subsystem.
 */
public class ExecutionStepHistoryFormatter {
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
        String debugPrefix = String.isNotBlank(loggingPrefix) ? loggingPrefix : '[ExecutionStepFormatter] ';

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
