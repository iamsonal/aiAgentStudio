/**
 * @description Tests for PipelineExecutionWorker DLQ-based pipeline bootstrap.
 *
 * NOTE: Test.stopTest() runs chained AgentExecutionWorker jobs (no LLM mock),
 * so child agent execution fails and cascades back to the pipeline. Assertions
 * verify that the worker itself claimed, bootstrapped, and created records —
 * not the final pipeline status after child failure cascade.
 */
@IsTest
private class PipelineExecutionWorkerTest {
    @TestSetup
    static void setupData() {
        TestFactory.createPipelineSetup().withStepCount(2).save();
        TestFactory.newCase().withSubject('Worker Test Case').save();
    }

    @IsTest
    static void testWorker_ClaimsAndBootstrapsPipeline() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        String triggerPayload = JSON.serialize(new Map<String, Object>{ 'userMessage' => 'Worker test' });
        AgentExecution__c exec = new AgentExecution__c(
            SourceRecordId__c = testCase.Id,
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Pipeline',
            PipelineDefinition__c = setup.pipelineDefinitionId,
            User__c = UserInfo.getUserId(),
            TriggerSource__c = 'Pipeline',
            TriggerPayload__c = triggerPayload,
            CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
            StartTime__c = Datetime.now(),
            LastActivityTime__c = Datetime.now(),
            BatchId__c = 'PBATCH-test-worker',
            RetryCount__c = 0,
            MaxRetries__c = 3
        );
        insert exec;

        Test.startTest();
        System.enqueueJob(new PipelineExecutionWorker(setup.pipelineDefinitionId, exec.Id), getTestAsyncOptions());
        Test.stopTest();

        // Worker claimed and bootstrapped — verify PipelineRunStep records were created
        List<PipelineRunStep__c> runSteps = [
            SELECT StepName__c, Status__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :exec.Id
            ORDER BY StepOrder__c ASC
        ];
        System.assertEquals(2, runSteps.size(), 'Should create PipelineRunStep records');

        // Verify child execution was created for the first step
        List<AgentExecution__c> children = [SELECT Id FROM AgentExecution__c WHERE ParentExecution__c = :exec.Id];
        System.assertEquals(1, children.size(), 'Should enqueue one child agent execution');

        // ProcessingStartedAt should have been set when the worker claimed the execution
        AgentExecution__c updated = [
            SELECT ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :exec.Id
        ];
        System.assertNotEquals(null, updated.ProcessingStartedAt__c, 'ProcessingStartedAt should be stamped');
    }

    @IsTest
    static void testWorker_NoPreAssigned_PullsFromPool() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        String triggerPayload = JSON.serialize(new Map<String, Object>{ 'userMessage' => 'Pool test' });
        AgentExecution__c exec = new AgentExecution__c(
            SourceRecordId__c = testCase.Id,
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Pipeline',
            PipelineDefinition__c = setup.pipelineDefinitionId,
            User__c = UserInfo.getUserId(),
            TriggerSource__c = 'Pipeline',
            TriggerPayload__c = triggerPayload,
            CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
            StartTime__c = Datetime.now(),
            LastActivityTime__c = Datetime.now()
        );
        insert exec;

        Test.startTest();
        System.enqueueJob(new PipelineExecutionWorker(setup.pipelineDefinitionId, null), getTestAsyncOptions());
        Test.stopTest();

        // Verify the worker pulled from pool and bootstrapped
        List<PipelineRunStep__c> runSteps = [SELECT Id FROM PipelineRunStep__c WHERE AgentExecution__c = :exec.Id];
        System.assert(!runSteps.isEmpty(), 'Worker should claim from pool and create PipelineRunStep records');

        List<AgentExecution__c> children = [SELECT Id FROM AgentExecution__c WHERE ParentExecution__c = :exec.Id];
        System.assertEquals(1, children.size(), 'Worker should create a child execution');
    }

    @IsTest
    static void testWorker_NoPendingWork_ExitsGracefully() {
        TestFactory.PipelineSetup setup = getPipelineSetup();

        Test.startTest();
        System.enqueueJob(new PipelineExecutionWorker(setup.pipelineDefinitionId, null));
        Test.stopTest();

        Integer pipelineExecCount = [SELECT COUNT() FROM AgentExecution__c WHERE ExecutionType__c = 'Pipeline'];
        System.assertEquals(0, pipelineExecCount, 'No executions should be created when pool is empty');
    }

    @IsTest
    static void testWorker_AlreadyClaimed_FallsBackToPool() {
        TestFactory.PipelineSetup setup = getPipelineSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        String triggerPayload = JSON.serialize(new Map<String, Object>{ 'userMessage' => 'Already claimed' });

        // Pre-assigned is already Processing (claimed by another worker)
        AgentExecution__c claimed = new AgentExecution__c(
            SourceRecordId__c = testCase.Id,
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
            ExecutionType__c = 'Pipeline',
            PipelineDefinition__c = setup.pipelineDefinitionId,
            User__c = UserInfo.getUserId(),
            TriggerPayload__c = triggerPayload,
            CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
            StartTime__c = Datetime.now(),
            LastActivityTime__c = Datetime.now()
        );
        insert claimed;

        // Another Pending execution in the pool
        AgentExecution__c poolExec = new AgentExecution__c(
            SourceRecordId__c = testCase.Id,
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Pipeline',
            PipelineDefinition__c = setup.pipelineDefinitionId,
            User__c = UserInfo.getUserId(),
            TriggerSource__c = 'Pipeline',
            TriggerPayload__c = triggerPayload,
            CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
            StartTime__c = Datetime.now(),
            LastActivityTime__c = Datetime.now()
        );
        insert poolExec;

        Test.startTest();
        System.enqueueJob(new PipelineExecutionWorker(setup.pipelineDefinitionId, claimed.Id), getTestAsyncOptions());
        Test.stopTest();

        // Verify the worker fell back to pool and bootstrapped the pool execution
        List<PipelineRunStep__c> runSteps = [SELECT Id FROM PipelineRunStep__c WHERE AgentExecution__c = :poolExec.Id];
        System.assert(!runSteps.isEmpty(), 'Worker should fall back to pool and bootstrap pending execution');
    }

    // =========================================================================
    // HELPERS
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

    private static AsyncOptions getTestAsyncOptions() {
        return new AgentJobEnqueuer().getAsyncOptions('[PipelineExecutionWorkerTest] ');
    }
}
