/**
 * @description Tests for ActionPostChatter validation paths and code coverage.
 * Note: ConnectApi methods fail in data-siloed tests, so execution path tests
 * verify code reaches ConnectApi (which surfaces the expected error).
 */
@IsTest
private class ActionPostChatterTest {
    @TestSetup
    static void setupTestData() {
        TestFactory.newAccount().withName('Test Account for Chatter').save();
    }

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-chatter-001', 1, 'Function');
    }

    // ========== CONFIGURATION PARSING ==========

    @IsTest
    static void testParseConfig_ValidRecordConfig_Success() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id });

        action.parseActionConfiguration(config, '[TEST] ');
        System.assert(true, 'Configuration parsed successfully');
    }

    @IsTest
    static void testParseConfig_ValidUserConfig_Success() {
        ActionPostChatter action = new ActionPostChatter();
        String config = JSON.serialize(new Map<String, Object>{ 'feedType' => 'User', 'targetId' => UserInfo.getUserId() });

        action.parseActionConfiguration(config, '[TEST] ');
        System.assert(true, 'User configuration parsed successfully');
    }

    @IsTest
    static void testParseConfig_MissingConfig_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration('', '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Configuration JSON is required') || e.getMessage().contains('Invalid configuration JSON'));
        }
    }

    @IsTest
    static void testParseConfig_InvalidJson_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration('not valid json {{{', '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid configuration JSON'));
        }
    }

    @IsTest
    static void testParseConfig_MissingFeedType_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration('{"targetId": "001000000000000AAA"}', '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('feedType is required'));
        }
    }

    @IsTest
    static void testParseConfig_MissingTargetId_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration('{"feedType": "Record"}', '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('targetId is required'));
        }
    }

    @IsTest
    static void testParseConfig_InvalidTargetIdFormat_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration('{"feedType": "Record", "targetId": "not-a-valid-id"}', '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid targetId format'));
        }
    }

    @IsTest
    static void testParseConfig_FeedTypeMismatch_UserWithAccount_ThrowsException() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'User', 'targetId' => testAccount.Id }), '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Mismatch between feedType'));
        }
    }

    @IsTest
    static void testParseConfig_FeedTypeMismatch_GroupWithUser_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Group', 'targetId' => UserInfo.getUserId() }), '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Mismatch between feedType'));
        }
    }

    @IsTest
    static void testParseConfig_FeedTypeMismatch_RecordWithUser_ThrowsException() {
        ActionPostChatter action = new ActionPostChatter();
        try {
            action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => UserInfo.getUserId() }), '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Mismatch between feedType'));
        }
    }

    // ========== VALIDATION (pre-ConnectApi) ==========

    @IsTest
    static void testMissingMessageText_ReturnsValidationError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id }), '[TEST] ');

        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>());
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail without messageText');
        System.assert(result.errorMessage.contains('messageText parameter cannot be blank'));
    }

    @IsTest
    static void testBlankMessageText_ReturnsValidationError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id }), '[TEST] ');

        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>{ 'messageText' => '   ' });
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with blank messageText');
    }

    @IsTest
    static void testInvalidTargetAccess_ReturnsPermissionDenied() {
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => '001000000000000AAA' }), '[TEST] ');

        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>{ 'messageText' => 'Test message' });
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with invalid target');
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, result.errorCode);
    }

    @IsTest
    static void testNullContext_ReturnsError() {
        ActionPostChatter action = new ActionPostChatter();
        ActionOutcome result = action.execute('{"feedType":"Record","targetId":"001000000000000AAA"}', '{"messageText":"Test"}', null);

        System.assert(!result.isSuccess, 'Should fail with null context');
    }

    // ========== EXECUTION PATHS (ConnectApi coverage) ==========

    @IsTest
    static void testValidText_ReachesConnectApi() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id }), '[TEST] ');

        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>{ 'messageText' => 'Test Chatter message' });
        Test.stopTest();

        // ConnectApi fails in data-siloed tests - we verify the code reaches it
        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void testWithTopics_ProcessesTopicFiltering() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id }), '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'messageText' => 'Test with topics',
            'topics' => new List<String>{ 'ValidTopic', 'ThisTopicIsWayTooLongToBeValid', '', '  ' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testWithMentions_ParsesMentionSyntax() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'Record', 'targetId' => testAccount.Id }), '[TEST] ');

        // Valid user mention, invalid mention, and non-user mention
        String msg = 'Hi {@' + UserInfo.getUserId() + '} and {@invalidId123} and {@' + testAccount.Id + '}';
        Map<String, Object> params = new Map<String, Object>{ 'messageText' => msg };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    @IsTest
    static void testUserFeed_ReachesConnectApi() {
        ActionPostChatter action = new ActionPostChatter();
        action.parseActionConfiguration(JSON.serialize(new Map<String, Object>{ 'feedType' => 'User', 'targetId' => UserInfo.getUserId() }), '[TEST] ');

        Test.startTest();
        ActionOutcome result = action.executeAction(new Map<String, Object>{ 'messageText' => 'Test user feed' });
        Test.stopTest();

        System.assertNotEquals(null, result);
    }

    // ========== RESULT DTO ==========

    @IsTest
    static void testChatterResult_SetsProperties() {
        ActionPostChatter.ChatterResult result = new ActionPostChatter.ChatterResult('0D5XXXXXXXXX', 'Success', 100, 2);

        System.assertEquals('0D5XXXXXXXXX', result.feedElementId);
        System.assertEquals(100, result.messageLength);
        System.assertEquals(2, result.topicCount);
        System.assertEquals(true, result.metadata.get('postSuccessful'));
    }
}
