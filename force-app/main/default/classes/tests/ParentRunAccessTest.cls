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
private class ParentRunAccessTest {
    /** A person's run limits each run started from it, even when automation, such as a platform-event flow, starts the next one. */
    @IsTest
    static void backgroundChildKeepsTheParentPersonLimit() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult parent = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AttendedAccessService.attendedForTest = false;
        Test.setMock(HttpCalloutMock.class, new AcceptedLoopback());

        Test.startTest();
        List<AgentStartRunAction.StartResult> results = AgentStartRunAction.start(
            new List<AgentStartRunAction.StartRequest>{ flowRequest(definition, parent.runId) }
        );
        Test.stopTest();

        System.assertEquals(true, results[0].started, 'Start failed: ' + results[0].errorMessage);
        AgentRun__c child = [SELECT ParentRun__c, AttendedBy__c FROM AgentRun__c WHERE Id = :results[0].runId WITH SYSTEM_MODE];
        System.assertEquals(parent.runId, child.ParentRun__c);
        System.assertEquals(UserInfo.getUserId(), child.AttendedBy__c, 'The child must keep the parent person limit.');
    }

    @IsTest
    static void anotherPersonCannotStartARunFromTheParent() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult parent = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        User other = AgentKernelTestFactory.userWith(new List<String>{ AgentKernelTestFactory.ADMIN });

        AgentKernelModels.StartRequest request = AgentKernelTestFactory.startRequest(definition, 'next step');
        request.parentRunId = parent.runId;
        System.runAs(other) {
            try {
                AgentRunService.startWithoutDispatch(request, AgentKernelModels.INVOCATION_APEX);
                System.assert(false, 'Another person must not continue a run limited to someone else.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('Only that person'), expected.getMessage());
            }
        }
    }

    /** A parent run by automation adds no limit, so the child follows its own start. */
    @IsTest
    static void automationParentAddsNoLimit() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AttendedAccessService.attendedForTest = false;
        AgentKernelModels.StartResult parent = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentKernelModels.StartRequest request = AgentKernelTestFactory.startRequest(definition, 'next step');
        request.parentRunId = parent.runId;
        AgentKernelModels.StartResult background = AgentRunService.startWithoutDispatch(request, AgentKernelModels.INVOCATION_APEX);
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult attended = AgentRunService.startWithoutDispatch(request, AgentKernelModels.INVOCATION_APEX);

        Map<Id, AgentRun__c> runs = new Map<Id, AgentRun__c>(
            [SELECT Id, AttendedBy__c FROM AgentRun__c WHERE Id IN :new Set<Id>{ background.runId, attended.runId } WITH SYSTEM_MODE]
        );
        System.assertEquals(null, runs.get(background.runId).AttendedBy__c);
        System.assertEquals(UserInfo.getUserId(), runs.get(attended.runId).AttendedBy__c);
    }

    private static AgentStartRunAction.StartRequest flowRequest(AgentDefinition__c definition, Id parentRunId) {
        AgentStartRunAction.StartRequest request = new AgentStartRunAction.StartRequest();
        request.agentDeveloperName = definition.DeveloperName__c;
        request.input = 'next step';
        request.parentRunId = parentRunId;
        return request;
    }

    private class AcceptedLoopback implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(202);
            response.setBody('{}');
            return response;
        }
    }
}
