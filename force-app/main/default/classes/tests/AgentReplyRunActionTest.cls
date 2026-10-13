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

/** Reference scenario 4: a person replies to a conversational run from Flow without Apex or revisions. */
@IsTest
private class AgentReplyRunActionTest {
    @IsTest
    static void starterRepliesToAWaitingConversation() {
        AgentKernelModels.StartResult started = waitingConversation();

        List<AgentReplyRunAction.Result> results = AgentReplyRunAction.reply(
            new List<AgentReplyRunAction.Request>{ request(started.runId, 'What happens next?') }
        );

        System.assertEquals(null, results[0].errorMessage);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, results[0].status);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c reply = [SELECT InputSource__c FROM AgentCommand__c WHERE Id = :run.CurrentCommand__c WITH SYSTEM_MODE];
        System.assertEquals(AgentKernelModels.INPUT_SOURCE_HUMAN_RESPONSE, reply.InputSource__c);
    }

    @IsTest
    static void someoneWhoCannotSeeTheRunIsRefused() {
        AgentKernelModels.StartResult started = waitingConversation();
        Decimal revision = AgentKernelTestFactory.getRun(started.runId).Revision__c;

        List<AgentReplyRunAction.Result> results;
        System.runAs(AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' })) {
            results = AgentReplyRunAction.reply(new List<AgentReplyRunAction.Request>{ request(started.runId, 'Let me in.') });
        }

        System.assertNotEquals(null, results[0].errorMessage, 'A person who cannot see the run cannot reply to it.');
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
        System.assertEquals(revision, run.Revision__c);
    }

    @IsTest
    static void aRunThatIsNotAConversationExplainsWhy() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);

        List<AgentReplyRunAction.Result> results = AgentReplyRunAction.reply(
            new List<AgentReplyRunAction.Request>{ request(started.runId, 'Hello?'), request(started.runId, ' ') }
        );

        System.assert(results[0].errorMessage.contains('Wait for Reply'), results[0].errorMessage);
        System.assert(results[1].errorMessage.contains('Enter the message'), results[1].errorMessage);
    }

    private static AgentKernelModels.StartResult waitingConversation() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ReplyWindowHours__c = 24;
        AgentKernelTestFactory.updateRecord(definition);
        AgentConfigService.clearCacheForTest();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, '{"answer":"Done."}')
        );
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(started.runId).Status__c);
        return started;
    }

    private static AgentReplyRunAction.Request request(Id runId, String message) {
        AgentReplyRunAction.Request request = new AgentReplyRunAction.Request();
        request.runId = runId;
        request.message = message;
        return request;
    }
}
