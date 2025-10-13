/**
 * @description Tests for BaseAgentAction using TestFactory utilities
 */
@IsTest
private class BaseAgentActionTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create full agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test capability for BaseAgentAction testing
        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Opportunity')
            .withName('test_create_opportunity')
            .save();

        // Create test accounts for security testing
        TestFactory.newAccount().withName('Test Account 1').save();
        TestFactory.newAccount().withName('Test Account 2').save();
    }

    // ===================================================================================
    // EXECUTE METHOD TESTS
    // ===================================================================================

    @IsTest
    static void testExecute_ValidInputs_Success() {
        // Given: Valid configuration and arguments
        AgentCapability__c capability = [SELECT Id, Parameters__c
                                         FROM AgentCapability__c LIMIT 1];

        ActionContext context = new ActionContext(
            'a01000000000001AAA',
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            'a02000000000001AAA',
            capability.Id,
            'TestAction',
            'test-turn-123',
            1,
            'Conversational'
        );

        TestAgentAction action = new TestAgentAction();
        String configJson = '{"testConfig": "value"}';
        String argsJson = '{"Name": "Test Opportunity", "StageName": "Prospecting"}';

        // When: Executing action
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, argsJson, context);
        Test.stopTest();

        // Then: Should succeed
        System.assert(outcome.isSuccess);
        System.assertEquals('Test execution successful', String.valueOf(outcome.data));
    }

    @IsTest
    static void testExecute_NullContext_ReturnsError() {
        // Given: Null context
        TestAgentAction action = new TestAgentAction();

        // When: Executing with null context
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', '{}', null);
        Test.stopTest();

        // Then: Should return error
        System.assert(!outcome.isSuccess);
        System.assert(String.valueOf(outcome.errorMessage).contains('Internal error'));
    }

    // ===================================================================================
    // ACTION OUTCOME TESTS
    // ===================================================================================

    @IsTest
    static void testActionOutcome_Success_CreatesCorrectOutcome() {
        // Given: Success outcome
        Test.startTest();
        ActionOutcome outcome = ActionOutcome.success('Test data');
        Test.stopTest();

        // Then: Properties should be set correctly
        System.assert(outcome.isSuccess);
        System.assertEquals('Test data', outcome.data);
    }

    @IsTest
    static void testActionOutcome_Failure_CreatesCorrectOutcome() {
        // Given: Failure outcome
        Test.startTest();
        ActionOutcome outcome = ActionOutcome.failure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'Test validation error'
        );
        Test.stopTest();

        // Then: Properties should be set correctly
        System.assert(!outcome.isSuccess);
        System.assert(String.valueOf(outcome.errorMessage).contains('Test validation error'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    // ===================================================================================
    // CONFIGURATION PARSING TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_ValidJson_Success() {
        // Given: Valid configuration JSON
        TestAgentAction action = new TestAgentAction();
        String configJson = '{"key1": "value1", "key2": "value2"}';

        // When: Parsing configuration
        Test.startTest();
        action.testParseActionConfiguration(configJson);
        Test.stopTest();

        // Then: Should parse successfully
        Map<String, Object> parsedConfig = action.getParsedActionConfig();
        System.assertNotEquals(null, parsedConfig);
        System.assertEquals('value1', parsedConfig.get('key1'));
        System.assertEquals('value2', parsedConfig.get('key2'));
    }

    @IsTest
    static void testParseConfig_InvalidJson_ThrowsException() {
        // Given: Invalid JSON
        TestAgentAction action = new TestAgentAction();
        String invalidJson = '{"key1": "value1", "key2": }';

        // When/Then: Should throw exception
        Test.startTest();
        try {
            action.testParseActionConfiguration(invalidJson);
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid ActionConfiguration JSON'));
        }
        Test.stopTest();
    }

    // ===================================================================================
    // UTILITY METHOD TESTS
    // ===================================================================================

    @IsTest
    static void testGetLogPrefixName_ReturnsCorrectName() {
        // Given: Test action
        TestAgentAction action = new TestAgentAction();

        // When: Getting log prefix name
        Test.startTest();
        String name = action.testGetLogPrefixName();
        Test.stopTest();

        // Then: Should return correct name
        System.assertEquals('TestAgent', name, 'Should extract correct class name');
    }

    // ===================================================================================
    // TEST AGENT ACTION IMPLEMENTATION
    // ===================================================================================

    /**
     * @description Test implementation of BaseAgentAction
     */
    private class TestAgentAction extends BaseAgentAction {

        public Map<String, Object> getParsedActionConfig() {
            return this.parsedActionConfig;
        }

        public override ActionOutcome executeAction(Map<String, Object> params) {
            return ActionOutcome.success('Test execution successful');
        }

        public ActionOutcome testExecuteActionMethod(Map<String, Object> params) {
            return this.executeAction(params);
        }

        public String testGetLogPrefixName() {
            return this.getLogPrefixName();
        }

        public void testParseActionConfiguration(String actionConfigurationJson) {
            this.parseActionConfiguration(actionConfigurationJson, '[TEST] ');
        }

        public override String toString() {
            return 'TestAgentAction:TestAgentAction';
        }
    }
}

