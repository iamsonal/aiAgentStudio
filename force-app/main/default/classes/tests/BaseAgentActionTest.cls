@IsTest
private class BaseAgentActionTest {
    @TestSetup
    static void makeData() {
        // Create test data for testing
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        List<AgentCapability__c> caps = TestFactory.createStandardCapabilities(agent.Id);
        insert caps;

        // Create test accounts for security testing
        List<Account> testAccounts = new List<Account>{ new Account(Name = 'Test Account 1'), new Account(Name = 'Test Account 2') };
        insert testAccounts;
    }

    @IsTest
    static void execute_validInputs_success() {
        // Get test data
        AgentCapability__c capability = [SELECT Id, Parameters__c FROM AgentCapability__c WHERE CapabilityName__c = 'create_opportunity' LIMIT 1];

        // Create a mock action context
        ActionContext context = new ActionContext(
            'a01000000000001AAA', // chatSessionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            null, // relatedRecordId
            'a02000000000001AAA', // agentDefinitionId
            capability.Id, // agentCapabilityId
            'TestAction', // implementationDetail
            'test-turn-123', // turnIdentifier
            1 // currentTurnCount
        );

        // Create a test implementation of BaseAgentAction
        TestAgentAction action = new TestAgentAction();

        // Test inputs
        String configJson = '{"testConfig": "value"}';
        String argsJson = '{"Name": "Test Opportunity", "StageName": "Prospecting"}';

        Test.startTest();
        ActionResult result = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Verify results
        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(true, result.getIsSuccess(), 'Result should be successful');
        // The output is an ActionOutcome, not a Map
        System.assertEquals('Test execution successful', String.valueOf(result.getOutputForLlm()), 'Should have correct success message');
    }

    @IsTest
    static void execute_nullContext_returnsError() {
        TestAgentAction action = new TestAgentAction();

        Test.startTest();
        ActionResult result = action.execute('{}', '{}', null);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.getIsSuccess(), 'Result should indicate failure');
        // Check that the error message contains the expected text
        System.assert(String.valueOf(result.getOutputForLlm()).contains('Internal error'), 'Should indicate internal error');
    }

    @IsTest
    static void testExecuteAction_validParams_success() {
        TestAgentAction action = new TestAgentAction();

        Map<String, Object> params = new Map<String, Object>{ 'testParam' => 'testValue' };

        Test.startTest();
        ActionOutcome outcome = action.testExecuteActionMethod(params);
        Test.stopTest();

        System.assertNotEquals(null, outcome, 'Outcome should not be null');
        System.assertEquals(true, outcome.isSuccess, 'Outcome should be successful');
        System.assertEquals('Test execution successful', outcome.data, 'Should have correct success message');
    }

    @IsTest
    static void actionOutcome_success_createsCorrectResult() {
        TestAgentAction action = new TestAgentAction();

        Test.startTest();
        ActionOutcome outcome = ActionOutcome.success('Test data');
        ActionResult result = outcome.toActionResult('TestAction');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(true, result.getIsSuccess(), 'Result should indicate success');
        System.assertEquals('Test data', result.getOutputForLlm(), 'Should have correct data');
    }

    @IsTest
    static void actionOutcome_failure_createsCorrectResult() {
        TestAgentAction action = new TestAgentAction();

        Test.startTest();
        ActionOutcome outcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Test validation error');
        ActionResult result = outcome.toActionResult('TestAction');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.getIsSuccess(), 'Result should indicate failure');
        // The output is a Map, so we need to cast it properly
        Map<String, Object> outputMap = (Map<String, Object>) result.getOutputForLlm();
        System.assert(String.valueOf(outputMap.get('messageForUser')).contains('Test validation error'), 'Should contain error message');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.getErrorCode(), 'Should have correct error code');
    }

    @IsTest
    static void getLogPrefixName_returnsCorrectName() {
        TestAgentAction action = new TestAgentAction();

        Test.startTest();
        String name = action.testGetLogPrefixName();
        Test.stopTest();

        // The getLogPrefixName method extracts the class name from the toString() method
        // and removes the "Action" prefix. Since our toString() returns "TestAgentAction:TestAgentAction",
        // the extracted name will be "TestAgent"
        System.assertEquals('TestAgent', name, 'Should return correct class name');
    }

    @IsTest
    static void parseActionConfiguration_validJson_success() {
        TestAgentAction action = new TestAgentAction();

        String configJson = '{"key1": "value1", "key2": "value2"}';

        Test.startTest();
        action.testParseActionConfiguration(configJson);
        Test.stopTest();

        // Should not throw exception
        System.assert(true, 'Should parse configuration successfully');

        // Verify parsed config
        Map<String, Object> parsedConfig = action.getParsedActionConfig();
        System.assertNotEquals(null, parsedConfig, 'Parsed config should not be null');
        System.assertEquals('value1', parsedConfig.get('key1'), 'Should have correct value for key1');
        System.assertEquals('value2', parsedConfig.get('key2'), 'Should have correct value for key2');
    }

    @IsTest
    static void parseActionConfiguration_invalidJson_throwsException() {
        TestAgentAction action = new TestAgentAction();

        String invalidJson = '{"key1": "value1", "key2": }'; // Invalid JSON

        Test.startTest();
        try {
            action.testParseActionConfiguration(invalidJson);
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid ActionConfiguration JSON'), 'Should indicate invalid JSON');
        }
        Test.stopTest();
    }

    // Test implementation of BaseAgentAction for testing purposes
    private class TestAgentAction extends BaseAgentAction {
        public Map<String, Object> getParsedActionConfig() {
            return this.parsedActionConfig;
        }

        // Implementation of abstract method
        public override ActionOutcome executeAction(Map<String, Object> params) {
            return ActionOutcome.success('Test execution successful');
        }

        // Test methods to expose protected methods
        public ActionOutcome testExecuteActionMethod(Map<String, Object> params) {
            return this.executeAction(params);
        }

        public String testGetLogPrefixName() {
            return this.getLogPrefixName();
        }

        public void testParseActionConfiguration(String actionConfigurationJson) {
            this.parseActionConfiguration(actionConfigurationJson, '[TEST] ');
        }

        // Override toString to return a predictable value for testing
        public override String toString() {
            return 'TestAgentAction:TestAgentAction';
        }
    }
}
