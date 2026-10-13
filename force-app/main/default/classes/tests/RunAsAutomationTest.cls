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
private class RunAsAutomationTest {
    /**
     * Whose access a run gets follows how it started, never what the starter
     * asks for: a person's own request (for example their save firing a
     * record-triggered flow) is limited to that person; background work runs
     * as automation.
     */
    @IsTest
    static void personStartIsAlwaysLimitedToThePerson() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);

        AttendedAccessService.attendedForTest = true;
        Id attended = AgentRunService.startWithoutDispatch(AgentKernelTestFactory.startRequest(definition, 'person'), AgentKernelModels.INVOCATION_FLOW).runId;
        AttendedAccessService.attendedForTest = false;
        Id background = AgentRunService.startWithoutDispatch(AgentKernelTestFactory.startRequest(definition, 'background'), AgentKernelModels.INVOCATION_FLOW)
            .runId;

        Map<Id, AgentRun__c> runs = new Map<Id, AgentRun__c>(
            [SELECT Id, AttendedBy__c FROM AgentRun__c WHERE Id IN :new Set<Id>{ attended, background } WITH SYSTEM_MODE]
        );
        System.assertEquals(UserInfo.getUserId(), runs.get(attended).AttendedBy__c, 'A person\'s start is limited to the person.');
        System.assertEquals(null, runs.get(background).AttendedBy__c, 'Background work keeps the execution user\'s access.');
    }
}
