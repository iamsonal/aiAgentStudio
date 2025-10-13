/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * LLMProviderException is the standard exception type for errors encountered during communication with
 * Large Language Model (LLM) providers. This includes:
 *   - HTTP communication failures
 *   - API response parsing errors
 *   - Provider-specific or protocol-level issues
 *
 * This exception extends AIAgentException to ensure all LLM provider errors are handled consistently
 * by the agent framework's error handling and logging system. Use this exception to signal any
 * unrecoverable or critical error in LLM provider integrations.
 */
public virtual class LLMProviderException extends AIAgentException {
    /**
     * @description
     * NonRetriableHttpException is thrown for immediate HTTP failures that are not eligible for retry.
     * Examples include:
     *   - 400 Bad Request (malformed request)
     *   - 401 Unauthorized (authentication failure)
     *   - 403 Forbidden (insufficient permissions)
     *   - 404 Not Found (invalid endpoint)
     *
     * This exception signals a fundamental problem with the API request itself, not a transient failure.
     * Downstream services can catch this specific exception to distinguish it from retry-exhausted scenarios.
     */
    public class NonRetriableHttpException extends LLMProviderException {
    }

    /**
     * @description
     * RetryExhaustedException is thrown when a retriable error persists after all retry attempts are exhausted.
     * Examples include:
     *   - 429 Too Many Requests (rate limiting that persists)
     *   - 503 Service Unavailable (extended provider outage)
     *   - Network timeouts that continue across all retry attempts
     *
     * This exception signals a prolonged external service disruption, not a flawed API request.
     * Downstream services can catch this specific exception to implement alternative handling strategies
     * such as fallback providers, circuit breakers, or extended retry queues.
     */
    public class RetryExhaustedException extends LLMProviderException {
    }
}
