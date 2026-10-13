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
private class RunCorrelationApiTest {
    @IsTest
    static void globalApisStartObserveAndResumeCorrelatedRun() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        Account anchor = new Account(Name = 'Correlated run anchor');
        insert anchor;
        AgentKernelModels.StartResult parent = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.developerName = definition.DeveloperName__c;
        request.input = '{"request":"correlated"}';
        request.anchorRecordId = anchor.Id;
        request.parentRunId = parent.runId;
        request.externalCorrelationKey = 'case-00042';

        Test.startTest();
        AgentKernelModels.StartResult child = AgentRunService.start(request);
        AgentKernelModels.RunRecord observed = AgentTraceService.getRun(child.runId);
        System.assertEquals(parent.runId, child.parentRunId);
        System.assertEquals(anchor.Id, child.anchorRecordId);
        System.assertEquals('case-00042', child.externalCorrelationKey);
        System.assertEquals(parent.runId, observed.parentRunId);
        System.assertEquals(anchor.Id, observed.anchorRecordId);
        System.assertEquals('case-00042', observed.externalCorrelationKey);

        AgentKernelModels.CommandOutcome waiting = AgentKernelModels.waitForResume(
            child.runId,
            child.commandId,
            child.revision,
            child.operationKey,
            '{"waiting":true}'
        );
        AgentKernelTestFactory.applyOutcome(waiting);
        AgentKernelModels.RunRecord waitingRun = AgentRunService.getRun(child.runId);
        Id resumedCommandId = AgentRunService.resume(AgentKernelTestFactory.resumeRequest(child.runId, waitingRun.revision, '{"resume":true}'));

        AgentKernelModels.RunRecord resumed = AgentTraceService.getRun(child.runId);
        System.assertNotEquals(null, resumedCommandId);
        System.assertEquals(parent.runId, resumed.parentRunId);
        System.assertEquals(anchor.Id, resumed.anchorRecordId);
        System.assertEquals('case-00042', resumed.externalCorrelationKey);
        Test.stopTest();
    }

    @IsTest
    static void startRequestRequiresExactlyOneDefinitionSelector() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.developerName = definition.DeveloperName__c;
        request.input = '{}';

        try {
            AgentRunService.start(request);
            System.assert(false, 'Expected ambiguous definition selectors to fail.');
        } catch (AgentKernelException.InvalidTransitionException expected) {
            System.assert(expected.getMessage().contains('exactly one'));
        }
    }

    @IsTest
    static void repeatedIdenticalCorrelationReturnsOriginalStartResult() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.input = '{"request":"same"}';
        request.externalCorrelationKey = 'idempotent-case-42';

        AgentKernelModels.StartResult first = AgentRunService.start(request);
        AgentKernelModels.StartResult duplicate = AgentRunService.start(request);

        System.assertEquals(first.runId, duplicate.runId);
        System.assertEquals(first.commandId, duplicate.commandId);
        System.assertEquals(first.operationKey, duplicate.operationKey);
        System.assertEquals(true, duplicate.deduplicated);
        System.assertEquals(1, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
        System.assertEquals(1, [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :first.runId]);
    }

    @IsTest
    static void repeatedCorrelationWithDifferentRequestFailsClosed() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.input = '{"request":"first"}';
        request.externalCorrelationKey = 'conflicting-case-42';
        AgentRunService.start(request);
        request.input = '{"request":"different"}';

        try {
            AgentRunService.start(request);
            System.assert(false, 'Expected a correlation conflict.');
        } catch (AgentKernelException.CorrelationConflictException expected) {
            System.assert(expected.getMessage().contains('different start request'));
        }
    }

    @IsTest
    static void repeatedCorrelationWithDifferentAnchorFailsClosed() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<Account> anchors = new List<Account>{ new Account(Name = 'First anchor'), new Account(Name = 'Second anchor') };
        insert anchors;
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.input = '{"request":"same"}';
        request.anchorRecordId = anchors[0].Id;
        request.externalCorrelationKey = 'anchor-conflict-42';
        AgentRunService.start(request);
        request.anchorRecordId = anchors[1].Id;

        try {
            AgentRunService.start(request);
            System.assert(false, 'Expected a correlation conflict for a different anchor.');
        } catch (AgentKernelException.CorrelationConflictException expected) {
            System.assert(expected.getMessage().contains('different start request'));
        }
    }

    @IsTest
    static void sameCorrelationKeyIsIndependentAcrossDefinitions() {
        AgentDefinition__c firstDefinition = AgentKernelTestFactory.createDefinition();
        AgentDefinition__c secondDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartRequest firstRequest = new AgentKernelModels.StartRequest();
        firstRequest.definitionId = firstDefinition.Id;
        firstRequest.input = '{}';
        firstRequest.externalCorrelationKey = 'shared-business-key';
        AgentKernelModels.StartRequest secondRequest = new AgentKernelModels.StartRequest();
        secondRequest.definitionId = secondDefinition.Id;
        secondRequest.input = '{}';
        secondRequest.externalCorrelationKey = 'shared-business-key';

        AgentKernelModels.StartResult first = AgentRunService.start(firstRequest);
        AgentKernelModels.StartResult second = AgentRunService.start(secondRequest);

        System.assertNotEquals(first.runId, second.runId);
        System.assertEquals(false, second.deduplicated);
    }
}
