/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface for custom Apex classes that execute after a main IAgentAction completes.
 *              Ideal for "fire and forget" tasks like logging, auditing, or notifications.
 *
 * @security Implementers are responsible for writing secure code within the hook.
 *           Any DML or callouts should be performed asynchronously (@future, Queueable).
 */
public interface IPostActionHook {
    /**
     * @description Executes logic after the main action has produced a result. This method
     *              should not throw exceptions, as it could mask the original action result.
     *              Log any errors internally.
     * @param result The final ActionResult from the main action's execution (can be success or failure).
     * @param context The shared ActionContext providing Session, User, Agent, and other IDs.
     */
    void postProcess(ActionResult result, ActionContext context);
}
