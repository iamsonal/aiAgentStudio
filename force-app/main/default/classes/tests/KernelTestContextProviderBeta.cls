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
public with sharing class KernelTestContextProviderBeta implements IContextProvider {
    public static String content = 'BBBBBBBB';
    public static Map<String, List<SObject>> recordSets;

    public AgentKernelModels.ContextResponse provide(AgentKernelModels.ContextRequest request) {
        AgentKernelModels.ContextResponse response = new AgentKernelModels.ContextResponse();
        response.sourceName = 'Beta';
        if (recordSets != null) {
            response.recordSets = recordSets;
        } else {
            response.content = content;
        }
        return response;
    }
}
