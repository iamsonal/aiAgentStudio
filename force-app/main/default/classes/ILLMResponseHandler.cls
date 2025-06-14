/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface for the Strategy pattern. Defines the contract for classes
 *              that handle different types of LLM responses (e.g., content-only, tool calls).
 */
public interface ILLMResponseHandler {
    /**
     * @description Handles the processing of an LLM response.
     * @param context The OrchestrationContext containing all necessary state and services.
     * @return String An outcome constant (e.g., OrchestrationService.OUTCOME_COMPLETED).
     */
    String handle(OrchestrationContext context);
}
