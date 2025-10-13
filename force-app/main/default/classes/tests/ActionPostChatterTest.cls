/**
 * @description Tests for ActionPostChatter using TestFactory utilities
 */
@IsTest
private class ActionPostChatterTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test account for Chatter
        TestFactory.newAccount()
            .withName('Test Account for Chatter')
            .save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testPostChatter_WithValidText_Success() {
        // Given: Chatter action with valid configuration
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account for Chatter' LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{
            'feedType' => 'Record',
            'targetId' => testAccount.Id
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'text' => 'Test Chatter message from unit test'
        };

        // When: Posting to Chatter
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should not throw exceptions
        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void testPostChatter_WithTopics_Success() {
        // Given: Message with topics
        Account testAccount = [SELECT Id FROM Account LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{
            'feedType' => 'Record',
            'targetId' => testAccount.Id
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'text' => 'Test message with topics',
            'topics' => new List<String>{'TestTopic1', 'TestTopic2'}
        };

        // When: Posting with topics
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should not throw exceptions
        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testPostChatter_WithMentions_Success() {
        // Given: Message with mentions
        Account testAccount = [SELECT Id FROM Account LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{
            'feedType' => 'Record',
            'targetId' => testAccount.Id
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'text' => 'Test message mentioning user {@' + UserInfo.getUserId() + '}'
        };

        // When: Posting with mentions
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should process mentions
        System.assertNotEquals(null, result);
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testPostChatter_MissingText_Failure() {
        // Given: Empty parameters
        Account testAccount = [SELECT Id FROM Account LIMIT 1];

        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{
            'feedType' => 'Record',
            'targetId' => testAccount.Id
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        // When: Attempting to post without text
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess, 'Should fail without text');
        System.assert(result.errorMessage.contains('Text parameter cannot be blank'));
    }

    @IsTest
    static void testParseConfig_MissingConfiguration_ThrowsException() {
        // Given: Empty configuration
        ActionPostChatter action = new ActionPostChatter();
        String config = '';

        // When/Then: Should throw exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('BackendConfiguration is required'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testParseConfig_MissingTargetId_ThrowsException() {
        // Given: Configuration without targetId
        ActionPostChatter action = new ActionPostChatter();
        String config = '{"feedType": "Record"}';

        // When/Then: Should throw exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('targetId'));
        }
        Test.stopTest();
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testChatterResult_Constructor_SetsProperties() {
        // Given: Result data
        String feedElementId = '0D5XXXXXXXXXXXXXXXXX';
        String message = 'Test message';
        Integer messageLength = 100;
        Integer topicCount = 2;

        // When: Creating result
        Test.startTest();
        ActionPostChatter.ChatterResult result = new ActionPostChatter.ChatterResult(
            feedElementId,
            message,
            messageLength,
            topicCount
        );
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals(feedElementId, result.feedElementId);
        System.assertEquals(message, result.message);
        System.assertEquals(messageLength, result.messageLength);
        System.assertEquals(topicCount, result.topicCount);
        System.assertNotEquals(null, result.metadata);
        System.assertEquals(feedElementId, result.metadata.get('feedElementId'));
        System.assertEquals(messageLength, result.metadata.get('messageLength'));
    }
}
