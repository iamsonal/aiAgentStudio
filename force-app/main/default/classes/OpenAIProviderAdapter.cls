/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * OpenAIProviderAdapter is a robust integration layer for the OpenAI Chat Completions API, implementing the ILLMProviderAdapter interface.
 * It manages HTTP request construction, retry logic, and response parsing, including support for function calling (tool calls),
 * token usage tracking, and structured error handling. The adapter is designed for resilience and maintainability, providing
 * detailed debug output and clear exception signaling for all failure modes. Its scope is limited to the OpenAI chat completions
 * endpoint, but it is architected for easy extension to future OpenAI API features or additional LLM providers.
 */
public class OpenAIProviderAdapter implements ILLMProviderAdapter {
    private static final String LOG_PREFIX = '[OpenAIAdapter] ';

    /**
     * Exception thrown when OpenAI response parsing fails due to malformed JSON or missing required fields.
     * Used to distinguish parsing errors from transport or configuration failures.
     */
    public class OpenAIParseException extends LLMProviderException {
    }

    /**
     * Sends a chat completion request to the OpenAI API with automatic retry handling.
     *
     * Builds the HTTP request, applies retry logic, and parses the response into a ProviderResult. Handles all error conditions
     * with clear debug output and exception signaling. Supports function calling (tool calls) and token usage tracking.
     *
     * @param messagesPayload Pre-formatted conversation history as OpenAI message objects (required)
     * @param toolsPayload    Pre-formatted tool definitions for function calling (optional)
     * @param llmConfig       Configuration record containing API endpoint, model, and retry settings (required)
     * @param agentConfig     Agent definition record (currently unused but required by interface)
     * @return                ProviderResult containing response content, token usage, and any tool call requests
     * @throws LLMProviderException If API call fails after all retries or response parsing fails
     *
     * Side effects: Emits debug logs for request execution, response parsing, and error conditions.
     */
    public ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    ) {
        // Build the HTTP request for OpenAI chat completions.
        HttpRequest request = buildHttpRequest(llmConfig, messagesPayload, toolsPayload, agentConfig);
        // Create retry configuration based on LLM config.
        HttpRetryService.RetryConfig retryConfig = HttpRetryService.createRetryConfig(llmConfig, LOG_PREFIX);
        try {
            // Execute HTTP request with retry logic.
            HttpRetryService.HttpRetryResult result = HttpRetryService.executeWithRetry(request, retryConfig);
            System.debug(
                LoggingLevel.INFO,
                LOG_PREFIX +
                    'OpenAI API call succeeded after ' +
                    result.attemptsMade +
                    ' attempt(s), total duration: ' +
                    result.totalDurationMs +
                    ' ms.'
            );
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'OpenAI response body: ' + result.response.getBody());
            // Parse and return the successful response.
            return parseOpenAIResponse(result.response.getBody());
        } catch (OpenAIParseException pex) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to parse OpenAI response: ' + pex.getMessage());
            throw new LLMProviderException('Failed to parse OpenAI response: ' + pex.getMessage(), pex);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Unexpected error during OpenAI API call: ' + e.getMessage());
            throw new LLMProviderException('Unexpected internal error: ' + e.getMessage(), e);
        }
    }

    /**
     * Constructs an HTTP request for the OpenAI Chat Completions API.
     *
     * Assembles the endpoint, headers, and JSON body, including model, messages, temperature, and tool definitions as needed.
     *
     * @param llmConfig      Configuration containing endpoint, model, and temperature settings (required)
     * @param openAIMessages Conversation history formatted as OpenAI message objects (required)
     * @param openAITools    Tool definitions for function calling (optional, null if no tools available)
     * @return               Configured HttpRequest with proper headers, endpoint, and JSON payload
     *
     * Side effects: Emits debug logs for tool configuration and payload size.
     */
    @TestVisible
    private HttpRequest buildHttpRequest(
        LLMConfiguration__c llmConfig,
        List<Map<String, Object>> openAIMessages,
        List<Map<String, Object>> openAITools,
        AIAgentDefinition__c agentConfig
    ) {
        HttpRequest req = new HttpRequest();
        String endpoint = 'callout:' + llmConfig.NamedCredential__c + '/v1/chat/completions';
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');

        Map<String, Object> body = new Map<String, Object>{ 'model' => llmConfig.DefaultModelIdentifier__c, 'messages' => openAIMessages };

        if (llmConfig.DefaultTemperature__c != null) {
            body.put('temperature', llmConfig.DefaultTemperature__c);
        }

        if (openAITools != null && !openAITools.isEmpty()) {
            body.put('tools', openAITools);
            body.put('tool_choice', 'auto'); // Let OpenAI decide when to use tools
            Boolean allowParallel = (agentConfig != null && agentConfig.EnableParallelToolCalling__c == true);
            body.put('parallel_tool_calls', allowParallel);
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Parallel tool calling enabled: ' + allowParallel);
        }
        req.setBody(JSON.serialize(body));
        req.setTimeout(120000); // 2 minute timeout for API calls
        System.debug(LoggingLevel.DEBUG, req.getBody());
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'HTTP request prepared. Payload size: ' + req.getBody().length() + ' characters.');
        return req;
    }

    /**
     * Parses the OpenAI Chat Completions API response into a standardized ProviderResult.
     *
     * Extracts message content, token usage, and tool call information. Handles all error conditions with clear debug output
     * and throws OpenAIParseException for malformed or incomplete responses.
     *
     * @param jsonBody Raw JSON response string from OpenAI API (required)
     * @return         ProviderResult containing parsed content, token usage, and tool calls
     * @throws OpenAIParseException If JSON is malformed or required response fields are missing
     *
     * Side effects: Emits debug logs for token usage, tool call extraction, and error conditions.
     */
    @TestVisible
    private ProviderResult parseOpenAIResponse(String jsonBody) {
        if (String.isBlank(jsonBody)) {
            throw new OpenAIParseException('Cannot parse blank response body.');
        }

        String content = null;
        Integer promptTokens = null;
        Integer completionTokens = null;
        Integer totalTokens = null;
        List<Map<String, String>> parsedActions = new List<Map<String, String>>();
        String rawToolCallsListJson = null;
        String rawAssistantMessageWithActionsJson = null;

        try {
            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(jsonBody);

            // Parse token usage information (log and continue if usage block is missing)
            if (responseMap.get('usage') instanceof Map<String, Object>) {
                Map<String, Object> usage = (Map<String, Object>) responseMap.get('usage');
                promptTokens = safeGetInteger(usage.get('prompt_tokens'), 'prompt_tokens');
                completionTokens = safeGetInteger(usage.get('completion_tokens'), 'completion_tokens');
                totalTokens = safeGetInteger(usage.get('total_tokens'), 'total_tokens');
                System.debug(
                    LoggingLevel.DEBUG,
                    LOG_PREFIX + 'Token usage parsed: prompt=' + promptTokens + ', completion=' + completionTokens + ', total=' + totalTokens
                );
            } else {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Token usage block missing in OpenAI response. Token counts unavailable.');
            }

            // Parse response choices and extract message content and tool calls.
            if (responseMap.get('choices') instanceof List<Object>) {
                List<Object> choices = (List<Object>) responseMap.get('choices');
                if (!choices.isEmpty() && choices[0] instanceof Map<String, Object>) {
                    Map<String, Object> choice = (Map<String, Object>) choices[0];
                    if (choice.get('message') instanceof Map<String, Object>) {
                        Map<String, Object> message = (Map<String, Object>) choice.get('message');
                        rawAssistantMessageWithActionsJson = JSON.serialize(message); // Store for history
                        if (message.get('content') instanceof String) {
                            content = (String) message.get('content');
                        }
                        if (message.get('tool_calls') instanceof List<Object>) {
                            List<Object> rawToolCallsList = (List<Object>) message.get('tool_calls');
                            if (!rawToolCallsList.isEmpty()) {
                                rawToolCallsListJson = JSON.serialize(rawToolCallsList);
                                parsedActions = parseStructuredToolCalls(rawToolCallsList);
                                System.debug(
                                    LoggingLevel.DEBUG,
                                    LOG_PREFIX + 'Parsed ' + parsedActions.size() + ' function call(s) from OpenAI response.'
                                );
                            }
                        }
                    } else {
                        throw new OpenAIParseException('OpenAI response choice missing required "message" object.');
                    }
                } else {
                    System.debug(LoggingLevel.WARN, LOG_PREFIX + 'OpenAI response contains empty or invalid choices array.');
                }
            } else {
                throw new OpenAIParseException('OpenAI response missing required "choices" list.');
            }
        } catch (JSONException jex) {
            throw new OpenAIParseException('Failed to parse OpenAI JSON response body: ' + jex.getMessage(), jex);
        } catch (Exception e) {
            if (e instanceof OpenAIParseException) {
                throw e;
            }
            throw new OpenAIParseException('Unexpected error during OpenAI response parsing: ' + e.getMessage(), e);
        }

        return new ProviderResult(
            content,
            promptTokens,
            completionTokens,
            totalTokens,
            parsedActions,
            rawToolCallsListJson,
            rawAssistantMessageWithActionsJson
        );
    }

    /**
     * Converts the OpenAI tool_calls array into a structured format for ProviderResult.
     *
     * Extracts tool call ID, function name, and arguments JSON string for each function call.
     *
     * @param rawToolCallsList Raw tool_calls array from OpenAI response (required)
     * @return                 List of maps containing tool call id, function name, and arguments JSON string
     *
     * Side effects: Emits debug logs for malformed or skipped tool calls.
     */
    @TestVisible
    private List<Map<String, String>> parseStructuredToolCalls(List<Object> rawToolCallsList) {
        List<Map<String, String>> actions = new List<Map<String, String>>();
        for (Object callObj : rawToolCallsList) {
            if (callObj instanceof Map<String, Object>) {
                Map<String, Object> callMap = (Map<String, Object>) callObj;
                if ('function'.equalsIgnoreCase(String.valueOf(callMap.get('type'))) && callMap.get('function') instanceof Map<String, Object>) {
                    String toolCallId = String.valueOf(callMap.get('id'));
                    Map<String, Object> funcMap = (Map<String, Object>) callMap.get('function');
                    String funcName = String.valueOf(funcMap.get('name'));
                    Object argsObj = funcMap.get('arguments'); // Arguments should be a JSON *string*
                    String argsJson = (argsObj instanceof String) ? (String) argsObj : null;
                    if (String.isNotBlank(toolCallId) && String.isNotBlank(funcName) && argsJson != null) {
                        actions.add(new Map<String, String>{ 'id' => toolCallId, 'name' => funcName, 'arguments' => argsJson });
                    } else {
                        System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Malformed tool call skipped: missing id, name, or arguments.');
                    }
                } else {
                    System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Non-function tool call skipped: type=' + callMap.get('type'));
                }
            } else {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Invalid tool call format encountered in OpenAI response.');
            }
        }
        return actions;
    }

    /**
     * Safely converts an Object to Integer, handling both Integer and Decimal types.
     *
     * Used for extracting token usage fields from JSON responses. Logs a warning if conversion fails.
     *
     * @param val       Object value to convert (typically from JSON deserialization)
     * @param fieldName Field name for error logging
     * @return          Integer value or null if conversion fails
     *
     * Side effects: Emits debug logs if conversion fails.
     */
    @TestVisible
    private static Integer safeGetInteger(Object val, String fieldName) {
        if (val == null) {
            return null;
        }
        try {
            if (val instanceof Integer) {
                return (Integer) val;
            }
            if (val instanceof Decimal) {
                return ((Decimal) val).intValue();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Failed to convert field "' + fieldName + '" to Integer: ' + e.getMessage());
        }
        return null;
    }
}
