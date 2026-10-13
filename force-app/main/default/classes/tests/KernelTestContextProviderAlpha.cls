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

@IsTest
public with sharing class KernelTestContextProviderAlpha implements IContextProvider {
    public static AgentKernelModels.ContextRequest lastRequest;

    public AgentKernelModels.ContextResponse provide(AgentKernelModels.ContextRequest request) {
        lastRequest = request;
        AgentKernelModels.ContextResponse response = new AgentKernelModels.ContextResponse();
        response.sourceName = 'Alpha';
        response.content = 'AAAA';
        return response;
    }
}
