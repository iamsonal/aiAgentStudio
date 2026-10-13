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
private class DeliveryBudgetRemediationTest {
    @IsTest
    static void undeliverableOrphanPausesAndNoLongerBlocksHealthyWork() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult stuck = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.StartResult healthy = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        Datetime past = System.now().addMinutes(-30);
        AgentKernelTestFactory.updateRecords(
            new List<AgentCommand__c>{
                new AgentCommand__c(Id = stuck.commandId, AvailableAt__c = past),
                new AgentCommand__c(Id = healthy.commandId, AvailableAt__c = past.addMinutes(1))
            }
        );
        // The stuck command was already redispatched the maximum number of times.
        AgentKernelTestFactory.updateRecord(
            new AgentCommand__c(Id = stuck.commandId, RedispatchCount__c = CommandLeaseRecoveryService.MAXIMUM_REDISPATCHES, DispatchDueAt__c = past)
        );
        CommandDeliveryTracker.suppressEnqueueForTest = true;

        Integer queriesBefore = Limits.getQueries();
        CommandLeaseRecoveryService.RecoveryResult result = CommandLeaseRecoveryService.recoverOperational(10);
        System.assert(Limits.getQueries() - queriesBefore <= 40, 'Recovery stays within a fixed query budget.');

        System.assertEquals(1, result.paused);
        System.assertEquals(1, result.orphanRedispatched);
        AgentRun__c stuckRun = AgentKernelTestFactory.getRun(stuck.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, stuckRun.Status__c);
        System.assertEquals(AgentKernelRecovery.DISPATCH_UNDELIVERABLE, stuckRun.ErrorCode__c);
        System.assertEquals(stuck.commandId, stuckRun.CurrentCommand__c, 'The command never ran, so it stays queued for rescue.');
        AgentCommand__c stuckCommand = AgentKernelTestFactory.getCommand(stuck.commandId);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, stuckCommand.Status__c);
        System.assertEquals(stuckRun.Revision__c, stuckCommand.ExpectedRunRevision__c);

        AgentCommand__c healthyCommand = [
            SELECT Status__c, RecoveryCheckAt__c
            FROM AgentCommand__c
            WHERE Id = :healthy.commandId
            WITH SYSTEM_MODE
        ];
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_LEASED, healthyCommand.Status__c, 'Recovery leases the orphan in its own pass.');
        System.assertNotEquals(null, healthyCommand.RecoveryCheckAt__c, 'Lease recovery now watches it.');

        CommandLeaseRecoveryService.RecoveryResult next = CommandLeaseRecoveryService.recoverOperational(10);
        System.assertEquals(0, next.orphanRedispatched, 'The backoff keeps the same command from taking every pass.');
    }

    @IsTest
    static void rescueRequeuesAnUndeliverableCommandWithAFreshCount() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentKernelModels.StartResult stuck = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
            Datetime past = System.now().addMinutes(-30);
            AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = stuck.commandId, AvailableAt__c = past));
            AgentKernelTestFactory.updateRecord(
                new AgentCommand__c(Id = stuck.commandId, RedispatchCount__c = CommandLeaseRecoveryService.MAXIMUM_REDISPATCHES, DispatchDueAt__c = past)
            );
            System.assertEquals(1, AgentKernelRecovery.pauseUndeliverableCommands(new List<Id>{ stuck.commandId }, System.now()));
            AgentRun__c run = AgentKernelTestFactory.getRun(stuck.runId);

            AgentKernelModels.RescueRequest rescue = new AgentKernelModels.RescueRequest();
            rescue.runId = run.Id;
            rescue.expectedRunRevision = run.Revision__c;
            System.assertEquals(stuck.commandId, AgentKernel.rescue(rescue));

            AgentCommand__c command = [SELECT RedispatchCount__c, DispatchDueAt__c FROM AgentCommand__c WHERE Id = :stuck.commandId WITH SYSTEM_MODE];
            System.assertEquals(0, command.RedispatchCount__c);
            System.assert(command.DispatchDueAt__c > System.now());
        }
    }

    @IsTest
    static void refusedLoopbackIsRecordedWithoutARetry() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        Test.setMock(HttpCalloutMock.class, new StatusMock(403));

        Test.startTest();
        System.enqueueJob(
            new ServicePrincipalDispatchQueueable(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                command.DispatchToken__c,
                AgentKernelTestFactory.TEST_LOOPBACK
            )
        );
        Test.stopTest();

        AgentCommand__c after = AgentKernelTestFactory.getCommand(started.commandId);
        System.assertEquals('DISPATCH_REFUSED_403', after.DeliveryAnomalyCode__c);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, after.Status__c);
    }

    @IsTest
    static void tokenCeilingPausesBeforeTheNextModelCall() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(10, 10);
        definition.MaxTotalTokens__c = 1000;
        AgentKernelTestFactory.updateRecord(definition);
        AgentConfigService.clearCacheForTest();
        AgentKernelTestFactory.createTool(definition.Id, 'first_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelModels.CommandOutcome modelOutcome = AgentKernelModels.continueWith(
            started.runId,
            started.commandId,
            started.revision,
            started.operationKey,
            null,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{"step":1}', 'first_tool')
        );
        modelOutcome.totalTokens = 1500;
        AgentKernelTestFactory.applyOutcome(modelOutcome);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c tool = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);

        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                run.Id,
                tool.Id,
                run.Revision__c,
                tool.OperationKey__c,
                '{"ok":true}',
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, '{"ok":true}', null)
            )
        );

        run = AgentKernelTestFactory.getRun(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assert(run.ErrorMessage__c.contains('Max Total Tokens'), run.ErrorMessage__c);
    }

    @IsTest
    static void tokenCeilingOutsideTheSupportedRangeIsReported() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.updateRecord(new AgentDefinition__c(Id = definition.Id, MaxTotalTokens__c = 10));
        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.definitionId = definition.Id;
        AgentConfigurationValidationService.ValidationReport report = AgentConfigurationValidationService.validate(request);
        Set<String> codes = new Set<String>();
        for (AgentConfigurationValidationService.ValidationIssue issue : report.issues) {
            codes.add(issue.code);
        }
        System.assert(codes.contains('MAX_TOTAL_TOKENS_INVALID'), 'Max Total Tokens below 1,000 is a configuration error: ' + codes);
    }

    @IsTest
    static void runReaderGetsTheAnswerWithTokensWithoutTrustResolver() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, 'safe input');
        TrustService.ProtectionContext context = TrustService.open(started.runId);
        String protectedOutput = TrustService.protect(context, '{"result":"person@example.com"}');
        TrustService.save(context);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, protectedOutput)
        );
        AgentRunResultAction.Request request = new AgentRunResultAction.Request();
        request.runId = started.runId;

        // A fresh user: the org's admin may already hold Trust Resolver. Sharing the run makes it readable to them.
        User reader = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        AgentKernelTestFactory.insertRecord(new AgentRun__Share(ParentId = started.runId, UserOrGroupId = reader.Id, AccessLevel = 'Read'));
        System.runAs(reader) {
            System.assert(!TrustService.isFinalOutputResolutionPermitted(), 'The reader must not hold Trust Resolver.');
            AgentRunResultAction.Result result = AgentRunResultAction.getResult(new List<AgentRunResultAction.Request>{ request })[0];
            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, result.status);
            System.assertEquals(null, result.errorMessage);
            System.assertEquals(protectedOutput, result.output);
            System.assert(result.output.contains('{{EMAIL_'), 'The protected value stays a token.');
            System.assert(!result.output.contains('person@example.com'));
        }
    }

    @IsTest
    static void agentModelOutputCapReachesTheAdapter() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentModel__mdt model = AgentKernelTestFactory.kernelTestModel();
        model.MaxOutputTokens__c = 12000;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ model });
        KernelTestModelProvider.mode = 'final';
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(started.commandId);
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(
            started.runId,
            command.Id,
            started.revision,
            command.OperationKey__c,
            command.DispatchToken__c
        );
        System.assertEquals(CommandLeaseService.Outcome.Leased, lease.outcome);
        AgentCommand__c leased = AgentKernelTestFactory.getCommand(command.Id);

        AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = leased.Id, WorkerEnqueuedAt__c = System.now().addSeconds(-3)));

        new ModelCommandQueueable(started.runId, leased.Id, leased.ExpectedRunRevision__c, leased.OperationKey__c, leased.LeaseToken__c).execute(null);

        Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(KernelTestModelProvider.lastRequestJson);
        System.assertEquals(12000, sent.get('maxOutputTokens'));
        Boolean recordedQueueWait = false;
        for (AgentEvent__c event : AgentKernelTestFactory.getEvents(started.runId)) {
            Map<String, Object> payload = String.isBlank(event.Payload__c) || !event.Payload__c.startsWith('{')
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(event.Payload__c);
            if (payload.get('queueWaitMs') != null) {
                recordedQueueWait = Decimal.valueOf(String.valueOf(payload.get('queueWaitMs'))) >= 2000;
            }
        }
        System.assert(recordedQueueWait, 'The model outcome records how long the worker waited in the queue.');
    }

    @IsTest
    static void recordRetentionDeletesABatchWithFixedDml() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentExecutionPolicyService.Policy policy = AgentKernelTestFactory.executionPolicyOverride();
            policy.payloadRetentionDays = 0;
            policy.recordRetentionDays = 0;
            AgentKernelTestFactory.configureExecutionPolicy(policy);
            Set<Id> runIds = new Set<Id>();
            for (Integer index = 0; index < 3; index++) {
                AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
                AgentKernel.cancel(started.runId, started.revision, 'Finished for retention.');
                runIds.add(started.runId);
            }
            PayloadRetentionPurgeService.purge(10);

            Integer dmlBefore = Limits.getDmlStatements();
            PayloadRetentionPurgeService.DeletionResult result = PayloadRetentionPurgeService.deleteExpiredRecords(10);
            Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

            System.assertEquals(3, result.runsDeleted);
            System.assertEquals(0, result.runsBlocked);
            System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE Id IN :runIds WITH SYSTEM_MODE]);
            System.assert(dmlUsed <= 6, 'The batch is deleted together, not one run at a time: ' + dmlUsed);
        }
    }

    private class StatusMock implements HttpCalloutMock {
        private final Integer status;

        StatusMock(Integer status) {
            this.status = status;
        }

        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody('{"code":"DISPATCH_PRINCIPAL_REFUSED"}');
            return response;
        }
    }
}
