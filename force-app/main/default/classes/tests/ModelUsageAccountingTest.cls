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

/** Every model attempt counts toward the run's token ceiling, even one that times out without reporting usage. */
@IsTest
private class ModelUsageAccountingTest {
    @IsTest
    static void timedOutAttemptCountsItsEstimatedInput() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5, 3);
        KernelTestModelProvider.mode = 'timeout';
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, 'Summarize the open cases. '.repeat(40));

        AgentRun__c run = AgentKernelTestFactory.runSteps(started.runId, 1);

        AgentRun__c counted = [SELECT TotalTokenCount__c, InputTokenCount__c, UnmeteredModelAttempts__c FROM AgentRun__c WHERE Id = :run.Id WITH SYSTEM_MODE];
        System.assert(counted.TotalTokenCount__c > 0, 'A timed-out request was still sent, so its input counts.');
        System.assertEquals(counted.TotalTokenCount__c, counted.InputTokenCount__c);
        System.assertEquals(1, counted.UnmeteredModelAttempts__c);
        AgentEvent__c retry = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :run.Id AND EventType__c = :AgentKernelModels.EVENT_COMMAND_RETRY_SCHEDULED
            WITH SYSTEM_MODE
        ];
        System.assert(retry.Payload__c.contains('"tokensEstimated":true'), retry.Payload__c);
    }

    @IsTest
    static void reportedUsageIsNotEstimated() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5, 3);
        KernelTestModelProvider.mode = 'retry';
        KernelTestModelProvider.inputTokens = 120;
        KernelTestModelProvider.totalTokens = 120;
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        AgentRun__c run = AgentKernelTestFactory.runSteps(started.runId, 1);

        AgentRun__c counted = [SELECT TotalTokenCount__c, UnmeteredModelAttempts__c FROM AgentRun__c WHERE Id = :run.Id WITH SYSTEM_MODE];
        System.assertEquals(120, counted.TotalTokenCount__c);
        System.assertEquals(0, counted.UnmeteredModelAttempts__c);
    }

    @IsTest
    static void retriesStopAtTheTokenCeiling() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 5, 3);
        AgentKernelTestFactory.updateRecord(new AgentDefinition__c(Id = definition.Id, MaxTotalTokens__c = 1000));
        AgentConfigService.clearCacheForTest();
        KernelTestModelProvider.mode = 'timeout';
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, 'x'.repeat(6000));

        AgentRun__c run = AgentKernelTestFactory.runSteps(started.runId, 1);

        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c, 'The run pauses instead of calling the model again.');
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assertEquals(1, KernelTestModelProvider.invocationCount);
        AgentCommand__c retry = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        System.assertEquals(
            AgentKernelModels.COMMAND_STATUS_RETRY_WAITING,
            retry.Status__c,
            'Rescue continues the same model call once the ceiling is raised.'
        );
        AgentKernelTestFactory.assertLifecycleInvariants(run.Id);
    }
}
