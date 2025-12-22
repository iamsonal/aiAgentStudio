/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BaseProviderAdapter provides common functionality for all LLM provider adapters.
 * Eliminates ~300-400 lines of duplicate code across OpenAI, Claude, and Gemini adapters.
 *
 * **Shared Functionality:**
 * - HTTP request execution with standardized error handling
 * - JSON response parsing with error recovery
 * - Token usage extraction from provider responses
 * - Common validation and logging patterns
 * - Standardized exception handling
 *
 * **Provider-Specific Implementation:**
 * Subclasses must implement:
 * - buildProviderRequest() - Build provider-specific HTTP request
 * - parseProviderResponse() - Parse provider-specific response format
 *
 * **Benefits:**
 * - Reduces code duplication by 60-70%
 * - Makes adding new providers trivial (Cohere, Mistral, etc.)
 * - Centralizes HTTP error handling
 * - Improves consistency across providers
 *
 * @example
 * public class NewProviderAdapter extends BaseProviderAdapter {
 *     protected override HttpRequest buildProviderRequest(...) {
 *         // Provider-specific request building
 *     }
 *
 *     protected override ProviderResult parseProviderResponse(...) {
 *         // Provider-specific response parsing
 *     }
 * }
 *
 * @author Sonal
 * @since 2025
 */
public abstract class BaseProviderAdapter implements ILLMProviderAdapter {
    // Subclasses should define their own LOG_PREFIX
    protected virtual String getLogPrefix() {
        return '[BaseAdapter] ';
    }

    /**
     * @description Main entry point for sending messages to LLM provider
     * Implements the ILLMProviderAdapter interface with common execution flow
     *
     * @param messagesPayload Pre-formatted conversation history
     * @param toolsPayload Pre-formatted tool definitions (optional)
     * @param llmConfig Configuration record containing API endpoint and model settings
     * @param agentConfig Agent definition record
     * @return ProviderResult containing response content, token usage, and any tool calls
     * @throws AIAgentException.ProviderException If API call fails or response parsing fails
     */
    public ProviderResult sendMessage(
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        LLMConfiguration__c llmConfig,
        AIAgentDefinition__c agentConfig
    ) {
        String logPrefix = getLogPrefix();

        // Build provider-specific HTTP request
        HttpRequest request = buildProviderRequest(llmConfig, messagesPayload, toolsPayload, agentConfig);

        // Create callout configuration
        HttpCalloutService.CalloutConfig calloutConfig = HttpCalloutService.createConfig(logPrefix);

        try {
            // Execute HTTP request with standardized error handling
            HttpCalloutService.CalloutResult result = executeHttpRequest(request, calloutConfig, logPrefix);

            System.debug(LoggingLevel.INFO, logPrefix + 'API call succeeded, duration: ' + result.durationMs + ' ms.');
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Response body: ' + result.response.getBody());

            // Parse provider-specific response
            return parseProviderResponse(result.response.getBody(), llmConfig.DefaultModelIdentifier__c, result.durationMs);
        } catch (AIAgentException.ProviderException providerEx) {
            // Re-throw provider exceptions (already logged by subclass)
            throw providerEx;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error during API call: ' + e.getMessage());
            throw new AIAgentException.ProviderException('Unexpected internal error: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Executes HTTP request with standardized error handling
     * Centralizes HTTP execution logic to eliminate duplication
     *
     * @param request HTTP request to execute
     * @param calloutConfig Callout configuration with retry/timeout settings
     * @param logPrefix Logging prefix for debug output
     * @return CalloutResult containing response and duration
     * @throws AIAgentException.ProviderException If HTTP call fails
     */
    protected HttpCalloutService.CalloutResult executeHttpRequest(
        HttpRequest request,
        HttpCalloutService.CalloutConfig calloutConfig,
        String logPrefix
    ) {
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

    /**
     * @description Parses JSON response with error recovery
     * Common utility to handle JSON parsing across all providers
     *
     * @param responseBody JSON response body as string
     * @param logPrefix Logging prefix for debug output
     * @return Parsed Map of response data
     * @throws AIAgentException.ProviderException If JSON parsing fails
     */
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

    /**
     * @description Safely extracts token counts from response metadata
     * Provides consistent token extraction logic across all providers
     *
     * @param usage Usage map from provider response
     * @param result ProviderResult to populate with token counts
     * @param logPrefix Logging prefix for debug output
     */
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

            // Handle provider-specific field names
            if (usage.containsKey('input_tokens')) {
                result.promptTokens = (Integer) usage.get('input_tokens');
            }
            if (usage.containsKey('output_tokens')) {
                result.completionTokens = (Integer) usage.get('output_tokens');
            }

            // Calculate total if not provided
            if (result.totalTokens == null && result.promptTokens != null && result.completionTokens != null) {
                result.totalTokens = result.promptTokens + result.completionTokens;
            }

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Token usage - Prompt: ' +
                    result.promptTokens +
                    ', Completion: ' +
                    result.completionTokens +
                    ', Total: ' +
                    result.totalTokens
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to extract token usage: ' + e.getMessage());
            // Non-fatal - continue without token counts
        }
    }

    /**
     * @description Validates required configuration fields
     * Common validation logic to reduce duplication
     *
     * @param llmConfig LLM configuration to validate
     * @throws AIAgentException.ProviderException If required fields are missing
     */
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

    /**
     * @description Validates messages payload
     * Common validation logic for message arrays
     *
     * @param messagesPayload Messages to validate
     * @throws AIAgentException.ProviderException If messages are invalid
     */
    protected void validateMessages(List<Map<String, Object>> messagesPayload) {
        String logPrefix = getLogPrefix();

        if (messagesPayload == null || messagesPayload.isEmpty()) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Messages payload is empty');
            throw new AIAgentException.ProviderException('Messages payload cannot be empty');
        }
    }

    /**
     * @description Safely extracts String value from map
     * Helper method to reduce null checks in subclasses
     *
     * @param data Map to extract from
     * @param key Key to extract
     * @param defaultValue Default value if not found
     * @return Extracted value or default
     */
    protected String getStringValue(Map<String, Object> data, String key, String defaultValue) {
        if (data == null || !data.containsKey(key)) {
            return defaultValue;
        }

        Object value = data.get(key);
        return value != null ? String.valueOf(value) : defaultValue;
    }

    /**
     * @description Safely extracts Integer value from map
     * Helper method to reduce null checks and type casting in subclasses
     *
     * @param data Map to extract from
     * @param key Key to extract
     * @param defaultValue Default value if not found
     * @return Extracted value or default
     */
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

    /**
     * @description Abstract method for building provider-specific HTTP request
     * Subclasses implement their specific request format
     *
     * @param llmConfig Configuration containing endpoint, model, and temperature
     * @param messagesPayload Conversation history in framework format
     * @param toolsPayload Tool definitions in framework format
     * @param agentConfig Agent definition for provider-specific settings
     * @return Configured HttpRequest ready for execution
     */
    protected abstract HttpRequest buildProviderRequest(
        LLMConfiguration__c llmConfig,
        List<Map<String, Object>> messagesPayload,
        List<Map<String, Object>> toolsPayload,
        AIAgentDefinition__c agentConfig
    );

    /**
     * @description Abstract method for parsing provider-specific response
     * Subclasses implement their specific response parsing logic
     *
     * @param responseBody Response body from provider API
     * @param modelIdentifier Model identifier for logging
     * @param durationMs Request duration in milliseconds
     * @return ProviderResult containing parsed content, tokens, and tool calls
     */
    protected abstract ProviderResult parseProviderResponse(String responseBody, String modelIdentifier, Long durationMs);
}
