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
 * Administrator-selected, query-only decision for each call of a tool whose
 * Approval is Decided by Policy. Core never asks it about other tools. It may
 * allow the call, deny it, or require approval from a queue or user it names.
 */
global interface IToolAuthorizationPolicy {
    AgentKernelModels.ToolAuthorizationResponse evaluate(AgentKernelModels.ToolAuthorizationRequest request);
}
