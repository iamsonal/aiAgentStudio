/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/** Tool execution extension. */
global interface ITool {
    AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request);

    /**
     * Checks this tool's Implementation Configuration and input schema when
     * the tool is saved and before each run starts, so an admin sees problems
     * at save time. Query-only: no DML, callouts, or async work. Return one
     * clear message per problem, or an empty list.
     */
    List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration);
}
