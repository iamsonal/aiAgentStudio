/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentException is the abstract base exception for all errors in the AI Agent Framework.
 * Responsibilities:
 *   - Provides a unified foundation for all framework-specific exceptions
 *   - Enables consistent, type-safe error handling and propagation across all framework layers
 *   - Should be extended by all custom exception types within the AI Agent Framework
 *
 * This class is not intended to be instantiated directly.
 */
public virtual class AIAgentException extends Exception {
}
