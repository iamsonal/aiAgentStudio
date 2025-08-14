/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * MemoryManagerFactory is a factory for creating IMemoryManager instances based on the
 * memory strategy defined in the AIAgentDefinition__c.
 *
 * Responsibilities:
 *   - Selects and instantiates the appropriate memory manager implementation for a given strategy
 *   - Supports extensibility for new memory strategies (e.g., buffer window, summary buffer, hybrid)
 *   - Provides a single entry point for memory manager selection throughout the agent framework
 *
 * This factory ensures that memory management is pluggable, maintainable, and consistent across all agent sessions.
 */
public class MemoryManagerFactory {
    /**
     * Selects and instantiates the appropriate memory manager implementation for the given strategy.
     *
     * - Returns a SummaryBufferMemoryManager for 'Summary Buffer' strategy
     * - Defaults to BufferWindowMemoryManager for all other or unknown strategies
     * - Logs the selected strategy and implementation for traceability
     *
     * @param strategyName  The API name of the memory strategy from the picklist (e.g., 'Buffer Window', 'Summary Buffer').
     * @return IMemoryManager  The selected memory manager implementation.
     */
    public static IMemoryManager getManager(String strategyName) {
        if ('Summary Buffer'.equalsIgnoreCase(strategyName)) {
            System.debug(LoggingLevel.INFO, '[MemoryManagerFactory] Selected strategy: Summary Buffer. Instantiating SummaryBufferMemoryManager.');
            return new SummaryBufferMemoryManager();
        }
        System.debug(
            LoggingLevel.INFO,
            '[MemoryManagerFactory] Selected strategy: ' + (strategyName ?? 'default') + '. Instantiating BufferWindowMemoryManager.'
        );
        return new BufferWindowMemoryManager();
    }
}
