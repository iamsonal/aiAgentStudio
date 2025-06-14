/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Factory for creating an ILLMResponseHandler instance based on the LLM's response.
 */
public class ResponseHandlerFactory {
    /**
     * @description Selects the appropriate handler for the given LLM interaction result.
     * @param llmResult The result from the LLMInteractionService.
     * @return An ILLMResponseHandler implementation.
     */
    public static ILLMResponseHandler getHandler(LLMInteractionService.LLMInteractionResult llmResult) {
        if (llmResult.providerResult?.requestedActions != null && !llmResult.providerResult.requestedActions.isEmpty()) {
            return new ToolCallResponseHandler();
        } else {
            return new ContentResponseHandler();
        }
    }
}
