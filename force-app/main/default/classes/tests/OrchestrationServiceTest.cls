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
        ActionOutcome outcome = ActionOutcome.failure('ERR_TEST', 'Failure', 'Try again');

        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');
        System.assert(json.contains('"success":false'), 'Serialized output should indicate failure');
        System.assert(json.contains('"error"'), 'Serialized output should include error field');
        System.assert(json.contains('Try again'), 'Serialized output should include guidance');
        System.assert(!json.contains('messageForUser'), 'Should not include display-only messageForUser field');
        System.assert(!json.contains('errorCategory'), 'Should not include framework-internal errorCategory');
        System.assert(!json.contains('"errorCode"'), 'Should use code not errorCode in LLM payload');
        System.assert(json.contains('"code"'), 'Should include code field for LLM context');
    }

    @IsTest
    static void testSerializeActionOutcome_NullOutcome_ReturnsErrorJson() {
        String json = OrchestrationService.serializeActionOutcome(null, '[test] ');

        System.assert(json.contains('"success":false'), 'Null outcome should return error JSON');
        System.assert(json.contains('"retryable":false'), 'Null outcome should not be retryable');
    }

    @IsTest
    static void testSerializeActionOutcome_SuccessWithNullData_ReturnsNoDataKey() {
        ActionOutcome outcome = ActionOutcome.success();
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"success":true'), 'Success should be indicated');
        System.assert(!json.contains('"data"'), 'Success with null data should omit data key');
    }

    @IsTest
    static void testSerializeActionOutcome_FailureWithGuidance_IncludesGuidanceKey() {
        // correctionGuidance is always populated from ErrorHandlerConfig__mdt.LLMGuidance__c.
        // It should appear under the 'guidance' key (not 'correctionGuidance') in the LLM payload.
        ActionOutcome outcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Something failed');
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"success":false'), 'Should indicate failure');
        System.assert(json.contains('"guidance"'), 'Metadata guidance should appear under the guidance key');
        System.assert(!json.contains('correctionGuidance'), 'Internal field name correctionGuidance should not appear in LLM payload');
    }

    @IsTest
    static void testSerializeActionOutcome_TransientError_RetryableTrue() {
        ActionOutcome outcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Timeout');
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"retryable":true'), 'Transient error code should produce retryable:true');
    }

    @IsTest
    static void testSerializeActionOutcome_NonTransientError_RetryableFalse() {
        ActionOutcome outcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid input');
        String json = OrchestrationService.serializeActionOutcome(outcome, '[test] ');

        System.assert(json.contains('"retryable":false'), 'Non-transient error code should produce retryable:false');
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
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function', ErrorRecoveryMode__c = 'Autonomous');
        ActionOutcome success = ActionOutcome.success();

        System.assertEquals(false, OrchestrationService.shouldFailFast(cap, agent, success, null, '[test] '), 'Success outcome should never fail fast');
    }

    @IsTest
    static void testShouldFailFast_NullOutcome_ReturnsFalse() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function', ErrorRecoveryMode__c = 'Autonomous');

        System.assertEquals(false, OrchestrationService.shouldFailFast(cap, agent, null, null, '[test] '), 'Null outcome should return false');
    }

    @IsTest
    static void testShouldFailFast_FailFastMode_ReturnsTrue() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function', ErrorRecoveryMode__c = 'Fail Fast');
        ActionOutcome failure = ActionOutcome.failure('ERR', 'Failed');

        System.assertEquals(true, OrchestrationService.shouldFailFast(cap, agent, failure, null, '[test] '), 'Fail Fast mode should immediately return true');
    }

    @IsTest
    static void testShouldFailFast_AutonomousMode_AllowsLLMRecovery() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Conversational', ErrorRecoveryMode__c = 'Autonomous');
        // Must use a transient error code so the non-transient shortcut does not fire before the circuit breaker logic
        ActionOutcome failure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Transient network error');

        System.assertEquals(
            false,
            OrchestrationService.shouldFailFast(cap, agent, failure, null, '[test] '),
            'Autonomous mode with transient error should allow LLM recovery (circuit breaker not yet hit)'
        );
    }

    @IsTest
    static void testShouldFailFast_NonTransientError_FailsFastImmediately() {
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'test_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function', ErrorRecoveryMode__c = 'Autonomous');
        // Non-transient errors should fail fast even in Autonomous mode — retrying cannot resolve them
        ActionOutcome permissionFailure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, 'Access denied');

        System.assertEquals(
            true,
            OrchestrationService.shouldFailFast(cap, agent, permissionFailure, null, '[test] '),
            'Non-transient error should fail fast regardless of recovery mode'
        );

        ActionOutcome inputFailure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid argument');
        System.assertEquals(
            true,
            OrchestrationService.shouldFailFast(cap, agent, inputFailure, null, '[test] '),
            'INPUT_VALIDATION should fail fast — LLM must fix args, not retry same call'
        );

        ActionOutcome configFailure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Bad config');
        System.assertEquals(
            true,
            OrchestrationService.shouldFailFast(cap, agent, configFailure, null, '[test] '),
            'CONFIG_ERROR should fail fast — needs admin intervention'
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
        AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'preloaded_tool');
        AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = 'Function', ErrorRecoveryMode__c = 'Autonomous');

        // Must use a transient error code so the non-transient shortcut does not short-circuit before the preloaded count is evaluated
        ActionOutcome retryableFailure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Transient network failure');

        Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();

        // The preloaded-count path (>= 0) never issues a SOQL, so a dummy Id is safe here.
        Id dummyId = UserInfo.getUserId();

        // Preloaded count at the threshold — should trigger circuit breaker
        Boolean atMax = OrchestrationService.shouldFailFast(cap, agent, retryableFailure, dummyId, maxRetries, '[test] ');
        System.assertEquals(true, atMax, 'Preloaded count at max retries should trigger circuit breaker');

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
     * @description Tests that the global MaxToolRetries circuit breaker fires for any agent type
     *              in Autonomous mode after successive tool failures exceed the threshold.
     */
    @IsTest
    static void testShouldFailFast_FunctionAgentExceedsMaxRetries_ReturnsTrue() {
        TestFactory.AgentSetup setup = getSetup();

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

        // Use a transient error to ensure the circuit breaker logic (not the non-transient shortcut) causes the halt
        ActionOutcome failure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Transient tool failure');

        // Reload agent with full details
        AIAgentDefinition__c agentFull = [
            SELECT Id, AgentType__c, ErrorRecoveryMode__c
            FROM AIAgentDefinition__c
            WHERE Id = :functionAgent.Id
        ];

        Boolean result = OrchestrationService.shouldFailFast(capability, agentFull, failure, execution.Id, '[test] ');

        System.assertEquals(true, result, 'Function agent with successive transient failures exceeding MaxToolRetries should fail fast via circuit breaker');
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
     * @description Verifies that the MaxToolRetries circuit breaker is agent-type agnostic.
     *              Conversational and Email agents in Autonomous mode must hit the circuit breaker
     *              once successive failures exceed the global threshold — there is no special exemption
     *              based on agent type. ErrorRecoveryMode__c is the sole controlling factor.
     */
    @IsTest
    static void testShouldFailFast_AllAgentTypes_HitCircuitBreakerInAutonomousMode() {
        TestFactory.AgentSetup setup = getSetup();
        Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
        // Use a transient error so the circuit breaker (not the non-transient shortcut) is what fires
        ActionOutcome failure = ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Transient tool failure');

        for (String agentType : new List<String>{ 'Conversational', 'Email' }) {
            AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
                .withName(agentType + '_CircuitBreaker_Agent')
                .withType(agentType)
                .withLLM(setup.llmConfig.Id)
                .save();

            AgentExecution__c exec = TestFactory.newExecution()
                .withAgent(agent.Id)
                .withUser(UserInfo.getUserId())
                .withExecutionType(agentType)
                .withStatus('Processing')
                .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
                .withTurnIdentifier('turn-cb-' + agentType.toLowerCase() + '-001')
                .save();

            AgentCapability__c cap = TestFactory.newCapability()
                .withAgent(agent.Id)
                .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
                .withName('cap_cb_' + agentType.toLowerCase())
                .save();

            ExecutionStepService stepService = new ExecutionStepService();
            for (Integer i = 1; i <= maxRetries + 2; i++) {
                stepService.createToolResultStep(
                    exec.Id,
                    'call-cb-' + agentType.toLowerCase() + '-00' + i,
                    cap.CapabilityName__c,
                    '{"error":"Failed"}',
                    'turn-cb-' + agentType.toLowerCase() + '-001',
                    1,
                    0L,
                    false,
                    cap.Id,
                    true
                );
            }

            AIAgentDefinition__c agentFull = [
                SELECT Id, AgentType__c, ErrorRecoveryMode__c
                FROM AIAgentDefinition__c
                WHERE Id = :agent.Id
            ];

            Boolean result = OrchestrationService.shouldFailFast(cap, agentFull, failure, exec.Id, '[test] ');

            System.assertEquals(
                true,
                result,
                agentType +
                ' agent in Autonomous mode should hit the circuit breaker after exceeding MaxToolRetries — agent type does not exempt any agent from the global ceiling'
            );
        }
    }

    /**
     * @description Verifies that countSuccessiveToolFailures() scopes to failures AFTER the resume
     *              timestamp when resumeAfter is provided. Pre-resume failures must not count against
     *              the post-resume circuit breaker budget.
     */
    @IsTest
    static void testCountSuccessiveToolFailures_WithResumeAfter_ScopsToPostResumeWindow() {
        TestFactory.AgentSetup setup = getSetup();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-scope-resume-001')
            .save();

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
            LIMIT 1
        ];

        ExecutionStepService stepSvc = new ExecutionStepService();
        Datetime beforeResume = Datetime.now().addSeconds(-60);
        Datetime afterResume = Datetime.now().addSeconds(-10);

        // Two failures BEFORE resume — these must not be counted
        ExecutionStep__c preFail1 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = beforeResume.addSeconds(-10)
        );
        ExecutionStep__c preFail2 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = beforeResume.addSeconds(-5)
        );
        // One failure AFTER resume — only this one should count
        ExecutionStep__c postFail = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = afterResume
        );
        insert new List<ExecutionStep__c>{ preFail1, preFail2, postFail };

        // Without resume scoping: all 3 successive failures counted
        Integer allFailures = OrchestrationService.countSuccessiveToolFailures(execution.Id, capability.CapabilityName__c, '[test] ');
        System.assertEquals(3, allFailures, 'Without resume scoping all 3 successive failures should be counted');

        // With resume scoping at beforeResume: only the 1 post-resume failure should count
        Integer scopedFailures = OrchestrationService.countSuccessiveToolFailures(execution.Id, capability.CapabilityName__c, beforeResume, '[test] ');
        System.assertEquals(1, scopedFailures, 'With resumeAfter, only failures after the resume timestamp should count');
    }

    /**
     * @description Verifies that a success step between pre- and post-resume failures still correctly
     *              resets the consecutive count, even when resume scoping is active.
     */
    @IsTest
    static void testCountSuccessiveToolFailures_WithResumeAfter_SuccessStillResetsStreak() {
        TestFactory.AgentSetup setup = getSetup();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-scope-success-001')
            .save();

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
            LIMIT 1
        ];

        Datetime resumeTs = Datetime.now().addSeconds(-30);

        // Steps newest-first after resume: fail → success → fail
        // The success in the middle breaks the streak so count should be 1 (only the most recent fail)
        ExecutionStep__c fail2 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = Datetime.now().addSeconds(-5) // newest
        );
        ExecutionStep__c success = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = false,
            Timestamp__c = Datetime.now().addSeconds(-15) // middle
        );
        ExecutionStep__c fail1 = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = capability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = Datetime.now().addSeconds(-20) // oldest post-resume
        );
        insert new List<ExecutionStep__c>{ fail2, success, fail1 };

        Integer count = OrchestrationService.countSuccessiveToolFailures(execution.Id, capability.CapabilityName__c, resumeTs, '[test] ');
        System.assertEquals(1, count, 'Success step between failures should reset the streak even with resume scoping');
    }

    /**
     * @description Verifies loadSuccessiveFailureCounts() applies the same resume-after scoping
     *              as countSuccessiveToolFailures() when resumeAfter is provided.
     */
    @IsTest
    static void testLoadSuccessiveFailureCounts_WithResumeAfter_ScopsToPostResumeWindow() {
        TestFactory.AgentSetup setup = getSetup();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-bulk-scope-001')
            .save();

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
            LIMIT 1
        ];

        Datetime resumeTs = Datetime.now().addSeconds(-30);

        // 2 pre-resume failures + 1 post-resume failure
        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                IsError__c = true,
                Timestamp__c = resumeTs.addSeconds(-20)
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                IsError__c = true,
                Timestamp__c = resumeTs.addSeconds(-10)
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                IsError__c = true,
                Timestamp__c = resumeTs.addSeconds(10)
            )
        };

        Map<String, Integer> counts = OrchestrationService.loadSuccessiveFailureCounts(
            execution.Id,
            new Set<String>{ capability.CapabilityName__c },
            resumeTs,
            '[test] '
        );

        System.assertEquals(1, counts.get(capability.CapabilityName__c), 'Bulk failure count should respect resumeAfter and return only post-resume failures');
    }

    /**
     * @description Verifies that Fail Fast mode halts immediately for non-Function agent types.
     *              ErrorRecoveryMode__c = Fail Fast must apply uniformly regardless of AgentType__c.
     */
    @IsTest
    static void testShouldFailFast_FailFastMode_AppliesToAllAgentTypes() {
        ActionOutcome failure = ActionOutcome.failure('ERR_TEST', 'Tool failed');

        for (String agentType : new List<String>{ 'Conversational', 'Email', 'Workflow', 'Function' }) {
            AgentCapability__c cap = new AgentCapability__c(CapabilityName__c = 'cap_ff_' + agentType.toLowerCase());
            AIAgentDefinition__c agent = new AIAgentDefinition__c(AgentType__c = agentType, ErrorRecoveryMode__c = 'Fail Fast');

            System.assertEquals(
                true,
                OrchestrationService.shouldFailFast(cap, agent, failure, null, '[test] '),
                agentType + ' agent with Fail Fast mode should halt immediately on any tool error'
            );
        }
    }

    // ─── detectUnretriedFailures tests ────────────────────────────────────────

    /**
     * @description detectUnretriedFailures returns an empty list when there are no
     *              RetryPending=true steps in the turn.
     */
    @IsTest
    static void testDetectUnretriedFailures_NoFailures_ReturnsEmpty() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-duf-001')
            .save();

        // No steps at all — expect empty
        List<OrchestrationService.UnretriedFailure> result = OrchestrationService.detectUnretriedFailures(
            execution.Id,
            setup.agentDefinition.Id,
            'turn-duf-001',
            '[test] '
        );

        System.assertEquals(0, result.size(), 'Should return empty when no RetryPending steps exist');
    }

    /**
     * @description detectUnretriedFailures returns the failed tool when a RetryPending=true
     *              step exists with no subsequent success.
     */
    @IsTest
    static void testDetectUnretriedFailures_WithRetryPendingFailure_ReturnsFailure() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-duf-002')
            .save();

        // Seed a ToolCall step with known arguments
        insert new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolCall',
            StepRole__c = 'Assistant',
            ToolCallId__c = 'call-abc-001',
            ToolName__c = 'assign_to_queue',
            ToolArguments__c = '{"queueDeveloperName":"Support_Queue"}',
            TurnIdentifier__c = 'turn-duf-002',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-10)
        );

        // Seed a retryable failure step
        insert new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolCallId__c = 'call-abc-001',
            ToolName__c = 'assign_to_queue',
            IsError__c = true,
            IsRetryable__c = true,
            RetryPending__c = true,
            TurnIdentifier__c = 'turn-duf-002',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addSeconds(-9)
        );

        List<OrchestrationService.UnretriedFailure> result = OrchestrationService.detectUnretriedFailures(
            execution.Id,
            setup.agentDefinition.Id,
            'turn-duf-002',
            '[test] '
        );

        System.assertEquals(1, result.size(), 'Should detect the unretried failure');
        System.assertEquals('assign_to_queue', result[0].toolName, 'Tool name should match');
        System.assertEquals('call-abc-001', result[0].toolCallId, 'Tool call ID should match');
        System.assertEquals('{"queueDeveloperName":"Support_Queue"}', result[0].originalArguments, 'Arguments should be populated from ToolCall step');
    }

    /**
     * @description detectUnretriedFailures excludes a failed tool when a later success exists
     *              for the same tool in the same turn (retry already happened).
     */
    @IsTest
    static void testDetectUnretriedFailures_WhenRetrySucceeded_ExcludesFromResult() {
        TestFactory.AgentSetup setup = getSetup();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-duf-003')
            .save();

        Datetime failureTs = Datetime.now().addSeconds(-20);
        Datetime successTs = Datetime.now().addSeconds(-5);

        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolCallId__c = 'call-retry-001',
                ToolName__c = 'assign_to_queue',
                IsError__c = true,
                IsRetryable__c = true,
                RetryPending__c = true,
                TurnIdentifier__c = 'turn-duf-003',
                Timestamp__c = failureTs
            ),
            // Success (retry) for the same tool
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolCallId__c = 'call-retry-002',
                ToolName__c = 'assign_to_queue',
                IsError__c = false,
                TurnIdentifier__c = 'turn-duf-003',
                Timestamp__c = successTs
            )
        };

        List<OrchestrationService.UnretriedFailure> result = OrchestrationService.detectUnretriedFailures(
            execution.Id,
            setup.agentDefinition.Id,
            'turn-duf-003',
            '[test] '
        );

        System.assertEquals(0, result.size(), 'Retry already succeeded — should not flag as unretried');
    }

    /**
     * @description detectUnretriedFailures handles null executionId gracefully.
     */
    @IsTest
    static void testDetectUnretriedFailures_NullExecutionId_ReturnsEmpty() {
        List<OrchestrationService.UnretriedFailure> result = OrchestrationService.detectUnretriedFailures(null, null, 'turn-x', '[test] ');
        System.assertEquals(0, result.size(), 'Null executionId should return empty list safely');
    }
}
