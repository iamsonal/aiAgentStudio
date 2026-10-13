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
 * Reference scenarios 3, 5, 7, 8, 9, 10, and 11 and agent chaining, end to end. Each test scripts the model's decisions,
 * then drives the run through the real model and tool workers, standard
 * tools, approvals, reconciliation, and trust, as dispatch would. Unit tests
 * cover each part; these prove the parts work together.
 */
@IsTest
private class ReferenceScenarioTest {
    private static final String CUSTOMER_EMAIL = 'pat.customer@example.com';
    /** SOQL one command may use, including the driver's one read of the leased command. A step that also runs tools in place may use this much per command it finishes. */
    private static final Integer MAX_QUERIES_PER_STEP = 25;

    /**
     * Scenario 7, first half: gather context, act on a low-risk step, and hold
     * a refund for approval. The model sees the customer's email only as a
     * token, and nothing runs the refund before a person approves it.
     */
    @IsTest
    static void caseResolutionActsOnLowRiskStepsAndHoldsTheRefund() {
        CaseResolution fixture = caseResolution();
        KernelTestModelProvider.scriptToolCall('get_case', '{"caseId":"' + fixture.caseId + '"}');
        KernelTestModelProvider.scriptToolCall('set_priority', '{"recordId":"' + fixture.caseId + '","recordData":{"Priority":"High"}}');
        scriptRefund();

        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(fixture.definition);
        // The first model turn also runs get_case in its own job.
        AgentRun__c run = AgentKernelTestFactory.runSteps(started.runId, 1);
        assertBoundedSteps();
        Test.startTest();
        run = AgentKernelTestFactory.runUntilSettled(run.Id);
        Test.stopTest();

        System.assertEquals(
            AgentKernelModels.RUN_STATUS_WAITING,
            run.Status__c,
            'The refund waits for its approver. ' + run.ErrorCode__c + ': ' + run.ErrorMessage__c
        );
        System.assertEquals('High', [SELECT Priority FROM Case WHERE Id = :fixture.caseId].Priority, 'The low-risk update ran without approval.');
        System.assertEquals(0, KernelTestTool.invocationCount, 'The refund must not run before approval.');
        System.assertEquals(3, run.ModelCallCount__c);
        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(run.Id);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, approval.Status__c);
        System.assertEquals(fixture.approverId, approval.OwnerId);
        assertModelNeverSaw(CUSTOMER_EMAIL);
        assertBoundedSteps();
    }

    /** Scenario 7, second half: the approved refund runs exactly once, then the agent drafts the reply. */
    @IsTest
    static void approvedRefundRunsOnceThenTheAgentDrafts() {
        CaseResolution fixture = caseResolution();
        scriptRefund();
        KernelTestModelProvider.scriptFinal('{"reply":"Your refund is on its way."}');
        AgentRun__c run = waitingForApproval(fixture);

        Test.startTest();
        System.runAs(new User(Id = fixture.approverId)) {
            AgentKernel.decideApproval(
                AgentKernelTestFactory.approvalDecision(AgentKernelTestFactory.pendingApproval(run.Id).Id, true, 'Refund is within policy.')
            );
        }
        run = AgentKernelTestFactory.runUntilSettled(run.Id);
        Test.stopTest();

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        System.assertEquals(1, KernelTestTool.invocationCount, 'The approved refund runs exactly once.');
        System.assertEquals(2, run.ModelCallCount__c);
        System.assertEquals(1, run.ToolCallCount__c);
        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(run.Id);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, approval.Status__c);
        System.assertEquals(fixture.approverId, approval.DecidedBy__c);
        assertBoundedSteps();
        assertEventsInclude(
            run.Id,
            new List<String>{
                AgentKernelModels.EVENT_RUN_STARTED,
                AgentKernelModels.EVENT_RUN_WAITING,
                AgentKernelModels.EVENT_RUN_RESUMED,
                AgentKernelModels.EVENT_TOOL_COMPLETED,
                AgentKernelModels.EVENT_RUN_COMPLETED
            }
        );
    }

    /** Scenario 3: a rejected refund never runs, and the model learns why and answers without it. */
    @IsTest
    static void rejectedRefundNeverRunsAndTheModelIsTold() {
        CaseResolution fixture = caseResolution();
        scriptRefund();
        KernelTestModelProvider.scriptFinal('{"reply":"A colleague will review your refund."}');
        AgentRun__c run = waitingForApproval(fixture);

        Test.startTest();
        System.runAs(new User(Id = fixture.approverId)) {
            AgentKernel.decideApproval(
                AgentKernelTestFactory.approvalDecision(AgentKernelTestFactory.pendingApproval(run.Id).Id, false, 'Over the refund limit.')
            );
        }
        run = AgentKernelTestFactory.runUntilSettled(run.Id);
        Test.stopTest();

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        System.assertEquals(0, KernelTestTool.invocationCount, 'A rejected refund never runs.');
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_REJECTED, AgentKernelTestFactory.pendingApproval(run.Id).Status__c);
        String lastRequest = KernelTestModelProvider.lastRequestJson;
        System.assert(lastRequest.contains(AgentKernelModels.ERROR_TOOL_APPROVAL_DENIED), 'The model is told the call was denied.');
        System.assert(lastRequest.contains('Over the refund limit.'), 'The model sees the approver\'s reason.');
    }

    /**
     * Scenario 9: an external call whose result is uncertain makes the run
     * wait as Unknown. An operator confirms what happened, and the run
     * continues with that result instead of calling again.
     */
    @IsTest
    static void uncertainExternalResultIsReconciledNotRepeated() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.HUMAN_DECISION, AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentTool__c refund = AgentKernelTestFactory.createTool(definition.Id, 'issue_refund', '{"type":"object"}');
            refund.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
            AgentKernelTestFactory.updateRecord(refund);
            KernelTestModelProvider.scriptToolCall('issue_refund', '{}');
            KernelTestModelProvider.scriptFinal('{"reply":"Refund R-77 is confirmed."}');
            KernelTestTool.throwUnexpected = true;

            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentRun__c run = AgentKernelTestFactory.runUntilSettled(started.runId);

            System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c);
            AgentCommand__c unknown = [
                SELECT Id, OperationKey__c, Status__c
                FROM AgentCommand__c
                WHERE AgentRun__c = :run.Id AND CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                WITH SYSTEM_MODE
            ];
            System.assertEquals(AgentKernelModels.COMMAND_STATUS_UNKNOWN, unknown.Status__c);
            KernelTestTool.throwUnexpected = false;

            Test.startTest();
            AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
            request.runId = run.Id;
            request.commandId = unknown.Id;
            request.expectedRunRevision = run.Revision__c;
            request.operationKey = unknown.OperationKey__c;
            request.decision = AgentKernelModels.ReconciliationDecision.ConfirmSucceeded;
            request.confirmedOutput = '{"refundId":"R-77"}';
            request.reason = 'Found refund R-77 in the payment system.';
            AgentRunService.reconcileUnknownOutcome(request);
            run = AgentKernelTestFactory.runUntilSettled(run.Id);
            Test.stopTest();

            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
            System.assertEquals(1, KernelTestTool.invocationCount, 'Core never repeats a call whose effect may have happened.');
            System.assert(KernelTestModelProvider.lastRequestJson.contains('R-77'), 'The model continues with the confirmed result.');
            assertEventsInclude(run.Id, new List<String>{ AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN, AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED });
        }
    }

    /**
     * A chain step that automation starts keeps the person limit of the run
     * it continues. The person starts a triage agent but cannot edit the
     * case, so the updater that automation starts next cannot edit it for them.
     */
    @IsTest
    static void chainedStepCannotDoWhatThePersonCannot() {
        AgentDefinition__c triage = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(triage);
        AgentDefinition__c updater = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(updater);
        Id caseId = insertCase();
        standardTool(updater.Id, 'set_priority', 'UpdateRecord', '{"objectApiName":"Case","fields":["Priority"]}');
        User person = personWithoutCaseAccess();
        AgentKernelModels.StartResult parent;
        AttendedAccessService.attendedForTest = true;
        System.runAs(person) {
            parent = AgentKernelTestFactory.startRunWithoutDispatch(triage);
        }
        KernelTestModelProvider.scriptToolCall('set_priority', '{"recordId":"' + caseId + '","recordData":{"Priority":"High"}}');
        KernelTestModelProvider.scriptFinal('{"reply":"I could not change the priority."}');

        Test.startTest();
        // A platform-event flow on the triage run's success starts the next step as automation.
        AttendedAccessService.attendedForTest = false;
        AgentKernelModels.StartRequest next = AgentKernelTestFactory.startRequest(updater, 'Raise the case priority.');
        next.parentRunId = parent.runId;
        AgentKernelModels.StartResult chained = AgentRunService.startWithoutDispatch(next, AgentKernelModels.INVOCATION_FLOW);
        AgentRun__c run = AgentKernelTestFactory.runUntilSettled(chained.runId);
        Test.stopTest();

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        System.assertEquals(person.Id, [SELECT AttendedBy__c FROM AgentRun__c WHERE Id = :run.Id WITH SYSTEM_MODE].AttendedBy__c);
        System.assertEquals('Low', [SELECT Priority FROM Case WHERE Id = :caseId].Priority, 'The chain must not edit what the person cannot.');
        System.assert(KernelTestModelProvider.lastRequestJson.contains('cannot edit this record'), 'The model learns why the update failed.');
        assertBoundedSteps();
    }

    /**
     * Scenario 5: unattended work across many records. Automation starts one
     * run per case; a bad record fails alone, and one run the provider
     * rejects pauses without stalling the others.
     */
    @IsTest
    static void bulkAutomationIsolatesEachBadRecord() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AttendedAccessService.attendedForTest = false;
        List<Id> caseIds = new List<Id>{ insertCase(), insertCase(), insertCase() };
        Case deleted = new Case(Subject = 'Deleted before the flow ran');
        insert deleted;
        delete deleted;
        // What a scheduled or record-triggered flow does for each record. Dispatch is
        // left out so the test drives each run; the Flow action's own rule that one
        // failed start never undoes the others is covered in AgentStartRunActionTest.
        List<Id> runIds = new List<Id>();
        String badRecordError;
        for (Id anchorId : new List<Id>{ caseIds[0], deleted.Id, caseIds[1], caseIds[2] }) {
            AgentKernelModels.StartRequest request = AgentKernelTestFactory.startRequest(definition, 'Summarize this case.');
            request.anchorRecordId = anchorId;
            try {
                runIds.add(AgentRunService.startWithoutDispatch(request, AgentKernelModels.INVOCATION_FLOW).runId);
            } catch (AgentKernelException failure) {
                badRecordError = failure.getMessage();
            }
        }

        System.assertEquals(3, runIds.size(), 'Every good record starts.');
        System.assertNotEquals(null, badRecordError, 'A deleted record fails alone.');
        KernelTestModelProvider.scriptFinal('{"summary":"First case."}');
        KernelTestModelProvider.scriptProviderError('PROVIDER_REJECTED', 'The provider rejected this request.');
        KernelTestModelProvider.scriptFinal('{"summary":"Third case."}');

        Test.startTest();
        List<AgentRun__c> runs = new List<AgentRun__c>();
        for (Id runId : runIds) {
            runs.add(AgentKernelTestFactory.runUntilSettled(runId));
            assertBoundedSteps();
        }

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, runs[0].Status__c, runs[0].ErrorCode__c + ': ' + runs[0].ErrorMessage__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, runs[1].Status__c, 'The rejected run waits for an operator.');
        System.assertEquals('PROVIDER_REJECTED', runs[1].ErrorCode__c);
        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, runs[2].Status__c, 'A paused run must not stall the next one.');
        System.assertEquals(
            0,
            [SELECT COUNT() FROM AgentRun__c WHERE Id IN :new List<Id>{ runs[0].Id, runs[1].Id, runs[2].Id } AND AttendedBy__c != NULL WITH SYSTEM_MODE],
            'Automation runs use the execution user\'s access.'
        );
    }

    /**
     * Scenario 8, Core's part: a conversation on a case over several days.
     * The agent answers and waits for a reply; someone who is not part of
     * the conversation cannot reply; the reply continues it with the earlier
     * answer remembered; and the reply window closes it.
     */
    @IsTest
    static void caseConversationContinuesOnlyForItsPeopleAndCloses() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.ReplyWindowHours__c = 72;
        AgentKernelTestFactory.updateRecord(definition);
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        Id caseId = insertCase();
        standardTool(definition.Id, 'get_case', 'QueryRecords', '{"query":"SELECT Subject, Priority FROM Case WHERE Id = :caseId LIMIT 1"}');
        User stranger = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelRunAgents' });
        AttendedAccessService.attendedForTest = false;
        KernelTestModelProvider.scriptToolCall('get_case', '{"caseId":"' + caseId + '"}');
        KernelTestModelProvider.scriptFinal('{"reply":"Your order is being replaced."}');
        KernelTestModelProvider.scriptFinal('{"reply":"It ships on Monday."}');

        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentRun__c run = AgentKernelTestFactory.runUntilSettled(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        System.assertEquals(AgentKernelModels.CONTINUATION_CONVERSATION, run.ContinuationMode__c);
        System.assert(run.WaitExpiresAt__c > System.now().addHours(71), 'The reply window spans days.');
        assertBoundedSteps();

        Test.startTest();
        System.runAs(stranger) {
            try {
                AgentKernel.resume(run.Id, run.Revision__c, '{"message":"Cancel my refund."}');
                System.assert(false, 'Someone outside the conversation must not reply.');
            } catch (AgentKernelException expected) {
                System.assertNotEquals(null, expected.getMessage());
            }
        }
        // The kernel call applies the same reply rules as AgentRunService.resume, without dispatching.
        AgentKernel.resume(run.Id, run.Revision__c, '{"message":"When will it ship?"}');
        run = AgentKernelTestFactory.runUntilSettled(run.Id);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        String lastRequest = KernelTestModelProvider.lastRequestJson;
        System.assert(lastRequest.contains('Your order is being replaced.'), 'The agent remembers its earlier answer.');
        System.assert(lastRequest.contains('When will it ship?'));
        System.assert(!lastRequest.contains('Cancel my refund.'), 'The stranger\'s message never reaches the model.');

        AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = run.Id, WaitExpiresAt__c = System.now().addMinutes(-1)));
        AgentKernelRecovery.expireIntentionalWaits(new Map<Id, Decimal>{ run.Id => run.Revision__c }, System.now());
        run = AgentKernelTestFactory.getRun(run.Id);
        Test.stopTest();

        System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, 'An unanswered conversation ends with its last answer.');
        System.assertEquals('{"reply":"It ships on Monday."}', run.Output__c);
    }

    /**
     * Scenario 10: the model sees the customer's email only as a token, the
     * one tool allowed to use emails gets the real value, and retention
     * removes the payloads and the vault value on schedule.
     */
    @IsTest
    static void sensitiveValueReachesOnlyTheAllowedToolAndRetentionRemovesIt() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentKernelTestFactory.useDelegatedPrincipal(definition);
            AgentTool__c notify = AgentKernelTestFactory.createTool(
                definition.Id,
                'notify_customer',
                '{"type":"object","properties":{"to":{"type":"string"}},"required":["to"],"additionalProperties":false}'
            );
            notify.AllowedSensitiveDataCategories__c = 'Email';
            AgentKernelTestFactory.updateRecord(notify);
            AgentConfigService.clearCacheForTest();
            AttendedAccessService.attendedForTest = false;

            AgentKernelModels.StartResult started = AgentKernelTestFactory.start(
                definition.Id,
                '{"request":"Tell the customer at ' + CUSTOMER_EMAIL + ' that the refund is done."}'
            );
            String storedInput = AgentKernelTestFactory.getRun(started.runId).Input__c;
            System.assert(!storedInput.contains(CUSTOMER_EMAIL), 'Raw input is never stored.');
            Matcher token = Pattern.compile('\\{\\{EMAIL_[^}]+\\}\\}').matcher(storedInput);
            System.assert(token.find(), 'The input holds an email token: ' + storedInput);
            KernelTestModelProvider.scriptToolCall('notify_customer', '{"to":"' + token.group() + '"}');
            KernelTestModelProvider.scriptFinal('{"reply":"The customer was told."}');

            AgentRun__c run = AgentKernelTestFactory.runUntilSettled(started.runId);

            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
            System.assertEquals('{"to":"' + CUSTOMER_EMAIL + '"}', KernelTestTool.lastRequest.input, 'The allowed tool gets the real value.');
            assertModelNeverSaw(CUSTOMER_EMAIL);
            assertBoundedSteps();

            Test.startTest();
            AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = run.Id, PayloadRetentionDays__c = 0, PurgeAfter__c = System.now().addMinutes(-1)));
            PayloadRetentionPurgeService.PurgeResult purged = PayloadRetentionPurgeService.purge(10);
            Test.stopTest();

            System.assertEquals(1, purged.runsPurged);
            AgentRun__c kept = [SELECT Input__c, Output__c, PayloadPurgedAt__c, Status__c FROM AgentRun__c WHERE Id = :run.Id WITH SYSTEM_MODE];
            System.assertEquals(null, kept.Input__c);
            System.assertEquals(null, kept.Output__c);
            System.assertNotEquals(null, kept.PayloadPurgedAt__c);
            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, kept.Status__c, 'The run and its evidence stay; only payloads go.');
            for (AgentTrustToken__c mapping : [SELECT OriginalValue__c FROM AgentTrustToken__c WHERE AgentRun__c = :run.Id WITH SYSTEM_MODE]) {
                System.assertEquals(null, mapping.OriginalValue__c, 'Retention removes the real value from the vault.');
            }
            for (AgentCommand__c command : [SELECT Input__c, Output__c FROM AgentCommand__c WHERE AgentRun__c = :run.Id WITH SYSTEM_MODE]) {
                System.assertEquals(null, command.Input__c, 'Retention clears each step\'s input.');
                System.assertEquals(null, command.Output__c, 'Retention clears each step\'s output.');
            }
        }
    }

    /**
     * Scenario 11: an operator sees why a run stopped and what it did,
     * rescues it with guidance, and cancels another, without reading code.
     */
    @IsTest
    static void operatorFindsRescuesAndCancelsRuns() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.OPERATOR });
        System.runAs(AgentKernelTestFactory.self()) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            KernelTestModelProvider.scriptProviderError('PROVIDER_OUTAGE', 'The model provider is unavailable.');
            KernelTestModelProvider.scriptFinal('{"summary":"Done after the outage."}');
            AgentKernelModels.StartResult stuck = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            AgentKernelModels.StartResult unwanted = AgentKernelTestFactory.startRunWithoutDispatch(definition);

            AgentRun__c run = AgentKernelTestFactory.runUntilSettled(stuck.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
            AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
            request.definitionId = definition.Id;
            AgentKernelHealthService.HealthReport health = AgentKernelHealthService.getHealth(request);
            System.assertEquals(1, health.pausedRuns);
            System.assert(
                AgentKernelTestFactory.healthCount(health, AgentKernelHealthService.ACTION_PAUSED_RUNS, 'rescuablePausedRuns') > 0,
                String.valueOf(health.actions)
            );
            AgentKernelModels.RunRecord traced = AgentTraceService.getRun(run.Id);
            System.assertEquals('PROVIDER_OUTAGE', traced.errorCode, 'The operator sees why the run stopped.');

            Test.startTest();
            AgentKernelModels.RescueRequest rescue = new AgentKernelModels.RescueRequest();
            rescue.runId = run.Id;
            rescue.expectedRunRevision = run.Revision__c;
            rescue.guidance = 'The provider is back. Continue.';
            AgentRunService.rescue(rescue);
            run = AgentKernelTestFactory.runUntilSettled(run.Id);
            AgentRun__c current = AgentKernelTestFactory.getRun(unwanted.runId);
            AgentRunService.cancel(unwanted.runId, current.Revision__c, 'Started by mistake.');
            Test.stopTest();

            System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
            assertEventsInclude(
                run.Id,
                new List<String>{ AgentKernelModels.EVENT_RUN_PAUSED, AgentKernelModels.EVENT_RUN_RESCUED, AgentKernelModels.EVENT_RUN_COMPLETED }
            );
            AgentRun__c cancelled = AgentKernelTestFactory.getRun(unwanted.runId);
            System.assertEquals(AgentKernelModels.RUN_STATUS_CANCELLED, cancelled.Status__c);
            System.assertEquals('Started by mistake.', cancelled.CancellationReason__c);
            System.assertEquals(0, AgentKernelHealthService.getHealth(request).pausedRuns, 'Health clears once the run is rescued.');
        }
    }

    private class CaseResolution {
        AgentDefinition__c definition;
        Id caseId;
        Id approverId;
    }

    /** A Delegated Principal case agent: read the case, update its priority, and a refund that needs approval. */
    private static CaseResolution caseResolution() {
        CaseResolution fixture = new CaseResolution();
        fixture.definition = AgentKernelTestFactory.createDefinition(6, 6);
        AgentKernelTestFactory.useDelegatedPrincipal(fixture.definition);
        fixture.approverId = AgentKernelTestFactory.approverUser();
        fixture.caseId = insertCase();
        standardTool(
            fixture.definition.Id,
            'get_case',
            'QueryRecords',
            '{"query":"SELECT Subject, Description, Priority FROM Case WHERE Id = :caseId LIMIT 1"}'
        );
        standardTool(fixture.definition.Id, 'set_priority', 'UpdateRecord', '{"objectApiName":"Case","fields":["Priority"]}');
        AgentTool__c refund = AgentKernelTestFactory.createTool(
            fixture.definition.Id,
            'issue_refund',
            '{"type":"object","properties":{"amount":{"type":"number"}},"required":["amount"],"additionalProperties":false}'
        );
        refund.ToolType__c = AgentToolTypeTestFixtures.EXTERNAL;
        refund.RequiresApproval__c = true;
        refund.ApproverType__c = AgentKernelModels.APPROVER_USER;
        refund.ApproverUser__c = fixture.approverId;
        refund.ApprovalTimeoutHours__c = 24;
        refund.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        AgentKernelTestFactory.updateRecord(refund);
        AgentConfigService.clearCacheForTest();
        AttendedAccessService.attendedForTest = false;
        return fixture;
    }

    private static void scriptRefund() {
        KernelTestModelProvider.scriptToolCall('issue_refund', '{"_rationale":"The order arrived damaged.","amount":1200}');
    }

    /** Starts the case agent and drives it until its refund waits for the approver. */
    private static AgentRun__c waitingForApproval(CaseResolution fixture) {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(fixture.definition);
        AgentRun__c run = AgentKernelTestFactory.runUntilSettled(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_WAITING, run.Status__c, run.ErrorCode__c + ': ' + run.ErrorMessage__c);
        assertBoundedSteps();
        return run;
    }

    private static Id insertCase() {
        Case record = new Case(Subject = 'Damaged order', Description = 'Please refund me at ' + CUSTOMER_EMAIL, Priority = 'Low');
        insert record;
        return record.Id;
    }

    private static AgentTool__c standardTool(Id definitionId, String developerName, String toolType, String configuration) {
        AgentTool__c tool = new AgentTool__c(
            Name = developerName,
            AgentDefinition__c = definitionId,
            DeveloperName__c = developerName,
            Description__c = 'A standard tool for the scenario.',
            ToolType__c = toolType,
            ImplementationConfiguration__c = configuration,
            IsActive__c = true,
            SortOrder__c = 1
        );
        insert tool;
        AgentConfigService.clearCacheForTest();
        return tool;
    }

    /** A person who may start agents but has no access to cases. */
    private static User personWithoutCaseAccess() {
        User person = new User(
            Alias = 'nocase',
            Email = 'no-case-access@example.com',
            Username = 'no-case-access-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'No Case Access',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert person;
        }
        AgentKernelTestFactory.grant(person.Id, new List<String>{ 'AgentKernelRunAgents', AgentKernelTestFactory.ADMIN });
        return person;
    }

    private static void assertModelNeverSaw(String value) {
        System.assert(!KernelTestModelProvider.requestLog.isEmpty());
        for (String request : KernelTestModelProvider.requestLog) {
            System.assert(!request.contains(value), 'The model must see protected values only as tokens.');
        }
    }

    private static void assertBoundedSteps() {
        for (Integer step = 0; step < AgentKernelTestFactory.stepQueries.size(); step++) {
            Integer queries = AgentKernelTestFactory.stepQueries[step];
            Integer commands = AgentKernelTestFactory.stepCommands[step];
            System.assert(
                queries <= MAX_QUERIES_PER_STEP * commands,
                'A worker step used ' +
                    queries +
                    ' queries for ' +
                    commands +
                    ' commands: ' +
                    AgentKernelTestFactory.stepQueries +
                    ' ' +
                    AgentKernelTestFactory.stepCommands
            );
        }
    }

    private static void assertEventsInclude(Id runId, List<String> expected) {
        Set<String> recorded = new Set<String>();
        for (AgentEvent__c event : AgentKernelTestFactory.getEvents(runId)) {
            recorded.add(event.EventType__c);
        }
        for (String eventType : expected) {
            System.assert(recorded.contains(eventType), 'Missing event ' + eventType + ' in ' + recorded);
        }
    }
}
