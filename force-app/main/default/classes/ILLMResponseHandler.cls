/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy pattern interface for processing different types of LLM responses. Enables flexible, pluggable response processing.
 */
public interface ILLMResponseHandler {
    String handle(OrchestrationContext context);
}
