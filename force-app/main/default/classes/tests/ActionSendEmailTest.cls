/**
 * @description Tests for ActionSendEmail using TestFactory utilities
 */
@IsTest
private class ActionSendEmailTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test send email capability
        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forSendEmail()
            .withName('test_send_email')
            .save();
    }

    private static ActionContext createTestContext() {
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        Id capabilityId = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'test_send_email' LIMIT 1].Id;

        return new ActionContext(
            session.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            agent.Id,
            capabilityId,
            'ActionSendEmail',
            'turn-123',
            1,
            'Conversational'
        );
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSendEmail_BasicEmail_Success() {
        // Given: Basic email parameters
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test@example.com'},
            'subject' => 'Test Email Subject',
            'body' => 'This is a test email body'
        };

        // When: Sending email
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should succeed
        System.assert(outcome.isSuccess, 'Email should be sent successfully');
        System.assertNotEquals(null, outcome.data);
    }

    @IsTest
    static void testSendEmail_WithHtml_Success() {
        // Given: Email with HTML body
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test@example.com'},
            'subject' => 'HTML Test Email',
            'body' => 'Test plain text body',
            'htmlBody' => '<h1>Test HTML</h1><p>This is HTML content.</p>'
        };

        // When: Sending HTML email
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should succeed
        System.assert(outcome.isSuccess);
    }

    @IsTest
    static void testSendEmail_WithCcAndBcc_Success() {
        // Given: Email with CC and BCC
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'primary@example.com'},
            'ccAddresses' => new List<String>{'cc@example.com'},
            'bccAddresses' => new List<String>{'bcc@example.com'},
            'subject' => 'Email with CC/BCC',
            'body' => 'Test body'
        };

        // When: Sending
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should succeed
        System.assert(outcome.isSuccess);
    }

    @IsTest
    static void testSendEmail_WithAttachments_Success() {
        // Given: Email with attachments
        ActionSendEmail action = new ActionSendEmail();
        String base64Content = EncodingUtil.base64Encode(Blob.valueOf('Test content'));

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test@example.com'},
            'subject' => 'Email with Attachments',
            'body' => 'Test body',
            'attachments' => new List<Map<String, Object>>{
                new Map<String, Object>{
                    'fileName' => 'test.txt',
                    'contentType' => 'text/plain',
                    'body' => base64Content
                }
            }
        };

        // When: Sending with attachments
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should succeed
        System.assert(outcome.isSuccess);
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSendEmail_MissingRecipients_Failure() {
        // Given: No recipients
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'subject' => 'Test',
            'body' => 'Test'
        };

        // When: Attempting to send
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testSendEmail_MissingSubject_Failure() {
        // Given: No subject
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test@example.com'},
            'body' => 'Test'
        };

        // When: Attempting to send
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testSendEmail_MissingBody_Failure() {
        // Given: No body content
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test@example.com'},
            'subject' => 'Test'
        };

        // When: Attempting to send
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testSendEmail_InvalidEmailFormat_Failure() {
        // Given: Invalid email format
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'invalid-email'},
            'subject' => 'Test',
            'body' => 'Test'
        };

        // When: Attempting to send
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testSendEmail_TooManyRecipients_Failure() {
        // Given: Too many recipients with limit
        ActionSendEmail action = new ActionSendEmail();
        String configJson = '{"maxRecipients":2}';

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{'test1@example.com', 'test2@example.com', 'test3@example.com'},
            'subject' => 'Test',
            'body' => 'Test'
        };

        // When: Attempting to send
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }
}
