/**
 * @description Focused tests for TransactionContext behavior
 */
@IsTest
private class TransactionContextTest {
    @TestSetup
    static void setupData() {
        TestFactory.createFullAgentSetup().save();
    }

    @IsTest
    static void testImmediateFollowUpEligibility() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();

        ctx.enableDeferredDMLMode();
        ctx.setHasPreExistingExecution(true);
        ctx.resetTurnSafetyTracking();

        Integer maxCalls = AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction();
        for (Integer i = 0; i < Math.max(0, maxCalls - 1); i++) {
            ctx.incrementLLMCallCount();
        }

        System.assertEquals(true, ctx.canContinueWithImmediateFollowUp(), 'Should allow immediate follow-up when safe');

        ctx.incrementLLMCallCount();
        System.assertEquals(false, ctx.canContinueWithImmediateFollowUp(), 'Should block immediate follow-up at max LLM calls');
    }

    @IsTest
    static void testToolPerformedDMLOrCallout_SetsStickyFlag() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.resetTurnSafetyTracking();

        Account acc = new Account(Name = 'TxnCtx Account');
        insert acc;

        Boolean unsafe = ctx.toolPerformedDMLOrCallout();

        System.assertEquals(true, unsafe, 'DML should be detected as unsafe');
        System.assertEquals(true, ctx.hasUnsafeOperationsThisTurn(), 'Sticky unsafe flag should be set');
    }

    @IsTest
    static void testToolPerformedDMLOrCallout_DetectsEmailInvocations() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.resetTurnSafetyTracking();

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ 'test@example.com' });
        email.setSubject('TxnCtx Email');
        email.setPlainTextBody('Test email body');
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });

        Boolean unsafe = ctx.toolPerformedDMLOrCallout();

        System.assertEquals(true, unsafe, 'Email send should be detected as unsafe');
        System.assertEquals(true, ctx.hasUnsafeOperationsThisTurn(), 'Sticky unsafe flag should be set for emails');
    }

    @IsTest
    static void testMarkUnsafeOperation_BlocksImmediateFollowUp() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.enableDeferredDMLMode();
        ctx.setHasPreExistingExecution(true);
        ctx.resetTurnSafetyTracking();

        ctx.markUnsafeOperation('Notification sent');

        System.assertEquals(true, ctx.hasUnsafeOperationsThisTurn(), 'Manual unsafe flag should be set');
        System.assertEquals(false, ctx.canContinueWithImmediateFollowUp(), 'Manual unsafe flag should block immediate follow-up');
    }

    @IsTest
    static void testTrackExecutedToolAndGetExecutedTools() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();

        Id executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;

        ctx.trackExecutedTool(executionId, 'toolA');
        ctx.trackExecutedTool(executionId, 'toolB');

        Set<String> executed = ctx.getExecutedTools(executionId);
        System.assertNotEquals(null, executed, 'Executed tools should be tracked for execution');
        System.assertEquals(true, executed.contains('toolA'), 'toolA should be tracked');
        System.assertEquals(true, executed.contains('toolB'), 'toolB should be tracked');
    }

    @IsTest
    static void testGetBufferedExecutionSteps_ReturnsOnlyMatchingExecution() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.enableDeferredDMLMode();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createUserInputStep(execution.Id, 'Buffered step', 'turn-buffered-001', 1);

        List<ExecutionStep__c> buffered = ctx.getBufferedExecutionSteps(execution.Id);
        System.assertEquals(1, buffered.size(), 'Buffered steps should be returned for execution');
        System.assertEquals('turn-buffered-001', buffered[0].TurnIdentifier__c, 'Buffered step should match turn');

        ctx.commitBuffer();
        List<ExecutionStep__c> afterCommit = ctx.getBufferedExecutionSteps(execution.Id);
        System.assertEquals(0, afterCommit.size(), 'Buffer should be empty after commit');
    }

    @IsTest
    static void testImmediateFollowUpBlockedWhenUnsafe() {
        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.enableDeferredDMLMode();
        ctx.setHasPreExistingExecution(true);
        ctx.resetTurnSafetyTracking();

        Account acc = new Account(Name = 'TxnCtx Unsafe');
        insert acc;
        ctx.toolPerformedDMLOrCallout();

        System.assertEquals(false, ctx.canContinueWithImmediateFollowUp(), 'Unsafe operations should block immediate follow-up');
    }
}
