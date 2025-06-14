/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Utility service for HTTP requests with retry logic and exponential backoff.
 *              Provides reusable retry functionality for any HTTP-based provider adapter.
 */
public class HttpRetryService {
    private static final Double DEFAULT_BACKOFF_FACTOR = 2.0;
    private static final Double JITTER_FACTOR = 0.3;
    private static final Integer MAX_DELAY_MS = 30000;

    /**
     * @description Configuration for retry behavior.
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
     * @description Result of HTTP execution with retry logic.
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
     * @description Executes HTTP request with retry logic and exponential backoff.
     * @param request The HttpRequest to execute.
     * @param config The retry configuration.
     * @return HttpRetryResult containing the response and execution metadata.
     * @throws LLMProviderException If the call fails after all retries or encounters a non-retryable error.
     */
    public static HttpRetryResult executeWithRetry(HttpRequest request, RetryConfig config) {
        if (config == null) {
            throw new IllegalArgumentException('RetryConfig cannot be null');
        }

        HttpResponse response = null;
        Exception lastException = null;
        Integer attempt = 0;
        Long totalStartTime = System.currentTimeMillis();

        while (attempt <= config.maxAttempts) {
            Long calloutStartTime = System.currentTimeMillis();
            lastException = null;

            try {
                Http http = new Http();

                response = http.send(request);
                Long callDuration = System.currentTimeMillis() - calloutStartTime;

                if (response.getStatusCode() >= 200 && response.getStatusCode() < 300) {
                    Long totalDuration = System.currentTimeMillis() - totalStartTime;
                    return new HttpRetryResult(response, true, attempt + 1, totalDuration);
                } else {
                    if (isRetryable(null, response, config.retryableStatusCodes) && attempt < config.maxAttempts) {
                        handleRetryDelay(attempt, config);
                        attempt++;
                        continue;
                    } else {
                        String errorMsg =
                            'HTTP Error after ' +
                            (attempt + 1) +
                            ' attempts. Status: ' +
                            response.getStatusCode() +
                            ' - ' +
                            response.getStatus();

                        throw new LLMProviderException(errorMsg);
                    }
                }
            } catch (System.CalloutException ce) {
                lastException = ce;

                if (isRetryable(ce, null, config.retryableStatusCodes) && attempt < config.maxAttempts) {
                    handleRetryDelay(attempt, config);
                    attempt++;
                    continue;
                } else {
                    throw new LLMProviderException('Callout failed: ' + ce.getMessage(), ce);
                }
            } catch (Exception e) {
                lastException = e;

                throw new LLMProviderException('Unexpected HTTP error: ' + e.getMessage(), e);
            }
        }

        String finalError = config.logPrefix + 'HTTP call failed after exhausting all retries.';
        if (lastException != null) {
            finalError += ' Last Error: ' + lastException.getMessage();
        } else if (response != null) {
            finalError += ' Last HTTP Status: ' + response.getStatusCode() + ' - ' + response.getStatus();
        }

        throw new LLMProviderException(finalError, lastException);
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
     */
    @TestVisible
    private static void handleRetryDelay(Integer currentAttempt, RetryConfig config) {
        Decimal backoffFactor = DEFAULT_BACKOFF_FACTOR;
        Decimal baseDelay = config.initialDelayMs * (backoffFactor.pow(currentAttempt + 1));

        Decimal jitter = Math.random() * config.initialDelayMs * JITTER_FACTOR * 2 - (config.initialDelayMs * JITTER_FACTOR);

        Integer delayMs = Integer.valueOf(baseDelay + jitter);
        delayMs = Math.max(0, delayMs);
        delayMs = Math.min(delayMs, MAX_DELAY_MS);

        Long waitUntil = System.currentTimeMillis() + delayMs;
        while (System.currentTimeMillis() < waitUntil) {
            Decimal x = Math.sqrt(Math.random());
        }
    }

    /**
     * @description Creates a RetryConfig from LLMConfiguration__c, falling back to framework defaults.
     * @param llmConfig The LLMConfiguration__c record.
     * @param logPrefix Optional log prefix for this specific usage.
     * @return A RetryConfig object containing the resolved settings.
     */
    public static RetryConfig createRetryConfig(LLMConfiguration__c llmConfig, String logPrefix) {
        RetryConfig config = new RetryConfig();

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
