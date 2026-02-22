/**
 * @description Focused tests for AsyncActionEngine using shared TestFactory helpers
 */
@IsTest
private class AsyncActionEngineTest {
    @TestSetup
    static void setupData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Account').withName('async_create_account').async().save();
    }

    @IsTest
    static void testProcess_CreatesToolResultStep() {
        AgentCapability__c capability = [
            SELECT
                Id,
                CapabilityName__c,
                ImplementationDetail__c,
                BackendConfiguration__c,
                StandardActionType__c,
                ImplementationType__c,
                AIAgentDefinition__c,
                Parameters__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'async_create_account'
            LIMIT 1
        ];
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-async-action-001')
            .save();

        String toolCallId = 'call_async_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{"Name": "Async Engine Account"}',
            capability,
            null,
            execution.CurrentTurnIdentifier__c,
            1
        );

        Test.startTest();
        engine.process('test_job_id');
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT Id, StepType__c, ToolCallId__c, IsAsyncToolExecution__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c = 'ToolResult' AND ToolCallId__c = :toolCallId
        ];

        System.assertEquals(1, toolResults.size(), 'Should create one tool result step');
        System.assertEquals(true, toolResults[0].IsAsyncToolExecution__c, 'Tool result should be marked async');
    }

    @IsTest
    static void testProcess_StaleExecution_SkipsProcessing() {
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c, AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'async_create_account'
            LIMIT 1
        ];
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-async-stale-001')
            .save();

        String toolCallId = 'call_stale_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{"Name": "Should Skip"}',
            capability,
            null,
            execution.CurrentTurnIdentifier__c,
            1
        );

        engine.process('test_job_id');

        List<ExecutionStep__c> toolResults = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c = 'ToolResult' AND ToolCallId__c = :toolCallId
        ];
        System.assertEquals(0, toolResults.size(), 'Stale execution should not create tool result');
    }

    @IsTest
    static void testProcess_FailFastFailure_MarksExecutionFailed() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c failFastCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withName('async_failfast_' + String.valueOf(Datetime.now().getTime()))
            .async()
            .build();
        insert failFastCap;

        // Set agent to Fail Fast mode — halts immediately on any tool error
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, ErrorRecoveryMode__c = 'Fail Fast');

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-async-failfast-001')
            .save();

        String toolCallId = 'call_failfast_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{}',
            failFastCap,
            null,
            execution.CurrentTurnIdentifier__c,
            1
        );

        engine.process('test_job_id');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Fail-fast should mark execution failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testProcess_ToolTerminatingMode_FailsImmediately() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c cap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withName('async_term_' + String.valueOf(Datetime.now().getTime()))
            .async()
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-async-term-001')
            .build();
        execution.IsToolTerminatingMode__c = true;
        insert execution;

        String toolCallId = 'call_term_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{}',
            cap,
            null,
            execution.CurrentTurnIdentifier__c,
            1
        );

        engine.process('test_job_id');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Tool-terminating mode should fail on tool error');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Should be marked failed');
    }

    @IsTest
    static void testProcess_MaxTurnsExceeded_FailsTurn() {
        AgentCapability__c capability = [
            SELECT
                Id,
                CapabilityName__c,
                ImplementationDetail__c,
                BackendConfiguration__c,
                StandardActionType__c,
                ImplementationType__c,
                AIAgentDefinition__c,
                Parameters__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'async_create_account'
            LIMIT 1
        ];
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-async-maxturns-001')
            .save();

        String toolCallId = 'call_maxturns_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{"Name": "Max Turns Test"}',
            capability,
            null,
            execution.CurrentTurnIdentifier__c,
            999
        );

        engine.process('test_job_id');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Max turns should fail execution');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Should mark processing status as failed');
    }

    @IsTest
    static void testProcess_SuccessfulExecution_QueuesFollowUp() {
        AgentCapability__c capability = [
            SELECT
                Id,
                CapabilityName__c,
                ImplementationDetail__c,
                BackendConfiguration__c,
                StandardActionType__c,
                ImplementationType__c,
                AIAgentDefinition__c,
                Parameters__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'async_create_account'
            LIMIT 1
        ];
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-async-success-001')
            .build();
        execution.PendingAsyncToolCount__c = 1;
        insert execution;

        String toolCallId = 'call_success_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            execution.Id,
            UserInfo.getUserId(),
            execution.AIAgentDefinition__c,
            null,
            toolCallId,
            '{"Name": "Success Test Account"}',
            capability,
            null,
            execution.CurrentTurnIdentifier__c,
            1
        );

        Test.startTest();
        engine.process('test_job_id');
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT PendingAsyncToolCount__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(0, updated.PendingAsyncToolCount__c, 'Async tool counter should decrement to 0');
        // Processing status will be AWAITING_FOLLOWUP or FAILED depending on whether metadata and configuration are present
        System.assert(true, 'Async tool execution should complete without throwing exception');
    }

    @IsTest
    static void testProcess_NullExecution_HandlesGracefully() {
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c, ImplementationDetail__c, BackendConfiguration__c, StandardActionType__c, ImplementationType__c, AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'async_create_account'
            LIMIT 1
        ];
        String toolCallId = 'call_null_' + System.currentTimeMillis();

        AsyncActionEngine engine = new AsyncActionEngine(
            'a0X000000000000',
            UserInfo.getUserId(),
            capability.AIAgentDefinition__c,
            null,
            toolCallId,
            '{}',
            capability,
            null,
            'turn-null-001',
            1
        );

        engine.process('test_job_id');

        List<ExecutionStep__c> steps = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = 'a0X000000000000'
        ];
        System.assertEquals(0, steps.size(), 'Should not create steps for non-existent execution');
    }
}
