/**
 * @description Focused tests for ContentResponseHandler using shared TestFactory helpers
 */
@IsTest
private class ContentResponseHandlerTest {
    @TestSetup
    static void setupData() {
        TestFactory.createFullAgentSetup().save();
    }

    @IsTest
    static void testHandle_TextResponse_PersistsStepsAndCompletes() {
        TestFactory.AgentSetup setup = getSetup();

        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('Resolved your issue. Here are the next steps.');

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withUserMessage('Please help with my case')
            .withTurn('turn-content-001', 1)
            .build();

        ContentResponseHandler handler = new ContentResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome, 'Content handler should complete on valid text');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Completed', execution.ExecutionStatus__c, 'Execution should be marked Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing status should be Idle');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assert(!steps.isEmpty(), 'Should create execution steps for user input and response');
    }

    @IsTest
    static void testHandle_EmptyContent_FailsAndMarksExecution() {
        TestFactory.AgentSetup setup = getSetup();

        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('');

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-content-002', 1).build();

        ContentResponseHandler handler = new ContentResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Empty content should fail');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Failed', execution.ExecutionStatus__c, 'Execution should be marked Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, execution.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testHandle_NoUserMessage_CreatesAgentResponseOnly() {
        TestFactory.AgentSetup setup = getSetup();

        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('Follow-up summary without user prompt.');

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-content-003', 2).build();

        ContentResponseHandler handler = new ContentResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome, 'Content handler should complete without user message');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        Boolean hasUserInput = false;
        Boolean hasAgentResponse = false;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'UserInput') {
                hasUserInput = true;
            } else if (step.StepType__c == 'AgentResponse') {
                hasAgentResponse = true;
            }
        }

        System.assert(!hasUserInput, 'User input step should not be created when user message is missing');
        System.assert(hasAgentResponse, 'Agent response step should be created');
    }

    private static TestFactory.AgentSetup getSetup() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        TestFactory.AgentSetup setup = new TestFactory.AgentSetup();
        setup.agentDefinition = agent;
        setup.agentExecution = execution;
        setup.llmConfig = llm;
        return setup;
    }
}
