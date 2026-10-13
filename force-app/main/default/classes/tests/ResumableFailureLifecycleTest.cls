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
private class ResumableFailureLifecycleTest {
    @IsTest
    static void operatorPauseAndRescueRearmsQueuedCheckpoint() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

            AgentKernel.pause(started.runId, started.revision, 'Maintenance window.');

            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assertEquals(started.commandId, paused.CurrentCommand__c);
            System.assertEquals(null, paused.CompletedAt__c);
            System.assertNotEquals(null, paused.PurgeAfter__c);

            AgentKernelModels.RescueRequest request = rescueRequest(paused, 'Continue after maintenance.');
            Id rescuedCommandId = AgentKernel.rescue(request);

            AgentRun__c rescued = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c command = AgentKernelTestFactory.getCommand(rescuedCommandId);
            System.assertEquals(started.commandId, rescuedCommandId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, rescued.Status__c);
            System.assertEquals(rescued.Revision__c, command.ExpectedRunRevision__c);
        }
    }

    @IsTest
    static void operatorPauseProtectsSensitiveReason() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy fullRetention = AgentExecutionPolicyService.defaults();
            fullRetention.payloadRetentionMode = PayloadProtectionService.MODE_FULL;
            AgentKernelTestFactory.configureExecutionPolicy(fullRetention);
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

            AgentKernel.pause(started.runId, started.revision, 'Contact alice@example.com before continuing.');

            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            AgentEvent__c pauseEvent = AgentKernelTestFactory.getEvents(started.runId)[2];
            System.assert(!paused.ErrorMessage__c.contains('alice@example.com'));
            System.assert(TrustService.containsToken(paused.ErrorMessage__c));
            System.assert(!pauseEvent.Payload__c.contains('alice@example.com'));
            System.assert(TrustService.containsToken(pauseEvent.Payload__c));
        }
    }

    @IsTest
    static void retryBudgetIsScopedToEachOperation() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 0, 1);
        AgentExecutionPolicyService.Policy policy = AgentExecutionPolicyService.defaults();
        policy.maxRetries = 1;
        AgentKernelTestFactory.configureExecutionPolicy(policy);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentCommand__c first = leaseCurrent(started.runId);
        System.assertEquals(true, scheduleRetry(started.runId, first));
        first = AgentKernelTestFactory.getCommand(first.Id);
        update new AgentCommand__c(Id = first.Id, AvailableAt__c = System.now().addSeconds(-1));
        first = leaseCurrent(started.runId);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                first.Id,
                run.Revision__c,
                first.OperationKey__c,
                '{"first":"complete"}',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, '{"next":true}', null)
            )
        );

        AgentCommand__c second = leaseCurrent(started.runId);
        System.assertEquals(true, scheduleRetry(started.runId, second));
        run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(2, run.RetryCount__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        AgentCommand__c retriedSecond = AgentKernelTestFactory.getCommand(second.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_RETRY_WAITING, retriedSecond.Status__c);
    }

    @IsTest
    static void rescuingFailedCommandKeepsAttemptIdentityMonotonic() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 0, 0);
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

            AgentCommand__c firstAttempt = leaseCurrent(started.runId);
            System.assertEquals(false, scheduleRetry(started.runId, firstAttempt));
            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c failed = AgentKernelTestFactory.getCommand(firstAttempt.Id);
            System.assertEquals(1, failed.AttemptNumber__c);

            Id rescuedCommandId = AgentKernel.rescue(rescueRequest(paused, 'Provider recovered.'));
            AgentCommand__c rescued = AgentKernelTestFactory.getCommand(rescuedCommandId);
            System.assertEquals(1, rescued.AttemptNumber__c, 'Rescue must never reuse an invocation attempt identity.');
            System.assertEquals(1, rescued.RetryWindowStartAttempt__c, 'Rescue opens a new retry window at the monotonic attempt boundary.');

            AgentCommand__c secondAttempt = leaseCurrent(started.runId);
            System.assertEquals(2, secondAttempt.AttemptNumber__c);
        }
    }

    @IsTest
    static void pauseRollsBackEveryLifecycleWriteWhenRunUpdateFails() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
            Integer eventsBefore = AgentKernelTestFactory.getEvents(started.runId).size();
            AgentLifecycleStore.failNextRunUpdateForTest = true;

            try {
                AgentKernel.pause(started.runId, started.revision, 'Atomic pause test.');
                System.assert(false, 'Injected persistence failure must escape.');
            } catch (AgentKernelException.PersistenceException expected) {
                System.assert(expected.getMessage().contains('RUN_UPDATE_FAILED'));
            }

            AgentRun__c unchangedRun = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c unchangedCommand = AgentKernelTestFactory.getCommand(started.commandId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, unchangedRun.Status__c);
            System.assertEquals(started.revision, unchangedRun.Revision__c);
            System.assertEquals(started.revision, unchangedCommand.ExpectedRunRevision__c);
            System.assertEquals(eventsBefore, AgentKernelTestFactory.getEvents(started.runId).size());
        }
    }

    @IsTest
    static void providerFaultPausesAndResumesFromSameCheckpoint() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            KernelTestModelProvider.mode = 'unexpectedException';
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
            AgentCommand__c firstAttempt = leaseCurrent(started.runId);

            new ModelCommandQueueable(
                    started.runId,
                    firstAttempt.Id,
                    firstAttempt.ExpectedRunRevision__c,
                    firstAttempt.OperationKey__c,
                    firstAttempt.LeaseToken__c
                )
                .execute(null);

            AgentRun__c paused = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, paused.Status__c);
            System.assertEquals(firstAttempt.Id, paused.CurrentCommand__c);
            KernelTestModelProvider.mode = 'final';
            Id rescuedCommandId = AgentKernel.rescue(rescueRequest(paused, 'Provider incident resolved.'));
            AgentCommand__c rescuedAttempt = leaseCurrent(started.runId);
            System.assertEquals(rescuedCommandId, rescuedAttempt.Id);

            new ModelCommandQueueable(
                    started.runId,
                    rescuedAttempt.Id,
                    rescuedAttempt.ExpectedRunRevision__c,
                    rescuedAttempt.OperationKey__c,
                    rescuedAttempt.LeaseToken__c
                )
                .execute(null);

            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelTestFactory.getRun(started.runId).Status__c);
        }
    }

    @IsTest
    static void explicitTerminalFailureRemainsNonResumable() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
            AgentCommand__c command = leaseCurrent(started.runId);
            AgentKernelModels.CommandOutcome terminalFailure = AgentKernelModels.terminalFailure(
                started.runId,
                command.Id,
                command.ExpectedRunRevision__c,
                command.OperationKey__c,
                'BUSINESS_TERMINAL_FAILURE',
                'No valid continuation exists.'
            );
            terminalFailure.leaseToken = command.LeaseToken__c;
            AgentKernel.applyOutcome(terminalFailure);

            AgentRun__c failed = AgentKernelTestFactory.getRun(started.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_FAILED, failed.Status__c);
            try {
                AgentKernel.rescue(rescueRequest(failed, 'Should not resume.'));
                System.assert(false, 'Terminal failure must remain immutable.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('paused'));
            }
        }
    }

    private static AgentKernelModels.RescueRequest rescueRequest(AgentRun__c run, String guidance) {
        AgentKernelModels.RescueRequest request = new AgentKernelModels.RescueRequest();
        request.runId = run.Id;
        request.expectedRunRevision = run.Revision__c;
        request.guidance = guidance;
        return request;
    }

    private static AgentCommand__c leaseCurrent(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
        System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
        return lease.command;
    }

    private static Boolean scheduleRetry(Id runId, AgentCommand__c command) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        return AgentKernel.scheduleRetry(AgentKernelTestFactory.retryRequest(run, command, 'TEST_RETRYABLE', 0));
    }
}
