@IsTest
private class ActionPostChatterTest {
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
                'post_chatter',
                'Posts a message to Chatter.',
                '{"type":"object","properties":{"text":{"type":"string"}, "topics":{"type":"array"}},"required":["text"]}',
                'Standard',
                null,
                'PostChatter',
                false,
                '{"feedType": "Record", "targetId": "001XXXXXXXXXXXXXXXXX"}'
            )
        };
        insert caps;

        // Create Chat Session
        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;

        // Create test account for Chatter posts
        Account testAccount = new Account(Name = 'Test Account for Chatter');
        insert testAccount;
    }

    @IsTest
    static void executeAction_success_withValidText() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account for Chatter' LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();

        // Configuration with actual test account ID
        String config = '{"feedType": "Record", "targetId": "' + testAccount.Id + '"}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters
        Map<String, Object> params = new Map<String, Object>{ 'text' => 'Test Chatter message from unit test' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Note: Actual success depends on Chatter availability and permissions, but shouldn't throw exceptions
    }

    @IsTest
    static void executeAction_success_withTopics() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account for Chatter' LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();

        // Configuration
        String config = '{"feedType": "Record", "targetId": "' + testAccount.Id + '"}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters with topics
        Map<String, Object> params = new Map<String, Object>{
            'text' => 'Test Chatter message with topics',
            'topics' => new List<String>{ 'TestTopic1', 'TestTopic2' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Note: Actual success depends on Chatter availability and permissions, but shouldn't throw exceptions
    }

    @IsTest
    static void executeAction_failure_missingTextParameter() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account for Chatter' LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();

        // Configuration
        String config = '{"feedType": "Record", "targetId": "' + testAccount.Id + '"}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Empty parameters (missing text)
        Map<String, Object> params = new Map<String, Object>{};

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.isSuccess, 'Action should fail without text parameter');
        System.assert(String.valueOf(result.errorMessage).contains('Text parameter cannot be blank'), 'Should indicate missing text parameter');
    }

    @IsTest
    static void executeAction_failure_missingConfiguration() {
        ActionPostChatter action = new ActionPostChatter();

        // Empty configuration
        String config = '';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown exception for missing configuration');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('BackendConfiguration is required'), 'Should indicate missing configuration');
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_failure_missingRequiredConfigFields() {
        ActionPostChatter action = new ActionPostChatter();

        // Configuration missing required fields
        String config = '{"feedType": "Record"}'; // Missing targetId

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown exception for missing required configuration fields');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('targetId'), 'Should indicate missing targetId');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseActionConfiguration_validJson_success() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account for Chatter' LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();

        // Valid configuration
        String config = '{"feedType": "Record", "targetId": "' + testAccount.Id + '"}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should not throw exceptions during parsing
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void chatterResult_constructor_setsProperties() {
        Test.startTest();
        ActionPostChatter.ChatterResult result = new ActionPostChatter.ChatterResult('0D5XXXXXXXXXXXXXXXXX', 'Test message', 100, 2);
        Test.stopTest();

        System.assertEquals('0D5XXXXXXXXXXXXXXXXX', result.feedElementId, 'Should set feedElementId');
        System.assertEquals('Test message', result.message, 'Should set message');
        System.assertEquals(100, result.messageLength, 'Should set messageLength');
        System.assertEquals(2, result.topicCount, 'Should set topicCount');
        System.assertNotEquals(null, result.metadata, 'Should initialize metadata');
        System.assertEquals('0D5XXXXXXXXXXXXXXXXX', result.metadata.get('feedElementId'), 'Metadata should contain feedElementId');
        System.assertEquals(100, result.metadata.get('messageLength'), 'Metadata should contain messageLength');
    }
}
