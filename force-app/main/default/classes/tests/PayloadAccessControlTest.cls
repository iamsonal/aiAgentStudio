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

@IsTest(SeeAllData=false)
private class PayloadAccessControlTest {
    private static final String OPERATOR_ALIAS = 'v2oper';
    private static final String SENSITIVE_ALIAS = 'v2sens';
    private static final String ADMIN_ALIAS = 'v2admin';

    @TestSetup
    static void createUsersAndAssignments() {
        Profile standardProfile = [
            SELECT Id
            FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator'
            LIMIT 1
        ];
        String unique = String.valueOf(System.now().getTime());
        List<User> users = new List<User>{
            user(standardProfile.Id, OPERATOR_ALIAS, unique + 'operator'),
            user(standardProfile.Id, SENSITIVE_ALIAS, unique + 'sensitive'),
            user(standardProfile.Id, ADMIN_ALIAS, unique + 'admin')
        };
        insert users;
        Map<String, Id> permissionSetIds = new Map<String, Id>();
        for (PermissionSet permissionSet : [
            SELECT Id, Name
            FROM PermissionSet
            WHERE Name IN ('AgentKernelOperator', 'AgentKernelSensitiveData', 'AgentKernelAdmin')
        ]) {
            permissionSetIds.put(permissionSet.Name, permissionSet.Id);
        }
        System.assertEquals(3, permissionSetIds.size());
        insert new List<PermissionSetAssignment>{
            assignment(users[0].Id, permissionSetIds.get('AgentKernelOperator')),
            assignment(users[1].Id, permissionSetIds.get('AgentKernelOperator')),
            assignment(users[1].Id, permissionSetIds.get('AgentKernelSensitiveData')),
            assignment(users[2].Id, permissionSetIds.get('AgentKernelAdmin'))
        };
    }

    @IsTest
    static void operatorCanTraceWithoutRawFieldAccess() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"password":"operator-must-not-see"}');
        recordInvocation(started, definition, '{"password":"operator-must-not-see"}');
        User operator = [SELECT Id FROM User WHERE Alias = :OPERATOR_ALIAS LIMIT 1];
        shareRun(started.runId, new Set<Id>{ operator.Id });

        System.runAs(operator) {
            AgentKernelModels.RunRecord run = AgentRunService.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.status);
            System.assertEquals(null, run.input);
            AgentKernelModels.EventPage eventPage = AgentTraceService.getEventPage(eventRequest(started.runId));
            System.assertEquals(2, eventPage.events.size());
            System.assertEquals(null, eventPage.events[1].payload);
            System.assertNotEquals(null, eventPage.events[1].payloadHash);
            AgentKernelModels.CommandPage commandPage = AgentTraceService.getCommandPage(commandRequest(started.runId));
            System.assertEquals(1, commandPage.commands.size());
            System.assertEquals(null, commandPage.commands[0].input);
            AgentKernelModels.InvocationPage invocationPage = AgentTraceService.getInvocationPage(invocationRequest(started.runId));
            System.assertEquals(1, invocationPage.invocations.size());
            System.assertEquals(null, invocationPage.invocations[0].request);
            System.assertNotEquals(null, invocationPage.invocations[0].requestHash);
        }
    }

    @IsTest
    static void sensitiveAssignmentAloneExposesAuthorizedPayloadFields() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"safe":"authorized"}');
        recordInvocation(started, definition, '{"safe":"authorized"}');
        User sensitive = [
            SELECT Id
            FROM User
            WHERE Alias = :SENSITIVE_ALIAS
            LIMIT 1
        ];
        User adminUser = [SELECT Id FROM User WHERE Alias = :ADMIN_ALIAS LIMIT 1];
        shareRun(started.runId, new Set<Id>{ sensitive.Id, adminUser.Id });

        System.runAs(sensitive) {
            AgentKernelModels.RunRecord run = AgentRunService.getRun(started.runId);
            System.assert(run.input.contains('authorized'));
            System.assert(AgentTraceService.getEventPage(eventRequest(started.runId)).events[1].payload.contains('authorized'));
            System.assert(AgentTraceService.getCommandPage(commandRequest(started.runId)).commands[0].input.contains('authorized'));
            System.assert(AgentTraceService.getInvocationPage(invocationRequest(started.runId)).invocations[0].request.contains('authorized'));
        }
        System.runAs(adminUser) {
            AgentKernelModels.RunRecord run = AgentRunService.getRun(started.runId);
            System.assertEquals(null, run.input);
            System.assertEquals(null, AgentTraceService.getEventPage(eventRequest(started.runId)).events[1].payload);
            System.assertEquals(null, AgentTraceService.getCommandPage(commandRequest(started.runId)).commands[0].output);
            System.assertEquals(null, AgentTraceService.getInvocationPage(invocationRequest(started.runId)).invocations[0].response);
        }
    }

    private static AgentKernelModels.EventPageRequest eventRequest(Id runId) {
        AgentKernelModels.EventPageRequest request = new AgentKernelModels.EventPageRequest();
        request.runId = runId;
        return request;
    }

    private static AgentKernelModels.CommandPageRequest commandRequest(Id runId) {
        AgentKernelModels.CommandPageRequest request = new AgentKernelModels.CommandPageRequest();
        request.runId = runId;
        return request;
    }

    private static AgentKernelModels.InvocationPageRequest invocationRequest(Id runId) {
        AgentKernelModels.InvocationPageRequest request = new AgentKernelModels.InvocationPageRequest();
        request.runId = runId;
        return request;
    }

    private static User user(Id profileId, String alias, String uniqueName) {
        return new User(
            Alias = alias,
            Email = uniqueName + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profileId,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = uniqueName + '@example.com'
        );
    }

    private static void recordInvocation(AgentKernelModels.StartResult started, AgentDefinition__c definition, String requestJson) {
        InvocationEvidenceService.Capture capture = new InvocationEvidenceService.Capture();
        capture.runId = started.runId;
        capture.commandId = started.commandId;
        capture.commandRevision = started.revision;
        capture.attemptNumber = 1;
        capture.invocationType = 'Model';
        capture.outcome = 'Succeeded';
        capture.operationKey = started.operationKey;
        capture.startedAt = System.now();
        capture.requestJson = requestJson;
        capture.responseJson = '{"result":"authorized"}';

        InvocationEvidenceService.record(capture);
    }

    private static void shareRun(Id runId, Set<Id> userIds) {
        List<AgentRun__Share> shares = new List<AgentRun__Share>();
        for (Id userId : userIds) {
            shares.add(new AgentRun__Share(ParentId = runId, UserOrGroupId = userId, AccessLevel = 'Read', RowCause = Schema.AgentRun__Share.RowCause.Manual));
        }
        insert shares;
    }

    private static PermissionSetAssignment assignment(Id userId, Id permissionSetId) {
        return new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSetId);
    }
}
