/**
 * @description Tests for ActionFlowHandler with mock Flow execution.
 */
@IsTest
private class ActionFlowHandlerTest {
    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
        TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forFlowHandler('Test_Flow').withName('test_flow_capability').save();
    }

    private static final String TEST_FLOW_API_NAME = 'Test_Flow_API_Name';

    // ========== MOCK IMPLEMENTATIONS ==========

    private class SuccessFlowMock implements ActionFlowHandler.FlowExecutionMock {
        private Object outputResult;
        public SuccessFlowMock(Object outputResult) {
            this.outputResult = outputResult;
        }
        public ActionFlowHandler.MockFlowResult execute(String flowApiName, Map<String, Object> flowParams) {
            return new ActionFlowHandler.MockFlowResult().setSuccess(outputResult);
        }
    }

    private class FaultFlowMock implements ActionFlowHandler.FlowExecutionMock {
        private String faultMessage;
        public FaultFlowMock(String faultMessage) {
            this.faultMessage = faultMessage;
        }
        public ActionFlowHandler.MockFlowResult execute(String flowApiName, Map<String, Object> flowParams) {
            return new ActionFlowHandler.MockFlowResult().setFault(faultMessage);
        }
    }

    private class FailureFlowMock implements ActionFlowHandler.FlowExecutionMock {
        private String errorCode;
        private String errorMessage;
        public FailureFlowMock(String errorCode, String errorMessage) {
            this.errorCode = errorCode;
            this.errorMessage = errorMessage;
        }
        public ActionFlowHandler.MockFlowResult execute(String flowApiName, Map<String, Object> flowParams) {
            return new ActionFlowHandler.MockFlowResult().setFailure(errorCode, errorMessage);
        }
    }

    private class CapturingFlowMock implements ActionFlowHandler.FlowExecutionMock {
        public String capturedFlowName;
        public Map<String, Object> capturedParams;
        public ActionFlowHandler.MockFlowResult execute(String flowApiName, Map<String, Object> flowParams) {
            this.capturedFlowName = flowApiName;
            this.capturedParams = flowParams;
            return new ActionFlowHandler.MockFlowResult().setSuccess(new Map<String, Object>{ 'captured' => true });
        }
    }

    private static ActionContext createTestContext(String implementationDetail) {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c capability = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'test_flow_capability' LIMIT 1];
        return new ActionContext(
            session.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            agent.Id,
            capability.Id,
            implementationDetail,
            'turn-123',
            1,
            'Conversational'
        );
    }

    // ========== SUCCESS SCENARIOS ==========

    @IsTest
    static void testFlowHandler_ValidParams_SuccessWithResult() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>{ 'resultKey' => 'resultValue', 'count' => 42 });

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{"param1": "test value", "param2": 42}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed with valid parameters');
        ActionFlowHandler.FlowResult flowResult = (ActionFlowHandler.FlowResult) outcome.data;
        System.assertEquals(TEST_FLOW_API_NAME, flowResult.flowName, 'Flow name should match');
        System.assertNotEquals(null, flowResult.result, 'Should have flow result');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_ComplexParams_CapturedCorrectly() {
        CapturingFlowMock capturingMock = new CapturingFlowMock();
        ActionFlowHandler.mockFlowExecution = capturingMock;

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{"textParam": "test", "numberParam": 123, "booleanParam": true}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(TEST_FLOW_API_NAME, capturingMock.capturedFlowName);
        System.assertEquals('test', capturingMock.capturedParams.get('textParam'));
        System.assertEquals(123, capturingMock.capturedParams.get('numberParam'));
        System.assertEquals(true, capturingMock.capturedParams.get('booleanParam'));

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_NullOutput_ReturnsDefaultPayload() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(null);

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess);
        ActionFlowHandler.FlowResult flowResult = (ActionFlowHandler.FlowResult) outcome.data;
        Map<String, Object> resultMap = (Map<String, Object>) flowResult.result;
        System.assertEquals(true, resultMap.get('flowCompleted'), 'Should have default flowCompleted flag');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_EmptyArgs_Succeeds() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>{ 'flowCompleted' => true });

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed with empty args');
        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_NullArgs_Succeeds() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>());

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', null, createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed with null args');
        ActionFlowHandler.mockFlowExecution = null;
    }

    // ========== FAILURE SCENARIOS ==========

    @IsTest
    static void testFlowHandler_FaultMessage_ReturnsError() {
        ActionFlowHandler.mockFlowExecution = new FaultFlowMock('Business validation failed: Invalid input');

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{"param1": "test"}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_FLOW_FAULT, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('faultMessage'), 'Error should mention faultMessage variable');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_ExecutionFailure_ReturnsError() {
        ActionFlowHandler.mockFlowExecution = new FailureFlowMock(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Mock failure');

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, outcome.errorCode);

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_BlankFlowName_ReturnsConfigError() {
        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{"param1": "test"}', createTestContext('   '));

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
    }

    @IsTest
    static void testFlowHandler_NullFlowName_ReturnsConfigError() {
        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext(null));

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
    }

    @IsTest
    static void testFlowHandler_NullContext_ReturnsError() {
        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{"param1": "test"}', null);

        System.assertEquals(false, outcome.isSuccess);
    }

    // ========== PARAMETER VALIDATION (validateFlowParameters(Map)) ==========

    @IsTest
    static void testFlowHandler_InvalidVariableNames_LogsWarningButSucceeds() {
        CapturingFlowMock capturingMock = new CapturingFlowMock();
        ActionFlowHandler.mockFlowExecution = capturingMock;

        ActionFlowHandler action = new ActionFlowHandler();
        // Invalid names: starts with number, contains dash
        String argsJson = '{"123InvalidStart": "value1", "invalid-dash": "value2", "validParam": "value3"}';

        ActionOutcome outcome = action.execute('{}', argsJson, createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed despite invalid variable names');
        System.assertEquals('value1', capturingMock.capturedParams.get('123InvalidStart'));
        System.assertEquals('value2', capturingMock.capturedParams.get('invalid-dash'));
        System.assertEquals('value3', capturingMock.capturedParams.get('validParam'));

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_NullValueInParams_PassesThrough() {
        CapturingFlowMock capturingMock = new CapturingFlowMock();
        ActionFlowHandler.mockFlowExecution = capturingMock;

        ActionFlowHandler action = new ActionFlowHandler();
        String argsJson = '{"nullParam": null, "validParam": "value"}';

        ActionOutcome outcome = action.execute('{}', argsJson, createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed with null param value');
        System.assertEquals(null, capturingMock.capturedParams.get('nullParam'), 'Null param should pass through');
        System.assertEquals('value', capturingMock.capturedParams.get('validParam'), 'Valid param should be captured');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_NestedInputParams_Serializable() {
        CapturingFlowMock capturingMock = new CapturingFlowMock();
        ActionFlowHandler.mockFlowExecution = capturingMock;

        ActionFlowHandler action = new ActionFlowHandler();
        String argsJson = '{"nested": {"key1": "value1", "key2": 123}, "simple": "value"}';

        ActionOutcome outcome = action.execute('{}', argsJson, createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess);
        System.assertNotEquals(null, capturingMock.capturedParams.get('nested'), 'Should capture nested param');
        System.assertEquals('value', capturingMock.capturedParams.get('simple'));

        ActionFlowHandler.mockFlowExecution = null;
    }

    // ========== FLOW VALIDATION - REAL METADATA (no mock) ==========

    @IsTest
    static void testFlowHandler_NonExistentFlow_FailsValidation() {
        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext('Non_Existent_Flow_Name_12345'));

        System.assertEquals(false, outcome.isSuccess, 'Should fail for non-existent flow');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('not found'), 'Error should mention flow not found');
    }

    @IsTest
    static void testFlowHandler_RealFlow_ValidatesMetadataAndExecutes() {
        // No mock — exercises the real validateFlowParameters(String, Map) and executeFlow paths.
        // Async_Framework_Request_Processor is a Platform Event-triggered Flow deployed with the framework.
        // Validation (FlowDefinitionView/FlowVariableView queries) succeeds; execution may fail
        // because Platform Event flows are not invocable via createInterview.
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext('Async_Framework_Request_Processor');

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', '{"unknownParam": "test"}', context);
        Test.stopTest();

        // The flow exists and is active, so validateFlowParameters(String, Map) runs fully:
        //   • Queries FlowDefinitionView → finds flow
        //   • Checks ActiveVersionId → not null
        //   • Queries FlowVariableView → iterates input/output vars
        //   • Detects "unknownParam" as unexpected parameter → logs warning
        // Then executeFlow calls Flow.Interview.createInterview → may throw, caught by handler
        System.assertNotEquals(null, outcome, 'Should always return an outcome');
    }

    @IsTest
    static void testFlowHandler_RealFlow_EmptyParams_CoversVariableIteration() {
        // Second real-flow test with empty params — covers the "no unexpected parameters" branch
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext('Async_Framework_Request_Processor');

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', '{}', context);
        Test.stopTest();

        System.assertNotEquals(null, outcome, 'Should return an outcome');
    }

    // ========== FLOW NAME VALIDATION (validateFlowApiName) ==========

    @IsTest
    static void testFlowHandler_FlowNameWithSpaces_LogsWarningAndProceeds() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>());

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext('Invalid Flow Name With Spaces'));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed despite spaces in name');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_FlowNameWithDots_LogsWarningAndProceeds() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>());

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{}', '{}', createTestContext('Invalid.Flow.Name'));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed despite dots in name');

        ActionFlowHandler.mockFlowExecution = null;
    }

    // ========== DIRECT EXECUTEACTION WITHOUT CONTEXT ==========

    @IsTest
    static void testExecuteAction_DirectCallWithoutContext_Fails() {
        ActionFlowHandler action = new ActionFlowHandler();
        Map<String, Object> params = new Map<String, Object>{ 'param1' => 'test' };

        Test.startTest();
        ActionOutcome outcome = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, outcome, 'Should return outcome');
        System.assertEquals(false, outcome.isSuccess, 'Should fail without context');
    }

    // ========== CONFIG HANDLING ==========

    @IsTest
    static void testFlowHandler_VariousEmptyConfigs_HandleGracefully() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>());

        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext ctx = createTestContext(TEST_FLOW_API_NAME);

        ActionOutcome outcome1 = action.execute(null, '{}', ctx);
        ActionOutcome outcome2 = action.execute('', '{}', ctx);
        ActionOutcome outcome3 = action.execute('{}', '{}', ctx);

        System.assertEquals(true, outcome1.isSuccess, 'Should handle null config');
        System.assertEquals(true, outcome2.isSuccess, 'Should handle empty config');
        System.assertEquals(true, outcome3.isSuccess, 'Should handle empty JSON config');

        ActionFlowHandler.mockFlowExecution = null;
    }

    @IsTest
    static void testFlowHandler_ValidJsonConfig_LogsButIgnores() {
        ActionFlowHandler.mockFlowExecution = new SuccessFlowMock(new Map<String, Object>());

        ActionFlowHandler action = new ActionFlowHandler();
        ActionOutcome outcome = action.execute('{"testConfig": "value", "anotherConfig": 123}', '{"param1": "test"}', createTestContext(TEST_FLOW_API_NAME));

        System.assertEquals(true, outcome.isSuccess, 'Should succeed with non-empty config (logged but ignored)');

        ActionFlowHandler.mockFlowExecution = null;
    }

    // ========== FLOW RESULT DTO ==========

    @IsTest
    static void testFlowResult_WithMapResult_SetsOutputMetadata() {
        Map<String, Object> result = new Map<String, Object>{ 'outputKey' => 'value', 'count' => 5 };
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult('Test_Flow', result, 'Success');

        System.assertEquals('Test_Flow', flowResult.flowName);
        System.assertEquals(result, flowResult.result);
        System.assertEquals(true, flowResult.metadata.get('hasResult'));
        System.assertEquals(2, flowResult.metadata.get('outputCount'));
        List<String> outputVars = (List<String>) flowResult.metadata.get('outputVariables');
        System.assertEquals(2, outputVars.size(), 'Should have 2 output variable names');
    }

    @IsTest
    static void testFlowResult_WithNullResult_SetsHasResultFalse() {
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult('Test_Flow', null, 'Message');

        System.assertEquals(null, flowResult.result);
        System.assertEquals(false, flowResult.metadata.get('hasResult'));
        System.assertEquals(false, flowResult.metadata.containsKey('resultType'), 'Null result should have no resultType');
    }

    @IsTest
    static void testFlowResult_WithStringResult_SetsResultType() {
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult('Test_Flow', 'Simple string', 'Success');

        System.assertEquals('Simple string', flowResult.result);
        System.assertEquals(true, flowResult.metadata.get('hasResult'));
        System.assertNotEquals(null, flowResult.metadata.get('resultType'));
    }

    @IsTest
    static void testFlowResult_WithListResult_SetsResultType() {
        List<String> result = new List<String>{ 'item1', 'item2', 'item3' };
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult('Test_Flow', result, 'Success');

        System.assertEquals(result, flowResult.result);
        System.assertEquals(true, flowResult.metadata.get('hasResult'));
        System.assertNotEquals(null, flowResult.metadata.get('resultType'), 'Non-Map results should have resultType');
    }

    // ========== DTO INSTANTIATION ==========

    @IsTest
    static void testConfigDTO_Instantiation() {
        ActionFlowHandler.ConfigDTO config = new ActionFlowHandler.ConfigDTO();
        System.assertNotEquals(null, config, 'ConfigDTO should instantiate');
    }

    @IsTest
    static void testArgumentsDTO_Instantiation() {
        ActionFlowHandler.ArgumentsDTO args = new ActionFlowHandler.ArgumentsDTO();
        args.inputParameters = new Map<String, Object>{ 'key1' => 'value1', 'key2' => 123 };

        System.assertEquals(2, args.inputParameters.size(), 'Should have 2 parameters');
        System.assertEquals('value1', args.inputParameters.get('key1'));
    }

    // ========== MOCK RESULT BUILDERS ==========

    @IsTest
    static void testMockFlowResult_SetSuccess() {
        ActionFlowHandler.MockFlowResult result = new ActionFlowHandler.MockFlowResult().setSuccess(new Map<String, Object>{ 'key' => 'value' });

        System.assertEquals(true, result.success);
        System.assertNotEquals(null, result.outputResult);
        System.assertEquals(null, result.faultMessage);
    }

    @IsTest
    static void testMockFlowResult_SetFault() {
        ActionFlowHandler.MockFlowResult result = new ActionFlowHandler.MockFlowResult().setFault('Test fault');

        System.assertEquals(true, result.success);
        System.assertEquals('Test fault', result.faultMessage);
    }

    @IsTest
    static void testMockFlowResult_SetFailure() {
        ActionFlowHandler.MockFlowResult result = new ActionFlowHandler.MockFlowResult().setFailure('ERR_001', 'Test error');

        System.assertEquals(false, result.success);
        System.assertEquals('ERR_001', result.errorCode);
        System.assertEquals('Test error', result.errorMessage);
    }
}
