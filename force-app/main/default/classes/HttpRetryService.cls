/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * HttpRetryService is a robust, configurable HTTP client utility for Apex that provides:
 *   - Intelligent retry logic with exponential backoff and jitter for transient network failures
 *   - Configurable retry strategies for handling rate limiting, service unavailability, and provider-specific errors
 *   - Centralized, observable HTTP callout execution for LLM provider and external API integrations
 *   - Detailed debug logging and result metadata for troubleshooting and performance analysis
 *
 * This service is designed for use in AI agent and LLM provider integrations, but is general-purpose and can be reused
 * for any Apex code requiring resilient HTTP callouts with retry and backoff policies.
 */
public class HttpRetryService {
    private static final Double DEFAULT_BACKOFF_FACTOR = 2.0;
    private static final Double JITTER_FACTOR = 0.3;
    private static final Integer MAX_DELAY_MS = 30000;

    /**
     * Configuration object for customizing retry behavior and policies.
     *
     * Defines retry limits, delays, retryable HTTP status codes, and logging preferences.
     * Use this to control how HttpRetryService handles retries for a given callout.
     */
    public class RetryConfig {
        public Integer maxAttempts = 0;
        public Integer initialDelayMs = 1000;
        public Set<Integer> retryableStatusCodes = new Set<Integer>();
        public String logPrefix = '[HttpRetryService] ';

        public RetryConfig() {
        }
        public RetryConfig(Integer maxAttempts, Integer initialDelayMs, Set<Integer> retryableStatusCodes) {
            this.maxAttempts = maxAttempts;
            this.initialDelayMs = initialDelayMs;
            this.retryableStatusCodes = retryableStatusCodes;
        }
        public RetryConfig withLogPrefix(String logPrefix) {
            this.logPrefix = logPrefix;
            return this;
        }
    }

    /**
     * Result object containing HTTP response and execution metadata.
     *
     * Provides success status, attempt count, and timing information for analysis and troubleshooting.
     */
    public class HttpRetryResult {
        public HttpResponse response { get; private set; }
        public Boolean isSuccess { get; private set; }
        public Integer attemptsMade { get; private set; }
        public Long totalDurationMs { get; private set; }
        public HttpRetryResult(HttpResponse response, Boolean isSuccess, Integer attemptsMade, Long totalDurationMs) {
            this.response = response;
            this.isSuccess = isSuccess;
            this.attemptsMade = attemptsMade;
            this.totalDurationMs = totalDurationMs;
        }
    }

