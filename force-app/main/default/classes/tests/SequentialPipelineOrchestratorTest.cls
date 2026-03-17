/**
 * @description Focused tests for SequentialPipelineOrchestrator using shared TestFactory helpers.
 */
@IsTest
private class SequentialPipelineOrchestratorTest {
    @TestSetup
    static void setupData() {
        TestFactory.createPipelineSetup().withStepCount(2).save();

        TestFactory.newCase().withSubject('Pipeline Case').save();
    }

    @IsTest
    static void testStartPipeline_CreatesParentExecutionAndStepRecords() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        System.assertNotEquals(null, executionId, 'Should create parent execution');

        AgentExecution__c parent = [
            SELECT ExecutionType__c, ExecutionStatus__c, ProcessingStatus__c, CurrentPipelineStep__c
            FROM AgentExecution__c
            WHERE Id = :executionId
        ];
        System.assertEquals('Pipeline', parent.ExecutionType__c, 'Execution should be Pipeline type');
        System.assertNotEquals(null, parent.CurrentPipelineStep__c, 'Current step should be set');

        List<PipelineRunStep__c> steps = [
            SELECT StepName__c, Status__c, IsCurrentStep__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY StepOrder__c ASC
        ];
        System.assertEquals(2, steps.size(), 'Should create pipeline run step records');
        System.assertEquals(true, steps[0].IsCurrentStep__c, 'First step should be current');
        System.assertEquals('in_progress', steps[0].Status__c, 'First step should be in progress');
    }

    @IsTest
    static void testOnChildComplete_FailedChild_FailsPipeline() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        PipelineStep__c firstStep = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :setup.pipelineDefinitionId
            ORDER BY ExecutionOrder__c ASC
            LIMIT 1
        ];

        // Use the actual child execution created by start() — stale-callback
        // validation rejects unknown child IDs.
        AgentExecution__c childExecution = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :firstStep.ChildAgent__c
            LIMIT 1
        ];

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'completedAgent' => firstStep.ChildAgent__r.DeveloperName__c,
            'childExecutionId' => childExecution.Id,
            'success' => false,
            'errorCode' => 'TEST_FAILURE',
            'errorMessage' => 'Child agent failed'
        };

        orchestrator.onChildComplete(executionId, asyncPayload);

        AgentExecution__c updatedParent = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :executionId
        ];
        System.assertEquals('Failed', updatedParent.ExecutionStatus__c, 'Pipeline should fail when child fails');
    }

    @IsTest
    static void testOnChildComplete_Success_AdvancesToNextStep() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        PipelineStep__c firstStep = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :setup.pipelineDefinitionId
            ORDER BY ExecutionOrder__c ASC
            LIMIT 1
        ];

        // Use the actual child execution created by start()
        AgentExecution__c childExecution = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :firstStep.ChildAgent__c
            LIMIT 1
        ];

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'completedAgent' => firstStep.ChildAgent__r.DeveloperName__c,
            'childExecutionId' => childExecution.Id,
            'success' => true,
            'response' => 'Step complete'
        };

        orchestrator.onChildComplete(executionId, asyncPayload);

        List<PipelineRunStep__c> steps = [
            SELECT StepName__c, StepOrder__c, Status__c, IsCurrentStep__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY StepOrder__c ASC
        ];
        System.assertEquals(2, steps.size(), 'Should retain pipeline run step records');
        System.assertEquals('completed', steps[0].Status__c, 'First step should be completed');
        System.assertEquals(false, steps[0].IsCurrentStep__c, 'First step should no longer be current');
        System.assertEquals('in_progress', steps[1].Status__c, 'Second step should be in progress');
        System.assertEquals(true, steps[1].IsCurrentStep__c, 'Second step should be current');

        AgentExecution__c updatedParent = [
            SELECT CurrentPipelineStep__c
            FROM AgentExecution__c
            WHERE Id = :executionId
        ];
        System.assertEquals(
            String.valueOf(Integer.valueOf(steps[1].StepOrder__c)),
            updatedParent.CurrentPipelineStep__c,
            'Current pipeline step should advance to the step order key'
        );
    }

    @IsTest
    static void testStartPipeline_WithTenSteps_CreatesAllRunSteps() {
        TestFactory.createPipelineSetup().withStepCount(10).save();
        TestFactory.newCase().withSubject('Pipeline Case 10').save();

        PipelineDefinition__c pipelineDef = [
            SELECT Id
            FROM PipelineDefinition__c
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        Case testCase = [SELECT Id FROM Case WHERE Subject = 'Pipeline Case 10' LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(pipelineDef.Id);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        List<PipelineRunStep__c> steps = [
            SELECT StepName__c, Status__c, IsCurrentStep__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId
        ];
        System.assertEquals(10, steps.size(), 'Should create run step record per pipeline step');

        Integer currentCount = 0;
        for (PipelineRunStep__c step : steps) {
            if (step.IsCurrentStep__c) {
                currentCount++;
            }
        }
        System.assertEquals(1, currentCount, 'Exactly one step should be current at start');
    }

    @IsTest
    static void testOnChildComplete_TruncatesContextForNextStep() {
        TestFactory.PipelineSetup setup = TestFactory.createPipelineSetup().withStepCount(3).save();
        TestFactory.newCase().withSubject('Pipeline Case Truncate').save();

        List<PipelineStep__c> steps = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :setup.pipelineDefinitionId
            ORDER BY ExecutionOrder__c ASC
        ];
        System.assertEquals(3, steps.size(), 'Should have 3 pipeline steps');

        Case testCase = [SELECT Id FROM Case WHERE Subject = 'Pipeline Case Truncate' LIMIT 1];
        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        AgentExecution__c firstChild = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :steps[0].ChildAgent__c
            LIMIT 1
        ];

        List<String> parts = new List<String>();
        for (Integer i = 0; i < 9000; i++) {
            parts.add('X');
        }
        String largeResponse = String.join(parts, '');

        Map<String, Object> payloadStep1 = new Map<String, Object>{
            'completedAgent' => steps[0].ChildAgent__r.DeveloperName__c,
            'childExecutionId' => firstChild.Id,
            'success' => true,
            'response' => largeResponse
        };
        orchestrator.onChildComplete(executionId, payloadStep1);

        AgentExecution__c secondChild = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :steps[1].ChildAgent__c
            LIMIT 1
        ];

        Map<String, Object> payloadStep2 = new Map<String, Object>{
            'completedAgent' => steps[1].ChildAgent__r.DeveloperName__c,
            'childExecutionId' => secondChild.Id,
            'success' => true,
            'response' => largeResponse
        };
        orchestrator.onChildComplete(executionId, payloadStep2);

        List<PipelineRunStep__c> runSteps = [
            SELECT StepName__c, Status__c, Response__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY StepOrder__c ASC
        ];
        System.assertEquals('completed', runSteps[0].Status__c, 'Step 1 should be completed');
        System.assertEquals('completed', runSteps[1].Status__c, 'Step 2 should be completed');
    }

    @IsTest
    static void testStartPipelineFromFlow_ReturnsBulkResults() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        PipelineDefinition__c pipelineDef = [SELECT DeveloperName__c FROM PipelineDefinition__c WHERE Id = :setup.pipelineDefinitionId LIMIT 1];
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator.InvocableRequest req = new SequentialPipelineOrchestrator.InvocableRequest();
        req.pipelineName = pipelineDef.DeveloperName__c;
        req.recordId = testCase.Id;
        req.triggerSource = 'Flow';

        List<SequentialPipelineOrchestrator.ExecutionResult> results = SequentialPipelineOrchestrator.startPipelineFromFlow(
            new List<SequentialPipelineOrchestrator.InvocableRequest>{ req }
        );

        System.assertEquals(1, results.size(), 'Should return one result per request');
        System.assertEquals(true, results[0].success, 'Pipeline should start successfully');
        System.assertNotEquals(null, results[0].executionId, 'Execution ID should be populated');
    }

    @IsTest
    static void testStartPipelineFromFlow_InvalidPipeline_ReturnsErrorResult() {
        SequentialPipelineOrchestrator.InvocableRequest req = new SequentialPipelineOrchestrator.InvocableRequest();
        req.pipelineName = 'NonExistent_Pipeline';
        req.recordId = UserInfo.getUserId();

        List<SequentialPipelineOrchestrator.ExecutionResult> results = SequentialPipelineOrchestrator.startPipelineFromFlow(
            new List<SequentialPipelineOrchestrator.InvocableRequest>{ req }
        );

        System.assertEquals(1, results.size(), 'Should return one result');
        System.assertEquals(false, results[0].success, 'Should return error result for invalid pipeline');
        System.assertEquals('PIPELINE_START_FAILED', results[0].errorCode, 'Should have correct error code');
    }

    @IsTest
    static void testOnChildComplete_CreatesChildWithStepScopedTurn_DistinctPerStep() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        List<PipelineStep__c> stepDefs = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c, ExecutionOrder__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :setup.pipelineDefinitionId
            ORDER BY ExecutionOrder__c ASC
        ];
        System.assertEquals(2, stepDefs.size(), 'Test requires a 2-step pipeline');
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        List<AgentExecution__c> step1Children = [
            SELECT Id, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :stepDefs[0].ChildAgent__c
        ];
        System.assertEquals(1, step1Children.size(), 'Step 1 child execution should exist');

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'completedAgent' => stepDefs[0].ChildAgent__r.DeveloperName__c,
            'childExecutionId' => step1Children[0].Id,
            'success' => true,
            'response' => 'Step 1 output'
        };
        orchestrator.onChildComplete(executionId, asyncPayload);

        List<AgentExecution__c> step2Children = [
            SELECT Id, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :stepDefs[1].ChildAgent__c
        ];
        System.assertEquals(1, step2Children.size(), 'Step 2 child execution should exist');
        System.assertNotEquals(step1Children[0].Id, step2Children[0].Id, 'Each step must have its own independent child execution');
    }

    @IsTest
    static void testResume_FailedStepCreatesNewChildExecution_AndRejectsOldCallback() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        SequentialPipelineOrchestrator orchestrator = new SequentialPipelineOrchestrator();
        orchestrator.configurePipeline(setup.pipelineDefinitionId);

        Id executionId = orchestrator.start(testCase.Id).executionId;

        PipelineStep__c firstStep = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :setup.pipelineDefinitionId
            ORDER BY ExecutionOrder__c ASC
            LIMIT 1
        ];

        AgentExecution__c originalChild = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :firstStep.ChildAgent__c
            LIMIT 1
        ];

        orchestrator.onChildComplete(
            executionId,
            new Map<String, Object>{
                'completedAgent' => firstStep.ChildAgent__r.DeveloperName__c,
                'childExecutionId' => originalChild.Id,
                'success' => false,
                'errorCode' => 'TEST_FAILURE',
                'errorMessage' => 'Original child failed'
            }
        );

        orchestrator.resume(executionId);

        List<AgentExecution__c> childExecutions = [
            SELECT Id, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE ParentExecution__c = :executionId AND AIAgentDefinition__c = :firstStep.ChildAgent__c
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, childExecutions.size(), 'Resume should create a fresh child execution instead of reusing the failed one');
        System.assertNotEquals(originalChild.Id, childExecutions[1].Id, 'Resumed pipeline should track a new child execution id');

        PipelineRunStep__c resumedStep = [
            SELECT ChildExecution__c, Status__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId AND StepOrder__c = 1
            LIMIT 1
        ];
        System.assertEquals(childExecutions[1].Id, resumedStep.ChildExecution__c, 'Pipeline state should point at the new child execution');
        System.assertEquals('in_progress', resumedStep.Status__c, 'Resumed step should be back in progress');

        orchestrator.onChildComplete(
            executionId,
            new Map<String, Object>{
                'completedAgent' => firstStep.ChildAgent__r.DeveloperName__c,
                'childExecutionId' => originalChild.Id,
                'success' => true,
                'response' => 'Late stale callback'
            }
        );

        PipelineRunStep__c afterStaleCallback = [
            SELECT ChildExecution__c, Status__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId AND StepOrder__c = 1
            LIMIT 1
        ];
        System.assertEquals(childExecutions[1].Id, afterStaleCallback.ChildExecution__c, 'Stale callback should not overwrite the resumed child execution');
        System.assertEquals('in_progress', afterStaleCallback.Status__c, 'Stale callback should not advance the resumed step');
    }

    // =========================================================================
    // BULK DISPATCH TESTS
    // =========================================================================

    @IsTest
    static void testStartPipeline_BulkRecords_CreatesBatchExecution() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        PipelineDefinition__c pipelineDef = [SELECT DeveloperName__c FROM PipelineDefinition__c WHERE Id = :setup.pipelineDefinitionId LIMIT 1];

        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 3; i++) {
            cases.add(new Case(Subject = 'Bulk Case ' + i));
        }
        insert cases;

        List<Id> caseIds = new List<Id>();
        for (Case c : cases) {
            caseIds.add(c.Id);
        }

        Test.startTest();
        SequentialPipelineOrchestrator.ExecutionResult result = SequentialPipelineOrchestrator.startPipeline(pipelineDef.DeveloperName__c, caseIds);

        System.assertEquals(true, result.success, 'Dispatch should succeed');
        System.assertNotEquals(null, result.batchId, 'BatchId should be set for bulk dispatch');
        System.assert(result.batchId.startsWith('PBATCH-'), 'BatchId should use PBATCH- prefix');
        System.assertNotEquals(null, result.executionId, 'Should have at least one execution ID');

        List<AgentExecution__c> executions = [
            SELECT ExecutionType__c, ExecutionStatus__c, PipelineDefinition__c, BatchId__c
            FROM AgentExecution__c
            WHERE BatchId__c = :result.batchId
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(3, executions.size(), 'Should have 3 execution records');
        for (AgentExecution__c exec : executions) {
            System.assertEquals('Pipeline', exec.ExecutionType__c, 'ExecutionType should be Pipeline');
            System.assertEquals('Pending', exec.ExecutionStatus__c, 'Initial status should be Pending');
            System.assertEquals(setup.pipelineDefinitionId, exec.PipelineDefinition__c, 'PipelineDefinition should be set');
        }

        Test.stopTest();
    }

    @IsTest
    static void testStartPipeline_BulkInvalidPipeline_Throws() {
        Boolean caught = false;
        try {
            SequentialPipelineOrchestrator.startPipeline('Nonexistent_Pipeline', new List<Id>{ UserInfo.getUserId() });
        } catch (SequentialPipelineOrchestrator.PipelineStateException e) {
            caught = true;
            System.assert(e.getMessage().contains('Active pipeline not found'), 'Should indicate pipeline not found');
        }
        System.assert(caught, 'Should throw PipelineStateException for invalid pipeline');
    }

    @IsTest
    static void testBootstrapExecution_InitializesPipelineState() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c exec = new AgentExecution__c(
            SourceRecordId__c = testCase.Id,
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
            ExecutionType__c = 'Pipeline',
            PipelineDefinition__c = setup.pipelineDefinitionId,
            User__c = UserInfo.getUserId(),
            TriggerSource__c = 'Pipeline',
            CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
            StartTime__c = Datetime.now(),
            LastActivityTime__c = Datetime.now()
        );
        insert exec;

        SequentialPipelineOrchestrator orch = new SequentialPipelineOrchestrator();
        orch.configurePipeline(setup.pipelineDefinitionId);

        // No Test.startTest/stopTest — bootstrapExecution is synchronous.
        // Wrapping would execute the chained AgentExecutionWorker (no LLM mock)
        // which cascades a failure back and changes PipelineRunStep statuses.
        orch.bootstrapExecution(exec.Id);

        List<PipelineRunStep__c> runSteps = [
            SELECT StepName__c, Status__c, IsCurrentStep__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :exec.Id
            ORDER BY StepOrder__c ASC
        ];
        System.assertEquals(2, runSteps.size(), 'Should create PipelineRunStep records for each step');
        System.assertEquals('in_progress', runSteps[0].Status__c, 'First step should be in progress');
        System.assertEquals(true, runSteps[0].IsCurrentStep__c, 'First step should be current');
        System.assertEquals('pending', runSteps[1].Status__c, 'Second step should be pending');

        List<AgentExecution__c> children = [SELECT Id FROM AgentExecution__c WHERE ParentExecution__c = :exec.Id];
        System.assertEquals(1, children.size(), 'Should create one child execution for the first step');
    }

    @IsTest
    static void testStartPipelineFromFlow_MultiRecord_UsesBulkDispatch() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        PipelineDefinition__c pipelineDef = [SELECT DeveloperName__c FROM PipelineDefinition__c WHERE Id = :setup.pipelineDefinitionId LIMIT 1];

        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 3; i++) {
            cases.add(new Case(Subject = 'Multi Record Case ' + i));
        }
        insert cases;

        List<SequentialPipelineOrchestrator.InvocableRequest> requests = new List<SequentialPipelineOrchestrator.InvocableRequest>();
        for (Case c : cases) {
            SequentialPipelineOrchestrator.InvocableRequest req = new SequentialPipelineOrchestrator.InvocableRequest();
            req.pipelineName = pipelineDef.DeveloperName__c;
            req.recordId = c.Id;
            req.triggerSource = 'Flow';
            requests.add(req);
        }

        Test.startTest();
        List<SequentialPipelineOrchestrator.ExecutionResult> results = SequentialPipelineOrchestrator.startPipelineFromFlow(requests);

        // Assert synchronous results before Test.stopTest runs workers
        System.assertEquals(3, results.size(), 'Should return one result per request');
        for (SequentialPipelineOrchestrator.ExecutionResult res : results) {
            System.assertEquals(true, res.success, 'Each result should be successful');
            System.assertNotEquals(null, res.executionId, 'Each result should have an execution ID');
            System.assertEquals('Pending', res.status, 'Bulk dispatched results should be Pending');
            System.assert(res.message.contains('PBATCH-'), 'Message should reference batch ID');
        }

        Set<Id> execIds = new Set<Id>();
        for (SequentialPipelineOrchestrator.ExecutionResult res : results) {
            execIds.add(res.executionId);
        }
        System.assertEquals(3, execIds.size(), 'Each record should get its own execution');

        Test.stopTest();
    }

    @IsTest
    static void testStartPipelineFromFlow_MixedPipelines_RoutesCorrectly() {
        TestFactory.PipelineSetup setupA = getPipelineSetup();
        TestFactory.PipelineSetup setupB = TestFactory.createPipelineSetup().withStepCount(2).save();
        PipelineDefinition__c pipelineA = [SELECT DeveloperName__c FROM PipelineDefinition__c WHERE Id = :setupA.pipelineDefinitionId LIMIT 1];
        PipelineDefinition__c pipelineB = [SELECT DeveloperName__c FROM PipelineDefinition__c WHERE Id = :setupB.pipelineDefinitionId LIMIT 1];

        List<Case> cases = new List<Case>();
        for (Integer i = 0; i < 3; i++) {
            cases.add(new Case(Subject = 'Mixed Case ' + i));
        }
        insert cases;

        List<SequentialPipelineOrchestrator.InvocableRequest> requests = new List<SequentialPipelineOrchestrator.InvocableRequest>();

        // 1 request for pipeline A (single → sync path)
        SequentialPipelineOrchestrator.InvocableRequest reqA = new SequentialPipelineOrchestrator.InvocableRequest();
        reqA.pipelineName = pipelineA.DeveloperName__c;
        reqA.recordId = cases[0].Id;
        requests.add(reqA);

        // 2 requests for pipeline B (multi → bulk dispatch path)
        for (Integer i = 1; i <= 2; i++) {
            SequentialPipelineOrchestrator.InvocableRequest reqB = new SequentialPipelineOrchestrator.InvocableRequest();
            reqB.pipelineName = pipelineB.DeveloperName__c;
            reqB.recordId = cases[i].Id;
            requests.add(reqB);
        }

        Test.startTest();
        List<SequentialPipelineOrchestrator.ExecutionResult> results = SequentialPipelineOrchestrator.startPipelineFromFlow(requests);

        // Assert synchronous results before Test.stopTest runs workers
        System.assertEquals(3, results.size(), 'Should return 3 results');

        // Pipeline A (index 0): sync path → Processing status
        System.assertEquals(true, results[0].success, 'Pipeline A should succeed');
        System.assertEquals(AIAgentConstants.STATUS_PROCESSING, results[0].status, 'Sync path should return Processing');

        // Pipeline B (indices 1, 2): bulk path → Pending status
        System.assertEquals(true, results[1].success, 'Pipeline B[1] should succeed');
        System.assertEquals('Pending', results[1].status, 'Bulk path should return Pending');
        System.assertEquals(true, results[2].success, 'Pipeline B[2] should succeed');
        System.assertEquals('Pending', results[2].status, 'Bulk path should return Pending');

        Test.stopTest();
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    private static TestFactory.PipelineSetup getPipelineSetup() {
        PipelineDefinition__c pipelineDef = [
            SELECT Id
            FROM PipelineDefinition__c
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        TestFactory.PipelineSetup setup = new TestFactory.PipelineSetup();
        setup.pipelineDefinitionId = pipelineDef.Id;
        return setup;
    }
}
