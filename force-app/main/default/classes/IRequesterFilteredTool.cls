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
 * Marks an ITool whose text output and error messages contain only data the
 * person an attended run works for may read: it filters record data with
 * ToolSecurity.requesterReadable, or writes none (for example, only IDs it
 * just created). Data from an outside system qualifies only when anyone may
 * see it, because the system answers for its own credential, not for the
 * person. On attended runs
 * Core withholds the text of any other tool from the model. Record sets are
 * always filtered by Core.
 */
global interface IRequesterFilteredTool {
}
