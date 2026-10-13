/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/** Failure types for Core lifecycle operations and extensions. */
global virtual inherited sharing class AgentKernelException extends Exception {
    global class ConfigurationException extends AgentKernelException {
    }

    global class ConcurrencyException extends AgentKernelException {
    }

    global class InvalidTransitionException extends AgentKernelException {
    }

    global class NotFoundException extends AgentKernelException {
    }

    global class AuthorizationException extends AgentKernelException {
    }

    global class RetryableException extends AgentKernelException {
    }

    global class PermanentException extends AgentKernelException {
    }

    global class OutcomeUnknownException extends AgentKernelException {
    }

    global class CorrelationConflictException extends AgentKernelException {
    }

    global class QueueCapacityException extends AgentKernelException {
    }

    /** Bounded, payload-free lifecycle persistence failure. */
    public class PersistenceException extends AgentKernelException {
        /** The platform status code of the failed write, such as DUPLICATE_VALUE; null when unknown. */
        public String statusCode;
    }
}
