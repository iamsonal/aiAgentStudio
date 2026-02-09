/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Base class for LLM provider adapters. Provides common HTTP execution, JSON parsing, and token extraction functionality.
 */
public abstract class BaseProviderAdapter implements ILLMProviderAdapter {
    protected virtual String getLogPrefix() {
        return '[BaseAdapter] ';
    }
    public ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    ) {
        String logPrefix = getLogPrefix();

        HttpRequest request = buildProviderRequest(llmConfig, messagesPayload, toolsPayload, agentConfig);
        HttpCalloutService.CalloutConfig calloutConfig = HttpCalloutService.createConfig(logPrefix);

        try {
            HttpCalloutService.CalloutResult result = executeHttpRequest(request, calloutConfig, logPrefix);

            System.debug(LoggingLevel.INFO, logPrefix + 'API call succeeded, duration: ' + result.durationMs + ' ms.');
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Response body: ' + result.response.getBody());

            return parseProviderResponse(result.response.getBody(), llmConfig.DefaultModelIdentifier__c, result.durationMs);
        } catch (AIAgentException.ProviderException providerEx) {
            throw providerEx;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error during API call: ' + e.getMessage());
            throw new AIAgentException.ProviderException('Unexpected internal error: ' + e.getMessage(), e);
        }
    }

    protected HttpCalloutService.CalloutResult executeHttpRequest(HttpRequest request, HttpCalloutService.CalloutConfig calloutConfig, String logPrefix) {
        try {
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(request, calloutConfig);
            return result;
        } catch (AIAgentException.NonRetriableHttpException httpEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'HTTP callout failed: ' + httpEx.getMessage());
            throw new AIAgentException.ProviderException('HTTP callout failed: ' + httpEx.getMessage(), httpEx);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing HTTP request: ' + e.getMessage());
            throw new AIAgentException.ProviderException('Error executing HTTP request: ' + e.getMessage(), e);
        }
    }

    protected Map<String, Object> parseJsonResponse(String responseBody, String logPrefix) {
        if (String.isBlank(responseBody)) {
            throw new AIAgentException.ProviderException('Response body is empty');
        }

        try {
            Object parsed = JSON.deserializeUntyped(responseBody);

            if (!(parsed instanceof Map<String, Object>)) {
                throw new AIAgentException.ProviderException('Response is not a JSON object');
            }

            return (Map<String, Object>) parsed;
        } catch (JSONException jsonEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'JSON parsing failed: ' + jsonEx.getMessage());
            throw new AIAgentException.ProviderException('Failed to parse JSON response: ' + jsonEx.getMessage(), jsonEx);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error parsing response: ' + e.getMessage());
            throw new AIAgentException.ProviderException('Unexpected error parsing response: ' + e.getMessage(), e);
        }
    }

    protected void extractTokenUsage(Map<String, Object> usage, ProviderResult result, String logPrefix) {
        if (usage == null) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'No usage data in response');
            return;
        }

        try {
            if (usage.containsKey('prompt_tokens')) {
                result.promptTokens = (Integer) usage.get('prompt_tokens');
            }
            if (usage.containsKey('completion_tokens')) {
                result.completionTokens = (Integer) usage.get('completion_tokens');
            }
            if (usage.containsKey('total_tokens')) {
                result.totalTokens = (Integer) usage.get('total_tokens');
            }

            if (usage.containsKey('input_tokens')) {
                result.promptTokens = (Integer) usage.get('input_tokens');
            }
            if (usage.containsKey('output_tokens')) {
                result.completionTokens = (Integer) usage.get('output_tokens');
            }

            if (result.totalTokens == null && result.promptTokens != null && result.completionTokens != null) {
                result.totalTokens = result.promptTokens + result.completionTokens;
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Token usage captured for provider response.');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to extract token usage: ' + e.getMessage());
        }
    }
    protected void validateConfiguration(LLMConfiguration__c llmConfig) {
        String logPrefix = getLogPrefix();

        if (llmConfig == null) {
            throw new AIAgentException.ProviderException('LLM configuration is required');
        }

        if (String.isBlank(llmConfig.NamedCredential__c)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'NamedCredential is missing from LLM configuration');
            throw new AIAgentException.ProviderException('NamedCredential is required in LLM configuration');
        }

        if (String.isBlank(llmConfig.DefaultModelIdentifier__c)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'DefaultModelIdentifier is missing from LLM configuration');
            throw new AIAgentException.ProviderException('DefaultModelIdentifier is required in LLM configuration');
        }
    }

    protected void validateMessages(List<Map<String, Object>> messagesPayload) {
        String logPrefix = getLogPrefix();

        if (messagesPayload == null || messagesPayload.isEmpty()) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Messages payload is empty');
            throw new AIAgentException.ProviderException('Messages payload cannot be empty');
        }
    }

    protected String getStringValue(Map<String, Object> data, String key, String defaultValue) {
        if (data == null || !data.containsKey(key)) {
            return defaultValue;
        }

        Object value = data.get(key);
        return value != null ? String.valueOf(value) : defaultValue;
    }

    protected Integer getIntegerValue(Map<String, Object> data, String key, Integer defaultValue) {
        if (data == null || !data.containsKey(key)) {
            return defaultValue;
        }

        Object value = data.get(key);
        if (value == null) {
            return defaultValue;
        }

        try {
            return (Integer) value;
        } catch (Exception e) {
            return defaultValue;
        }
    }

    protected abstract HttpRequest buildProviderRequest(
        LLMConfiguration__c llmConfig,
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        AIAgentDefinition__c agentConfig
    );

    protected abstract ProviderResult parseProviderResponse(String responseBody, String modelIdentifier, Long durationMs);
}
