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
private class RecoveryBatchDispatchTest {
    private static String capturedEndpoint;
    private static String capturedBody;

    @IsTest
    static void recoveryUsesOneBoundedLoopbackForMultipleCommands() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult first = AgentKernelTestFactory.start(definition.Id, '{"request":1}');
        AgentKernelModels.StartResult second = AgentKernelTestFactory.start(definition.Id, '{"request":2}');
        Test.setMock(HttpCalloutMock.class, new AcceptedBatchMock());

        Test.startTest();
        Id jobId = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ first.commandId, second.commandId }).jobIds[0];
        System.assertNotEquals(null, jobId);
        System.assertEquals(
            'callout:Agent_Core_Loopback/services/apexrest/agent-core/v1/dispatch-batch',
            ServicePrincipalBatchDispatchQueueable.preparedEndpointForTest
        );
        Map<String, Object> request = (Map<String, Object>) JSON.deserializeUntyped(ServicePrincipalBatchDispatchQueueable.preparedBodyForTest);
        System.assertEquals(2, ((List<Object>) request.get('commands')).size());
        Test.stopTest();
    }

    @IsTest
    static void loopbackBatchValidatesAndEnqueuesEveryEnvelope() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult first = AgentKernelTestFactory.start(definition.Id, '{"request":1}');
        AgentKernelModels.StartResult second = AgentKernelTestFactory.start(definition.Id, '{"request":2}');
        AgentCommand__c firstCommand = AgentKernelTestFactory.getCommand(first.commandId);
        AgentCommand__c secondCommand = AgentKernelTestFactory.getCommand(second.commandId);
        InternalCommandBatchDispatchRest.DispatchRequest request = new InternalCommandBatchDispatchRest.DispatchRequest();
        request.commands = new List<InternalCommandBatchDispatchRest.CommandEnvelope>{ envelope(first, firstCommand), envelope(second, secondCommand) };
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));

        InternalCommandBatchDispatchRest.DispatchResponse response;
        System.runAs(AgentKernelTestFactory.principal(identity)) {
            response = InternalCommandBatchDispatchRest.dispatch();
        }

        System.assertEquals(202, RestContext.response.statusCode);
        System.assertEquals(2, response.accepted);
        System.assertEquals(0, response.skipped);
        Set<Id> runIds = new Set<Id>{ first.runId, second.runId };
        System.assertEquals(2, [SELECT COUNT() FROM AgentRun__c WHERE Id IN :runIds AND ExecutionContextStatus__c = 'Established']);
    }

    @IsTest
    static void mixedIdentityBatchAcceptsEveryCurrentCommand() {
        AgentDefinition__c initiatorDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult initiator = AgentKernelTestFactory.start(initiatorDefinition.Id, '{"request":"initiator"}');
        AgentDefinition__c serviceDefinition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(serviceDefinition);
        AgentKernelModels.StartResult service = AgentKernelTestFactory.start(serviceDefinition.Id, '{"request":"service"}');
        Test.setMock(HttpCalloutMock.class, new AcceptedBatchMock());

        // A test cannot call out after DML, so the current-user command, which is leased here, is dispatched before the loopback batch.
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        CommandDispatcher.BatchDispatchResult direct = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ initiator.commandId });
        CommandDeliveryTracker.suppressEnqueueForTest = false;
        Test.startTest();
        CommandDispatcher.BatchDispatchResult loopback = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ service.commandId });
        Test.stopTest();

        System.assertEquals(new Set<Id>{ initiator.commandId }, direct.acceptedCommandIds);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(initiator.commandId).Status__c);
        System.assertEquals(new Set<Id>{ service.commandId }, loopback.acceptedCommandIds);
        System.assertEquals(1, loopback.jobIds.size());
    }

    @IsTest
    static void fullLoopbackBatchUsesConstantGovernorBudget() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.SERVICE_PRINCIPAL });
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        // The runs below expect the running user; the identity record only marks them as runs with an identity.
        Id identityId = AgentKernelTestFactory.serviceUser(AgentKernelTestFactory.servicePrincipalUser().Id, 'Agent_Core_Loopback').Id;
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Integer index = 0; index < 25; index++) {
            runs.add(
                new AgentRun__c(
                    AgentDefinition__c = definition.Id,
                    InitiatingUser__c = UserInfo.getUserId(),
                    ExecutionIdentity__c = identityId,
                    LoopbackNamedCredential__c = 'Agent_Core_Loopback',
                    ExpectedPrincipalUser__c = UserInfo.getUserId(),
                    ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_PENDING,
                    Status__c = AgentKernelModels.RUN_STATUS_RUNNING,
                    Revision__c = 0,
                    StartedAt__c = System.now(),
                    LastActivityAt__c = System.now()
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
                    Status__c = AgentKernelModels.COMMAND_STATUS_PENDING,
                    ExpectedRunRevision__c = 1,
                    OperationKey__c = 'batch-governor-' + index,
                    DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
                    AttemptNumber__c = 0,
                    AvailableAt__c = System.now()
                )
            );
        }
        AgentKernelTestFactory.insertRecords(commands);
        InternalCommandBatchDispatchRest.DispatchRequest request = new InternalCommandBatchDispatchRest.DispatchRequest();
        request.commands = new List<InternalCommandBatchDispatchRest.CommandEnvelope>();
        for (Integer index = 0; index < runs.size(); index++) {
            runs[index].CurrentCommand__c = commands[index].Id;
            runs[index].Revision__c = 1;
            AgentKernelModels.StartResult started = new AgentKernelModels.StartResult();
            started.runId = runs[index].Id;
            started.commandId = commands[index].Id;
            started.revision = 1;
            started.operationKey = commands[index].OperationKey__c;
            request.commands.add(envelope(started, commands[index]));
        }
        AgentKernelTestFactory.updateRecords(runs);
        RestContext.request = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(request));

        InternalCommandBatchDispatchRest.DispatchResponse response;
        Integer queriesUsed;
        Integer dmlUsed;
        System.runAs(AgentKernelTestFactory.self()) {
            Test.startTest();
            CommandDeliveryTracker.suppressEnqueueForTest = true;
            Integer queriesBefore = Limits.getQueries();
            Integer dmlBefore = Limits.getDmlStatements();
            response = InternalCommandBatchDispatchRest.dispatch();
            queriesUsed = Limits.getQueries() - queriesBefore;
            dmlUsed = Limits.getDmlStatements() - dmlBefore;
            CommandDeliveryTracker.suppressEnqueueForTest = false;
            Test.stopTest();
        }

        System.assertEquals(25, response.accepted);
        System.assertEquals(0, response.skipped);
        System.assert(queriesUsed <= 2, 'The full batch should use only the run and command lock queries.');
        System.assert(dmlUsed <= 2, 'The full batch should update runs and commands in bulk.');
        Set<Id> commandIds = new Map<Id, AgentCommand__c>(commands).keySet();
        System.assertEquals(25, [SELECT COUNT() FROM AgentCommand__c WHERE Id IN :commandIds AND Status__c = 'Leased']);
    }

    @IsTest
    static void currentUserCommandLeasesInTheDispatchingTransaction() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"request":"bulk"}');
        CommandDeliveryTracker.suppressEnqueueForTest = true;

        CommandDispatcher.BatchDispatchResult result = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ started.commandId });

        System.assertEquals(new Set<Id>{ started.commandId }, result.acceptedCommandIds);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelTestFactory.getCommand(started.commandId).Status__c);
        System.assertEquals(0, Limits.getQueueableJobs(), 'No lease Queueable runs before the worker.');
    }

    @IsTest
    static void currentUserCommandsBeyondQueueableCapacityStayUnleased() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<Id> commandIds = new List<Id>();
        for (Integer index = 0; index < 3; index++) {
            commandIds.add(AgentKernelTestFactory.start(definition.Id, '{"request":' + index + '}').commandId);
        }
        while (Limits.getQueueableJobs() < Limits.getLimitQueueableJobs() - 1) {
            System.enqueueJob(new NoOpJob());
        }

        CommandDispatcher.BatchDispatchResult result = CommandDispatcher.dispatchBatchDetailed(commandIds);

        System.assertEquals(1, result.acceptedCommandIds.size());
        System.assertEquals(2, result.deferredCommandIds.size());
        for (AgentCommand__c command : [SELECT Status__c, LeaseToken__c, DeliveryAnomalyCode__c FROM AgentCommand__c WHERE Id IN :result.deferredCommandIds]) {
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, command.Status__c);
            System.assertEquals(null, command.LeaseToken__c);
            System.assertEquals('CAPACITY_DEFERRED', command.DeliveryAnomalyCode__c);
        }
    }

    @IsTest
    static void repeatedBatchDispatchLeasesOnce() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"request":"race"}');
        CommandDeliveryTracker.suppressEnqueueForTest = true;

        CommandDispatcher.BatchDispatchResult first = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ started.commandId });
        CommandDispatcher.BatchDispatchResult second = CommandDispatcher.dispatchBatchDetailed(new List<Id>{ started.commandId });

        System.assertEquals(new Set<Id>{ started.commandId }, first.acceptedCommandIds);
        System.assertEquals(new Set<Id>{ started.commandId }, second.skippedCommandIds);
        System.assertEquals(1, AgentKernelTestFactory.getCommand(started.commandId).AttemptNumber__c);
    }

    private class NoOpJob implements Queueable {
        public void execute(QueueableContext context) {
        }
    }

    private static InternalCommandBatchDispatchRest.CommandEnvelope envelope(AgentKernelModels.StartResult started, AgentCommand__c command) {
        InternalCommandBatchDispatchRest.CommandEnvelope result = new InternalCommandBatchDispatchRest.CommandEnvelope();
        result.runId = started.runId;
        result.commandId = started.commandId;
        result.expectedRevision = started.revision;
        result.operationKey = started.operationKey;
        result.dispatchToken = command.DispatchToken__c;
        return result;
    }

    private class AcceptedBatchMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            capturedEndpoint = request.getEndpoint();
            capturedBody = request.getBody();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(202);
            return response;
        }
    }
}