    /**
     * Executes an HTTP request with retry logic and exponential backoff.
     *
     * - Retries on configured HTTP status codes and network exceptions, up to maxAttempts.
     * - Applies exponential backoff with jitter between retries.
     * - Logs all attempts and errors for observability.
     *
     * @param request  The HttpRequest to execute.
     * @param config   The retry configuration (must not be null).
     * @return HttpRetryResult  The response and execution metadata.
     * @throws LLMProviderException if the call fails after all retries or encounters a non-retryable error.
     */
    public static HttpRetryResult executeWithRetry(HttpRequest request, RetryConfig config) {
        if (config == null) {
            throw new IllegalArgumentException('RetryConfig cannot be null');
        }
        System.debug(
            LoggingLevel.DEBUG,
            config.logPrefix +
                'Retry configuration: maxAttempts=' +
                config.maxAttempts +
                ', initialDelayMs=' +
                config.initialDelayMs +
                ', retryableStatusCodes=' +
                JSON.serialize(config.retryableStatusCodes)
        );
        HttpResponse response = null;
        Exception lastException = null;
        Integer attempt = 0;
        Long totalStartTime = System.currentTimeMillis();
        while (attempt <= config.maxAttempts) {
            Long calloutStartTime = System.currentTimeMillis();
            lastException = null;
            try {
                Http http = new Http();
                System.debug(LoggingLevel.INFO, config.logPrefix + 'HTTP request attempt ' + (attempt + 1) + ' of ' + (config.maxAttempts + 1));
                response = http.send(request);
                Long callDuration = System.currentTimeMillis() - calloutStartTime;
                System.debug(
                    LoggingLevel.DEBUG,
                    config.logPrefix +
                        'HTTP response: status=' +
                        response.getStatusCode() +
                        ', duration=' +
                        callDuration +
                        'ms, attempt=' +
                        (attempt + 1)
                );
                if (response.getStatusCode() >= 200 && response.getStatusCode() < 300) {
                    Long totalDuration = System.currentTimeMillis() - totalStartTime;
                    return new HttpRetryResult(response, true, attempt + 1, totalDuration);
                } else {
                    // Check retryability
                    if (isRetryable(null, response, config.retryableStatusCodes) && attempt < config.maxAttempts) {
                        handleRetryDelay(attempt, config);
                        attempt++;
                        continue;
                    } else {
                        String errorMsg =
                            'HTTP error after ' +
                            (attempt + 1) +
                            ' attempts: status=' +
                            response.getStatusCode() +
                            ' (' +
                            response.getStatus() +
                            ')';
                        System.debug(LoggingLevel.ERROR, config.logPrefix + errorMsg);
                        throw new LLMProviderException(errorMsg);
                    }
                }
            } catch (System.CalloutException ce) {
                lastException = ce;
                System.debug(LoggingLevel.WARN, config.logPrefix + 'Callout exception on attempt ' + (attempt + 1) + ': ' + ce.getMessage());
                if (isRetryable(ce, null, config.retryableStatusCodes) && attempt < config.maxAttempts) {
                    handleRetryDelay(attempt, config);
                    attempt++;
                    continue;
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        config.logPrefix + 'Non-retryable callout exception or max retries exceeded (attempt=' + (attempt + 1) + ')'
                    );
                    throw new LLMProviderException('Callout failed: ' + ce.getMessage(), ce);
                }
            } catch (Exception e) {
                lastException = e;
                System.debug(
                    LoggingLevel.ERROR,
                    config.logPrefix + 'Unexpected exception during HTTP execution (attempt=' + (attempt + 1) + '): ' + e.getMessage()
                );
                // Assume non-retryable for unexpected exceptions
                throw new LLMProviderException('Unexpected HTTP error: ' + e.getMessage(), e);
            }
        }
        // Final error handling after all retries exhausted
        String finalError = config.logPrefix + 'HTTP request failed after all retry attempts.';
        if (lastException != null) {
            finalError += ' Last error: ' + lastException.getMessage();
        } else if (response != null) {
            finalError += ' Last HTTP status: ' + response.getStatusCode() + ' (' + response.getStatus() + ')';
        }
        System.debug(LoggingLevel.ERROR, finalError);
        throw new LLMProviderException(finalError, lastException);
    }

    /**
     * Determines if an error condition warrants a retry.
     *
     * @param ex                    The exception caught (null if checking HttpResponse).
     * @param res                   The HttpResponse received (null if CalloutException occurred).
     * @param retryableStatusCodes  Set of integer HTTP status codes configured for retry.
     * @return Boolean              True if the condition is transient and retryable, false otherwise.
     */
    @TestVisible
    private static Boolean isRetryable(Exception ex, HttpResponse res, Set<Integer> retryableStatusCodes) {
        if (ex instanceof System.CalloutException) {
            // Retry network-related exceptions (timeouts, connection failures, etc.)
            System.debug(LoggingLevel.DEBUG, '[HttpRetryService] CalloutException detected - retrying');
            return true;
        }
        if (res != null && retryableStatusCodes != null) {
            Boolean isCodeRetryable = retryableStatusCodes.contains(res.getStatusCode());
            System.debug(LoggingLevel.DEBUG, '[HttpRetryService] HTTP status ' + res.getStatusCode() + ' retryable=' + isCodeRetryable);
            return isCodeRetryable;
        }
        System.debug(LoggingLevel.DEBUG, '[HttpRetryService] Condition is not retryable');
        return false;
    }

    /**
     * Calculates and applies the delay before the next retry attempt.
     *
     * Uses exponential backoff with jitter. Busy-waits due to Apex limitations (CPU-intensive).
     *
     * @param currentAttempt  The attempt number that just failed (0-indexed).
     * @param config          The retry configuration.
     * @sideeffect Consumes CPU cycles during delay; keep delays reasonable to avoid governor limits.
     */
    @TestVisible
    private static void handleRetryDelay(Integer currentAttempt, RetryConfig config) {
        // Calculate base delay: initial * (factor ^ attempt)
        Decimal backoffFactor = DEFAULT_BACKOFF_FACTOR;
        Decimal baseDelay = config.initialDelayMs * (backoffFactor.pow(currentAttempt + 1)); // Increase delay for *next* attempt
        // Calculate jitter: +/- jitterFactor % of initialDelay
        Decimal jitter = Math.random() * config.initialDelayMs * JITTER_FACTOR * 2 - (config.initialDelayMs * JITTER_FACTOR);
        // Total delay = base + jitter, capped
        Integer delayMs = Integer.valueOf(baseDelay + jitter);
        delayMs = Math.max(0, delayMs); // Ensure non-negative
        delayMs = Math.min(delayMs, MAX_DELAY_MS); // Apply max cap
        System.debug(
            LoggingLevel.INFO,
            config.logPrefix +
                'Retry delay: attempt=' +
                (currentAttempt + 1) +
                ', delayMs=' +
                delayMs +
                ' (base=' +
                baseDelay.intValue() +
                'ms, jitter=' +
                jitter.intValue() +
                'ms)'
        );
        // Implement delay using busy wait (CPU-intensive but necessary in Apex)
        // WARNING: Consumes CPU cycles - keep delays reasonable to avoid governor limits
        Long waitUntil = System.currentTimeMillis() + delayMs;
        while (System.currentTimeMillis() < waitUntil) {
            // Busy wait loop - performs mathematical operations to consume CPU cycles
            Decimal x = Math.sqrt(Math.random());
        }
    }

    /**
     * Creates a RetryConfig from an LLMConfiguration__c record, falling back to framework defaults as needed.
     *
     * @param llmConfig  The LLMConfiguration__c record.
     * @param logPrefix  Optional log prefix for this specific usage.
     * @return RetryConfig  The resolved retry configuration.
     */
    public static RetryConfig createRetryConfig(LLMConfiguration__c llmConfig, String logPrefix) {
        RetryConfig config = new RetryConfig();
        // Use AIAgentFrameworkSettings getters which handle the defaulting logic
        config.maxAttempts = (llmConfig.MaxRetryAttempts__c != null &&
            llmConfig.MaxRetryAttempts__c >= 0)
            ? Integer.valueOf(llmConfig.MaxRetryAttempts__c)
            : AIAgentFrameworkSettings.getDefaultMaxRetryAttempts();
        config.initialDelayMs = (llmConfig.InitialRetryDelayMillis__c != null &&
            llmConfig.InitialRetryDelayMillis__c > 0)
            ? Integer.valueOf(llmConfig.InitialRetryDelayMillis__c)
            : AIAgentFrameworkSettings.getDefaultInitialRetryDelayMillis();
        config.retryableStatusCodes = String.isNotBlank(llmConfig.RetryableHttpStatusCodes__c)
            ? AIAgentFrameworkSettings.parseRetryableCodes(llmConfig.RetryableHttpStatusCodes__c)
            : AIAgentFrameworkSettings.getDefaultRetryableStatusCodes();
        if (String.isNotBlank(logPrefix)) {
            config.logPrefix = logPrefix;
        }
        return config;
    }
}
