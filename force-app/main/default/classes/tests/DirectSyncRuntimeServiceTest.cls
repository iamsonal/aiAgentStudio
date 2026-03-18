/**
 * @description Focused tests for DirectSyncRuntimeService using shared TestFactory helpers
 */
@IsTest
private class DirectSyncRuntimeServiceTest {
    @TestSetup
    static void setupData() {
        AgentCapability__c capability = TestFactory.newCapability()
            .withName('get_case_details')
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .build();

        TestFactory.createFunctionAgentSetup().withAuditLevel('Standard').withCapability(capability).save();

        TestFactory.newCase().withSubject('Sync Function Case').save();
    }

    @IsTest
    static void testExecute_TextResponse_CreatesExecutionAndSteps() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        DirectSyncRuntimeService orchestrator = new DirectSyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Summary complete.'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Summarize case', testCase.Id, UserInfo.getUserId(), 'turn-sync-text-001', capabilities, null);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Text response should succeed');
        System.assertNotEquals(null, result.executionId, 'Should create execution record');
        System.assertEquals('Completed', result.status, 'Status should be Completed');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        System.assertEquals('Completed', execution.ExecutionStatus__c, 'Execution should be Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing should be Idle');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :result.executionId
        ];
        System.assert(!steps.isEmpty(), 'Should create execution steps');
    }

    @IsTest
    static void testExecute_ToolCall_CreatesToolStepsAndCompletes() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        DirectSyncRuntimeService orchestrator = new DirectSyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCall('get_case_details', '{"Id":"' + testCase.Id + '"}'));

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Get case details', testCase.Id, UserInfo.getUserId(), 'turn-sync-tool-001', capabilities, null);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Tool call should succeed');
        System.assertEquals('Completed', result.status, 'Status should be Completed');
        System.assertNotEquals(null, result.executionId, 'Should create execution record');

        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :result.executionId AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testExecute_MultipleToolCalls_Fails() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction('get_case_details', '{"Id":"' + testCase.Id + '"}', 'call-multi-001'),
            TestFactory.createToolCallAction('get_case_details', '{"Id":"' + testCase.Id + '"}', 'call-multi-002')
        };

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCalls(actions, 'Multiple tools'));

        DirectSyncRuntimeService orchestrator = new DirectSyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Get case details', testCase.Id, UserInfo.getUserId(), 'turn-sync-multi-001', capabilities, null);
        Test.stopTest();

        System.assertEquals(false, result.success, 'Multiple tool calls should fail in tool-terminating pattern');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode, 'Should return config error for multiple tools');
        System.assertEquals('Failed', result.status, 'Status should be Failed');
        System.assertEquals(null, result.executionId, 'Should not create execution record on failure');
    }

    @IsTest
    static void testExecute_ToolCallWithoutCapabilities_Fails() {
        TestFactory.FunctionAgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCall('get_case_details', '{"Id":"' + testCase.Id + '"}'));

        DirectSyncRuntimeService orchestrator = new DirectSyncRuntimeService(setup.agentDefinition, setup.llmConfig);

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute(
            'Get case details',
            testCase.Id,
            UserInfo.getUserId(),
            'turn-sync-nocaps-001',
            new List<AgentCapability__c>(),
            null
        );
        Test.stopTest();

        System.assertEquals(false, result.success, 'Tool call with no capabilities should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode, 'Should return config error for missing capabilities');
        System.assertEquals('Failed', result.status, 'Status should be Failed');
    }

    private static TestFactory.FunctionAgentSetup getSetup() {
        AgentCapability__c capability = [
            SELECT AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'get_case_details'
            LIMIT 1
        ];
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, LLMConfiguration__c, AuditLevel__c
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
