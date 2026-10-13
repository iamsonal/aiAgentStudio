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

/** Reference scenario 9: an outside system answers a waiting tool with the key the tool handed out, and nothing more. */
@IsTest
private class AgentResumeWaitTest {
    private static final String RESUME_SCHEMA = '{"type":"object","properties":{"status":{"type":"string"}},"required":["status"],"additionalProperties":false}';

    @IsTest
    static void outsideSystemResumesTheWaitWithoutRunControl() {
        // The resumed step reaches the execution user through Core's loopback.
        Test.setMock(HttpCalloutMock.class, new AcceptedLoopback());
        WaitingTool waiting = delegatedToolWait();
        User integration = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });

        List<AgentResumeWaitAction.Result> results;
        Test.startTest();
        System.runAs(integration) {
            System.assertEquals(false, ExecutionIdentityService.canReconcile(), 'The integration user holds no Run Control.');
            results = AgentResumeWaitAction.resume(new List<AgentResumeWaitAction.Request>{ request(waiting.resumeKey, '{"status":"paid"}') });
        }
        Test.stopTest();

        System.assertEquals(null, results[0].errorMessage, 'The key alone resumes the wait.');
        System.assertEquals(true, results[0].resumed);
        AgentRun__c run = AgentKernelTestFactory.getRun(waiting.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c);
        AgentEvent__c resumed = [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :run.Id AND EventType__c = :AgentKernelModels.EVENT_RUN_RESUMED
            WITH SYSTEM_MODE
        ];
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(resumed.Payload__c);
        System.assertEquals(true, payload.get('resumedWithKey'));
        System.assertEquals(String.valueOf(integration.Id), payload.get('actorId'));

        System.runAs(integration) {
            results = AgentResumeWaitAction.resume(new List<AgentResumeWaitAction.Request>{ request(waiting.resumeKey, '{"status":"paid"}') });
        }
        System.assertEquals(false, results[0].resumed, 'A used key cannot resume the run again.');
    }

    @IsTest
    static void anyOtherKeyIsRefused() {
        WaitingTool waiting = delegatedToolWait();
        String otherCallKey = AgentKernel.resumeKey(waiting.runId, waiting.runId + ':1:Model');
        String forged = waiting.runId + '.' + 'ab'.repeat(32);

        List<AgentResumeWaitAction.Result> results;
        System.runAs(AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' })) {
            results = AgentResumeWaitAction.resume(
                new List<AgentResumeWaitAction.Request>{
                    request(otherCallKey, '{"status":"paid"}'),
                    request(forged, '{"status":"paid"}'),
                    request('not-a-key', '{"status":"paid"}'),
                    request(waiting.resumeKey, '{"amount":10}')
                }
            );
        }

        System.assert(results[0].errorMessage.contains('not valid'), results[0].errorMessage);
        System.assert(results[1].errorMessage.contains('not valid'), results[1].errorMessage);
        System.assert(results[2].errorMessage.contains('not valid'), results[2].errorMessage);
        System.assert(results[3].errorMessage.contains('resume schema') || results[3].errorMessage.contains('configured schema'), results[3].errorMessage);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(waiting.runId).Status__c);
    }

    @IsTest
    static void initiatingUserRunResumesOnlyForItsStarter() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'payment_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        WaitingTool waiting = waitOnTool(started);

        List<AgentResumeWaitAction.Result> results;
        System.runAs(AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' })) {
            results = AgentResumeWaitAction.resume(new List<AgentResumeWaitAction.Request>{ request(waiting.resumeKey, '{"status":"paid"}') });
        }
        System.assert(results[0].errorMessage.contains('Only the person who started this run can resume it'), results[0].errorMessage);

        results = AgentResumeWaitAction.resume(new List<AgentResumeWaitAction.Request>{ request(waiting.resumeKey, '{"status":"paid"}') });
        System.assertEquals(true, results[0].resumed, 'Starter resume failed: ' + results[0].errorMessage);
    }

    private static WaitingTool delegatedToolWait() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(definition.Id, 'payment_tool', '{"type":"object"}');
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        return waitOnTool(started);
    }

    private static WaitingTool waitOnTool(AgentKernelModels.StartResult started) {
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', 'payment_tool')
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        AgentKernelModels.CommandOutcome wait = AgentKernelModels.waitForResume(run.Id, tool.Id, run.Revision__c, tool.OperationKey__c, '{"status":"pending"}');
        wait.waitingReason = 'Waiting for the payment provider.';
        wait.resumeJsonSchema = RESUME_SCHEMA;
        wait.waitExpiresAt = System.now().addHours(1);
        wait.continuationMode = AgentKernelModels.CONTINUATION_MODEL;
        AgentKernelTestFactory.applyOutcome(wait);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, AgentKernelTestFactory.getRun(run.Id).Status__c);
        WaitingTool result = new WaitingTool();
        result.runId = run.Id;
        result.resumeKey = AgentKernel.resumeKey(run.Id, tool.OperationKey__c);
        return result;
    }

    private static AgentResumeWaitAction.Request request(String resumeKey, String payload) {
        AgentResumeWaitAction.Request request = new AgentResumeWaitAction.Request();
        request.resumeKey = resumeKey;
        request.payload = payload;
        return request;
    }

    private class AcceptedLoopback implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(202);
            response.setBody('{}');
            return response;
        }
    }

    private class WaitingTool {
        Id runId;
        String resumeKey;
    }
}
