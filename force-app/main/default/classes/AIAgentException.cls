/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentException is the base exception for all errors in the AI Agent Framework.
 *
 * This class consolidates framework exceptions into a single file with nested exception types
 * for better organization and maintainability.
 *
 * Responsibilities:
 *   - Provides a unified foundation for all framework-specific exceptions
 *   - Enables consistent, type-safe error handling and propagation across all framework layers
 *   - Organizes related exception types as nested classes for better discoverability
 *
 * Usage:
 *   throw new AIAgentException.OrchestrationException('Orchestration failed');
 *   throw new AIAgentException.ProviderException('Provider error');
 *   throw new AIAgentException.NonRetriableHttpException('HTTP 500');
 *
 * Catching:
 *   catch (AIAgentException.NonRetriableHttpException e) { ... }
 *   catch (AIAgentException.ProviderException e) { ... }
 *   catch (AIAgentException e) { ... } // Catches all framework exceptions
 */
public virtual class AIAgentException extends Exception {
    /**
     * @description
     * OrchestrationException is thrown when agent orchestration operations fail due to
     * validation errors, configuration issues, or execution problems.
     *
     * Replaces: AgentOrchestratorException
     */
    public class OrchestrationException extends AIAgentException {
    }

    /**
     * @description
     * ProviderException is the standard exception type for errors encountered during
     * communication with Large Language Model (LLM) providers. This includes:
     *   - HTTP communication failures
     *   - API response parsing errors
     *   - Provider-specific or protocol-level issues
     *
     * This exception ensures all LLM provider errors are handled consistently by the
     * agent framework's error handling and logging system.
     *
     * Replaces: LLMProviderException
     */
    public virtual class ProviderException extends AIAgentException {
    }

    /**
     * @description
     * NonRetriableHttpException is thrown for HTTP failures that indicate a fundamental
     * problem with the API request. Examples include:
     *   - 400 Bad Request (malformed request)
     *   - 401 Unauthorized (authentication failure)
     *   - 403 Forbidden (insufficient permissions)
     *   - 404 Not Found (invalid endpoint)
     *   - 429 Too Many Requests (rate limiting)
     *   - 500 Internal Server Error (server issues)
     *   - Network timeouts and connection failures
     *
     * This exception signals a problem with the API request or external service
     * that requires attention.
     *
     * Note: Extends ProviderException to maintain logical hierarchy while respecting
     * Apex's limitation that nested classes cannot have their own nested classes.
     *
     * Replaces: LLMProviderException.NonRetriableHttpException
     */
    public class NonRetriableHttpException extends ProviderException {
    }
}
