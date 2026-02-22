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

    // ─── Retry enforcement tests ──────────────────────────────────────────────

    /**
     * @description When the LLM returns a text response while there are unretried retryable tool
     *              failures in the current turn, ContentResponseHandler should return
     *              OUTCOME_IMMEDIATE_FOLLOWUP and create an internal enforcement step.
     *
     *              Requires: agent has ErrorRecoveryMode__c='Autonomous', MaxProcessingCycles__c > 1
     *              and a committed RetryPending=true step in the current turn.
     */
    @IsTest
    static void testHandle_WithUnretriedRetryableFailure_InjectsEnforcementAndReturnsFollowUp() {
        TestFactory.AgentSetup setup = getSetup();

        // Configure agent for Autonomous recovery so enforcement triggers
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, ErrorRecoveryMode__c = 'Autonomous', MaxProcessingCycles__c = 10);

        String turnId = 'turn-enf-crh-001';

        // Create the ToolCall step whose arguments the enforcement message will reference
        insert new ExecutionStep__c(
            AgentExecution__c = setup.agentExecution.Id,
            StepType__c = 'ToolCall',
            StepRole__c = 'Assistant',
            ToolCallId__c = 'call-crh-001',
            ToolName__c = 'assign_to_queue',
            ToolArguments__c = '{"queueDeveloperName":"Support_Queue"}',
            TurnIdentifier__c = turnId,
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-15)
        );

        // Create a RetryPending=true failure step for the same tool in the same turn
        insert new ExecutionStep__c(
            AgentExecution__c = setup.agentExecution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolCallId__c = 'call-crh-001',
            ToolName__c = 'assign_to_queue',
            IsError__c = true,
            IsRetryable__c = true,
            RetryPending__c = true,
            TurnIdentifier__c = turnId,
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-14)
        );

        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('I have routed your case.');

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn(turnId, 1).build();

        ContentResponseHandler handler = new ContentResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(
            OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP,
            outcome,
            'Should return IMMEDIATE_FOLLOWUP when unretried retryable failures exist in Autonomous mode'
        );

        // The enforcement step is buffered (deferred DML) — commit before querying
        TransactionContext.getInstance().commitBuffer();

        // Enforcement step is IsInternal__c = false so the LLM can see it in history
        List<ExecutionStep__c> enforcementSteps = [
            SELECT StepType__c, IsInternal__c, Content__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'UserInput' AND IsInternal__c = FALSE AND TurnIdentifier__c = :turnId
        ];
        System.assertEquals(1, enforcementSteps.size(), 'Should have created one enforcement step');
        System.assert(enforcementSteps[0].Content__c.contains('assign_to_queue'), 'Enforcement step content should reference the failed tool name');
    }

    /**
     * @description In Fail Fast mode, ContentResponseHandler completes normally even if there are
     *              RetryPending steps in the turn — enforcement is disabled for non-Autonomous agents.
     */
    @IsTest
    static void testHandle_FailFastMode_WithRetryPendingFailure_CompletesNormally() {
        TestFactory.AgentSetup setup = getSetup();

        // Ensure agent is in Fail Fast mode
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, ErrorRecoveryMode__c = 'Fail Fast');

        String turnId = 'turn-ff-crh-001';

        // Create a RetryPending step (should be ignored in Fail Fast mode)
        insert new ExecutionStep__c(
            AgentExecution__c = setup.agentExecution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolCallId__c = 'call-ff-001',
            ToolName__c = 'get_case_details',
            IsError__c = true,
            IsRetryable__c = true,
            RetryPending__c = true,
            TurnIdentifier__c = turnId,
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-5)
        );

        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('Case was not retrieved.');

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn(turnId, 1).build();

        ContentResponseHandler handler = new ContentResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(
            OrchestrationService.OUTCOME_COMPLETED,
            outcome,
            'Fail Fast mode should not trigger retry enforcement — text responses should complete normally'
        );
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
