/**
 * @description Focused tests for AgentStateService using shared TestFactory helpers
 */
@IsTest
private class AgentStateServiceTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('StateSvc_Agent').withType('SingleShot').withLLM(llm.Id).save();

        TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('SingleShot')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-state-001')
            .save();
    }

    @IsTest
    static void testCreateExecution_SetsDefaults() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'StateSvc_Agent%' LIMIT 1];

        AgentStateService svc = new AgentStateService();
        Id executionId = svc.createExecution('SingleShot', agent.Id, 'Test', 'Payload', null, UserInfo.getUserId(), null);

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ExecutionType__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :executionId
        ];
        System.assertEquals('Pending', execution.ExecutionStatus__c, 'Execution should start Pending');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing should start Idle');
        System.assertEquals('SingleShot', execution.ExecutionType__c, 'Execution type should match');
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
    static void testPauseForOperationalIssue_SetsPausedStateAndMessage() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-pause-001');

        AgentStateService svc = new AgentStateService();
        svc.pauseForOperationalIssue(
            execution.Id,
            'turn-pause-001',
            AIAgentConstants.OP_STATE_FOLLOWUP_QUEUE_FAILED,
            'Follow-up queueing failed for this execution.',
            '[Test] '
        );

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c, EndTime__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(AIAgentConstants.EXECUTION_STATUS_PAUSED, updated.ExecutionStatus__c, 'Execution should be Paused');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Paused operational issues should use Failed processing status');
        System.assert(
            updated.ErrorMessage__c != null && updated.ErrorMessage__c.contains(AIAgentConstants.OP_STATE_FOLLOWUP_QUEUE_FAILED),
            'Operational state should be included in the persisted message'
        );
        System.assertEquals(null, updated.EndTime__c, 'Paused executions should remain resumable and not set EndTime');
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
    static void testUpdateStatus_StaleTerminalDiscardsBufferedSteps() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-current-owner-001');

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();

        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createUserInputStep(execution.Id, 'Stale buffered step', 'turn-stale-owner-001', 1);

        AgentStateService svc = new AgentStateService();
        Boolean applied = svc.updateStatus(execution.Id, 'Completed', AIAgentConstants.STATUS_IDLE, 'turn-stale-owner-001', null);

        System.assertEquals(false, applied, 'Stale terminal update should be rejected');
        System.assertEquals(false, txnCtx.isDeferredDMLMode(), 'Deferred mode should be disabled after stale terminal rejection');
        System.assertEquals(0, txnCtx.getBufferedExecutionSteps(execution.Id).size(), 'Buffered records for the stale execution should be discarded');

        List<ExecutionStep__c> persisted = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-stale-owner-001'
        ];
        System.assertEquals(0, persisted.size(), 'Stale buffered steps should not be committed');
    }

    @IsTest
    static void testUpdateStatus_StaleSyncRecovery_PreservesBufferedStepsUntilFinalize() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        update new AgentExecution__c(Id = execution.Id, CurrentTurnIdentifier__c = 'turn-current-owner-002');

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();
        txnCtx.markSyncFinalizationRecovery(execution.Id, 'turn-sync-recover-001');

        insert new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'UserInput',
            StepRole__c = 'User',
            Content__c = 'previous turn input',
            TurnIdentifier__c = 'turn-current-owner-002',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-10)
        );

        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createToolCallStep(
            execution.Id,
            'call-sync-recover-001',
            'lookup_case',
            '{"caseNumber":"3344567"}',
            'turn-sync-recover-001',
            1,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            false
        );
        stepSvc.createToolResultStep(
            execution.Id,
            'call-sync-recover-001',
            'lookup_case',
            '{"success":false,"error":"Not found"}',
            'turn-sync-recover-001',
            1,
            25L,
            false,
            null,
            false,
            false
        );
        stepSvc.createAgentResponseStep(execution.Id, 'No case found for that number.', 'turn-sync-recover-001', 1);

        AgentStateService svc = new AgentStateService();
        Boolean applied = svc.updateStatus(execution.Id, 'Completed', AIAgentConstants.STATUS_IDLE, 'turn-sync-recover-001', null);

        System.assertEquals(false, applied, 'Sync recovery still uses the stale-turn guard');
        System.assertEquals(true, txnCtx.isDeferredDMLMode(), 'Deferred mode should remain enabled so sync finalization can recover');
        System.assert(txnCtx.getBufferedExecutionSteps(execution.Id).size() > 0, 'Buffered steps should be preserved for sync recovery');

        Boolean recovered = svc.syncFinalizeExecution(execution.Id, 'turn-sync-recover-001', AIAgentConstants.STATUS_IDLE, '[Test] ');
        System.assertEquals(true, recovered, 'sync finalization recovery should report success');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'sync finalization should complete the execution');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'sync finalization should set Idle status');
        System.assertEquals('turn-sync-recover-001', updated.CurrentTurnIdentifier__c, 'sync finalization should stamp the recovering turn');

        List<ExecutionStep__c> persisted = [
            SELECT Id, StepType__c, Content__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-sync-recover-001'
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(3, persisted.size(), 'Buffered sync-turn steps should be committed during recovery finalization');
        System.assertEquals('AgentResponse', persisted[2].StepType__c, 'Final assistant response should be persisted');
        System.assertEquals('No case found for that number.', persisted[2].Content__c, 'Assistant response content should survive sync recovery');
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
    static void testSyncFinalizeExecution_RecoversStaleTurn() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        update new AgentExecution__c(
            Id = execution.Id,
            CurrentTurnIdentifier__c = 'old-turn-001',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING
        );

        AgentStateService svc = new AgentStateService();
        Boolean recovered = svc.syncFinalizeExecution(execution.Id, 'new-turn-001', AIAgentConstants.STATUS_IDLE, '[Test] ');
        System.assertEquals(true, recovered, 'syncFinalizeExecution should report successful recovery');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, EndTime__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'syncFinalizeExecution should set status to Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'syncFinalizeExecution should set processing status to Idle');
        System.assertEquals('new-turn-001', updated.CurrentTurnIdentifier__c, 'syncFinalizeExecution should stamp the new turn identifier');
        System.assertNotEquals(null, updated.EndTime__c, 'syncFinalizeExecution should set EndTime for terminal state');
    }

    @IsTest
    static void testSyncFinalizeExecution_NoopWhenTurnAlreadyStamped() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        update new AgentExecution__c(
            Id = execution.Id,
            CurrentTurnIdentifier__c = 'already-stamped-001',
            ExecutionStatus__c = 'Completed',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );

        AgentStateService svc = new AgentStateService();
        Boolean recovered = svc.syncFinalizeExecution(execution.Id, 'already-stamped-001', AIAgentConstants.STATUS_IDLE, '[Test] ');
        System.assertEquals(true, recovered, 'syncFinalizeExecution should no-op successfully when already stamped');

        // No DML should have occurred - verify state is unchanged
        AgentExecution__c unchanged = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', unchanged.ExecutionStatus__c, 'No-op: status should remain Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, unchanged.ProcessingStatus__c, 'No-op: processing status should remain Idle');
        System.assertEquals('already-stamped-001', unchanged.CurrentTurnIdentifier__c, 'No-op: turn identifier should remain unchanged');
    }

    @IsTest
    static void testSyncFinalizeExecution_PausesDurablyWhenRecoveryFails() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        update new AgentExecution__c(
            Id = execution.Id,
            CurrentTurnIdentifier__c = 'old-turn-sync-finalize',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING
        );

        AgentStateService svc = new AgentStateService();
        AgentStateService.forceSyncFinalizeExecutionFailure = true;

        Boolean recovered;
        try {
            recovered = svc.syncFinalizeExecution(execution.Id, 'new-turn-sync-finalize', AIAgentConstants.STATUS_IDLE, '[Test] ');
        } finally {
            AgentStateService.forceSyncFinalizeExecutionFailure = false;
        }

        System.assertEquals(false, recovered, 'syncFinalizeExecution should signal failure when recovery breaks');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, ErrorMessage__c, EndTime__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(
            AIAgentConstants.EXECUTION_STATUS_PAUSED,
            updated.ExecutionStatus__c,
            'Execution should be paused for operator review when sync recovery fails'
        );
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updated.ProcessingStatus__c, 'Processing status should reflect failure');
        System.assertEquals('old-turn-sync-finalize', updated.CurrentTurnIdentifier__c, 'Pause path should not stamp a new turn after failed recovery');
        System.assert(
            updated.ErrorMessage__c.contains(AIAgentConstants.OP_STATE_SYNC_FINALIZATION_FAILED),
            'Error should include the operational state marker'
        );
        System.assertNotEquals(null, updated.EndTime__c, 'Pause path should stamp an end time');
    }

    @IsTest
    static void testIsContextTrackingEnabled_ByExecutionType() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'StateSvc_Agent%' LIMIT 1];

        AgentExecution__c conversational = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Iterative')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-ctx-001')
            .save();

        AgentExecution__c functionExec = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ExecutionType__c = 'SingleShot'
            LIMIT 1
        ];

        AgentStateService svc = new AgentStateService();

        System.assertEquals(true, svc.isContextTrackingEnabled(conversational.Id), 'Conversational execution should enable context tracking');
        System.assertEquals(false, svc.isContextTrackingEnabled(functionExec.Id), 'Function execution should not enable context tracking');
    }
}
