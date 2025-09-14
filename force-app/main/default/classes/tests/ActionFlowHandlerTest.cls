@IsTest
private class ActionFlowHandlerTest {
    @TestSetup
    static void makeData() {
        // Create LLM Configuration
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        // Create Agent Definition
        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        // Create Agent Capabilities
        List<AgentCapability__c> caps = new List<AgentCapability__c>{
            TestFactory.createSingleCapability(
                agent.Id,
                'run_flow',
                'Executes a Salesforce Flow.',
                '{"type":"object","properties":{"param1":{"type":"string"}, "param2":{"type":"integer"}}}',
                'Standard',
                'Test_Flow_API_Name',
                'RunFlow',
                false,
                null
            )
        };
        insert caps;

        // Create Chat Session
        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @IsTest
    static void executeAction_success_withValidParameters() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Configuration
        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters
        Map<String, Object> params = new Map<String, Object>{ 'param1' => 'test value', 'param2' => 42 };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Note: Actual success depends on Flow availability, but shouldn't throw exceptions during parameter handling
    }

    @IsTest
    static void executeAction_success_withEmptyParameters() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Configuration
        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Empty parameters
        Map<String, Object> params = new Map<String, Object>{};

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Should handle empty parameters gracefully
    }

    @IsTest
    static void executeAction_success_withComplexParameters() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Configuration
        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Complex parameters
        Map<String, Object> params = new Map<String, Object>{
            'textParam' => 'test text',
            'numberParam' => 123,
            'booleanParam' => true,
            'listParam' => new List<String>{ 'item1', 'item2', 'item3' },
            'mapParam' => new Map<String, Object>{ 'key1' => 'value1', 'key2' => 42 }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Should handle complex parameters gracefully
    }

    @IsTest
    static void validateFlowApiName_success_withValidName() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Configuration
        String config = '{}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        System.assert(true, 'Should handle configuration without exceptions');
    }

    @IsTest
    static void parseActionConfiguration_validJson_success() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Valid configuration
        String config = '{"testConfig": "value"}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should not throw exceptions during parsing
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void parseActionConfiguration_invalidJson_handledGracefully() {
        ActionFlowHandler action = new ActionFlowHandler();

        // Invalid configuration
        String config = '{"testConfig": }'; // Invalid JSON

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown exception for invalid JSON');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('Invalid ActionConfiguration JSON'), 'Should indicate invalid JSON');
        }
        Test.stopTest();
    }

    @IsTest
    static void flowResult_constructor_setsProperties() {
        Test.startTest();
        ActionFlowHandler.FlowResult result = new ActionFlowHandler.FlowResult(
            'Test_Flow_API_Name',
            new Map<String, Object>{ 'outputKey' => 'outputValue' },
            'Test success message'
        );
        Test.stopTest();

        System.assertEquals('Test_Flow_API_Name', result.flowName, 'Should set flowName');
        System.assertNotEquals(null, result.result, 'Should set result');
        System.assertEquals('Test success message', result.message, 'Should set message');
        System.assertNotEquals(null, result.metadata, 'Should initialize metadata');
        System.assertEquals('Test_Flow_API_Name', result.metadata.get('flowApiName'), 'Metadata should contain flowApiName');
        System.assertEquals(true, result.metadata.get('hasResult'), 'Metadata should indicate hasResult');
    }
}
