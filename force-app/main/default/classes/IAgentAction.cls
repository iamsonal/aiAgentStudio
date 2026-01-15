/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contract for all executable AI agent actions. Enforces consistent execution signature and error handling.
 */
public interface IAgentAction {
    ActionOutcome execute(String actionConfigurationJson, String argumentsJson, ActionContext context);
}
