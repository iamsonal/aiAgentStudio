/**
 * @description Tests for the shared initial iterative turn executor.
 */
@IsTest
private class ConversationalTurnExecutionServiceTest {
    private static AgentExecution__c createExecution(String turnId) {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            CurrentTurnIdentifier__c = turnId
        );
        insert execution;
        return execution;
    }

    @IsTest
    static void testExecuteInitialTurn_MissingLlmConfig_FailsTurnAndCleansDeferredMode() {
        AgentExecution__c execution = createExecution('turn-shared-001');
        TransactionContext.getInstance().reset();

        Test.startTest();
        ConversationalTurnExecutionService.RunResult result = new ConversationalTurnExecutionService()
            .executeInitialTurn(
                execution.Id,
                UserInfo.getUserId(),
                UserInfo.getUserId(),
                execution.AIAgentDefinition__c,
                null,
                'turn-shared-001',
                'Hello from shared executor',
                null,
                '[test] '
            );
        Test.stopTest();

        AgentExecution__c reloaded = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(false, result.success, 'Service should surface the failed execution outcome.');
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, result.outcome, 'Missing LLM configuration should fail the shared initial turn.');
        System.assertEquals('Failed', reloaded.ExecutionStatus__c, 'Execution should be marked Failed.');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, reloaded.ProcessingStatus__c, 'Processing status should be Failed.');
        System.assertEquals(false, TransactionContext.getInstance().isDeferredDMLMode(), 'Deferred DML mode should be cleaned up after shared execution.');
    }
}
