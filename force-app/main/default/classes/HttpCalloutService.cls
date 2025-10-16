/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * HttpCalloutService is a simple HTTP client utility for Apex that provides:
 *   - Single-attempt HTTP callout execution (fail-fast approach)
 *   - Centralized, observable HTTP callout execution for LLM provider and external API integrations
 *   - Detailed debug logging and result metadata for troubleshooting
 *
 * This service is designed for use in AI agent and LLM provider integrations, but is general-purpose.
 */
public class HttpCalloutService {

    /**
     * Configuration object for HTTP callout execution.
     *
     * Defines logging preferences for HTTP callouts.
     */
    public class CalloutConfig {
        public String logPrefix = '[HttpCalloutService] ';

        public CalloutConfig() {
        }
        public CalloutConfig withLogPrefix(String logPrefix) {
            this.logPrefix = logPrefix;
            return this;
        }
    }

    /**
     * Result object containing HTTP response and execution metadata.
     *
     * Provides success status and timing information for analysis and troubleshooting.
     */
    public class CalloutResult {
        public HttpResponse response { get; private set; }
        public Boolean isSuccess { get; private set; }
        public Long durationMs { get; private set; }
        public CalloutResult(HttpResponse response, Boolean isSuccess, Long durationMs) {
            this.response = response;
            this.isSuccess = isSuccess;
            this.durationMs = durationMs;
        }
    }

    /**
     * Executes a single HTTP request and fails fast on any error.
     *
     * This method performs ONE attempt only and throws exceptions for any HTTP errors.
     *
     * @param request  The HttpRequest to execute.
     * @param config   The callout configuration (must not be null).
     * @return CalloutResult  The response and execution metadata.
     * @throws LLMProviderException.NonRetriableHttpException for any HTTP error
     */
    public static CalloutResult execute(HttpRequest request, CalloutConfig config) {
        if (config == null) {
            throw new IllegalArgumentException('CalloutConfig cannot be null');
        }

        System.debug(LoggingLevel.DEBUG, config.logPrefix + 'Executing HTTP callout');

        Long startTime = System.currentTimeMillis();

        try {
            Http http = new Http();
            System.debug(LoggingLevel.INFO, config.logPrefix + 'Executing HTTP request');
            HttpResponse response = http.send(request);
            Long duration = System.currentTimeMillis() - startTime;

            System.debug(
                LoggingLevel.DEBUG,
                config.logPrefix +
                    'HTTP response: status=' +
                    response.getStatusCode() +
                    ', duration=' +
                    duration +
                    'ms'
            );

            // Success response (2xx)
            if (response.getStatusCode() >= 200 && response.getStatusCode() < 300) {
                return new CalloutResult(response, true, duration);
            }

            // Error response - throw exception for any HTTP error
            String errorMsg =
                'HTTP error: status=' +
                response.getStatusCode() +
                ' (' +
                response.getStatus() +
                ')';

            System.debug(LoggingLevel.ERROR, config.logPrefix + errorMsg + ' - throwing NonRetriableHttpException');
            throw new LLMProviderException.NonRetriableHttpException(errorMsg);

        } catch (System.CalloutException ce) {
            System.debug(LoggingLevel.ERROR, config.logPrefix + 'Callout exception: ' + ce.getMessage());
            throw new LLMProviderException.NonRetriableHttpException('Callout failed: ' + ce.getMessage(), ce);

        } catch (LLMProviderException llmEx) {
            // Re-throw LLMProviderException subtypes
            throw llmEx;

        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                config.logPrefix + 'Unexpected exception during HTTP execution: ' + e.getMessage()
            );
            // Unexpected exceptions are non-retryable
            throw new LLMProviderException.NonRetriableHttpException('Unexpected HTTP error: ' + e.getMessage(), e);
        }
    }


    /**
     * Creates a CalloutConfig for HTTP callouts.
     *
     * @param logPrefix  Optional log prefix for this specific usage.
     * @return CalloutConfig  The callout configuration.
     */
    public static CalloutConfig createConfig(String logPrefix) {
        CalloutConfig config = new CalloutConfig();
        if (String.isNotBlank(logPrefix)) {
            config.logPrefix = logPrefix;
        }
        return config;
    }
}
