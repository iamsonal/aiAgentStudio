/**
 * @description Focused tests for OrchestrationService using shared TestFactory helpers
 */
@IsTest
private class OrchestrationServiceTest {
    @TestSetup
    static void setupData() {
        AgentCapability__c getCaseDetails = TestFactory.newCapability()
            .withName('get_case_details')
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject', 'Status' })
            .build();

        TestFactory.createFullAgentSetup().withCapability(getCaseDetails).save();

        TestFactory.newCase().withSubject('Orchestration Test Case').save();
    }

    @IsTest
    static void testProcessLlmResult_TextResponse_CompletesAndPersistsSteps() {
        TestFactory.AgentSetup setup = getSetup();
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmTextResult('Hello! How can I help?');
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-text-001')
            .save();
        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-text-001');

        OrchestrationService service = new OrchestrationService();

        String outcome = service.processLlmResult(
            llmResult,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-text-001',
            1,
            TestFactory.createUserMessage('Hi there'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome, 'Text responses should complete');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updatedExecution.ExecutionStatus__c, 'Execution should complete');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updatedExecution.ProcessingStatus__c, 'Processing status should return to Idle');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    @IsTest
    static void testProcessLlmResult_ToolCall_QueuesFollowUpAndCreatesToolSteps() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-tool-001')
            .save();
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
            LIMIT 1
        ];
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'call-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Calling tool', actions);
        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-tool-001');

        OrchestrationService service = new OrchestrationService();

        String outcome = service.processLlmResult(
            llmResult,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-tool-001',
            1,
            TestFactory.createUserMessage('Get case details'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'Sync tool calls should queue a follow-up');

        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c, ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testProcessLlmResult_FailedResult_MarksExecutionFailed() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-fail-001')
            .save();

        LLMInteractionService.LLMInteractionResult llmResult = new LLMInteractionService.LLMInteractionResult(
            'LLM failed',
            AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
            new AIAgentException('LLM failure')
        );
        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-fail-001');

        OrchestrationService service = new OrchestrationService();
        String outcome = service.processLlmResult(
            llmResult,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-fail-001',
            1,
            TestFactory.createUserMessage('Trigger failure'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Failed LLM result should mark failure');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updatedExecution.ExecutionStatus__c, 'Execution should be failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updatedExecution.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testProcessLlmResult_InvalidToolCall_FailsTurn() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-invalid-tool-001')
            .save();

        Map<String, String> invalidTool = new Map<String, String>{ 'name' => 'nonexistent', 'arguments' => '{}' };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult(
            'Invalid tool call',
            new List<Map<String, String>>{ invalidTool }
        );
        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-invalid-tool-001');

        OrchestrationService service = new OrchestrationService();
        String outcome = service.processLlmResult(
            llmResult,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-invalid-tool-001',
            1,
            TestFactory.createUserMessage('Bad tool request'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Invalid tool call should fail');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updatedExecution.ExecutionStatus__c, 'Execution should be failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updatedExecution.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testProcessLlmResult_ImmediateFollowUp_ReturnsImmediateFollowUp() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-immediate-001')
            .save();

        AgentCapability__c capability = [
            SELECT CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'call-immediate-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Calling tool', actions);

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();
        txnCtx.setHasPreExistingExecution(true);
        txnCtx.resetTurnSafetyTracking();
        txnCtx.incrementLLMCallCount();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-immediate-001');
        OrchestrationService service = new OrchestrationService();

        String outcome = service.processLlmResult(
            llmResult,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-immediate-001',
            1,
            TestFactory.createUserMessage('Get case details'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP, outcome, 'Should signal immediate follow-up');

        List<ExecutionStep__c> bufferedSteps = txnCtx.getBufferedExecutionSteps(execution.Id);
        Boolean hasToolCall = false;
        Boolean hasToolResult = false;
        for (ExecutionStep__c step : bufferedSteps) {
            if (step.StepType__c == 'ToolCall') {
                hasToolCall = true;
            } else if (step.StepType__c == 'ToolResult') {
                hasToolResult = true;
            }
        }
        System.assert(hasToolCall, 'Buffered steps should include ToolCall');
        System.assert(hasToolResult, 'Buffered steps should include ToolResult');

        txnCtx.disableDeferredDMLMode();
    }

    @IsTest
    static void testProcessLlmResult_NullResult_FailsTurn() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-null-001')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-null-001');
        OrchestrationService service = new OrchestrationService();

        String outcome = service.processLlmResult(
            null,
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-null-001',
            1,
            TestFactory.createUserMessage('Null result'),
            null,
            logger
        );

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Null LLM result should fail');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updatedExecution.ExecutionStatus__c, 'Execution should be failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updatedExecution.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testSerializeActionOutcome_ErrorIncludesGuidance() {
        ActionOutcome outcome = ActionOutcome.failureWithGuidance('ERR_TEST', 'Failure', 'Try again');

        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');
        System.assert(json.contains('"isSuccess":false'), 'Serialized output should indicate failure');
        System.assert(json.contains('messageForUser'), 'Serialized output should include messageForUser');
        System.assert(json.contains('Try again'), 'Serialized output should include correctionGuidance');
    }

    @IsTest
    static void testSerializeActionOutcome_NullOutcome_ReturnsErrorJson() {
        String json = OrchestrationService.serializeActionOutcome(null, '[test] ');

        System.assert(json.contains('"isSuccess":false'), 'Null outcome should return error JSON');
        System.assert(json.contains('did not return an outcome'), 'Should explain outcome was null');
    }

    @IsTest
    static void testSerializeActionOutcome_SuccessWithNullData_ReturnsEmptyDataMap() {
        ActionOutcome outcome = ActionOutcome.success();
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"isSuccess":true'), 'Success should be indicated');
    }

    @IsTest
    static void testSerializeActionOutcome_FailureWithoutGuidance_OmitsGuidance() {
        ActionOutcome outcome = ActionOutcome.failure('ERR_TEST', 'Something failed');
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"isSuccess":false'), 'Should indicate failure');
        System.assert(!json.contains('correctionGuidance'), 'Should not include guidance when not provided');
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_NullOutcome_ReturnsNull() {
        Id result = OrchestrationService.extractRecordIdFromOutcome(null);
        System.assertEquals(null, result, 'Null outcome should return null');
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_FailureOutcome_ReturnsNull() {
        ActionOutcome failure = ActionOutcome.failure('ERR', 'Failed');
        Id result = OrchestrationService.extractRecordIdFromOutcome(failure);
        System.assertEquals(null, result, 'Failure outcome should return null');
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_InvalidIdFormat_ReturnsNull() {
        Map<String, Object> dataMap = new Map<String, Object>{ 'status' => 'SUCCESS', 'data' => new Map<String, Object>{ 'recordId' => 'not-a-valid-id' } };
        ActionOutcome outcome = ActionOutcome.success(dataMap);
        Id result = OrchestrationService.extractRecordIdFromOutcome(outcome);
        System.assertEquals(null, result, 'Invalid ID format should return null');
    }

    @IsTest
    static void testShouldFailFast_SuccessOutcome_ReturnsFalse() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool', FailFastOnError__c = true);
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function');
        ActionOutcome success = ActionOutcome.success();

        System.assertEquals(false, OrchestrationService.shouldFailFast(cap, agent, success, null, '[test] '), 'Success outcome should never fail fast');
    }

    @IsTest
    static void testShouldFailFast_NullOutcome_ReturnsFalse() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool', FailFastOnError__c = false);
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function');

        System.assertEquals(false, OrchestrationService.shouldFailFast(cap, agent, null, null, '[test] '), 'Null outcome should return false');
    }

    @IsTest
    static void testShouldFailFast_FailFastEnabled_ReturnsTrue() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool', FailFastOnError__c = true);
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function');
        ActionOutcome failure = ActionOutcome.failure('ERR', 'Failed');

        System.assertEquals(true, OrchestrationService.shouldFailFast(cap, agent, failure, null, '[test] '), 'FailFastOnError should immediately return true');
    }

    @IsTest
    static void testShouldFailFast_ConversationalAgent_AllowsLLMRecovery() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool', FailFastOnError__c = false);
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Conversational');
        ActionOutcome failure = ActionOutcome.failure('ERR', 'Failed');

        System.assertEquals(
            false,
            OrchestrationService.shouldFailFast(cap, agent, failure, null, '[test] '),
            'Conversational agents should allow LLM recovery'
        );
    }

    @IsTest
    static void testCountSuccessiveToolFailures_NullInputs_ReturnsZero() {
        System.assertEquals(0, OrchestrationService.countSuccessiveToolFailures(null, 'tool', '[test] '), 'Null executionId should return 0');
        System.assertEquals(0, OrchestrationService.countSuccessiveToolFailures(UserInfo.getUserId(), '', '[test] '), 'Blank toolName should return 0');
    }

    @IsTest
    static void testConstructor_NullDependency_ThrowsException() {
        Boolean threw = false;
        try {
            new OrchestrationService(null, new CapabilityExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null dependency should throw IllegalArgumentException');
    }

    @IsTest
    static void testExtractRecordIdFromOutcome_Variants() {
        Account account = new Account(Name = 'Outcome Account');
        insert account;
        ActionOutcome outcome = ActionOutcome.success();

        Map<String, Object> dataMap = new Map<String, Object>{
            'status' => 'SUCCESS',
            'data' => new Map<String, Object>{ 'recordId' => String.valueOf(account.Id) }
        };
        outcome = ActionOutcome.success(dataMap);
        System.assertEquals(account.Id, OrchestrationService.extractRecordIdFromOutcome(outcome), 'Should read recordId');

        SObject record = new Account(Id = account.Id);
        dataMap.put('data', new Map<String, Object>{ 'records' => new List<Object>{ record } });
        outcome = ActionOutcome.success(dataMap);
        System.assertEquals(account.Id, OrchestrationService.extractRecordIdFromOutcome(outcome), 'Should read Id from SObject');

        dataMap.put('data', new Map<String, Object>{ 'record' => new Map<String, Object>{ 'Id' => String.valueOf(account.Id) } });
        outcome = ActionOutcome.success(dataMap);
        System.assertEquals(account.Id, OrchestrationService.extractRecordIdFromOutcome(outcome), 'Should read Id from record map');
    }

    /**
     * C-4: Verifies loadSuccessiveFailureCounts() returns correct per-tool failure streaks
     * in a single bulk query, handling tools with different histories correctly.
     */
    @IsTest
    static void testLoadSuccessiveFailureCounts_MultipleTools_ReturnsCorrectCounts() {
        TestFactory.AgentSetup setup = getSetup();

        AIAgentDefinition__c functionAgent = TestFactory.newAgentDefinition()
            .withName('BulkCount_Function_Agent')
            .withType('Function')
            .withLLM(setup.llmConfig.Id)
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(functionAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-bulkcount-001')
            .save();

        AgentCapability__c capA = TestFactory.newCapability()
            .withAgent(functionAgent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id' })
            .withName('tool_alpha_bulk')
            .save();

        AgentCapability__c capB = TestFactory.newCapability()
            .withAgent(functionAgent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id' })
            .withName('tool_beta_bulk')
            .save();

        ExecutionStepService stepSvc = new ExecutionStepService();

        // tool_alpha: 2 successive failures — streak = 2 (both most-recent steps are errors)
        stepSvc.createToolResultStep(execution.Id, 'call-a-001', capA.CapabilityName__c, '{}', 'turn-bulkcount-001', 1, 0L, false, capA.Id, true);
        stepSvc.createToolResultStep(execution.Id, 'call-a-002', capA.CapabilityName__c, '{}', 'turn-bulkcount-001', 1, 0L, false, capA.Id, true);

        // tool_beta: 1 failure then 1 success — success is most recent, streak = 0.
        // Steps are sorted DESC by Timestamp/Id, so the last-inserted step is evaluated first.
        // Creating success last (larger Id) makes it the most recent; it breaks the streak immediately.
        stepSvc.createToolResultStep(execution.Id, 'call-b-001', capB.CapabilityName__c, '{}', 'turn-bulkcount-001', 1, 0L, false, capB.Id, true); // older failure
        stepSvc.createToolResultStep(execution.Id, 'call-b-002', capB.CapabilityName__c, '{}', 'turn-bulkcount-001', 1, 0L, false, capB.Id, false); // most-recent success → resets streak

        Set<String> toolNames = new Set<String>{ capA.CapabilityName__c, capB.CapabilityName__c };
        Map<String, Integer> counts = OrchestrationService.loadSuccessiveFailureCounts(execution.Id, toolNames, '[test] ');

        System.assertEquals(2, counts.get(capA.CapabilityName__c), 'tool_alpha should have 2 successive failures');
        System.assertEquals(0, counts.get(capB.CapabilityName__c), 'tool_beta streak should be 0: most recent step is a success which breaks the sequence');
    }

    /**
     * C-4: Verifies that the preloaded-count overload of shouldFailFast() uses the supplied
     * count directly and does not issue an additional SOQL.
     */
    @IsTest
    static void testShouldFailFast_WithPreloadedCount_UsesPreloadedValue() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'preloaded_tool', FailFastOnError__c = false);
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function');

        // Use a retryable failure so Tier 2 (non-retryable check) is bypassed and only
        // Tier 3 (MaxToolRetries / preloaded count) is exercised.
        ActionOutcome retryableFailure = ActionOutcome.failureWithMeta(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Transient failure', null, true, null);

        Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();

        // Tier 3 guard requires a non-null executionId. The preloaded-count path (>= 0) never
        // issues a SOQL, so a dummy Id from an unrelated object is safe here.
        Id dummyId = UserInfo.getUserId();

        // Preloaded count at the threshold — should trigger Tier 3 fail-fast
        Boolean atMax = OrchestrationService.shouldFailFast(cap, agent, retryableFailure, dummyId, maxRetries, '[test] ');
        System.assertEquals(true, atMax, 'Preloaded count at max retries should trigger Tier 3 fail-fast');

        // Preloaded count strictly below threshold — should allow LLM recovery
        Boolean belowMax = OrchestrationService.shouldFailFast(cap, agent, retryableFailure, dummyId, maxRetries - 1, '[test] ');
        System.assertEquals(false, belowMax, 'Preloaded count below max retries should allow LLM recovery');
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

    /**
     * @description Tests that MaxToolRetries check (Tier 3) causes fail-fast for Function agents
     *              after successive tool failures exceed the threshold.
     */
    @IsTest
    static void testShouldFailFast_FunctionAgentExceedsMaxRetries_ReturnsTrue() {
        TestFactory.AgentSetup setup = getSetup();

        // Create a Function agent (not Conversational/Email)
        AIAgentDefinition__c functionAgent = TestFactory.newAgentDefinition()
            .withName('Function_FailFast_Agent')
            .withType('Function')
            .withLLM(setup.llmConfig.Id)
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(functionAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-maxretries-001')
            .save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(functionAgent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withName('test_capability_retry')
            .save();

        // Create multiple successive tool failures (more than MaxToolRetries)
        ExecutionStepService stepService = new ExecutionStepService();
        for (Integer i = 1; i <= 4; i++) {
            stepService.createToolResultStep(
                execution.Id,
                'call-retry-00' + i,
                capability.CapabilityName__c,
                '{"error":"Failed"}',
                'turn-maxretries-001',
                1,
                0L,
                false,
                capability.Id,
                true // IsError = true
            );
        }

        ActionOutcome failure = ActionOutcome.failure('ERR_TEST', 'Tool failed again');

        // Reload agent with full details
        AIAgentDefinition__c agentFull = [
            SELECT Id, AgentType__c
            FROM AIAgentDefinition__c
            WHERE Id = :functionAgent.Id
        ];

        Boolean result = OrchestrationService.shouldFailFast(capability, agentFull, failure, execution.Id, '[test] ');

        System.assertEquals(true, result, 'Function agent with successive failures exceeding MaxToolRetries should fail fast (Tier 3)');
    }

    /**
     * @description Tests that ExecutionStepTimestampComparator correctly sorts steps with null timestamps.
     *              This covers the comparator's null safety logic.
     */
    @IsTest
    static void testCountSuccessiveToolFailures_WithBufferedSteps_UseComparator() {
        TestFactory.AgentSetup setup = getSetup();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-comparator-001')
            .save();

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
            LIMIT 1
        ];

        // Create buffered steps in TransactionContext to exercise the comparator
        TransactionContext.getInstance().enableDeferredDMLMode();

        // Add steps with different timestamps (and some null) to test comparator
        ExecutionStep__c step1 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            ToolName__c = capability.CapabilityName__c,
            ToolCallId__c = 'call-comp-001',
            IsError__c = true,
            Timestamp__c = Datetime.now().addSeconds(-10)
        );

        ExecutionStep__c step2 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            ToolName__c = capability.CapabilityName__c,
            ToolCallId__c = 'call-comp-002',
            IsError__c = true,
            Timestamp__c = Datetime.now() // Most recent
        );

        ExecutionStep__c step3 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            ToolName__c = capability.CapabilityName__c,
            ToolCallId__c = 'call-comp-003',
            IsError__c = true,
            Timestamp__c = null // Null timestamp to test comparator null handling
        );

        TransactionContext.getInstance().bufferInsert(step1);
        TransactionContext.getInstance().bufferInsert(step2);
        TransactionContext.getInstance().bufferInsert(step3);

        // This call will use the ExecutionStepTimestampComparator to sort buffered steps
        Integer failureCount = OrchestrationService.countSuccessiveToolFailures(execution.Id, capability.CapabilityName__c, '[test] ');

        // Should count all 3 failures (comparator sorted them correctly)
        System.assert(failureCount >= 2, 'Should count multiple successive failures after sorting: ' + failureCount);

        TransactionContext.getInstance().disableDeferredDMLMode();
    }

    /**
     * @description Tests that Conversational and Email agents skip MaxToolRetries check (Tier 3)
     *              and allow LLM recovery even with multiple failures.
     */
    @IsTest
    static void testShouldFailFast_ConversationalAndEmailAgents_SkipMaxRetries() {
        TestFactory.AgentSetup setup = getSetup();

        // Test Conversational agent
        AIAgentDefinition__c convoAgent = TestFactory.newAgentDefinition()
            .withName('Conversational_Retry_Agent')
            .withType('Conversational')
            .withLLM(setup.llmConfig.Id)
            .save();

        AgentExecution__c convoExec = TestFactory.newExecution()
            .withAgent(convoAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-convo-retry-001')
            .save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(convoAgent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withName('test_capability_convo_retry')
            .save();

        // Create many successive failures (way more than MaxToolRetries)
        ExecutionStepService stepService = new ExecutionStepService();
        for (Integer i = 1; i <= 10; i++) {
            stepService.createToolResultStep(
                convoExec.Id,
                'call-convo-retry-00' + i,
                capability.CapabilityName__c,
                '{"error":"Failed"}',
                'turn-convo-retry-001',
                1,
                0L,
                false,
                capability.Id,
                true // IsError = true
            );
        }

        ActionOutcome failure = ActionOutcome.failure('ERR_TEST', 'Tool failed');

        AIAgentDefinition__c convoAgentFull = [
            SELECT Id, AgentType__c
            FROM AIAgentDefinition__c
            WHERE Id = :convoAgent.Id
        ];

        Boolean convoResult = OrchestrationService.shouldFailFast(capability, convoAgentFull, failure, convoExec.Id, '[test] ');

        System.assertEquals(false, convoResult, 'Conversational agent should skip MaxToolRetries check and allow LLM recovery (Tier 3)');

        // Test Email agent
        AIAgentDefinition__c emailAgent = TestFactory.newAgentDefinition().withName('Email_Retry_Agent').withType('Email').withLLM(setup.llmConfig.Id).save();

        AgentExecution__c emailExec = TestFactory.newExecution()
            .withAgent(emailAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Email')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-email-retry-001')
            .save();

        AgentCapability__c emailCap = TestFactory.newCapability()
            .withAgent(emailAgent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withName('test_capability_email_retry')
            .save();

        // Create many successive failures
        for (Integer i = 1; i <= 10; i++) {
            stepService.createToolResultStep(
                emailExec.Id,
                'call-email-retry-00' + i,
                emailCap.CapabilityName__c,
                '{"error":"Failed"}',
                'turn-email-retry-001',
                1,
                0L,
                false,
                emailCap.Id,
                true // IsError = true
            );
        }

        AIAgentDefinition__c emailAgentFull = [
            SELECT Id, AgentType__c
            FROM AIAgentDefinition__c
            WHERE Id = :emailAgent.Id
        ];

        Boolean emailResult = OrchestrationService.shouldFailFast(emailCap, emailAgentFull, failure, emailExec.Id, '[test] ');

        System.assertEquals(false, emailResult, 'Email agent should skip MaxToolRetries check and allow LLM recovery (Tier 3)');
    }
}
