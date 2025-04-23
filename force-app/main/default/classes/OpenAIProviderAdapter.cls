/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description OpenAI Adapter implementing ILLMProviderAdapter.
 *              Handles sending message history and tool definitions to OpenAI API.
 *              Includes **retry logic with exponential backoff** for transient errors.
 *              Parses text content, tool call requests, and token usage into ProviderResult.
 */
public class OpenAIProviderAdapter implements ILLMProviderAdapter {
    private static final String API_KEY = 'sk-proj-';

    private static final Double DEFAULT_BACKOFF_FACTOR = 2.0;
    private static final Double JITTER_FACTOR = 0.3;
    private static final Integer MAX_DELAY_MS = 30000;
    private static final String LOG_PREFIX = 'OpenAIAdapter: ';

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
        RetryConfig retryConfig = getRetryConfig(llmConfig);

        HttpRequest req = buildHttpRequest(llmConfig, agentConfig, messagesPayload, toolsPayload);

        HttpResponse res = null;
        Exception lastException = null;
        Integer attempt = 0;

        while (attempt <= retryConfig.maxAttempts) {
            Long calloutStartTime = System.currentTimeMillis();
            lastException = null;

            try {
                Http http = new Http();

                res = http.send(req);
                Long calloutDuration = System.currentTimeMillis() - calloutStartTime;

                if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                    return parseOpenAIResponse(res.getBody());
                } else {
                    if (isRetryable(null, res, retryConfig.retryableStatusCodes) && attempt < retryConfig.maxAttempts) {
                        handleRetryDelay(attempt, retryConfig, LOG_PREFIX);
                        attempt++;
                        continue;
                    } else {
                        String errorMsg = getErrorMessageFromResponse(res);

                        throw new LLMProviderException(errorMsg);
                    }
                }
            } catch (System.CalloutException ce) {
                lastException = ce;
                Long calloutFailTime = System.currentTimeMillis();

                if (isRetryable(ce, null, retryConfig.retryableStatusCodes) && attempt < retryConfig.maxAttempts) {
                    handleRetryDelay(attempt, retryConfig, LOG_PREFIX);
                    attempt++;
                    continue;
                } else {
                    throw new LLMProviderException(
                        'Callout failed sending request to OpenAI after ' +
                            (attempt + 1) +
                            ' attempts: ' +
                            ce.getMessage(),
                        ce
                    );
                }
            } catch (Exception e) {
                lastException = e;

                throw new LLMProviderException(
                    'Unexpected internal error during OpenAI call processing: ' + e.getMessage(),
                    e
                );
            }
        }

        if (lastException != null) {
            throw new LLMProviderException(
                'LLM call failed after exhausting all retries. Last Error: ' + lastException.getMessage(),
                lastException
            );
        } else if (res != null) {
            throw new LLMProviderException(
                'LLM call failed after exhausting all retries. Last HTTP Status: ' +
                    res.getStatusCode() +
                    ' - ' +
                    getErrorMessageFromResponse(res)
            );
        } else {
            throw new LLMProviderException('LLM call failed after exhausting all retries. Unknown final state.');
        }
    }

    /**
     * @description Determines if an error condition warrants a retry.
     * @param ex The exception caught (null if checking HttpResponse).
     * @param res The HttpResponse received (null if CalloutException occurred).
     * @param retryableStatusCodes Set of integer HTTP status codes configured for retry.
     * @return True if the condition is transient and retryable, false otherwise.
     */
    @TestVisible
    private static Boolean isRetryable(Exception ex, HttpResponse res, Set<Integer> retryableStatusCodes) {
        if (ex instanceof System.CalloutException) {
            return true;
        }
        if (res != null && retryableStatusCodes != null) {
            Boolean isCodeRetryable = retryableStatusCodes.contains(res.getStatusCode());

            return isCodeRetryable;
        }

        return false;
    }

    /**
     * @description Calculates and applies the delay before the next retry attempt.
     *              Uses exponential backoff with jitter. Uses busy-waiting due to Apex limitations.
     * @param currentAttempt The attempt number that just failed (0-indexed).
     * @param config The retry configuration.
     * @param logPrefix Prefix for logging messages.
     */
    @TestVisible
    private static void handleRetryDelay(Integer currentAttempt, RetryConfig config, String logPrefix) {
        Decimal backoffFactor = DEFAULT_BACKOFF_FACTOR;
        Decimal baseDelay = config.initialDelayMs * (backoffFactor.pow(currentAttempt + 1));

        Decimal jitter =
            Math.random() * config.initialDelayMs * JITTER_FACTOR * 2 - (config.initialDelayMs * JITTER_FACTOR);

        Integer delayMs = Integer.valueOf(baseDelay + jitter);
        delayMs = Math.max(0, delayMs);
        delayMs = Math.min(delayMs, MAX_DELAY_MS);

        Long waitUntil = System.currentTimeMillis() + delayMs;
        while (System.currentTimeMillis() < waitUntil) {
            Decimal x = Math.sqrt(Math.random());
        }
    }

    /**
     * @description Loads retry parameters from LLM Config, falling back to framework defaults.
     * @param llmConfig The LLMConfiguration__c record.
     * @return A RetryConfig object containing the resolved settings.
     */
    private RetryConfig getRetryConfig(LLMConfiguration__c llmConfig) {
        RetryConfig config = new RetryConfig();

        Integer settingsDefaultAttempts = AIAgentFrameworkSettings.getDefaultMaxRetryAttempts();
        if (llmConfig.MaxRetryAttempts__c != null && llmConfig.MaxRetryAttempts__c >= 0) {
            config.maxAttempts = Integer.valueOf(llmConfig.MaxRetryAttempts__c);
        } else {
            config.maxAttempts = settingsDefaultAttempts;
        }

        Integer settingsDefaultDelay = AIAgentFrameworkSettings.getDefaultInitialRetryDelayMillis();
        if (llmConfig.InitialRetryDelayMillis__c != null && llmConfig.InitialRetryDelayMillis__c > 0) {
            config.initialDelayMs = Integer.valueOf(llmConfig.InitialRetryDelayMillis__c);
        } else {
            config.initialDelayMs = settingsDefaultDelay;
        }

        Set<Integer> settingsDefaultCodes = AIAgentFrameworkSettings.getDefaultRetryableStatusCodes();
        if (String.isNotBlank(llmConfig.RetryableHttpStatusCodes__c)) {
            config.retryableStatusCodes = AIAgentFrameworkSettings.parseRetryableCodes(
                llmConfig.RetryableHttpStatusCodes__c
            );

            if (config.retryableStatusCodes.isEmpty() && String.isNotBlank(llmConfig.RetryableHttpStatusCodes__c)) {
            }
        } else {
            config.retryableStatusCodes = settingsDefaultCodes;
        }

        return config;
    }

    /**
     * @description Simple inner class to hold resolved retry configuration.
     */
    @TestVisible
    private class RetryConfig {
        Integer maxAttempts = 0;
        Integer initialDelayMs = 1000;
        Set<Integer> retryableStatusCodes = new Set<Integer>();
    }

    /** Builds HttpRequest including messages and tools */
    private HttpRequest buildHttpRequest(
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig,
        List<Map<String, Object>> openAIMessages,
        List<Map<String, Object>> openAITools
    ) {
        HttpRequest req = new HttpRequest();
        String endpoint = 'callout:' + llmConfig.NamedCredential__c + '/v1/chat/completions';
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');

        req.setHeader('Authorization', 'Bearer ' + API_KEY);

        Map<String, Object> body = new Map<String, Object>{
            'model' => llmConfig.DefaultModelIdentifier__c,
            'messages' => openAIMessages
        };
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
     * Parses the JSON response body from OpenAI Chat Completions API into a ProviderResult.
     * Handles extracting text content, tool call requests (both raw list and full message object),
     * and token usage.
     * @param jsonBody The JSON string response from the OpenAI API.
     * @return ProviderResult containing parsed data.
     * @throws LLMProviderException If the JSON is invalid or critical fields are missing/malformed.
     */
    private ProviderResult parseOpenAIResponse(String jsonBody) {
        if (String.isBlank(jsonBody)) {
            throw new LLMProviderException('Received blank response body from OpenAI.');
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

                if (usage.get('prompt_tokens') instanceof Integer || usage.get('prompt_tokens') instanceof Decimal) {
                    promptTokens = Integer.valueOf(usage.get('prompt_tokens'));
                } else {
                }

                if (
                    usage.get('completion_tokens') instanceof Integer ||
                    usage.get('completion_tokens') instanceof Decimal
                ) {
                    completionTokens = Integer.valueOf(usage.get('completion_tokens'));
                } else {
                }

                if (usage.get('total_tokens') instanceof Integer || usage.get('total_tokens') instanceof Decimal) {
                    totalTokens = Integer.valueOf(usage.get('total_tokens'));
                } else {
                }
            } else {
            }

            if (responseMap.get('choices') instanceof List<Object>) {
                List<Object> choices = (List<Object>) responseMap.get('choices');
                if (!choices.isEmpty() && choices[0] instanceof Map<String, Object>) {
                    Map<String, Object> choice = (Map<String, Object>) choices[0];

                    if (choice.get('message') instanceof Map<String, Object>) {
                        Map<String, Object> message = (Map<String, Object>) choice.get('message');

                        if (message.get('content') instanceof String) {
                            content = (String) message.get('content');
                        } else {
                        }

                        if (message.get('tool_calls') instanceof List<Object>) {
                            List<Object> rawToolCallsList = (List<Object>) message.get('tool_calls');
                            if (!rawToolCallsList.isEmpty()) {
                                rawToolCallsListJson = JSON.serialize(rawToolCallsList);

                                rawAssistantMessageWithActionsJson = JSON.serialize(message);

                                for (Object callObj : rawToolCallsList) {
                                    if (callObj instanceof Map<String, Object>) {
                                        Map<String, Object> callMap = (Map<String, Object>) callObj;

                                        if (
                                            'function'.equalsIgnoreCase(String.valueOf(callMap.get('type'))) &&
                                            callMap.get('function') instanceof Map<String, Object>
                                        ) {
                                            String toolCallId = String.valueOf(callMap.get('id'));
                                            Map<String, Object> funcMap = (Map<String, Object>) callMap.get('function');
                                            String funcName = String.valueOf(funcMap.get('name'));
                                            String argsJson = String.valueOf(funcMap.get('arguments'));

                                            if (
                                                String.isNotBlank(toolCallId) &&
                                                String.isNotBlank(funcName) &&
                                                argsJson != null
                                            ) {
                                                parsedActions.add(
                                                    new Map<String, String>{
                                                        'id' => toolCallId,
                                                        'name' => funcName,
                                                        'arguments' => argsJson
                                                    }
                                                );
                                            } else {
                                            }
                                        } else {
                                        }
                                    } else {
                                    }
                                }
                            } else {
                            }
                        }
                    } else {
                    }
                } else {
                }
            } else {
                throw new LLMProviderException('OpenAI response missing required "choices" list.');
            }
        } catch (Exception e) {
            throw new LLMProviderException('Failed to parse OpenAI JSON response: ' + e.getMessage(), e);
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

    /** Minimal error message parsing */
    private String getErrorMessageFromResponse(HttpResponse res) {
        String defaultMessage = 'OpenAI API Error: ' + res.getStatusCode() + ' ' + res.getStatus();
        try {
            if (String.isNotBlank(res.getBody())) {
                Map<String, Object> errorMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                if (errorMap.get('error') instanceof Map<String, Object>) {
                    Map<String, Object> errorDetails = (Map<String, Object>) errorMap.get('error');
                    String msg = String.valueOf(errorDetails.get('message'));
                    return defaultMessage + '. Details: ' + msg;
                } else {
                    return defaultMessage + '. Raw Body: ' + res.getBody().abbreviate(500);
                }
            }
        } catch (Exception e) {
        }
        return defaultMessage;
    }
}
