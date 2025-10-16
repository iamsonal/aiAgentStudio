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
     * NonRetriableHttpException is thrown for HTTP failures that indicate a fundamental problem with the API request.
     * Examples include:
     *   - 400 Bad Request (malformed request)
     *   - 401 Unauthorized (authentication failure)
     *   - 403 Forbidden (insufficient permissions)
     *   - 404 Not Found (invalid endpoint)
     *   - 429 Too Many Requests (rate limiting)
     *   - 500 Internal Server Error (server issues)
     *   - Network timeouts and connection failures
     *
     * This exception signals a problem with the API request or external service that requires attention.
     */
    public class NonRetriableHttpException extends LLMProviderException {
    }

}
