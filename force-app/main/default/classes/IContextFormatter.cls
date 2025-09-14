/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * IContextFormatter defines the contract for formatting SObject data into structured text formats
 * optimized for LLM (Large Language Model) consumption. Implementations should support multiple
 * formatting strategies while ensuring consistent, readable data presentation for AI context injection.
 */
public interface IContextFormatter {
    /**
     * Main entry point for formatting SObject data into structured context for LLMs.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param logPrefix       Logging prefix for debug messages.
     * @return                Formatted context string ready for LLM consumption.
     */
    String formatContext(List<SObject> records, String logPrefix);
}
