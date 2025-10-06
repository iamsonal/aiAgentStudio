/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@IsTest
private class ActionSendEmailTest {
    @TestSetup
    static void setupTestData() {
        // Create test agent and capability using TestFactory
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();

        // Insert LLM Configuration
        insert setup.llmConfig;

        // Insert Agent Definition
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        insert setup.agentDefinition;

        // Create email capability
        AgentCapability__c capability = TestFactory.createSingleCapability(
            setup.agentDefinition.Id,
            'send_email',
            'Send Email',
            '{"type":"object","properties":{"toAddresses":{"type":"array","items":{"type":"string","format":"email"},"minItems":1},"subject":{"type":"string","minLength":1},"body":{"type":"string"},"ccAddresses":{"type":"array","items":{"type":"string","format":"email"}},"bccAddresses":{"type":"array","items":{"type":"string","format":"email"}},"htmlBody":{"type":"string"},"plainTextBody":{"type":"string"},"templateId":{"type":"string"},"fromName":{"type":"string"},"replyTo":{"type":"string","format":"email"},"attachments":{"type":"array","items":{"type":"object","properties":{"fileName":{"type":"string"},"contentType":{"type":"string"},"body":{"type":"string"}}}}},"required":["toAddresses","subject"]}',
            'Standard',
            null,
            'SendEmail',
            false,
            null
        );
        insert capability;

        // Create test execution
        AgentExecution__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;
    }

    /**
     * Helper method to create ActionContext for testing
     */
    private static ActionContext createActionContext() {
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentCapability__c capability = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'send_email' LIMIT 1];

