/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Factory for creating an IMemoryManager instance based on the
 *              memory strategy defined in the AIAgentDefinition__c.
 */
public class MemoryManagerFactory {
    /**
     * @description Selects and instantiates the appropriate memory manager.
     * @param strategyName The API name of the memory strategy from the picklist
     *        (e.g., 'Buffer Window', 'Summary Buffer').
     * @return An IMemoryManager implementation. Defaults to BufferWindowMemoryManager if
     *         the strategy is unknown.
     */
    public static IMemoryManager getManager(String strategyName) {
        if ('Summary Buffer'.equalsIgnoreCase(strategyName)) {
            return new SummaryBufferMemoryManager();
        }

        return new BufferWindowMemoryManager();
    }
}
