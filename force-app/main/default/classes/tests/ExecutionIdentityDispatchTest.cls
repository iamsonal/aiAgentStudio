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
private class ExecutionIdentityDispatchTest {
    private static String capturedEndpoint;
    private static String capturedBody;

    @TestSetup
    static void createOtherUser() {
        Profile restrictedProfile = [
            SELECT Id
            FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator'
            LIMIT 1
        ];
        User otherUser = new User(
            Alias = 'idother',
            Email = 'identity-other@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Identity Other',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = restrictedProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'identity-other-' + UserInfo.getOrganizationId() + '@example.com'
        );
        insert otherUser;
        PermissionSet servicePrincipal = [
            SELECT Id
            FROM PermissionSet
            WHERE Name = 'AgentKernelServicePrincipal'
            LIMIT 1
        ];
        insert new PermissionSetAssignment(AssigneeId = otherUser.Id, PermissionSetId = servicePrincipal.Id);
    }

    @IsTest
    static void servicePrincipalCanReadActiveRuntimeConfiguration() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'service_tool', '{"type":"object"}');
        AgentKernelTestFactory.createContextProvider(definition.Id, 'service_context', 'KernelTestContextProviderAlpha');
        User serviceUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];

        System.runAs(serviceUser) {
            AgentDefinition__c loadedDefinition = AgentConfigService.getActiveDefinition(definition.Id);
            List<AgentTool__c> tools = AgentConfigService.getActiveTools(definition.Id);
            List<AgentContextProvider__c> providers = AgentConfigService.getActiveContextProviders(definition.Id);

            System.assertEquals(definition.Id, loadedDefinition.Id);
            System.assertEquals(1, tools.size());
            System.assertEquals(1, providers.size());
        }
    }

    @IsTest
    static void delegatedPrincipalIdentityIsSnapshottedAndEstablishedByLoopback() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);

        System.assertEquals(UserInfo.getUserId(), run.InitiatingUser__c);
        System.assertEquals(identity.Id, run.ExecutionIdentity__c);
        System.assertEquals('Agent_Core_Loopback', run.LoopbackNamedCredential__c);
        System.assertEquals(identity.PrincipalUser__c, run.ExpectedPrincipalUser__c);
        System.assertEquals(null, run.ResolvedPrincipalUser__c);
        System.assertEquals(ExecutionIdentityService.CONTEXT_PENDING, run.ExecutionContextStatus__c);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);

        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf(
            JSON.serialize(
                new Map<String, Object>{
                    'runId' => started.runId,
                    'commandId' => started.commandId,
                    'expectedRevision' => started.revision,
                    'operationKey' => started.operationKey,
                    'dispatchToken' => command.DispatchToken__c
                }
            )
        );
        System.runAs(AgentKernelTestFactory.principal(identity)) {
            InternalCommandDispatchRest.dispatch();
        }

        run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(202, RestContext.response.statusCode);
        System.assertEquals(identity.PrincipalUser__c, run.ResolvedPrincipalUser__c);
        System.assertEquals(ExecutionIdentityService.CONTEXT_ESTABLISHED, run.ExecutionContextStatus__c);
        command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, command.Status__c);
        System.assertNotEquals(null, command.LeaseToken__c);
    }

    @IsTest
    static void definitionUsesTheSelectedServiceUser() {
        User principal = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.serviceUser(principal.Id, 'Other_Principal_Loopback');
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ExecutionIdentity__c = identity.Id;
        update definition;

        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(identity.Id, run.ExecutionIdentity__c);
        System.assertEquals(principal.Id, run.ExpectedPrincipalUser__c);
        System.assertEquals('Other_Principal_Loopback', run.LoopbackNamedCredential__c);
        System.assertEquals(ExecutionIdentityService.CONTEXT_PENDING, run.ExecutionContextStatus__c);
        run.ExecutionIdentity__c = null;
        System.assertEquals(false, Database.update(run, false).isSuccess(), 'The execution identity is frozen at start.');
    }

    @IsTest
    static void serviceUserMisconfigurationFailsWhenSaved() {
        ExecutionIdentityService.testNamedCredentials = new Set<String>{ 'Existing_Loopback' };
        Id serviceUserId = AgentKernelTestFactory.servicePrincipalUser().Id;
        AgentExecutionIdentity__c malformed = new AgentExecutionIdentity__c(
            Name = 'Malformed',
            PrincipalUser__c = serviceUserId,
            LoopbackNamedCredential__c = 'not-an-api-name'
        );
        assertInsertFails(malformed, 'Enter the API name');
        AgentExecutionIdentity__c missing = new AgentExecutionIdentity__c(
            Name = 'Missing',
            PrincipalUser__c = serviceUserId,
            LoopbackNamedCredential__c = 'Missing_Loopback'
        );
        assertInsertFails(missing, 'No Named Credential');
        AgentExecutionIdentity__c approver = new AgentExecutionIdentity__c(
            Name = 'Approver',
            PrincipalUser__c = AgentKernelTestFactory.approverUser(),
            LoopbackNamedCredential__c = 'Existing_Loopback'
        );
        assertInsertFails(approver, 'must not hold Agent Kernel Human Decision');

        AgentExecutionIdentity__c identity = AgentKernelTestFactory.serviceUser(serviceUserId, 'Existing_Loopback');
        update new AgentExecutionIdentity__c(Id = identity.Id, IsActive__c = false);
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        assertSaveFails(new AgentDefinition__c(Id = definition.Id, ExecutionIdentity__c = identity.Id), 'must be active');
    }

    @IsTest
    static void delegatedPrincipalDispatchCrossesNamedCredentialBoundary() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        ExecutionIdentityService.testNamedCredentials.add('Changed_After_Start');
        update new AgentExecutionIdentity__c(Id = identity.Id, LoopbackNamedCredential__c = 'Changed_After_Start');
        Test.setMock(HttpCalloutMock.class, new AcceptedLoopbackMock());

        Test.startTest();
        Id jobId = CommandDispatcher.dispatch(started.commandId);
        System.assertNotEquals(null, jobId);
        System.assertEquals('callout:Agent_Core_Loopback/services/apexrest/agent-core/v1/dispatch', ServicePrincipalDispatchQueueable.preparedEndpointForTest);
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(ServicePrincipalDispatchQueueable.preparedBodyForTest);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(String.valueOf(started.runId), String.valueOf(envelope.get('runId')));
        System.assertEquals(String.valueOf(started.commandId), String.valueOf(envelope.get('commandId')));
        System.assertEquals(started.operationKey, envelope.get('operationKey'));
        System.assertEquals(command.DispatchToken__c, envelope.get('dispatchToken'));
        Test.stopTest();
    }

    @IsTest
    static void startByTheIdentityUserNeedsNoLoopback() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started;

        Test.startTest();
        System.runAs(AgentKernelTestFactory.principal(identity)) {
            started = AgentKernelTestFactory.start(definition.Id, '{}');
            CommandDispatcher.dispatch(started.commandId);
        }
        Test.stopTest();

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(identity.PrincipalUser__c, run.ResolvedPrincipalUser__c, 'The starter already is the execution user.');
        System.assertEquals(ExecutionIdentityService.CONTEXT_ESTABLISHED, run.ExecutionContextStatus__c);
        System.assertEquals(null, ServicePrincipalDispatchQueueable.preparedEndpointForTest, 'No loopback callout is prepared.');
        System.assertNotEquals(
            AgentKernelModels.COMMAND_STATUS_PENDING,
            AgentKernelTestFactory.getCommand(started.commandId).Status__c,
            'The step ran directly.'
        );
    }

    @IsTest
    static void recoveryRunningAsTheExecutionUserNeedsNoLoopback() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started;
        System.runAs(AgentKernelTestFactory.principal(identity)) {
            started = AgentKernelTestFactory.start(definition.Id, '{}');
        }

        Test.startTest();
        CommandDispatcher.BatchDispatchResult result;
        System.runAs(AgentKernelTestFactory.principal(identity)) {
            result = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ started.commandId });
        }
        Test.stopTest();

        System.assertEquals(new Set<Id>{ started.commandId }, result.acceptedCommandIds);
        System.assertEquals(null, ServicePrincipalBatchDispatchQueueable.preparedEndpointForTest, 'No loopback batch is prepared.');
    }

    @IsTest
    static void unownedUsersCannotStartAnAgentWithoutIdentity() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        for (String userType : new List<String>{ 'AutomatedProcess', 'Guest' }) {
            ExecutionIdentityService.userTypeForTest = userType;
            try {
                AgentKernelTestFactory.start(definition.Id, '{}');
                System.assert(false, userType + ' must not start an agent that runs as whoever starts it.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('Set an Agent Execution Identity'), expected.getMessage());
            }
        }
        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }

    @IsTest
    static void agentWithoutIdentityRunsAsItsStarterWithoutLoopback() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        ExecutionIdentityService.userTypeForTest = 'Standard';

        Test.startTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        CommandDispatcher.dispatch(started.commandId);
        Test.stopTest();

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(null, run.ExecutionIdentity__c);
        System.assertEquals(UserInfo.getUserId(), run.ResolvedPrincipalUser__c);
        System.assertEquals(null, ServicePrincipalDispatchQueueable.preparedEndpointForTest, 'An agent without an identity never loops back.');
    }

    @IsTest
    static void loopbackSignedInAsAnotherUserIsRefused() {
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);

        Boolean refused = false;
        System.runAs(otherUser) {
            try {
                AgentKernel.acceptLoopbackDispatch(started.runId, started.commandId, started.revision, started.operationKey, command.DispatchToken__c);
            } catch (AgentKernelException.ConfigurationException expected) {
                refused = expected.getMessage().contains('not the run\'s execution user');
            }
        }

        System.assert(refused, 'A Named Credential that signs in as another user must not run the step.');
        System.assertEquals(null, AgentKernelTestFactory.getRun(started.runId).ResolvedPrincipalUser__c);
    }

    @IsTest
    static void failedIdentityHopIsRetriedOnceWhileTheCommandIsStillDue() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        ServicePrincipalDispatchQueueable hop = new ServicePrincipalDispatchQueueable(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            command.DispatchToken__c,
            AgentKernelTestFactory.TEST_LOOPBACK
        );
        ServicePrincipalDispatchQueueable staleHop = new ServicePrincipalDispatchQueueable(
            started.runId,
            started.commandId,
            started.revision + 1,
            started.operationKey,
            command.DispatchToken__c,
            AgentKernelTestFactory.TEST_LOOPBACK
        );

        Test.setMock(HttpCalloutMock.class, new AcceptedLoopbackMock());
        Test.startTest();
        System.assertNotEquals(null, hop.retryAfterFailure(), 'A transient loopback failure is retried a minute later.');
        System.assertEquals(null, staleHop.retryAfterFailure(), 'A hop for an older revision is not retried.');
        Test.stopTest();

        AgentCommand__c retried = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals('DISPATCH_RETRIED', retried.DeliveryAnomalyCode__c);
        System.assertEquals(1, retried.DeliveryAnomalyCount__c);
    }

    @IsTest
    static void loopbackRejectsStaleOperationIdentity() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);

        try {
            AgentKernel.acceptLoopbackDispatch(started.runId, started.commandId, started.revision, 'stale-operation-key', command.DispatchToken__c);
            System.assert(false, 'A stale operation key must fail closed.');
        } catch (AgentKernelException.ConcurrencyException expected) {
        }
        try {
            AgentKernel.acceptLoopbackDispatch(started.runId, started.commandId, started.revision, started.operationKey, 'stale-dispatch-token');
            System.assert(false, 'A stale dispatch token must fail closed.');
        } catch (AgentKernelException.ConcurrencyException expected) {
        }
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(ExecutionIdentityService.CONTEXT_PENDING, run.ExecutionContextStatus__c);
        System.assertEquals(null, run.ResolvedPrincipalUser__c);
    }

    @IsTest
    static void initiatorDispatchFailsClosedForDifferentUser() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];
        Boolean rejected = false;

        System.runAs(otherUser) {
            try {
                CommandDispatcher.dispatch(started.commandId);
            } catch (AgentKernelException.ConfigurationException expected) {
                rejected = true;
            }
        }
        System.assert(rejected, 'Initiating User mode must reject a different current user.');
    }

    @IsTest
    static void recoveryFailsAnInitiatingUserRunWhoseChainWasLost() {
        AgentKernelModels.StartResult started = overdueInitiatingUserRun(CommandLeaseRecoveryService.INITIATING_USER_CHAIN_GRACE_MINUTES + 5);
        CommandLeaseRecoveryService.RecoveryResult result = recoverAsOtherUser();

        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(1, result.lostInitiatingUserChains);
        System.assertEquals(AgentKernelModels.RUN_STATUS_FAILED, run.Status__c);
        System.assertEquals('INITIATING_USER_CHAIN_LOST', run.ErrorCode__c);
        System.assertNotEquals(null, run.CompletedAt__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, command.Status__c);
    }

    @IsTest
    static void recoveryLeavesARecentlyDueInitiatingUserCommandRunning() {
        AgentKernelModels.StartResult started = overdueInitiatingUserRun(5);
        CommandLeaseRecoveryService.RecoveryResult result = recoverAsOtherUser();

        System.assertEquals(0, result.lostInitiatingUserChains);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    private static AgentKernelModels.StartResult overdueInitiatingUserRun(Integer minutesOverdue) {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = started.commandId, AvailableAt__c = System.now().addMinutes(-minutesOverdue)));
        return started;
    }

    private static CommandLeaseRecoveryService.RecoveryResult recoverAsOtherUser() {
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];
        CommandLeaseRecoveryService.RecoveryResult result;
        System.runAs(otherUser) {
            result = CommandLeaseRecoveryService.recoverOperational(25);
        }
        return result;
    }

    @IsTest
    static void delegatedPrincipalRunControlRequiresStarterOrPermission() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{}');
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];

        System.runAs(otherUser) {
            assertRunControlDenied(run, true);
            assertRunControlDenied(run, false);
        }
        AgentKernelTestFactory.grant(otherUser.Id, new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(otherUser) {
            ExecutionIdentityService.assertCanCancel(run);
            ExecutionIdentityService.assertCanResume(run);
        }
    }

    @IsTest
    static void runControllerCanCancelButCannotResumeAnotherUsersInitiatingUserRun() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(AgentKernelTestFactory.createDefinition().Id, '{}');
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];

        AgentKernelTestFactory.grant(otherUser.Id, new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(otherUser) {
            ExecutionIdentityService.assertCanCancel(run);
            assertRunControlDenied(run, false);
        }
    }

    @IsTest
    static void schedulerIdentityCanExpireAnotherUsersIntentionalWait() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(AgentKernelTestFactory.createDefinition().Id, '{}');
        AgentKernelModels.CommandOutcome waiting = AgentKernelModels.waitForResume(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            null
        );
        waiting.continuationMode = AgentKernelModels.CONTINUATION_MODEL;
        waiting.waitExpiresAt = System.now().addMinutes(5);
        AgentKernelTestFactory.applyOutcome(waiting);
        update new AgentRun__c(Id = started.runId, WaitExpiresAt__c = System.now().addMinutes(-1));
        User otherUser = [SELECT Id FROM User WHERE Alias = 'idother' LIMIT 1];

        System.runAs(otherUser) {
            CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(10);
            System.assertEquals(1, result.expiredWaits);
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelTestFactory.getRun(started.runId).Status__c);
    }

    @IsTest
    static void anIdentityInUseCannotBeDeleted() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);

        Database.DeleteResult deleted = Database.delete(identity, false);

        System.assertEquals(false, deleted.isSuccess(), 'Deleting the identity would turn the agent into one that runs as whoever starts it.');
        System.assertEquals(identity.Id, [SELECT ExecutionIdentity__c FROM AgentDefinition__c WHERE Id = :definition.Id].ExecutionIdentity__c);
    }

    private static void assertInsertFails(SObject record, String expectedMessage) {
        Database.SaveResult saved = Database.insert(record, false);
        System.assertEquals(false, saved.isSuccess(), 'Misconfiguration must fail when saved: ' + expectedMessage);
        System.assert(saved.getErrors()[0].getMessage().contains(expectedMessage), saved.getErrors()[0].getMessage());
    }

    private static void assertSaveFails(SObject record, String expectedMessage) {
        Database.SaveResult saved = Database.update(record, false);
        System.assertEquals(false, saved.isSuccess(), 'Misconfiguration must fail when saved: ' + expectedMessage);
        System.assert(saved.getErrors()[0].getMessage().contains(expectedMessage), saved.getErrors()[0].getMessage());
    }

    private static void assertRunControlDenied(AgentRun__c run, Boolean cancelOperation) {
        try {
            if (cancelOperation) {
                ExecutionIdentityService.assertCanCancel(run);
            } else {
                ExecutionIdentityService.assertCanResume(run);
            }
            System.assert(false, 'Run control must require the initiating actor or explicit authority.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('not authorized'));
        }
    }

    private class AcceptedLoopbackMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            capturedEndpoint = request.getEndpoint();
            capturedBody = request.getBody();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(202);
            return response;
        }
    }
}
