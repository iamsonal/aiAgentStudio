/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ILLMResponseHandler defines the strategy pattern interface for processing different types of LLM responses.
 *
 * Responsibilities:
 *   - Enables flexible, pluggable response processing based on LLM output characteristics
 *   - Supports handling of content-only responses, tool/function calls, error conditions, and multi-turn conversations
 *   - Allows orchestration logic to delegate response handling to specialized implementations
 *
 * Implementations must:
 *   - Inspect the orchestration context and LLM output
 *   - Perform any required processing, state updates, or follow-up actions
 *   - Return an outcome constant (e.g., OrchestrationService.OUTCOME_COMPLETED) to guide orchestration flow
 */
public interface ILLMResponseHandler {
    /**
     * Handles the processing of an LLM response for a given orchestration context.
     *
     * @param context  The OrchestrationContext containing all necessary state and services.
     * @return String  An outcome constant (e.g., OrchestrationService.OUTCOME_COMPLETED) to guide orchestration flow.
     *
     * Implementations should:
     *   - Inspect the context and LLM output
     *   - Perform any required processing, state updates, or follow-up actions
     *   - Return the appropriate outcome constant for orchestration
     */
    String handle(OrchestrationContext context);
}
