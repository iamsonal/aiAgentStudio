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
public inherited sharing class KernelTestInheritedSharingContext implements IContextProvider {
    public static Id hiddenRunId;
    public static Integer constructorRows;
    public static Integer invocationRows;

    public KernelTestInheritedSharingContext() {
        constructorRows = [SELECT COUNT() FROM AgentRun__c WHERE Id = :hiddenRunId];
    }

    public AgentKernelModels.ContextResponse provide(AgentKernelModels.ContextRequest request) {
        invocationRows = [SELECT COUNT() FROM AgentRun__c WHERE Id = :hiddenRunId];
        AgentKernelModels.ContextResponse response = new AgentKernelModels.ContextResponse();
        response.sourceName = 'Sharing';
        response.content = 'visible rows: ' + invocationRows;
        return response;
    }
}
