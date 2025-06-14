/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description OpenAI Adapter implementing ILLMProviderAdapter.
 *              Handles sending message history and tool definitions to OpenAI API.
 *              Uses HttpRetryService for resilient HTTP communication with exponential backoff.
 *              Parses text content, tool call requests, and token usage into ProviderResult.
 */
public class OpenAIProviderAdapter implements ILLMProviderAdapter {
    private static final String LOG_PREFIX = '[OpenAIAdapter] ';

    /** @description Exception specifically for errors during OpenAI response parsing */
    public class OpenAIParseException extends LLMProviderException {
    }

    /**
     * @description Sends messages and tool definitions to OpenAI, handling transient errors with retries.
     * @param messagesPayload Pre-formatted list of message history Maps.
     * @param toolsPayload Pre-formatted list of action/tool definition Maps.
     * @param llmConfig The LLMConfiguration__c record containing API details and retry settings.
     * @param agentConfig The AIAgentDefinition__c record.
     * @return ProviderResult containing content, token usage, AND requested actions.
     * @throws LLMProviderException If the call fails after all retries or encounters a non-retryable error.
     */
    public ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    ) {
        HttpRequest request = buildHttpRequest(llmConfig, messagesPayload, toolsPayload);

        HttpRetryService.RetryConfig retryConfig = HttpRetryService.createRetryConfig(llmConfig, LOG_PREFIX);

        try {
            HttpRetryService.HttpRetryResult result = HttpRetryService.executeWithRetry(request, retryConfig);

            return parseOpenAIResponse(result.response.getBody());
        } catch (OpenAIParseException pex) {
            throw new LLMProviderException('Failed to parse OpenAI response: ' + pex.getMessage(), pex);
        } catch (Exception e) {
            throw new LLMProviderException('Unexpected internal error: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Builds HttpRequest including messages and tools for OpenAI API.
     * @param llmConfig The LLM configuration containing endpoint and model details.
     * @param openAIMessages Pre-formatted OpenAI message list.
     * @param openAITools Pre-formatted OpenAI tools list.
     * @return Configured HttpRequest ready for execution.
     */
    @TestVisible
    private HttpRequest buildHttpRequest(
        LLMConfiguration__c llmConfig,
        List<Map<String, Object>> openAIMessages,
        List<Map<String, Object>> openAITools
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
            body.put('tool_choice', 'auto');
            body.put('parallel_tool_calls', false);
        }

        req.setBody(JSON.serialize(body));
        req.setTimeout(120000);

        return req;
    }

    /**
     * @description Parses the successful JSON response body from the OpenAI Chat Completions API
     *              into the standardized ProviderResult DTO.
     * @param jsonBody The JSON string response body.
     * @return ProviderResult Fully populated DTO.
     * @throws OpenAIParseException If JSON is invalid or critical fields are missing/malformed.
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

            if (responseMap.get('usage') instanceof Map<String, Object>) {
                Map<String, Object> usage = (Map<String, Object>) responseMap.get('usage');
                promptTokens = safeGetInteger(usage.get('prompt_tokens'), 'prompt_tokens');
                completionTokens = safeGetInteger(usage.get('completion_tokens'), 'completion_tokens');
                totalTokens = safeGetInteger(usage.get('total_tokens'), 'total_tokens');
            } else {
            }

            if (responseMap.get('choices') instanceof List<Object>) {
                List<Object> choices = (List<Object>) responseMap.get('choices');
                if (!choices.isEmpty() && choices[0] instanceof Map<String, Object>) {
                    Map<String, Object> choice = (Map<String, Object>) choices[0];
                    if (choice.get('message') instanceof Map<String, Object>) {
                        Map<String, Object> message = (Map<String, Object>) choice.get('message');

                        rawAssistantMessageWithActionsJson = JSON.serialize(message);

                        if (message.get('content') instanceof String) {
                            content = (String) message.get('content');
                        }

                        if (message.get('tool_calls') instanceof List<Object>) {
                            List<Object> rawToolCallsList = (List<Object>) message.get('tool_calls');
                            if (!rawToolCallsList.isEmpty()) {
                                rawToolCallsListJson = JSON.serialize(rawToolCallsList);
                                parsedActions = parseStructuredToolCalls(rawToolCallsList);
                            }
                        }
                    } else {
                        throw new OpenAIParseException('OpenAI response choice missing required "message" object.');
                    }
                } else {
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
     * @description Parses the raw 'tool_calls' list from LLM response into the structured map format needed by ProviderResult.
     *              Specific to OpenAI 'function' tool call structure.
     * @param rawToolCallsList The List<Object> from the 'tool_calls' field.
     * @return List<Map<String, String>> where each map has {id, name, arguments}.
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
                    Object argsObj = funcMap.get('arguments');
                    String argsJson = (argsObj instanceof String) ? (String) argsObj : null;

                    if (String.isNotBlank(toolCallId) && String.isNotBlank(funcName) && argsJson != null) {
                        actions.add(new Map<String, String>{ 'id' => toolCallId, 'name' => funcName, 'arguments' => argsJson });
                    } else {
                    }
                } else {
                }
            } else {
            }
        }
        return actions;
    }

    /**
     * @description Safely attempts to get an Integer value from an Object, handling potential Decimal conversion.
     * @param val The object value to convert.
     * @param fieldName The field name for logging purposes.
     * @return Integer value or null if conversion fails.
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
        }
        return null;
    }
}
