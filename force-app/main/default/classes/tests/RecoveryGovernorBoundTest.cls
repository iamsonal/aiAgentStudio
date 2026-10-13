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
private class RecoveryGovernorBoundTest {
    @IsTest
    static void staleRecoveryProcessesOnlyTheBoundedOldestBatch() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Integer index = 0; index < 30; index++) {
            runs.add(
                new AgentRun__c(
                    AgentDefinition__c = definition.Id,
                    InitiatingUser__c = UserInfo.getUserId(),
                    ResolvedPrincipalUser__c = UserInfo.getUserId(),
                    ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED,
                    Status__c = AgentKernelModels.RUN_STATUS_RUNNING,
                    Revision__c = 0,
                    StartedAt__c = System.now(),
                    LastActivityAt__c = System.now()
                )
            );
        }
        insert runs;
        List<AgentCommand__c> commands = new List<AgentCommand__c>();
        for (Integer index = 0; index < runs.size(); index++) {
            commands.add(
                new AgentCommand__c(
                    AgentRun__c = runs[index].Id,
                    CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                    Status__c = AgentKernelModels.COMMAND_STATUS_LEASED,
                    ExpectedRunRevision__c = 1,
                    OperationKey__c = 'recovery-bound-' + index,
                    DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                    LeaseToken__c = 'stale-' + index,
                    LeaseExpiresAt__c = System.now().addMinutes(-5),
                    AvailableAt__c = System.now().addMinutes(-10)
                )
            );
        }
        AgentKernelTestFactory.insertRecords(commands);
        for (Integer index = 0; index < runs.size(); index++) {
            runs[index].CurrentCommand__c = commands[index].Id;
            runs[index].Revision__c = 1;
        }
        AgentKernelTestFactory.updateRecords(runs);

        Test.startTest();
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(25);
        CommandDeliveryTracker.suppressEnqueueForTest = false;
        Test.stopTest();

        // A requeued command is leased again in the same pass, so stale leases are told apart by their token.
        System.assertEquals(25, result.requeued);
        System.assertEquals(5, [SELECT COUNT() FROM AgentCommand__c WHERE LeaseToken__c LIKE 'stale-%']);
        System.assertEquals(
            25,
            [SELECT COUNT() FROM AgentCommand__c WHERE Status__c = :AgentKernelModels.COMMAND_STATUS_LEASED AND (NOT LeaseToken__c LIKE 'stale-%')]
        );

        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandLeaseRecoveryService.RecoveryResult continuation = CommandLeaseRecoveryService.recoverOperational(25);
        CommandDeliveryTracker.suppressEnqueueForTest = false;
        System.assertEquals(5, continuation.requeued);
        System.assertEquals(0, [SELECT COUNT() FROM AgentCommand__c WHERE LeaseToken__c LIKE 'stale-%']);
        System.assertEquals(30, [SELECT COUNT() FROM AgentCommand__c WHERE Status__c = :AgentKernelModels.COMMAND_STATUS_LEASED]);
    }

    @IsTest
    static void intentionalWaitExpiryUsesBulkGovernorBudget() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Integer index = 0; index < 20; index++) {
            runs.add(
                new AgentRun__c(
                    AgentDefinition__c = definition.Id,
                    InitiatingUser__c = UserInfo.getUserId(),
                    ResolvedPrincipalUser__c = UserInfo.getUserId(),
                    ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED,
                    Status__c = AgentKernelModels.RUN_STATUS_WAITING,
                    Revision__c = 1,
                    StartedAt__c = System.now(),
                    LastActivityAt__c = System.now(),
                    WaitExpiresAt__c = System.now().addMinutes(-5),
                    ContinuationMode__c = AgentKernelModels.CONTINUATION_MODEL
                )
            );
        }
        AgentKernelTestFactory.insertRecords(runs);
        List<AgentCommand__c> commands = new List<AgentCommand__c>();
        for (Integer index = 0; index < runs.size(); index++) {
            commands.add(
                new AgentCommand__c(
                    AgentRun__c = runs[index].Id,
                    CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                    Status__c = AgentKernelModels.COMMAND_STATUS_WAITING,
                    ExpectedRunRevision__c = 1,
                    OperationKey__c = 'operational-expiry-' + index,
                    DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                    AttemptNumber__c = 0,
                    AvailableAt__c = System.now()
                )
            );
        }
        AgentKernelTestFactory.insertRecords(commands);
        for (Integer index = 0; index < runs.size(); index++) {
            runs[index].WaitingCommand__c = commands[index].Id;
        }
        AgentKernelTestFactory.updateRecords(runs);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        CommandLeaseRecoveryService.RecoveryResult firstPass = CommandLeaseRecoveryService.recoverOperational(50);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        CommandLeaseRecoveryService.RecoveryResult secondPass = CommandLeaseRecoveryService.recoverOperational(50);
        Test.stopTest();

        Set<Id> runIds = new Map<Id, AgentRun__c>(runs).keySet();
        System.assertEquals(20, firstPass.expiredWaits, 'Expired waits have their own bulk budget.');
        System.assertEquals(false, firstPass.continuationRequired);
        System.assertEquals(0, secondPass.expiredWaits);
        System.assert(queriesUsed <= 8, 'Intentional-wait expiry should use a constant number of bulk queries.');
        System.assert(
            dmlUsed <= 8,
            'Intentional-wait expiry should use an isolation savepoint and its release, one atomic savepoint boundary, and batched command, event, run, and lifecycle writes.'
        );
        System.assertEquals(20, [SELECT COUNT() FROM AgentRun__c WHERE Id IN :runIds AND Status__c = 'Paused']);
    }

    @IsTest
    static void oneFailingExpiredWaitIsSetAsideWhileOthersExpire() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Integer index = 0; index < 3; index++) {
            runs.add(
                new AgentRun__c(
                    AgentDefinition__c = definition.Id,
                    InitiatingUser__c = UserInfo.getUserId(),
                    ResolvedPrincipalUser__c = UserInfo.getUserId(),
                    ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED,
                    Status__c = AgentKernelModels.RUN_STATUS_WAITING,
                    Revision__c = 1,
                    ContinuationMode__c = AgentKernelModels.CONTINUATION_MODEL,
                    WaitExpiresAt__c = System.now().addMinutes(-10 + index),
                    StartedAt__c = System.now(),
                    LastActivityAt__c = System.now(),
                    PayloadRetentionMode__c = 'Redacted',
                    PayloadRetentionDays__c = 30
                )
            );
        }
        AgentKernelTestFactory.insertRecords(runs);
        CommandLeaseRecoveryService.failingRunIdsForTest = new Set<Id>{ runs[0].Id };

        CommandLeaseRecoveryService.RecoveryResult pass = CommandLeaseRecoveryService.recoverOperational(25);

        System.assertEquals(2, pass.expiredWaits, 'Runs behind a failing run must still expire.');
        AgentRun__c failing = [SELECT Status__c, RecoveryCheckAt__c FROM AgentRun__c WHERE Id = :runs[0].Id WITH SYSTEM_MODE];
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, failing.Status__c);
        System.assert(failing.RecoveryCheckAt__c > System.now(), 'The failing run is set aside for a later pass.');
        System.assertEquals(2, [SELECT COUNT() FROM AgentRun__c WHERE Id IN :runs AND Status__c = 'Paused' WITH SYSTEM_MODE]);
    }

    @IsTest
    static void recoveryDispatchLimitIsBoundedAndConfigurable() {
        CommandLeaseRecoveryService.dispatchLimitOverride = 40;
        System.assertEquals(25, CommandLeaseRecoveryService.configuredDispatchLimit());
        CommandLeaseRecoveryService.dispatchLimitOverride = 75;
        System.assertEquals(25, CommandLeaseRecoveryService.configuredDispatchLimit());
        CommandLeaseRecoveryService.dispatchLimitOverride = null;
    }
}
