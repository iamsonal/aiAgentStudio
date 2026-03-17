/**
 * @description Focused tests for DirectAsyncRuntimeService using shared TestFactory helpers
 */
@IsTest
private class DirectAsyncRuntimeServiceTest {
    @TestSetup
    static void setupData() {
        AgentCapability__c syncCapability = TestFactory.newCapability()
            .withName('get_case_details')
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .build();

        AgentCapability__c asyncCapability = TestFactory.newCapability().forCreateRecord('Account').withName('create_account_async').async().build();

        TestFactory.createFunctionAgentSetup().withAuditLevel('Standard').withCapability(syncCapability).withCapability(asyncCapability).save();

        TestFactory.newCase().withSubject('Async Function Case').save();
    }

    @IsTest
    static void testExecute_TextOnlyResponse_Standalone_ReturnsImmediately() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Quick summary.'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Summarize case',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-text-001',
            new List<AgentCapability__c>(),
            null
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Text-only response should succeed');
        System.assertEquals(null, result.executionId, 'Standalone text response should not create execution');
        System.assertEquals('Completed', result.status, 'Status should be Completed');
        System.assertEquals(false, result.requiresPolling, 'Should not require polling for text response');
    }

    @IsTest
    static void testExecute_ResetsTurnSafetyTrackingAtStart() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        TransactionContext.resetInstance();
        TransactionContext ctx = TransactionContext.getInstance();
        ctx.setUnsafeOperationsForTest(true);
        System.assertEquals(true, ctx.hasUnsafeOperationsThisTurn(), 'Precondition: unsafe flag should be set');

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Quick summary.'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Summarize case',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-reset-001',
            new List<AgentCapability__c>(),
            null
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Text-only response should succeed');
        System.assertEquals(false, TransactionContext.getInstance().hasUnsafeOperationsThisTurn(), 'Turn safety flag should reset at turn start');
    }

    @IsTest
    static void testExecute_AsyncToolCall_CreatesExecutionAndQueuesAction() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        AgentCapability__c capability = [
            SELECT CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = TRUE
            LIMIT 1
        ];

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse(capability.CapabilityName__c, '{"recordData":{"Name":"Async Account"}}', 'Creating account'))
            .addTextResponse('Async tool completed.');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Create account', testCase.Id, UserInfo.getUserId(), 'turn-async-tool-001', capabilities, null);
        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        Test.stopTest();

        System.assertEquals(true, result.success, 'Async tool call should succeed');
        System.assertEquals('Processing', result.status, 'Status should be Processing');
        System.assertEquals(true, result.requiresPolling, 'Async tool requires polling');
        System.assertNotEquals(null, result.executionId, 'Should create execution record');
        System.assertEquals('Processing', execution.ExecutionStatus__c, 'Execution should be Processing');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_ACTION, execution.ProcessingStatus__c, 'Processing status should be Awaiting Action');
    }

    @IsTest
    static void testExecute_SyncToolCall_CreatesToolStepsAndQueuesFollowUp() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        AgentCapability__c syncCapability = [
            SELECT CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse(syncCapability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'Fetching case details'))
            .addTextResponse('Case details ready.');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Get case details', testCase.Id, UserInfo.getUserId(), 'turn-async-sync-001', capabilities, null);
        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :result.executionId AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        Test.stopTest();

        System.assertEquals(true, result.success, 'Sync tool call should succeed');
        System.assertEquals('Processing', result.status, 'Status should be Processing');
        System.assertEquals(true, result.requiresPolling, 'Sync tool path should require polling for follow-up');
        System.assertNotEquals(null, result.executionId, 'Should create execution record');
        System.assertEquals('Processing', execution.ExecutionStatus__c, 'Execution should be Processing');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_FOLLOWUP, execution.ProcessingStatus__c, 'Processing status should be Awaiting Followup');
        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testExecute_SyncToolCall_DisablesDeferredDml() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        AgentCapability__c syncCapability = [
            SELECT CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse(syncCapability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'Fetching case details'))
            .addTextResponse('Case details ready.');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        orchestrator.execute('Get case details', testCase.Id, UserInfo.getUserId(), 'turn-async-sync-002', capabilities, null);
        Test.stopTest();

        System.assertEquals(
            false,
            TransactionContext.getInstance().isDeferredDMLMode(),
            'Deferred DML mode should be disabled after single sync tool execution'
        );
    }

    @IsTest
    static void testExecute_FailFastRespectsMaxToolRetriesForExistingExecution() {
        insert new AIAgentFrameworkSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), MaxToolRetries__c = 1);

        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-async-retry-001')
            .save();

        AgentCapability__c syncCapability = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        insert new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = syncCapability.CapabilityName__c,
            IsError__c = true,
            Timestamp__c = Datetime.now()
        );

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse(syncCapability.CapabilityName__c, '{}', 'Attempting tool'));
        Test.setMock(HttpCalloutMock.class, mock);

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Try tool',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-retry-001',
            new List<AgentCapability__c>{ syncCapability },
            execution.Id
        );
        Test.stopTest();

        System.assertEquals(false, result.success, 'Fail-fast should stop execution once retry limit is exceeded');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updatedExecution.ExecutionStatus__c, 'Execution should be marked Failed');
    }

    @IsTest
    static void testExecute_TextResponse_WithExistingExecution_Completes() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-async-text-existing-001')
            .save();

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Summarize case',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-text-existing-001',
            new List<AgentCapability__c>(),
            execution.Id
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Text response should succeed');
        System.assertEquals(execution.Id, result.executionId, 'Should reuse existing execution');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'Execution should be completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing status should be Idle');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c IN ('UserInput', 'AgentResponse')
        ];
        System.assertEquals(2, steps.size(), 'Should create user input and response steps');
    }

    @IsTest
    static void testExecute_WithExistingExecution_EnablesDeferredDmlBeforeFirstLlmCall() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(testCase.Id)
            .withTurnIdentifier('turn-async-cache-seed-001')
            .save();

        TransactionContext.resetInstance();
        LLMInteractionService.clearAllRequestCaches();

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Done.'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Summarize case',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-cache-seed-001',
            new List<AgentCapability__c>(),
            execution.Id
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Execution should succeed');
        System.assertEquals(
            true,
            LLMInteractionService.requestCacheByExecution.containsKey(execution.Id),
            'First LLM cycle should seed request cache for existing execution (deferred DML enabled before call)'
        );
    }

    @IsTest
    static void testExecute_UnknownTool_ReturnsConfigError() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        MockHttpResponses mock = MockHttpResponses.conversational().addResponse(MockHttpResponses.toolCallResponse('unknown_tool', '{}', 'Attempting tool'));
        Test.setMock(HttpCalloutMock.class, mock);

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Try tool',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-async-unknown-001',
            new List<AgentCapability__c>(),
            null
        );
        Test.stopTest();

        System.assertEquals(false, result.success, 'Unknown tool should fail');
        System.assert(
            result.errorCode == AIAgentConstants.ERR_CODE_CONFIG_ERROR || result.errorCode == AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
            'Should return config or unexpected error code, got: ' + result.errorCode
        );
        System.assert(String.isNotBlank(result.errorMessage), 'Error message should be set');
        System.assert(result.errorMessage.contains('unknown_tool'), 'Error should reference unknown tool name');
    }

    /**
     * R-3: Verifies that handleSyncToolResult() populates the AgentCapability__c lookup on both
     * the ToolCall and ToolResult ExecutionStep__c records.
     * Before the fix, both steps were created with null capabilityId, breaking all reporting
     * queries and UI components that join on AgentCapability__c.
     */
    @IsTest
    static void testExecute_SyncToolResult_CreatesStepsWithCapabilityId() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        AgentCapability__c syncCapability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse(syncCapability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'Fetching'))
            .addTextResponse('Done.');
        Test.setMock(HttpCalloutMock.class, mock);

        DirectAsyncRuntimeService orchestrator = new DirectAsyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Get case details',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-capability-id-001',
            capabilities,
            null
        );
        Test.stopTest();

        System.assertEquals(true, result.success, 'Sync tool execution should succeed');
        System.assertNotEquals(null, result.executionId, 'Should create execution');

        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c, AIAgentCapability__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :result.executionId AND StepType__c IN ('ToolCall', 'ToolResult') AND ToolName__c = :syncCapability.CapabilityName__c
        ];

        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
        for (ExecutionStep__c step : toolSteps) {
            System.assertEquals(
                syncCapability.Id,
                step.AIAgentCapability__c,
                step.StepType__c + ' step must have AIAgentCapability__c populated (was null before R-3 fix)'
            );
        }
    }

    private static TestFactory.FunctionAgentSetup getSetup() {
        AgentCapability__c capability = [
            SELECT AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'create_account_async'
            LIMIT 1
        ];
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, EnableParallelToolCalling__c, RuntimeStrategy__c
            FROM AIAgentDefinition__c
            WHERE Id = :capability.AIAgentDefinition__c
            LIMIT 1
        ];
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c WHERE Id = :agent.LLMConfiguration__c LIMIT 1];

        TestFactory.FunctionAgentSetup setup = new TestFactory.FunctionAgentSetup();
        setup.agentDefinition = agent;
        setup.llmConfig = llm;
        return setup;
    }
}
