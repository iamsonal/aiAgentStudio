/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contract for custom context providers that supply relevant data to AI agents. Enforces security boundaries and bulk-safe query patterns.
 */
public interface IAgentContextProvider {
    Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson);
}
