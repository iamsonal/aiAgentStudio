/**
 * @description Focused tests for AgentStateService using shared TestFactory helpers
 */
@IsTest
private class AgentStateServiceTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('StateSvc_Agent').withType('Function').withLLM(llm.Id).save();

        TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-state-001')
            .save();
    }

    @IsTest
    static void testCreateExecution_SetsDefaults() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'StateSvc_Agent%' LIMIT 1];

        AgentStateService svc = new AgentStateService();
        Id executionId = svc.createExecution('Function', agent.Id, 'Test', 'Payload', null, UserInfo.getUserId(), null);

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ExecutionType__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :executionId
        ];
        System.assertEquals('Pending', execution.ExecutionStatus__c, 'Execution should start Pending');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing should start Idle');
        System.assertEquals('Function', execution.ExecutionType__c, 'Execution type should match');
        System.assert(String.isNotBlank(execution.CurrentTurnIdentifier__c), 'Turn identifier should be set');
    }

    @IsTest
    static void testPauseForAsyncActionWithTracking_UpdatesStatusAndCounts() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        AgentStateService svc = new AgentStateService();
        svc.pauseForAsyncActionWithTracking(execution.Id, 'turn-state-async', 2, 'TestTool', '[Test] ');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Processing', updated.ExecutionStatus__c, 'Execution should be Processing');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_ACTION, updated.ProcessingStatus__c, 'Processing status should be Awaiting Action');
        System.assertEquals(2, Integer.valueOf(updated.PendingAsyncToolCount__c), 'Pending async tool count should be set');
        System.assertEquals('turn-state-async', updated.AsyncToolTurnIdentifier__c, 'Async tool turn identifier should be set');
    }

    @IsTest
    static void testResumeForFollowUpLlmCall_SetsAwaitingFollowup() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-followup-001');

        AgentStateService svc = new AgentStateService();
        svc.resumeForFollowUpLlmCall(execution.Id, 'turn-followup-001', null, '[Test] ');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Processing', updated.ExecutionStatus__c, 'Execution should be Processing');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, updated.ProcessingStatus__c, 'Processing status should be Awaiting Followup');
        System.assertEquals('turn-followup-001', updated.CurrentTurnIdentifier__c, 'Turn identifier should update');
    }

    @IsTest
    static void testFailTurn_SetsErrorAndEndTime() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-fail-001');

        AgentStateService svc = new AgentStateService();
        svc.failTurn(execution.Id, 'turn-fail-001', 'Something went wrong', 'ERR_TEST', '[Test] ');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c, EndTime__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Execution should be Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Processing status should be Failed');
        System.assert(String.isNotBlank(updated.ErrorMessage__c), 'Error message should be populated');
        System.assert(updated.ErrorMessage__c.contains('ERR_TEST'), 'Error message should include error code');
        System.assertNotEquals(null, updated.EndTime__c, 'End time should be set on failure');
    }

    @IsTest
    static void testUpdateStatus_TerminalCommitsBufferedSteps() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-buffer-001');

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();

        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createUserInputStep(execution.Id, 'Buffered step', 'turn-buffer-001', 1);

        List<ExecutionStep__c> beforeCommit = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-buffer-001'
        ];
        System.assertEquals(0, beforeCommit.size(), 'Buffered step should not be inserted yet');

        AgentStateService svc = new AgentStateService();
        svc.updateStatus(execution.Id, 'Completed', AIAgentConstants.STATUS_IDLE, 'turn-buffer-001', null);

        List<ExecutionStep__c> afterCommit = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-buffer-001'
        ];
        System.assertEquals(1, afterCommit.size(), 'Buffered step should be committed on terminal status');
    }

    @IsTest
    static void testValidateAndGetExecution_ThrowsOnStaleTurn() {
        AgentExecution__c execution = [SELECT Id, CurrentTurnIdentifier__c FROM AgentExecution__c LIMIT 1];

        AgentStateService svc = new AgentStateService();
        Boolean threw = false;

        try {
            svc.validateAndGetExecution(execution.Id, 'turn-stale-xyz');
        } catch (AgentStateService.AgentStateException ex) {
            threw = true;
            System.assert(
                ex.getMessage().contains('Stale execution detected') || ex.getMessage().contains('Failed to validate execution'),
                'Should surface stale execution validation failure'
            );
        }

        System.assertEquals(true, threw, 'Expected stale turn validation to throw');
    }

    @IsTest
    static void testIsContextTrackingEnabled_ByExecutionType() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'StateSvc_Agent%' LIMIT 1];

        AgentExecution__c conversational = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-ctx-001')
            .save();

        AgentExecution__c functionExec = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ExecutionType__c = 'Function'
            LIMIT 1
        ];

        AgentStateService svc = new AgentStateService();

        System.assertEquals(true, svc.isContextTrackingEnabled(conversational.Id), 'Conversational execution should enable context tracking');
        System.assertEquals(false, svc.isContextTrackingEnabled(functionExec.Id), 'Function execution should not enable context tracking');
    }
}
