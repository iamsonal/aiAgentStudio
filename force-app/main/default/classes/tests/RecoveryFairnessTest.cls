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
private class RecoveryFairnessTest {
    @TestSetup
    static void createOtherActor() {
        Profile profile = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator' LIMIT 1];
        insert new User(
            Alias = 'rcvother',
            Email = 'recovery-other@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Recovery Other',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'recovery-other-' + UserInfo.getOrganizationId() + '@example.com'
        );
    }

    @IsTest
    static void olderWrongUserOrphansDoNotHideEligibleWork() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        Id otherUserId = [SELECT Id FROM User WHERE Alias = 'rcvother' LIMIT 1].Id;
        List<AgentCommand__c> commands = seedCommands(definition.Id, 51, false, otherUserId);
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandLeaseRecoveryService.RecoveryResult recovered = CommandLeaseRecoveryService.recoverOperational(25);
        System.assertEquals(1, recovered.orphanRedispatched);
        System.assertEquals(0, recovered.deferredByInitiatingUser);
        System.assertEquals(
            AgentKernelModels.COMMAND_STATUS_LEASED,
            AgentKernelTestFactory.getCommand(commands[50].Id).Status__c,
            'The eligible command is leased in the same pass.'
        );
    }

    @IsTest
    static void activeStaleWorkersDeferSoLaterEligibleLeaseProgresses() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentCommand__c> commands = seedCommands(definition.Id, 51, true, UserInfo.getUserId());
        CommandDeliveryTracker.testJobStatuses = new Map<Id, String>{ UserInfo.getUserId() => 'Processing' };
        CommandDeliveryTracker.suppressEnqueueForTest = true;

        Test.startTest();
        CommandLeaseRecoveryService.RecoveryResult first = CommandLeaseRecoveryService.recoverOperational(25);
        CommandLeaseRecoveryService.RecoveryResult second = CommandLeaseRecoveryService.recoverOperational(25);
        CommandLeaseRecoveryService.RecoveryResult third = CommandLeaseRecoveryService.recoverOperational(25);
        Test.stopTest();

        System.assertEquals(25, first.deferredByActiveWorker);
        System.assertEquals(25, second.deferredByActiveWorker);
        System.assertEquals(1, third.requeued);
        AgentCommand__c progressed = AgentKernelTestFactory.getCommand(commands[50].Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, progressed.Status__c, 'The requeued command is leased again in the same pass.');
        System.assertNotEquals(commands[50].LeaseToken__c, progressed.LeaseToken__c, 'It holds a fresh lease.');
    }

    @IsTest
    static void batchDispatcherReportsEveryCommandAboveItsBound() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentCommand__c> commands = seedCommands(definition.Id, 30, false, UserInfo.getUserId());
        List<Id> commandIds = new List<Id>();
        for (AgentCommand__c command : commands) {
            commandIds.add(command.Id);
        }
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandDispatcher.BatchDispatchResult dispatched = CommandDispatcher.dispatchBatchDetailed(commandIds);
        System.assertEquals(25, dispatched.acceptedCommandIds.size());
        System.assertEquals(5, dispatched.deferredCommandIds.size());
        System.assertEquals(30, dispatched.acceptedCommandIds.size() + dispatched.deferredCommandIds.size());
    }

    @IsTest
    static void kernelReportsEveryCommandItCannotTransitionInOneBatch() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentCommand__c> commands = seedCommands(definition.Id, 30, true, UserInfo.getUserId());
        List<Id> commandIds = new List<Id>();
        for (AgentCommand__c command : commands) {
            commandIds.add(command.Id);
        }
        AgentKernel.StaleLeaseRecoveryResult recovered = AgentKernelRecovery.recoverStaleLeases(
            commandIds,
            System.now(),
            new Map<Id, CommandDeliveryTracker.JobState>()
        );
        System.assertEquals(25, recovered.requeuedCommandIds.size());
        System.assertEquals(5, recovered.deferredCommandIds.size());
        System.assertEquals(30, recovered.requeuedCommandIds.size() + recovered.deferredCommandIds.size());
    }

    private static List<AgentCommand__c> seedCommands(Id definitionId, Integer count, Boolean leased, Id oldActorId) {
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Integer index = 0; index < count; index++) {
            Id actorId = index == count - 1 ? UserInfo.getUserId() : oldActorId;
            runs.add(
                new AgentRun__c(
                    AgentDefinition__c = definitionId,
                    InitiatingUser__c = actorId,
                    ExpectedPrincipalUser__c = actorId,
                    ResolvedPrincipalUser__c = actorId,
                    ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED,
                    Status__c = AgentKernelModels.RUN_STATUS_RUNNING,
                    Revision__c = 0,
                    StartedAt__c = System.now(),
                    LastActivityAt__c = System.now()
                )
            );
        }
        AgentKernelTestFactory.insertRecords(runs);
        List<AgentCommand__c> commands = new List<AgentCommand__c>();
        for (Integer index = 0; index < count; index++) {
            commands.add(
                new AgentCommand__c(
                    AgentRun__c = runs[index].Id,
                    CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                    Status__c = leased ? AgentKernelModels.COMMAND_STATUS_LEASED : AgentKernelModels.COMMAND_STATUS_PENDING,
                    ExpectedRunRevision__c = 1,
                    OperationKey__c = 'fair-recovery-' + index,
                    DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                    LeaseToken__c = leased ? 'fair-lease-' + index : null,
                    LeaseExpiresAt__c = leased ? System.now().addMinutes(-5) : null,
                    WorkerJobId__c = leased && index < count - 1 ? UserInfo.getUserId() : null,
                    AvailableAt__c = System.now().addMinutes(-10),
                    AttemptNumber__c = leased ? 1 : 0
                )
            );
        }
        AgentKernelTestFactory.insertRecords(commands);
        for (Integer index = 0; index < count; index++) {
            runs[index].CurrentCommand__c = commands[index].Id;
            runs[index].Revision__c = 1;
        }
        AgentKernelTestFactory.updateRecords(runs);
        return commands;
    }
}
