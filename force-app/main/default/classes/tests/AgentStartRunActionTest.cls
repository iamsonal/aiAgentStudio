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

/** Bulk Flow starts (scenario 5): failures stay per request, limits hold at 200 requests, and a lost continuation is reported. */
@IsTest
private class AgentStartRunActionTest {
    @IsTest
    static void failedContinuationRetriesThenReportsTheLoss() {
        List<AgentKernelModels.StartRequest> pending = new List<AgentKernelModels.StartRequest>{
            new AgentKernelModels.StartRequest(),
            new AgentKernelModels.StartRequest()
        };
        Test.startTest();
        new AgentStartRunAction.StartFinalizer(pending, null, 0).execute(new Outcome(ParentJobResult.UNHANDLED_EXCEPTION));
        System.assertEquals(0, Limits.getPublishImmediateDML(), 'An early failure is retried, not reported.');
        new AgentStartRunAction.StartFinalizer(pending, null, AgentStartRunAction.MAX_CONTINUATION_ATTEMPTS - 1)
            .execute(new Outcome(ParentJobResult.UNHANDLED_EXCEPTION));
        System.assertEquals(1, Limits.getPublishImmediateDML(), 'The last failed attempt publishes FLOW_START_LOST.');
        new AgentStartRunAction.StartFinalizer(pending, null, AgentStartRunAction.MAX_CONTINUATION_ATTEMPTS - 1).execute(new Outcome(ParentJobResult.SUCCESS));
        System.assertEquals(1, Limits.getPublishImmediateDML(), 'A successful continuation reports nothing.');
        Test.stopTest();
    }

    @IsTest
    static void eachLostStartNamesItsAgentAndAnchor() {
        Account anchor = new Account(Name = 'Lost start anchor');
        insert anchor;
        AgentKernelModels.StartRequest lost = new AgentKernelModels.StartRequest();
        lost.developerName = 'triage_agent';
        lost.anchorRecordId = anchor.Id;

        List<AgentOperationalSignal__e> signals = AgentStartRunAction.lostStartSignals(
            new List<AgentKernelModels.StartRequest>{ lost, new AgentKernelModels.StartRequest() }
        );

        System.assertEquals(2, signals.size(), 'One signal per lost start.');
        System.assertEquals('FLOW_START_LOST', signals[0].Code__c);
        System.assert(signals[0].ExceptionType__c.contains('triage_agent'), signals[0].ExceptionType__c);
        System.assert(signals[0].ExceptionType__c.contains(String.valueOf(anchor.Id)), signals[0].ExceptionType__c);
    }

    @IsTest
    static void oneFailedStartNeverUndoesTheOthersInTheSameTransaction() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentStartRunAction.StartRequest> requests = new List<AgentStartRunAction.StartRequest>();
        for (Integer index = 0; index < 12; index++) {
            requests.add(request(Math.mod(index, 4) == 1 ? 'missing_agent' : definition.DeveloperName__c, index));
        }

        Test.startTest();
        List<AgentStartRunAction.StartResult> results = AgentStartRunAction.start(requests);
        Test.stopTest();

        Integer started = 0;
        for (Integer index = 0; index < results.size(); index++) {
            AgentStartRunAction.StartResult result = results[index];
            if (Math.mod(index, 4) == 1) {
                System.assertEquals(false, result.started);
                System.assertNotEquals(null, result.errorMessage, 'A missing agent is reported on its own request.');
            } else if (result.started) {
                started++;
            } else {
                System.assert(result.errorMessage.contains('Start fewer'), result.errorMessage);
            }
        }
        System.assert(results[0].started && results[2].started, 'Starts around a failed one stay committed.');
        System.assertEquals(started, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id WITH SYSTEM_MODE]);
    }

    @IsTest
    static void twoHundredMixedRequestsEachGetADeterministicResultWithinLimits() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentStartRunAction.StartRequest> requests = new List<AgentStartRunAction.StartRequest>();
        for (Integer index = 0; index < 200; index++) {
            Integer kind = Math.mod(index, 4);
            String name = kind == 0 ? definition.DeveloperName__c : kind == 1 ? 'missing_agent' : 'distinct_missing_' + index;
            requests.add(request(name, index));
        }

        Test.startTest();
        List<AgentStartRunAction.StartResult> results = AgentStartRunAction.start(requests);
        Integer queries = Limits.getQueries();
        Integer queueables = Limits.getQueueableJobs();
        Test.stopTest();

        System.assertEquals(200, results.size());
        Integer started = 0;
        for (AgentStartRunAction.StartResult result : results) {
            System.assert(result.started || result.queued || result.errorMessage != null, 'Every request has a result.');
            started += result.started ? 1 : 0;
        }
        System.assert(started > 0, 'Healthy starts persist.');
        System.assertEquals(started, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id WITH SYSTEM_MODE]);
        System.assert(queries < Limits.getLimitQueries(), 'Lookups stop while the reserve remains: ' + queries);
        System.assert(queueables <= started + 1, 'One job per started Initiating User run and at most one continuation: ' + queueables);
    }

    @IsTest
    static void bulkStartsReachTheirWorkersInOneHop() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentStartRunAction.StartRequest> requests = new List<AgentStartRunAction.StartRequest>();
        for (Integer index = 0; index < 3; index++) {
            requests.add(request(definition.DeveloperName__c, index));
        }

        Test.startTest();
        List<AgentStartRunAction.StartResult> results = AgentStartRunAction.start(requests);
        Integer queueables = Limits.getQueueableJobs();

        Set<Id> runIds = new Set<Id>();
        for (AgentStartRunAction.StartResult result : results) {
            System.assert(result.started, result.errorMessage);
            runIds.add(result.runId);
        }
        System.assertEquals(3, queueables, 'One worker per run and no lease job before it.');
        System.assertEquals(
            3,
            [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c IN :runIds AND Status__c = 'Leased' AND WorkerJobId__c != NULL WITH SYSTEM_MODE],
            'Each first command is leased in the starting transaction and records its worker job.'
        );
    }

    private static AgentStartRunAction.StartRequest request(String agentName, Integer index) {
        AgentStartRunAction.StartRequest request = new AgentStartRunAction.StartRequest();
        request.agentDeveloperName = agentName;
        request.input = '{"index":' + index + '}';
        return request;
    }

    private class Outcome implements FinalizerContext {
        private final ParentJobResult result;
        Outcome(ParentJobResult result) {
            this.result = result;
        }
        public Id getAsyncApexJobId() {
            return null;
        }
        public Exception getException() {
            return null;
        }
        public String getRequestId() {
            return null;
        }
        public ParentJobResult getResult() {
            return result;
        }
    }
}
