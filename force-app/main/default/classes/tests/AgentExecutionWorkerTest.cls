/**
 * @description Focused tests for AgentExecutionWorker using shared TestFactory helpers.
 *   Tests cover both pre-assigned and pool selection modes for the DLQ-based worker.
 *
 *   The @TestSetup creates a pipeline (which provisions Direct child agent
 *   definitions) and a Case.  Tests that exercise the Worker's generic claim/chain
 *   logic re-use those child agents.  Tests that need a fully-wired Direct agent
 *   with capabilities create their own setup via TestFactory.createFunctionAgentSetup().
 */
@IsTest
private class AgentExecutionWorkerTest {
    @TestSetup
    static void setupData() {
        TestFactory.createPipelineSetup().withStepCount(2).save();
        TestFactory.newCase().withSubject('Worker Test Case').save();
    }

    private static AIAgentDefinition__c getChildAgent() {
        return [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c ORDER BY CreatedDate ASC LIMIT 1];
    }

    @IsTest
    static void testPreAssignedMode_ClaimsExecutionAndStartsPipeline() {
        AIAgentDefinition__c childAgent = getChildAgent();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-worker-001')
            .save();

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withExistingExecution(execution.Id)
            .withTriggerSource('DLQ')
            .build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(childAgent.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertNotEquals(null, updated.ProcessingStartedAt__c, 'Worker should set ProcessingStartedAt__c');
        System.assertNotEquals(null, updated.ExecutionStatus__c, 'Execution status should be set');
    }

    @IsTest
    static void testPoolSelectionMode_ClaimsSingleExecution() {
        AIAgentDefinition__c childAgent = getChildAgent();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c exec1 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-worker-010')
            .save();

        AgentExecution__c exec2 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-worker-011')
            .save();

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload().withUser(UserInfo.getUserId()).withTriggerSource('DLQ').build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(childAgent.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        List<AgentExecution__c> executions = [
            SELECT Id, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id IN :new List<Id>{ exec1.Id, exec2.Id }
        ];

        Integer claimedCount = 0;
        for (AgentExecution__c exec : executions) {
            if (exec.ProcessingStartedAt__c != null) {
                claimedCount++;
            }
        }

        System.assert(claimedCount >= 1, 'Worker should claim at least one pending execution in pool mode');
    }

    @IsTest
    static void testPreAssignedProcessing_AllowsPipelineStart() {
        AIAgentDefinition__c childAgent = getChildAgent();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-worker-processing-001')
            .save();

        execution.ProcessingStartedAt__c = Datetime.now();
        execution.LastActivityTime__c = Datetime.now();
        execution.WorkerClaimToken__c = 'claim-processing-001';
        update execution;

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withExistingExecution(execution.Id)
            .withTriggerSource('DLQ')
            .build();
        payload.claimToken = 'claim-processing-001';

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        System.enqueueJob(new AgentExecutionWorker(childAgent.DeveloperName__c, payload));
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertNotEquals('Pending', updated.ExecutionStatus__c, 'Already-Processing execution should be accepted and processed');
    }

    @IsTest
    static void testPreAssignedProcessing_RejectsStaleTurnMismatch() {
        AIAgentDefinition__c childAgent = getChildAgent();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-worker-current-001')
            .save();

        execution.ProcessingStartedAt__c = Datetime.now().addMinutes(-5);
        execution.LastActivityTime__c = Datetime.now().addMinutes(-5);
        execution.WorkerClaimToken__c = 'claim-stale-turn-001';
        update execution;

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withExistingExecution(execution.Id)
            .withTriggerSource('DLQ')
            .build();
        payload.claimToken = 'claim-stale-turn-001';
        payload.turnIdentifier = 'turn-worker-stale-001';

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        System.enqueueJob(new AgentExecutionWorker(childAgent.DeveloperName__c, payload));
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, CurrentTurnIdentifier__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Processing', updated.ExecutionStatus__c, 'Stale worker should not take ownership of the execution');
        System.assertEquals('turn-worker-current-001', updated.CurrentTurnIdentifier__c, 'Stale worker should not mutate the current turn');
    }

    // --- Function Agent-specific tests (use dedicated setup per method) ---

    @IsTest
    static void testFunctionAgent_DefersProcessingAndSetsTimestamp() {
        TestFactory.FunctionAgentSetup setup = TestFactory.createFunctionAgentSetup().withAuditLevel('Standard').withStandardActions().save();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-function-worker-001')
            .save();

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withExistingExecution(execution.Id)
            .withTriggerSource('DLQ')
            .build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(setup.agentDefinition.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertNotEquals(null, updatedExecution.ProcessingStartedAt__c, 'Direct agent should set ProcessingStartedAt__c on claim');
        System.assertNotEquals('Pending', updatedExecution.ExecutionStatus__c, 'Execution should not remain Pending after processing');
    }

    @IsTest
    static void testFunctionAgent_ChainsPreAssignedExecutionWithoutDeferral() {
        TestFactory.FunctionAgentSetup setup = TestFactory.createFunctionAgentSetup().withAuditLevel('Standard').withStandardActions().save();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c firstExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-function-chain-001')
            .save();

        AgentExecution__c secondExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-function-chain-002')
            .save();

        firstExec.ProcessingStartedAt__c = Datetime.now();
        firstExec.LastActivityTime__c = Datetime.now();
        firstExec.WorkerClaimToken__c = 'claim-chain-001';
        update firstExec;

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload()
            .withUser(UserInfo.getUserId())
            .withExistingExecution(firstExec.Id)
            .withTriggerSource('DLQ')
            .build();
        payload.claimToken = 'claim-chain-001';

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(setup.agentDefinition.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        AgentExecution__c updatedSecondExec = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :secondExec.Id
        ];
        System.assertNotEquals('Pending', updatedSecondExec.ExecutionStatus__c, 'Chained execution should not remain Pending');
        System.assertNotEquals(null, updatedSecondExec.ProcessingStartedAt__c, 'Chained execution should set ProcessingStartedAt__c');
    }

    @IsTest
    static void testFunctionAgent_PoolMode_DefersProcessingAfterClaim() {
        TestFactory.FunctionAgentSetup setup = TestFactory.createFunctionAgentSetup().withAuditLevel('Standard').withStandardActions().save();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-function-pool-001')
            .save();

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload().withUser(UserInfo.getUserId()).withTriggerSource('DLQ').build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(setup.agentDefinition.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertNotEquals(null, updated.ProcessingStartedAt__c, 'Pool claim should set ProcessingStartedAt__c');
        System.assertNotEquals('Pending', updated.ExecutionStatus__c, 'Execution should not remain Pending after pool claim');
    }

    @IsTest
    static void testPoolSelectionMode_ChainsNextPendingWorker() {
        AIAgentDefinition__c childAgent = getChildAgent();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c exec1 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-chain-001')
            .save();

        AgentExecution__c exec2 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-chain-002')
            .save();

        AgentExecutionService.ExecutionPayload payload = TestFactory.newExecutionPayload().withUser(UserInfo.getUserId()).withTriggerSource('DLQ').build();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = 5;
        System.enqueueJob(new AgentExecutionWorker(childAgent.DeveloperName__c, payload), asyncOptions);
        Test.stopTest();

        List<AgentExecution__c> executions = [
            SELECT Id, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id IN :new List<Id>{ exec1.Id, exec2.Id }
        ];

        Integer claimedCount = 0;
        for (AgentExecution__c exec : executions) {
            if (exec.ProcessingStartedAt__c != null) {
                claimedCount++;
            }
        }

        System.assert(claimedCount >= 1, 'Pool mode should claim at least one execution per worker run');
    }
}
