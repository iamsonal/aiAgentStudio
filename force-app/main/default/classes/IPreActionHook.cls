/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface for custom Apex classes that execute before a main IAgentAction.
 *              It operates on the raw, deserialized argument map from the LLM, allowing for
 *              validation, transformation, or enrichment before the main action parses it.
 *
 * @security Implementers are responsible for writing secure code within the hook.
 *           The hook runs in the user's context, and all data access must be secure.
 */
public interface IPreActionHook {
    /**
     * @description Processes the raw argument map before it is passed to the main action's
     *              internal `parseAndValidateArguments` method.
     * @param originalArgumentsMap The raw, deserialized Map<String, Object> from the LLM's request.
     * @param context The shared ActionContext providing Session, User, Agent, and other IDs.
     * @return Map<String, Object> The (potentially modified) argument map to be used by the main action.
     * @throws BaseAgentAction.ValidationException To halt execution with a controlled validation error.
     * @throws BaseAgentAction.ActionSecurityException To halt execution with a controlled security error.
     */
    Map<String, Object> preProcess(Map<String, Object> originalArgumentsMap, ActionContext context);
}