        return new ActionContext(
            session.Id, // executionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            null, // relatedRecordId
            agent.Id, // agentDefinitionId
            capability.Id, // agentCapabilityId
            'ActionSendEmail', // implementationDetail
            'test-turn-123', // turnIdentifier
            1, // currentTurnCount
            'Conversational' // executionType
        );
    }

    /**
     * Test successful email sending with basic parameters
     */
    @IsTest
    static void executeAction_basicEmail_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Test Email Subject',
            'body' => 'This is a test email body'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email should be sent successfully');
        System.assertNotEquals(null, outcome.data, 'Output should not be null');
    }

    /**
     * Test email sending with HTML body
     */
    @IsTest
    static void executeAction_htmlEmail_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'HTML Test Email',
            'htmlBody' => '<h1>Test HTML Email</h1><p>This is a test email with HTML content.</p>',
            'plainTextBody' => 'Test HTML Email - This is a test email with HTML content.'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'HTML email should be sent successfully');
    }

    /**
     * Test email sending with only HTML and plain text bodies (no main body)
     */
    @IsTest
    static void executeAction_htmlAndPlainTextOnly_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'HTML and Plain Text Only',
            'htmlBody' => '<h1>HTML Only</h1><p>This email has only HTML and plain text bodies.</p>',
            'plainTextBody' => 'Plain Text Only - This email has only HTML and plain text bodies.'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with only HTML and plain text should be sent successfully');
    }

    /**
     * Test email sending with CC and BCC recipients
     */
    @IsTest
    static void executeAction_withCcAndBcc_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'primary@example.com' },
            'ccAddresses' => new List<String>{ 'cc1@example.com', 'cc2@example.com' },
            'bccAddresses' => new List<String>{ 'bcc@example.com' },
            'subject' => 'Email with CC and BCC',
            'body' => 'This email has CC and BCC recipients'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with CC and BCC should be sent successfully');
    }

    /**
     * Test email sending with attachments
     */
    @IsTest
    static void executeAction_withAttachments_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String base64Content = EncodingUtil.base64Encode(Blob.valueOf('Test attachment content'));

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Email with Attachments',
            'body' => 'This email has attachments',
            'attachments' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'fileName' => 'test.txt', 'contentType' => 'text/plain', 'body' => base64Content }
            }
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with attachments should be sent successfully');
    }

    /**
     * Test email sending with targetObjectId (for template-like functionality)
     */
    @IsTest
    static void executeAction_withTemplate_success() {
        // Setup - create a test contact for targetObjectId
        Contact testContact = new Contact(FirstName = 'Test', LastName = 'Contact', Email = 'testcontact@example.com');
        insert testContact;

        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Target Object Email',
            'body' => 'This email uses targetObjectId for merge field functionality',
            'targetObjectId' => testContact.Id, // Use Contact as target for merge fields
            'saveAsActivity' => false // Set to false to avoid whatId validation issues
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with targetObjectId should be sent successfully');
    }

    /**
     * Test email sending with custom from name and reply-to
     */
    @IsTest
    static void executeAction_withCustomHeaders_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Custom Headers Email',
            'body' => 'This email has custom headers',
            'fromName' => 'Custom Sender',
            'replyTo' => 'noreply@example.com'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with custom headers should be sent successfully');
    }

    /**
     * Test email sending with configuration
     */
    @IsTest
    static void executeAction_withConfiguration_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String configJson = '{"defaultFromName":"AI Agent","defaultReplyTo":"ai@company.com","maxRecipients":50,"maxAttachments":5}';

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Configured Email',
            'body' => 'This email uses configuration defaults'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Configured email should be sent successfully');
    }

    /**
     * Test email sending with approval required
     */
    @IsTest
    static void executeAction_approvalRequired_returnsApprovalData() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String configJson = '{"requireApproval":true}';

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Approval Required Email',
            'body' => 'This email requires approval'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Approval request should be created successfully');
        System.assertNotEquals(null, outcome.data, 'Approval data should be returned');
    }

    /**
     * Test validation error - missing recipients
     */
    @IsTest
    static void executeAction_missingRecipients_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{ 'subject' => 'Test Subject', 'body' => 'Test body' };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for missing recipients');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test validation error - missing subject
     */
    @IsTest
    static void executeAction_missingSubject_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{ 'toAddresses' => new List<String>{ 'test@example.com' }, 'body' => 'Test body' };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for missing subject');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test validation error - missing body content
     */
    @IsTest
    static void executeAction_missingBody_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{ 'toAddresses' => new List<String>{ 'test@example.com' }, 'subject' => 'Test Subject' };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for missing body');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test validation error - invalid email format
     */
    @IsTest
    static void executeAction_invalidEmailFormat_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'invalid-email-format' },
            'subject' => 'Test Subject',
            'body' => 'Test body'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for invalid email format');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test validation error - too many recipients
     */
    @IsTest
    static void executeAction_tooManyRecipients_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String configJson = '{"maxRecipients":2}';

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test1@example.com', 'test2@example.com', 'test3@example.com' },
            'subject' => 'Test Subject',
            'body' => 'Test body'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for too many recipients');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test validation error - too many attachments
     */
    @IsTest
    static void executeAction_tooManyAttachments_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String configJson = '{"maxAttachments":1}';
        String base64Content = EncodingUtil.base64Encode(Blob.valueOf('Test content'));

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Test Subject',
            'body' => 'Test body',
            'attachments' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'fileName' => 'test1.txt', 'contentType' => 'text/plain', 'body' => base64Content },
                new Map<String, Object>{ 'fileName' => 'test2.txt', 'contentType' => 'text/plain', 'body' => base64Content }
            }
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for too many attachments');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test error handling - empty email addresses
     */
    @IsTest
    static void executeAction_emptyEmailAddresses_validationError() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com', '' },
            'subject' => 'Test Subject',
            'body' => 'Test body'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(!outcome.isSuccess, 'Should fail validation for empty email addresses');
        System.assert(outcome.errorCode == AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Should return validation error code');
    }

    /**
     * Test successful email with all optional parameters
     */
    @IsTest
    static void executeAction_allParameters_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        String base64Content = EncodingUtil.base64Encode(Blob.valueOf('Test attachment content'));

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'primary@example.com' },
            'ccAddresses' => new List<String>{ 'cc@example.com' },
            'bccAddresses' => new List<String>{ 'bcc@example.com' },
            'subject' => 'Complete Email Test',
            'body' => 'Plain text body',
            'htmlBody' => '<h1>HTML Body</h1>',
            'plainTextBody' => 'Plain text body',
            'fromName' => 'Test Sender',
            'replyTo' => 'reply@example.com',
            'whatId' => UserInfo.getUserId(),
            'targetObjectId' => UserInfo.getUserId(),
            'saveAsActivity' => false, // Must be false when sending to users
            'useSignature' => true,
            'treatBodiesAsTemplate' => false,
            'attachments' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'fileName' => 'test.txt', 'contentType' => 'text/plain', 'body' => base64Content }
            }
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Complete email should be sent successfully');
    }

    /**
     * Test email result structure
     */
    @IsTest
    static void executeAction_verifyResultStructure() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Result Structure Test',
            'body' => 'Testing result structure'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email should be sent successfully');
        System.assertNotEquals(null, outcome.data, 'Output should not be null');

        // Verify result structure if it's a Map
        if (outcome.data instanceof Map<String, Object>) {
            Map<String, Object> outputMap = (Map<String, Object>) outcome.data;
            System.assert(outputMap.containsKey('success'), 'Result should contain success field');
            System.assert(outputMap.containsKey('subject'), 'Result should contain subject field');
            System.assert(outputMap.containsKey('recipientCount'), 'Result should contain recipientCount field');
        }
    }

    /**
     * Test type conversion for JSON deserialized arrays
     */
    @IsTest
    static void executeAction_jsonDeserializedArrays_success() {
        // Setup - simulate JSON deserialization that creates List<Object> instead of List<String>
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        // Create parameters that simulate JSON deserialization behavior
        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<Object>{ 'test1@example.com', 'test2@example.com' },
            'ccAddresses' => new List<Object>{ 'cc1@example.com' },
            'bccAddresses' => new List<Object>{ 'bcc1@example.com' },
            'subject' => 'JSON Deserialization Test',
            'body' => 'Testing type conversion from JSON deserialization'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with JSON deserialized arrays should be sent successfully');
    }

    /**
     * Test type conversion with mixed data types (simulating real JSON deserialization)
     */
    @IsTest
    static void executeAction_mixedDataTypes_success() {
        // Setup - simulate the exact scenario that was failing
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        // This simulates what happens when JSON.deserializeUntyped() is called
        // and the framework processes the parameters
        Map<String, Object> rawParams = new Map<String, Object>{
            'toAddresses' => new List<Object>{ 'user@example.com' },
            'subject' => 'Mixed Data Types Test',
            'htmlBody' => '<h1>Test</h1>',
            'plainTextBody' => 'Test content'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(rawParams), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with mixed data types should be sent successfully');
    }

    /**
     * Test permission validation passes in test context
     */
    @IsTest
    static void executeAction_permissionValidation_success() {
        // Setup
        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Permission Test',
            'body' => 'Testing permission validation'
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify - should succeed as permission validation is delegated to email sending
        System.assert(outcome.isSuccess, 'Email should succeed with delegated permission validation');
    }

    /**
     * Test saveAsActivity with non-user target (should work)
     */
    @IsTest
    static void executeAction_saveAsActivityWithContact_success() {
        // Setup - create a test contact
        Contact testContact = new Contact(FirstName = 'Test', LastName = 'Contact', Email = 'testcontact@example.com');
        insert testContact;

        ActionSendEmail action = new ActionSendEmail();
        ActionContext context = createActionContext();

        Map<String, Object> params = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'test@example.com' },
            'subject' => 'Save As Activity Test',
            'body' => 'Testing saveAsActivity with Contact',
            'targetObjectId' => testContact.Id,
            'saveAsActivity' => true // This should work with Contact
        };

        // Execute
        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(params), context);
        Test.stopTest();

        // Verify
        System.assert(outcome.isSuccess, 'Email with saveAsActivity=true should work with Contact target');
    }
}
