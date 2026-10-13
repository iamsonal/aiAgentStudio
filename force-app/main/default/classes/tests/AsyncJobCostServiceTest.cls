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
private class AsyncJobCostServiceTest {
    @IsTest
    static void estimatesPostOptimizationQueueableCost() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(4, 6, 2);
        AsyncJobCostService.Estimate estimate = AsyncJobCostService.estimate(definition);
        System.assertEquals(10, estimate.configuredMaxCommands);
        System.assertEquals(1, estimate.jobsPerCommand);
        System.assertEquals(10, estimate.baseJobsPerRun);
        System.assertEquals(16, estimate.retryFreeJobsPerRun);
        System.assertEquals(76, estimate.worstCaseJobsPerRun, 'Two retries for each of ten operations, three jobs per initiating-user retry.');
        System.assertEquals(14, estimate.requiredInitiatingUserStackDepth);
        System.assertEquals(false, estimate.exceedsInitiatingUserChainDepth);
    }

    @IsTest
    static void delegatedPrincipalEstimateIncludesIdentityAndApprovalReentry() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(4, 6, 2);
        definition.ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId();
        AsyncJobCostService.Estimate estimate = AsyncJobCostService.estimate(definition);

        System.assertEquals(11, estimate.baseJobsPerRun);
        System.assertEquals(23, estimate.retryFreeJobsPerRun);
        System.assertEquals(63, estimate.worstCaseJobsPerRun, 'Delegated retries park instead of hopping, costing two jobs each.');
    }

    @IsTest
    static void identifiesIncompatibleInitiatingUserBudget() {
        AsyncJobCostService.Estimate estimate = AsyncJobCostService.estimate(unsavedInitiatingUserDefinition(50, 50, 2));
        System.assertEquals(true, estimate.exceedsInitiatingUserChainDepth);
        System.assertEquals(AsyncJobCostService.MAXIMUM_INITIATING_USER_CHAIN_DEPTH, estimate.requiredInitiatingUserStackDepth);
    }

    @IsTest
    static void supportedPerRunMaximumHasExactBoundary() {
        AsyncJobCostService.Estimate supported = AsyncJobCostService.estimate(unsavedInitiatingUserDefinition(100, 0, 0));
        AsyncJobCostService.Estimate unsupported = AsyncJobCostService.estimate(unsavedInitiatingUserDefinition(101, 0, 0));

        System.assertEquals(100, AsyncJobCostService.MAXIMUM_JOBS_PER_RUN);
        System.assertEquals(100, supported.worstCaseJobsPerRun);
        System.assertEquals(false, supported.exceedsMaximumJobsPerRun);
        System.assertEquals(101, unsupported.worstCaseJobsPerRun);
        System.assertEquals(true, unsupported.exceedsMaximumJobsPerRun);
    }

    @IsTest
    static void startRejectsDefinitionsOutsideSupportedAsyncEnvelope() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(10, 50, 0);
        try {
            AgentRunService.start(AgentKernelTestFactory.startRequest(definition, '{}'));
            System.assert(false, 'A run that exceeds the asynchronous work budget must be rejected.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('supported per-run maximum'));
        }
        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }

    private static AgentDefinition__c unsavedInitiatingUserDefinition(Integer maxModelCalls, Integer maxToolCalls, Integer maxRetries) {
        return new AgentDefinition__c(MaxModelCalls__c = maxModelCalls, MaxToolCalls__c = maxToolCalls, MaxRetries__c = maxRetries);
    }

    @IsTest
    static void initiatingUserAdmissionEnforcesInheritedDepthBoundary() {
        CommandDispatcher.assertInitiatingUserChainDepth(14, 86, 100);
        try {
            CommandDispatcher.assertInitiatingUserChainDepth(15, 86, 100);
            System.assert(false, 'A run that exceeds the remaining inherited chain depth must be rejected.');
        } catch (AgentKernelException.QueueCapacityException expected) {
            System.assert(expected.getMessage().contains('remains in this chain'), expected.getMessage());
        }
    }

    @IsTest
    static void childQueueablePreservesInheritedMaximumStackDepth() {
        Test.startTest();
        System.enqueueJob(new ChildOptionsProbe(), CommandDispatcher.options('root', UserInfo.getUserId(), null, null, false));
        Test.stopTest();
    }

    @IsTest
    static void delayedDispatchIsClampedToPlatformMaximum() {
        AsyncOptions options = CommandDispatcher.options('delay', UserInfo.getUserId(), null, 90, false);
        System.assertEquals(10, options.MinimumQueueableDelayInMinutes);
    }

    @IsTest
    static void dispatchRevisionChangesDuplicateSignature() {
        AsyncOptions first = CommandDispatcher.options('lease', UserInfo.getUserId(), 1, null, false);
        AsyncOptions second = CommandDispatcher.options('lease', UserInfo.getUserId(), 2, null, false);

        System.assertNotEquals(first.DuplicateSignature, second.DuplicateSignature);
    }

    @IsTest
    static void successfulFinalizerLeasesContinuationWithoutDispatchJob() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelTestFactory.getCommand(started.commandId).Status__c);

        Test.startTest();
        System.enqueueJob(new FinalizerProbe(started.commandId));
        Test.stopTest();

        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_SUCCEEDED, command.Status__c);
        System.assertEquals(1, command.AttemptNumber__c);
        System.assertEquals(null, command.LeaseToken__c);
    }

    @IsTest
    static void initiatingUserEntryLeasesBeforeWorkerEnqueue() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());

        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandDispatcher.dispatch(started.commandId);
        CommandDeliveryTracker.suppressEnqueueForTest = false;

        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, command.Status__c);
        System.assertEquals(1, command.AttemptNumber__c);
    }

    @IsTest
    static void staleFinalizerContinuationIsAnIdempotentNoop() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernel.cancel(started.runId, started.revision, 'Cancelled before continuation.');

        Id jobId = CommandDispatcher.continueAfterCommit(started.commandId);

        System.assertEquals(null, jobId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_CANCELLED, AgentKernelTestFactory.getCommand(started.commandId).Status__c);
    }

    private class ChildOptionsProbe implements Queueable {
        public void execute(QueueableContext context) {
            AsyncOptions childOptions = CommandDispatcher.options('child', UserInfo.getUserId(), null, null, false);
            System.assertEquals(null, childOptions.MaximumQueueableStackDepth);
            System.assertNotEquals(null, childOptions.DuplicateSignature);
            System.enqueueJob(new NoopQueueable(), childOptions);
        }
    }

    private class NoopQueueable implements Queueable {
        public void execute(QueueableContext context) {
        }
    }

    private class FinalizerProbe implements Queueable {
        private Id commandId;

        private FinalizerProbe(Id commandId) {
            this.commandId = commandId;
        }

        public void execute(QueueableContext context) {
            CommandContinuationFinalizer finalizer = new CommandContinuationFinalizer(null, null, null);
            finalizer.prepare(commandId);
            System.attachFinalizer(finalizer);
        }
    }
}
