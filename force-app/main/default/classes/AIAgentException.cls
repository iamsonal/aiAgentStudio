/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Base exception for all errors in the AI Agent Framework. Consolidates framework exceptions with nested exception types.
 */
public virtual inherited sharing class AIAgentException extends Exception {
    public class OrchestrationException extends AIAgentException {
    }

    public virtual class ProviderException extends AIAgentException {
    }

    public class NonRetriableHttpException extends ProviderException {
    }
}
