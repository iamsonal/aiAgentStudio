/**
 * @description Focused tests for AgentExecutionDispatcher DLQ dispatch and retry behavior
 */
@IsTest
private class AgentExecutionDispatcherTest {
    @TestSetup
    static void setupData() {
        AIAgentFrameworkSettings__c settings = new AIAgentFrameworkSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), BulkConcurrencyLimit__c = 1);
        insert settings;

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Dispatch LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Dispatch_Agent').withType('Direct').withLLM(llm.Id).save();

        TestFactory.newAccount().withName('Dispatch Account 1').save();
        TestFactory.newAccount().withName('Dispatch Account 2').save();
        TestFactory.newAccount().withName('Dispatch Account 3').save();
    }

    @IsTest
    static void testDispatch_CreatesExecutionsAndEnqueuesWorkers() {
        AIAgentFrameworkSettings.clearCache();

        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RuntimeStrategy__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Dispatch_Agent%'
            LIMIT 1
        ];
        List<Account> sources = [SELECT Id FROM Account WHERE Name LIKE 'Dispatch Account%' ORDER BY Name];

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.triggerSource = 'Apex';
        payload.sourceRecordIds = new List<Id>{ sources[0].Id, sources[1].Id };
        payload.priority = 7;

        AgentExecutionDispatcher.DispatchResult result = AgentExecutionDispatcher.dispatch(agent.DeveloperName__c, payload);

        System.assertEquals(true, result.success, 'Dispatch should succeed');
        System.assertEquals(2, result.executionIds.size(), 'Should create execution per source record');
        System.assertEquals(1, result.enqueuedJobCount, 'Worker count should respect bulk concurrency limit');
        System.assert(result.batchId.startsWith('BATCH-'), 'BatchId should be generated');

        List<AgentExecution__c> executions = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ProcessingStartedAt__c, Priority__c, BatchId__c, SourceRecordId__c, RetryCount__c, MaxRetries__c
            FROM AgentExecution__c
            WHERE BatchId__c = :result.batchId
        ];
        System.assertEquals(2, executions.size(), 'Should insert two execution records');
        Integer processingCount = 0;
        Integer pendingCount = 0;
        for (AgentExecution__c exec : executions) {
            if (exec.ExecutionStatus__c == 'Processing') {
                processingCount++;
                System.assertNotEquals(null, exec.ProcessingStartedAt__c, 'Processing start should be set for pre-assigned workers');
            } else {
                pendingCount++;
                System.assertEquals('Pending', exec.ExecutionStatus__c, 'Non-preassigned executions should remain pending');
            }
            System.assertEquals(AIAgentConstants.STATUS_IDLE, exec.ProcessingStatus__c, 'Processing status should be idle');
            System.assertEquals(7, Integer.valueOf(exec.Priority__c), 'Priority should be set from payload');
            System.assertEquals(0, Integer.valueOf(exec.RetryCount__c), 'Retry count should start at 0');
            System.assertEquals(3, Integer.valueOf(exec.MaxRetries__c), 'Max retries should default to 3');
        }
        System.assertEquals(result.enqueuedJobCount, processingCount, 'Pre-assigned processing count should match enqueued workers');
        System.assertEquals(executions.size() - result.enqueuedJobCount, pendingCount, 'Remaining executions should stay pending');
    }

    @IsTest
    static void testGetBatchProgress_ComputesOverallStatus() {
        AIAgentDefinition__c agent = [
            SELECT Id, RuntimeStrategy__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Dispatch_Agent%'
            LIMIT 1
        ];
        Id sourceId = [SELECT Id FROM Account WHERE Name = 'Dispatch Account 1' LIMIT 1].Id;

        String batchId = 'BATCH-PROGRESS';
        insert new List<AgentExecution__c>{
            new AgentExecution__c(
                AIAgentDefinition__c = agent.Id,
                ExecutionType__c = agent.RuntimeStrategy__c,
                ExecutionStatus__c = 'Completed',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                BatchId__c = batchId,
                SourceRecordId__c = sourceId,
                User__c = UserInfo.getUserId()
            ),
            new AgentExecution__c(
                AIAgentDefinition__c = agent.Id,
                ExecutionType__c = agent.RuntimeStrategy__c,
                ExecutionStatus__c = 'Failed',
                ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
                BatchId__c = batchId,
                SourceRecordId__c = sourceId,
                User__c = UserInfo.getUserId()
            ),
            new AgentExecution__c(
                AIAgentDefinition__c = agent.Id,
                ExecutionType__c = agent.RuntimeStrategy__c,
                ExecutionStatus__c = 'Pending',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                BatchId__c = batchId,
                SourceRecordId__c = sourceId,
                User__c = UserInfo.getUserId()
            )
        };

        AgentExecutionDispatcher.BatchProgress progress = AgentExecutionDispatcher.getBatchProgress(batchId);

        System.assertEquals(3, progress.totalRecords, 'Should count all batch records');
        System.assertEquals(1, progress.completedRecords, 'Should count completed records');
        System.assertEquals(1, progress.failedRecords, 'Should count failed records');
        System.assertEquals(1, progress.pendingRecords, 'Should count pending records');
        System.assertEquals('Processing', progress.overallStatus, 'Overall status should be Processing when pending exists');
    }

    @IsTest
    static void testRequeueBatch_ResetsStatusWithoutIncrementingRetry() {
        // Manual requeue is an admin override: ALL failed/pending records in the batch
        // are reset regardless of RetryCount__c, and RetryCount__c is NOT incremented
        // (only the automated stale-job detector counts against MaxRetries__c).
        AIAgentFrameworkSettings.clearCache();

        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, RuntimeStrategy__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Dispatch_Agent%'
            LIMIT 1
        ];
        Id sourceId = [SELECT Id FROM Account WHERE Name = 'Dispatch Account 2' LIMIT 1].Id;

        String batchId = 'BATCH-REQUEUE';
        AgentExecution__c exec1 = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            ExecutionType__c = agent.RuntimeStrategy__c,
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
            BatchId__c = batchId,
            RetryCount__c = 0,
            MaxRetries__c = 1,
            ErrorMessage__c = 'Old error',
            SourceRecordId__c = sourceId,
            User__c = UserInfo.getUserId()
        );
        AgentExecution__c exec2 = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            ExecutionType__c = agent.RuntimeStrategy__c,
            ExecutionStatus__c = 'Failed',
            ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
            BatchId__c = batchId,
            RetryCount__c = 1,
            MaxRetries__c = 1,
            ErrorMessage__c = 'Max retries hit — admin forcing retry',
            SourceRecordId__c = sourceId,
            User__c = UserInfo.getUserId()
        );
        insert new List<AgentExecution__c>{ exec1, exec2 };

        Integer requeued = AgentExecutionDispatcher.requeueBatch(batchId, false);

        // Both records are requeued — manual override ignores retry count
        System.assertEquals(2, requeued, 'All failed/pending executions should be requeued on manual override');

        AgentExecution__c updated1 = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, RetryCount__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :exec1.Id
        ];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated1.ProcessingStatus__c, 'Processing status should reset to Idle');
        System.assertEquals(0, Integer.valueOf(updated1.RetryCount__c), 'RetryCount must NOT be incremented by manual requeue');
        System.assertEquals(null, updated1.ErrorMessage__c, 'Error message should be cleared');

        AgentExecution__c updated2 = [
            SELECT ExecutionStatus__c, RetryCount__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :exec2.Id
        ];
        System.assertEquals(1, Integer.valueOf(updated2.RetryCount__c), 'RetryCount for exec2 must remain unchanged');
        System.assertEquals(null, updated2.ErrorMessage__c, 'Error message should be cleared');
    }
}
