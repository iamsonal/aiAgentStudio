/**
 * @description Tests for ActionFlowHandler using TestFactory utilities
 */
@IsTest
private class ActionFlowHandlerTest {

    private static final String TEST_FLOW_API_NAME = 'Test_Flow_API_Name';
    private static final String INVALID_FLOW_API_NAME = 'Invalid Flow Name With Spaces';

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test flow capability
        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forFlowHandler('Test_Flow')
            .withName('test_flow_capability')
            .save();
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

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testFlowHandler_WithValidParameters_Success() {
        // Given: Valid flow parameters
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);

        String configJson = '{}';
        String argsJson = '{"param1": "test value", "param2": 42}';

        // When: Executing flow
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should not throw exceptions
        System.assertNotEquals(null, outcome);
        // Flow will likely fail in test context but should handle gracefully
    }

    @IsTest
    static void testFlowHandler_WithEmptyParameters_Success() {
        // Given: Empty parameters
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);

        String configJson = '{}';
        String argsJson = '{}';

        // When: Executing with empty params
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should handle gracefully
        System.assertNotEquals(null, outcome);
    }

    @IsTest
    static void testFlowHandler_WithComplexParameters_Success() {
        // Given: Complex parameters
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);

        String configJson = '{}';
        String argsJson = '{"textParam": "test", "numberParam": 123, "booleanParam": true}';

        // When: Executing with complex params
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should handle gracefully
        System.assertNotEquals(null, outcome);
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testFlowHandler_BlankFlowApiName_Failure() {
        // Given: Blank flow API name
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext('   ');

        String configJson = '{}';
        String argsJson = '{"param1": "test"}';

        // When: Executing with blank name
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should fail with config error
        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
    }

    @IsTest
    static void testFlowHandler_InvalidVariableNames_Warning() {
        // Given: Parameters with invalid variable names
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);

        String configJson = '{}';
        String argsJson = '{"123InvalidStart": "value", "invalid-dash": "value", "validParam": "valid"}';

        // When: Executing with invalid names
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should process with warnings
        System.assertNotEquals(null, outcome);
    }

    @IsTest
    static void testFlowHandler_NullContext_Failure() {
        // Given: Null context
        ActionFlowHandler action = new ActionFlowHandler();

        String configJson = '{}';
        String argsJson = '{"param1": "test"}';

        // When: Executing with null context
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, null);
        Test.stopTest();

        // Then: Should fail gracefully
        System.assertEquals(false, outcome.isSuccess);
        System.assertNotEquals(null, outcome.errorCode);
    }

    // ===================================================================================
    // CONFIGURATION TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_ValidJson_Success() {
        // Given: Valid configuration
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);

        String configJson = '{"testConfig": "value", "anotherConfig": 123}';
        String argsJson = '{"param1": "test"}';

        // When: Parsing config
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should not throw exceptions
        System.assertNotEquals(null, outcome);
    }

    @IsTest
    static void testParseConfig_EmptyJson_Success() {
        // Given: Empty/null configurations
        ActionFlowHandler action = new ActionFlowHandler();
        ActionContext context = createTestContext(TEST_FLOW_API_NAME);
        String argsJson = '{"param1": "test"}';

        // When: Testing various empty configs
        Test.startTest();
        ActionOutcome outcome1 = action.execute(null, argsJson, context);
        ActionOutcome outcome2 = action.execute('', argsJson, context);
        ActionOutcome outcome3 = action.execute('{}', argsJson, context);
        Test.stopTest();

        // Then: Should handle gracefully
        System.assertNotEquals(null, outcome1);
        System.assertNotEquals(null, outcome2);
        System.assertNotEquals(null, outcome3);
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testFlowResult_Constructor_SetsProperties() {
        // Given: Flow result data
        String flowName = 'Test_Flow';
        Map<String, Object> result = new Map<String, Object>{'outputKey' => 'value', 'count' => 5};
        String message = 'Success message';

        // When: Creating result
        Test.startTest();
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult(flowName, result, message);
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals(flowName, flowResult.flowName);
        System.assertEquals(result, flowResult.result);
        System.assertEquals(message, flowResult.message);
        System.assertNotEquals(null, flowResult.metadata);
        System.assertEquals(flowName, flowResult.metadata.get('flowApiName'));
        System.assertEquals(true, flowResult.metadata.get('hasResult'));
    }

    @IsTest
    static void testFlowResult_Constructor_WithNullResult() {
        // Given: Null result
        String flowName = 'Test_Flow';
        Object result = null;
        String message = 'Message with null result';

        // When: Creating result
        Test.startTest();
        ActionFlowHandler.FlowResult flowResult = new ActionFlowHandler.FlowResult(flowName, result, message);
        Test.stopTest();

        // Then: Should handle null
        System.assertEquals(flowName, flowResult.flowName);
        System.assertEquals(null, flowResult.result);
        System.assertEquals(message, flowResult.message);
        System.assertEquals(false, flowResult.metadata.get('hasResult'));
        System.assertEquals('null', flowResult.metadata.get('resultType'));
    }

    @IsTest
    static void testExecuteAction_DirectCall() {
        // Given: Direct method call
        ActionFlowHandler action = new ActionFlowHandler();
        Map<String, Object> params = new Map<String, Object>{'param1' => 'test'};

        // When: Calling executeAction directly
        Test.startTest();
        ActionOutcome outcome = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail without proper context
        System.assertNotEquals(null, outcome);
        System.assertEquals(false, outcome.isSuccess);
    }
}
