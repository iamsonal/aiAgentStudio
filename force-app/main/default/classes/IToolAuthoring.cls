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

/**
 * Optional for an ITool class: describes the tool's settings and builds its
 * input schema from them, so the admin fills in only the settings. A tool
 * whose class implements this has a blank Input Schema. Core calls describe
 * on each run and applies the admin's edits (inputOverrides) on top, so
 * picklist, field, and Flow changes reach the model without a save.
 *
 * Runs on every run, save, and preview, as whoever is running, and must
 * stay query-only. Return inputSchema, or put what the admin must fix in
 * problem. Never throw.
 */
global interface IToolAuthoring {
    AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration);
}
