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

/** KernelTestTool that declares its text is filtered for the requester. */
@IsTest
public with sharing class KernelTestFilteredTool implements ITool, IRequesterFilteredTool {
    private final KernelTestTool delegate = new KernelTestTool();

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        return delegate.validateConfiguration(configuration);
    }

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        return delegate.execute(request);
    }
}
