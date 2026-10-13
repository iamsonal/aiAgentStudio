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
private class AttendedAccessTest {
    @IsTest
    static void backgroundAndTestRequestsAreNotAttended() {
        System.assertEquals(null, AttendedAccessService.attendedRequester(), 'Apex tests are not a person\'s own request.');
        AttendedAccessService.attendedForTest = true;
        System.assertEquals(UserInfo.getUserId(), AttendedAccessService.attendedRequester());
    }

    @IsTest
    static void attendedDelegatedStartRecordsTheRequester() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentRun__c run = [SELECT AttendedBy__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE];
        System.assertEquals(UserInfo.getUserId(), run.AttendedBy__c);
        System.assertEquals(UserInfo.getUserId(), AgentRunService.getRun(started.runId).attendedById);
        try {
            AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = started.runId, AttendedBy__c = null));
            System.assert(false, 'The person a run works for cannot change.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('immutable'));
        }
    }

    @IsTest
    static void initiatingUserRunsNeedNoRequesterLimit() {
        AttendedAccessService.attendedForTest = true;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        System.assertEquals(null, [SELECT AttendedBy__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE].AttendedBy__c);
    }

    @IsTest
    static void recordsTheRequesterCannotReadNeverReachTheModel() {
        User requester = minimumAccessUser();
        Account hidden = new Account(Name = 'Hidden from requester');
        insert hidden;
        Id runId = attendedRun(requester.Id);

        TrustService.ProtectionContext context = TrustService.openForAuthorizedTransition(runId);
        String serialized = TrustService.protectRecordSets(
            context,
            new Map<String, List<SObject>>{
                'accounts' => new List<SObject>{ [SELECT Id, Name FROM Account WHERE Id = :hidden.Id] },
                'people' => new List<SObject>{ [SELECT Id, LastName FROM User WHERE Id = :requester.Id] }
            }
        );

        Map<String, Object> sets = (Map<String, Object>) JSON.deserializeUntyped(serialized);
        System.assertEquals(0, ((List<Object>) sets.get('accounts')).size(), 'The requester cannot read Accounts.');
        System.assertEquals(1, ((List<Object>) sets.get('people')).size(), 'The requester can read their own user record.');
        System.assert(!serialized.contains('Hidden from requester'));
    }

    @IsTest
    static void childRecordsAreCheckedForTheRequesterOneByOne() {
        User requester = minimumAccessUser();
        User report = minimumAccessUser();
        report.ManagerId = requester.Id;
        System.runAs(AgentKernelTestFactory.self()) {
            update report;
        }
        Id runId = attendedRun(requester.Id);

        String serialized = TrustService.protectRecordSets(
            TrustService.openForAuthorizedTransition(runId),
            new Map<String, List<SObject>>{ 'people' => [SELECT Id, LastName, (SELECT Id, LastName FROM ManagedUsers) FROM User WHERE Id = :requester.Id] }
        );

        List<Object> people = (List<Object>) ((Map<String, Object>) JSON.deserializeUntyped(serialized)).get('people');
        System.assertEquals(1, people.size(), serialized);
        List<Object> reports = (List<Object>) ((Map<String, Object>) people[0]).get('ManagedUsers');
        Integer readable = AttendedAccessService.readableRecordIds(requester.Id, new Set<Id>{ report.Id }).size();
        System.assertEquals(readable, reports.size(), 'A child record reaches the model only when the requester can read it: ' + serialized);
    }

    @IsTest
    static void recordsWithoutAnIdNeverReachTheRequester() {
        User requester = minimumAccessUser();
        Id runId = attendedRun(requester.Id);

        String serialized = TrustService.protectRecordSets(
            TrustService.openForAuthorizedTransition(runId),
            new Map<String, List<SObject>>{
                'rebuilt' => new List<SObject>{ new User(LastName = 'Rebuilt without an Id') },
                'people' => new List<SObject>{ [SELECT Id, LastName FROM User WHERE Id = :requester.Id] }
            }
        );

        Map<String, Object> sets = (Map<String, Object>) JSON.deserializeUntyped(serialized);
        System.assertEquals(0, ((List<Object>) sets.get('rebuilt')).size(), 'A record without an Id has no sharing Core can check.');
        System.assertEquals(1, ((List<Object>) sets.get('people')).size(), 'Queried records the requester can read still pass.');
        System.assert(!serialized.contains('Rebuilt without an Id'));
    }

    @IsTest
    static void unattendedRunsKeepTheServiceUsersReach() {
        Account visible = new Account(Name = 'Visible to the service user');
        insert visible;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());

        String serialized = TrustService.protectRecordSets(
            TrustService.openForAuthorizedTransition(started.runId),
            new Map<String, List<SObject>>{ 'accounts' => new List<SObject>{ [SELECT Id, Name FROM Account WHERE Id = :visible.Id] } }
        );
        System.assert(serialized.contains('Visible to the service user'));
    }

    @IsTest
    static void standardWriteToolsRefuseChangesTheRequesterCouldNotMake() {
        User requester = minimumAccessUser();
        Account target = new Account(Name = 'Before');
        insert target;
        AgentKernelModels.ToolRequest request = new AgentKernelModels.ToolRequest();
        request.implementationConfiguration = '{"objectApiName":"Account","fields":["Name"]}';
        request.input = JSON.serialize(new Map<String, Object>{ 'recordId' => target.Id, 'recordData' => new Map<String, Object>{ 'Name' => 'After' } });
        request.principal = new AgentKernelModels.ExecutionPrincipal(
            requester.Id,
            AgentKernelTestFactory.unsavedIdentityId(),
            UserInfo.getUserId(),
            null,
            requester.Id
        );

        try {
            new StandardUpdateRecordTool().execute(request);
            System.assert(false, 'The agent must not change a record for someone who could not.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('cannot edit this record'), expected.getMessage());
        }
        System.assertEquals('Before', [SELECT Name FROM Account WHERE Id = :target.Id].Name);

        request.input = JSON.serialize(new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'Created' } });
        try {
            new StandardCreateRecordTool().execute(request);
            System.assert(false, 'The agent must not create a record for someone who could not.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('cannot create Account records'), expected.getMessage());
        }
    }

    @IsTest
    static void runFlowRefusesRecordsTheRequesterCannotEdit() {
        User requester = minimumAccessUser();
        Account target = new Account(Name = 'Before');
        insert target;
        AgentKernelModels.ToolRequest request = new AgentKernelModels.ToolRequest();
        request.implementationConfiguration = '{"flowApiName":"StandardToolTestEchoFlow","allowSystemContext":true}';
        request.input = JSON.serialize(new Map<String, Object>{ 'echoInput' => String.valueOf(target.Id) });
        request.principal = new AgentKernelModels.ExecutionPrincipal(
            requester.Id,
            AgentKernelTestFactory.unsavedIdentityId(),
            UserInfo.getUserId(),
            null,
            requester.Id
        );

        try {
            new StandardRunFlowTool().execute(request);
            System.assert(false, 'A flow must not act on a record for someone who could not edit it.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('cannot edit this record'), expected.getMessage());
        }

        request.input = JSON.serialize(new Map<String, Object>{ 'echoInput' => 'not a record' });
        System.assertEquals(true, new StandardRunFlowTool().execute(request).isSuccess, 'Inputs that are not record Ids need no check.');
        request.input = JSON.serialize(new Map<String, Object>{ 'echoInput' => String.valueOf(target.Id) });
        request.principal = new AgentKernelModels.ExecutionPrincipal(
            requester.Id,
            AgentKernelTestFactory.unsavedIdentityId(),
            UserInfo.getUserId(),
            null,
            null
        );
        System.assertEquals(true, new StandardRunFlowTool().execute(request).isSuccess, 'Unattended runs keep the service user\'s reach.');
    }

    @IsTest
    static void requesterFieldAccessComesFromThePlatform() {
        Set<String> readable = AttendedAccessService.permittedFields(
            UserInfo.getUserId(),
            Account.SObjectType,
            new Set<String>{ 'Name', 'Id', 'NotAField__c' },
            AttendedAccessService.Operation.READABLE
        );
        System.assert(readable.contains('Name'));
        System.assert(readable.contains('Id'));
        System.assert(!readable.contains('NotAField__c'));

        User requester = minimumAccessUser();
        System.assert(
            AttendedAccessService.permittedFields(requester.Id, Account.SObjectType, new Set<String>{ 'Name' }, AttendedAccessService.Operation.READABLE)
                .isEmpty(),
            'Without object access no field is readable.'
        );
    }

    @IsTest
    static void textToolsFilterForTheRequesterOrTheirOutputIsWithheld() {
        User requester = minimumAccessUser();
        Account hidden = new Account(Name = 'Hidden from requester');
        insert hidden;
        User self = [SELECT Id FROM User WHERE Id = :requester.Id];
        AgentKernelModels.ExecutionPrincipal attended = new AgentKernelModels.ExecutionPrincipal(
            requester.Id,
            AgentKernelTestFactory.unsavedIdentityId(),
            UserInfo.getUserId(),
            null,
            requester.Id
        );
        List<SObject> filtered = ToolSecurity.requesterReadable(attended, new List<SObject>{ hidden, self });
        System.assertEquals(1, filtered.size(), 'Only records the requester can read remain.');
        System.assertEquals(requester.Id, filtered[0].Id);
        AgentKernelModels.ExecutionPrincipal unattended = new AgentKernelModels.ExecutionPrincipal(
            UserInfo.getUserId(),
            AgentKernelTestFactory.unsavedIdentityId(),
            UserInfo.getUserId(),
            null,
            null
        );
        System.assertEquals(2, ToolSecurity.requesterReadable(unattended, new List<SObject>{ hidden, self }).size());

        System.assert(
            !(AgentConfigService.newTool(new AgentTool__c(ToolType__c = 'RunFlow')) instanceof IRequesterFilteredTool),
            'Run Flow text is withheld on attended runs.'
        );
        System.assert(ToolCommandExecutor.WITHHELD_OUTPUT.contains('outputWithheld'));
    }

    @IsTest
    static void queriedParentsTheRequesterCannotReadNeverReachTheModel() {
        User requester = minimumAccessUser();
        System.runAs(AgentKernelTestFactory.self()) {
            PermissionSet caseReader = new PermissionSet(Name = 'AttendedCaseRead' + Math.abs(Crypto.getRandomInteger()), Label = 'Case reader');
            insert caseReader;
            insert new ObjectPermissions(ParentId = caseReader.Id, SobjectType = 'Case', PermissionsRead = true);
            insert new FieldPermissions(ParentId = caseReader.Id, SobjectType = 'Case', Field = 'Case.Subject', PermissionsRead = true);
            insert new PermissionSetAssignment(AssigneeId = requester.Id, PermissionSetId = caseReader.Id);
        }
        Account parent = new Account(Name = 'Parent hidden from requester');
        insert parent;
        insert new Case(Subject = 'Case the requester owns', AccountId = parent.Id, OwnerId = requester.Id);
        AgentKernelModels.ToolRequest request = new AgentKernelModels.ToolRequest();
        request.implementationConfiguration = '{"query":"SELECT Subject, Account.Name FROM Case WHERE AccountId = :anchorId LIMIT 5"}';
        request.principal = new AgentKernelModels.ExecutionPrincipal(requester.Id, null, UserInfo.getUserId(), parent.Id, requester.Id);
        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool().execute(request);
        System.assert(JSON.serialize(response.recordSets).contains('Parent hidden from requester'), 'The service user reads the parent.');

        String serialized = TrustService.protectRecordSets(TrustService.openForAuthorizedTransition(attendedRun(requester.Id)), response.recordSets);

        System.assert(serialized.contains('Case the requester owns'), serialized);
        System.assert(!serialized.contains('Parent hidden from requester'), 'The requester cannot read Accounts: ' + serialized);
        System.assert(AgentConfigService.newTool(new AgentTool__c(ToolType__c = 'QueryRecords')) instanceof IRequesterFilteredTool);
    }

    /** A run a person started in their own request; inserted directly so the requester needs no agent access. */
    private static Id attendedRun(Id requesterId) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentRun__c run = new AgentRun__c(
            AgentDefinition__c = definition.Id,
            Status__c = AgentKernelModels.RUN_STATUS_RUNNING,
            Revision__c = 0,
            ExecutionIdentity__c = AgentKernelTestFactory.serviceUser(AgentKernelTestFactory.servicePrincipalUser().Id).Id,
            InitiatingUser__c = requesterId,
            AttendedBy__c = requesterId,
            StartedAt__c = System.now(),
            LastActivityAt__c = System.now()
        );
        AgentKernelTestFactory.insertRecord(run);
        return run.Id;
    }

    private static User minimumAccessUser() {
        User requester = new User(
            Alias = 'minacc',
            Email = 'attended-access-test@example.com',
            Username = 'attended-access-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'Requester',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert requester;
        }
        return requester;
    }
}
