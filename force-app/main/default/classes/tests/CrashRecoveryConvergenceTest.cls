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

/**
 * "Safe to repeat" and "If you cannot prove an outside action happened, mark it
 * unknown", proved by crashing a run at each of its steps. A crashed worker job
 * is rolled back by the platform and its finalizer recovers the lease; this
 * test does exactly that, then drives the run to its end. Whatever step
 * crashes, the run ends the same way: in-org work happens once, an outside
 * effect is never repeated, and the lifecycle rules hold after every step.
 *
 * The run: the model asks for one tool, the tool runs, the model answers.
 */
@IsTest
private class CrashRecoveryConvergenceTest {
    private static final String PROBE = 'Crash probe ';
    private static final String TOOL_NAME = 'act_on_case';
    private static final Integer MODEL_TURN = 0;
    private static final Integer TOOL_CALL = 1;
    private static final Integer FINAL_ANSWER = 2;

    @IsTest
    static void crashOnAModelTurnAsksTheModelAgainAndAnswersOnce() {
        Outcome outcome = runWithCrashAt(MODEL_TURN, AgentToolTypeTestFixtures.IN_ORG, false);

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, outcome.run.Status__c, outcome.describe());
        System.assertEquals(3, KernelTestModelProvider.invocationCount, 'The crashed turn is asked again, once.');
        System.assertEquals(1, outcome.toolCalls, 'The tool runs once.');
        System.assertEquals(1, outcome.probeAccounts, 'Its record is written once.');
    }

    @IsTest
    static void crashAfterAToolWithoutEffectsUndoesItAndRunsItAgain() {
        Outcome outcome = runWithCrashAt(TOOL_CALL, AgentToolTypeTestFixtures.IN_ORG, false);

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, outcome.run.Status__c, outcome.describe());
        System.assertEquals(2, outcome.toolCalls, 'A tool without outside effects is safe to run again.');
        System.assertEquals(1, outcome.probeAccounts, 'The crashed call\'s record was rolled back, so only one remains.');
        System.assertEquals(false, outcome.reconciled, 'Nothing needed an operator.');
    }

    @IsTest
    static void crashAfterAToolWithOutsideEffectsIsNeverRunAgain() {
        Outcome outcome = runWithCrashAt(TOOL_CALL, AgentToolTypeTestFixtures.EXTERNAL, false);

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, outcome.run.Status__c, outcome.describe());
        System.assertEquals(1, outcome.toolCalls, 'An outside effect that may have happened is never repeated.');
        System.assertEquals(true, outcome.reconciled, 'An operator confirmed the outcome before the run went on.');
        System.assertEquals(2, KernelTestModelProvider.invocationCount, 'The model continues from the confirmed result.');
    }

    @IsTest
    static void crashOnTheFinalAnswerStillAnswersOnce() {
        Outcome outcome = runWithCrashAt(FINAL_ANSWER, AgentToolTypeTestFixtures.IN_ORG, false);

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, outcome.run.Status__c, outcome.describe());
        System.assertEquals('{"reply":"Done."}', outcome.run.Output__c);
        System.assertEquals(3, KernelTestModelProvider.invocationCount, 'Only the crashed final turn is asked again.');
        System.assertEquals(1, outcome.toolCalls);
    }

    /** A person cancels while the tool runs, and the worker then crashes: recovery finishes the cancel and never runs the tool again. */
    @IsTest
    static void cancelDuringACrashedToolEndsTheRunWithoutRepeatingIt() {
        Outcome outcome = runWithCrashAt(TOOL_CALL, AgentToolTypeTestFixtures.IN_ORG, true);

        System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, outcome.run.Status__c, outcome.describe());
        System.assertEquals(1, outcome.toolCalls, 'A cancelled run does not run its tool again.');
        System.assertEquals(0, outcome.probeAccounts, 'The crashed call\'s record was rolled back.');
        System.assertEquals(1, KernelTestModelProvider.invocationCount, 'The model is not asked again after the cancel.');
    }

    private class Outcome {
        AgentRun__c run;
        Integer toolCalls;
        Integer probeAccounts;
        Boolean reconciled = false;

        String describe() {
            return run.Status__c + ' ' + run.ErrorCode__c + ': ' + run.ErrorMessage__c;
        }
    }

    /**
     * Drives the run, crashing the step numbered crashStep once. Test.startTest
     * sits just before the crash, so each half of the run has its own limits.
     */
    private static Outcome runWithCrashAt(Integer crashStep, String toolType, Boolean cancelDuringCrash) {
        Outcome outcome = new Outcome();
        // Each step is one job here; InlineToolExecutionTest crashes a tool that runs in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(10, 10);
            AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, TOOL_NAME, '{"type":"object"}');
            tool.ToolType__c = toolType;
            AgentKernelTestFactory.updateRecord(tool);
            AgentConfigService.clearCacheForTest();
            KernelTestTool.accountPrefixPerTool = PROBE;
            KernelTestModelProvider.scriptToolCall(TOOL_NAME, '{}');
            KernelTestModelProvider.scriptFinal('{"reply":"Done."}');
            Id runId = AgentKernelTestFactory.startRunWithoutDispatch(definition).runId;

            Boolean crashed = false;
            for (Integer step = 0; step < 8; step++) {
                AgentRun__c run = AgentKernelTestFactory.getRun(runId);
                if (run.Status__c == AgentKernelModels.RUN_STATUS_WAITING) {
                    reconcileAsSucceeded(run);
                    outcome.reconciled = true;
                } else if (run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING || run.CurrentCommand__c == null) {
                    break;
                } else if (step == crashStep && !crashed) {
                    Test.startTest();
                    crashCurrentStep(runId, cancelDuringCrash);
                    crashed = true;
                } else {
                    AgentKernelTestFactory.runSteps(runId, 1);
                }
                AgentKernelTestFactory.assertLifecycleInvariants(runId);
            }
            Test.stopTest();
            System.assert(crashed, 'The run ended before step ' + crashStep + ' could crash.');
            outcome.run = AgentKernelTestFactory.getRun(runId);
            AgentKernelTestFactory.assertLifecycleInvariants(runId);
        }
        Integer calls = KernelTestTool.invocationsByTool.get(TOOL_NAME);
        outcome.toolCalls = calls == null ? 0 : calls;
        String probeName = PROBE + TOOL_NAME;
        outcome.probeAccounts = [SELECT COUNT() FROM Account WHERE Name = :probeName];
        return outcome;
    }

    /**
     * Leases the current command and runs its worker until the settlement
     * fails, rolls the job back as the platform does, and recovers the lease
     * as the job's finalizer does.
     */
    private static void crashCurrentStep(Id runId, Boolean cancelDuringCrash) {
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
        System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
        AgentCommand__c leased = AgentKernelTestFactory.getCommand(command.Id);
        if (cancelDuringCrash) {
            AgentRunService.cancel(runId, run.Revision__c, 'The customer withdrew the request.');
        }
        // The crashed model turn reached the provider; asked again, it answers the same way.
        String replayedAnswer = leased.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL ? JSON.serialize(KernelTestModelProvider.script[0]) : null;

        Savepoint job = Database.setSavepoint();
        CommandAttemptRuntime.failSettlementForTest = true;
        Exception failure;
        try {
            if (leased.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL) {
                new ModelCommandQueueable(run.Id, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
            } else {
                new ToolCommandQueueable(run.Id, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);
            }
        } catch (AgentKernelException.PersistenceException crash) {
            failure = crash;
        } finally {
            CommandAttemptRuntime.failSettlementForTest = false;
        }
        Database.rollback(job);
        Database.releaseSavepoint(job);
        System.assertNotEquals(null, failure, 'The worker must fail its job when it cannot settle.');

        if (replayedAnswer != null) {
            AgentKernelModels.ModelResponse replay = (AgentKernelModels.ModelResponse) JSON.deserialize(replayedAnswer, AgentKernelModels.ModelResponse.class);
            // Apex cannot insert at index 0 of an empty list.
            if (KernelTestModelProvider.script.isEmpty()) {
                KernelTestModelProvider.script.add(replay);
            } else {
                KernelTestModelProvider.script.add(0, replay);
            }
        }
        CommandDeliveryTracker.recordAnomaly(leased.Id, 'WORKER_FAILED');
        CommandLeaseRecoveryService.recoverFailedWorker(leased.Id, leased.LeaseToken__c);
    }

    /** What an operator does after checking the outside system: the call did happen. */
    private static void reconcileAsSucceeded(AgentRun__c run) {
        AgentCommand__c unknown = [
            SELECT Id, OperationKey__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :run.Id AND Status__c = :AgentKernelModels.COMMAND_STATUS_UNKNOWN
            WITH SYSTEM_MODE
        ];
        AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
        request.runId = run.Id;
        request.commandId = unknown.Id;
        request.expectedRunRevision = run.Revision__c;
        request.operationKey = unknown.OperationKey__c;
        request.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
        request.confirmedOutput = '{"done":true}';
        request.reason = 'Checked the case: the action was applied.';
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        AgentRunService.reconcileUnknownOutcome(request);
    }
}
