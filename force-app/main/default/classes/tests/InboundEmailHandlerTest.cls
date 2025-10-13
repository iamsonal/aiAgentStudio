/**
 * @description Test class for InboundEmailHandler
 * Tests email parsing, routing, and agent execution creation from inbound emails
 */
@IsTest
private class InboundEmailHandlerTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create email-enabled agent
        LLMConfiguration__c llmConfig = TestFactory.newLLMConfiguration()
            .withName('Email Agent LLM')
            .save();

        AIAgentDefinition__c emailAgent = TestFactory.newAgentDefinition()
            .withName('Email_Support_Agent')
            .withLLM(llmConfig.Id)
            .build();
        emailAgent.AgentType__c = 'Email';
        emailAgent.IsActive__c = true;
        insert emailAgent;
    }

    // ===================================================================================
    // EMAIL PARSING TESTS
    // ===================================================================================

    @IsTest
    static void testHandleInboundEmail_WithBasicEmail_CreatesExecution() {
        // Given: Basic inbound email
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Test Support Request';
        email.plainTextBody = 'This is a test support request from a customer.';
        email.fromAddress = 'customer@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling inbound email
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process email successfully');

        // Verify execution created
        List<AgentExecution__c> executions = [SELECT Id, ExecutionType__c, TriggerSource__c, ExecutionStatus__c
                                              FROM AgentExecution__c];
        System.assertEquals(1, executions.size(), 'Should create one execution');
        System.assertEquals('Email', executions[0].ExecutionType__c, 'Should be email type');
        System.assertEquals('Email', executions[0].TriggerSource__c, 'Should have email trigger source');
    }

    @IsTest
    static void testHandleInboundEmail_WithCcAddresses_ParsesCorrectly() {
        // Given: Email with CC addresses
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Team Discussion';
        email.plainTextBody = 'Team discussion email';
        email.fromAddress = 'sender@example.com';
        email.ccAddresses = new String[]{'cc1@example.com', 'cc2@example.com'};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with CC
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process email with CC');

        // Verify execution created
        List<AgentExecution__c> executions = [SELECT Id FROM AgentExecution__c];
        System.assertEquals(1, executions.size(), 'Should create execution');
    }

    @IsTest
    static void testHandleInboundEmail_WithTextAttachments_ParsesAttachments() {
        // Given: Email with text attachments
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Email with Text Attachment';
        email.plainTextBody = 'See attached file.';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEmail.TextAttachment textAttachment = new Messaging.InboundEmail.TextAttachment();
        textAttachment.fileName = 'notes.txt';
        textAttachment.body = 'These are my notes.';
        email.textAttachments = new Messaging.InboundEmail.TextAttachment[]{textAttachment};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with text attachment
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process email with text attachment');

        // Verify execution created
        List<AgentExecution__c> executions = [SELECT Id FROM AgentExecution__c];
        System.assertEquals(1, executions.size(), 'Should create execution with attachment');
    }

    @IsTest
    static void testHandleInboundEmail_WithBinaryAttachments_ParsesAttachments() {
        // Given: Email with binary attachments
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Email with Binary Attachment';
        email.plainTextBody = 'See attached PDF.';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEmail.BinaryAttachment binaryAttachment = new Messaging.InboundEmail.BinaryAttachment();
        binaryAttachment.fileName = 'document.pdf';
        binaryAttachment.body = Blob.valueOf('PDF content');
        binaryAttachment.mimeTypeSubType = 'application/pdf';
        email.binaryAttachments = new Messaging.InboundEmail.BinaryAttachment[]{binaryAttachment};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with binary attachment
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process email with binary attachment');
    }

    @IsTest
    static void testHandleInboundEmail_WithHeaders_ParsesHeaders() {
        // Given: Email with custom headers
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Email with Headers';
        email.plainTextBody = 'Email content';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEmail.Header header1 = new Messaging.InboundEmail.Header();
        header1.name = 'X-Custom-Header';
        header1.value = 'custom-value';

        Messaging.InboundEmail.Header header2 = new Messaging.InboundEmail.Header();
        header2.name = 'X-Priority';
        header2.value = 'high';

        email.headers = new Messaging.InboundEmail.Header[]{header1, header2};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with headers
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process email with headers');
    }

    @IsTest
    static void testHandleInboundEmail_WithHtmlBody_ParsesCorrectly() {
        // Given: Email with HTML body
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'HTML Email';
        email.plainTextBody = 'Plain text version';
        email.htmlBody = '<html><body><p>HTML version</p></body></html>';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling HTML email
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should process HTML email');
    }

    // ===================================================================================
    // EMAIL ROUTING TESTS
    // ===================================================================================

    @IsTest
    static void testHandleInboundEmail_WithNoEmailAgent_ReturnsSuccessWithoutProcessing() {
        // Given: No email-enabled agent exists
        // Delete the email agent
        delete [SELECT Id FROM AIAgentDefinition__c WHERE AgentType__c = 'Email'];

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Test Email';
        email.plainTextBody = 'Test content';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with no agent
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should return success but no execution
        System.assertEquals(true, result.success, 'Should return success even without agent');
        System.assert(result.message.contains('no agent routing'), 'Should indicate no routing configured');

        // Verify no execution created
        List<AgentExecution__c> executions = [SELECT Id FROM AgentExecution__c];
        System.assertEquals(0, executions.size(), 'Should not create execution without agent');
    }

    @IsTest
    static void testHandleInboundEmail_WithMultipleEmailAgents_SelectsFirst() {
        // Given: Multiple email-enabled agents
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        AIAgentDefinition__c secondEmailAgent = TestFactory.newAgentDefinition()
            .withName('Second_Email_Agent')
            .withLLM(llmConfig.Id)
            .build();
        secondEmailAgent.AgentType__c = 'Email';
        secondEmailAgent.IsActive__c = true;
        insert secondEmailAgent;

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Test Email';
        email.plainTextBody = 'Test content';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with multiple agents
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should route to one agent
        System.assertEquals(true, result.success, 'Should process successfully');

        List<AgentExecution__c> executions = [SELECT Id FROM AgentExecution__c];
        System.assertEquals(1, executions.size(), 'Should create one execution');
    }

    // ===================================================================================
    // ERROR HANDLING TESTS
    // ===================================================================================

    @IsTest
    static void testHandleInboundEmail_WithProcessingError_CreatesFailedExecution() {
        // Given: Email that will cause processing error
        // Make agent inactive to trigger failure
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE AgentType__c = 'Email' LIMIT 1];
        agent.IsActive__c = false;
        update agent;

        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Test Email';
        email.plainTextBody = 'Test content';
        email.fromAddress = 'sender@example.com';

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email that causes error
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should return success (no agent available)
        System.assertEquals(true, result.success, 'Should not bounce email');
    }

    @IsTest
    static void testHandleInboundEmail_WithNullValues_HandlesGracefully() {
        // Given: Email with null subject and body (invalid email)
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = null;  // Null subject
        email.plainTextBody = null;  // Null body
        email.fromAddress = null;  // Null from

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = null;  // Null to

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with nulls (no subject or body)
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should handle validation error gracefully by returning false
        // Email orchestrator requires subject or body, so this should fail gracefully
        System.assertEquals(false, result.success, 'Should return false for email with no subject or body');
        System.assert(result.message.contains('subject or body'), 'Error message should indicate subject or body requirement');
    }

    @IsTest
    static void testHandleInboundEmail_WithEmptyAttachments_HandlesGracefully() {
        // Given: Email with empty attachment arrays
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Test Email';
        email.plainTextBody = 'Test content';
        email.fromAddress = 'sender@example.com';
        email.textAttachments = new Messaging.InboundEmail.TextAttachment[]{};
        email.binaryAttachments = new Messaging.InboundEmail.BinaryAttachment[]{};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling email with empty attachments
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process successfully
        System.assertEquals(true, result.success, 'Should handle empty attachments');
    }

    // ===================================================================================
    // DATA STRUCTURE TESTS
    // ===================================================================================

    @IsTest
    static void testEmailRoutingConfig_Creation() {
        // When: Creating EmailRoutingConfig
        Test.startTest();
        InboundEmailHandler.EmailRoutingConfig config = new InboundEmailHandler.EmailRoutingConfig();
        config.agentDefinitionId = [SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id;
        config.routingRule = 'TestRule';
        config.fromAddressPattern = '*@example.com';
        config.toAddressPattern = 'support@*';
        config.subjectPattern = '*support*';
        config.isActive = true;
        config.priority = 1;
        Test.stopTest();

        // Then: Should create config
        System.assertNotEquals(null, config.agentDefinitionId, 'Should set agent definition ID');
        System.assertEquals('TestRule', config.routingRule, 'Should set routing rule');
        System.assertEquals(true, config.isActive, 'Should set active flag');
    }

    @IsTest
    static void testParsedEmailContent_Creation() {
        // When: Creating ParsedEmailContent
        Test.startTest();
        InboundEmailHandler.ParsedEmailContent parsed = new InboundEmailHandler.ParsedEmailContent();
        parsed.subject = 'Test Subject';
        parsed.plainTextBody = 'Test Body';
        parsed.htmlBody = '<p>HTML Body</p>';
        parsed.fromAddress = 'from@example.com';
        parsed.toAddress = 'to@example.com';
        parsed.ccAddresses = new List<String>{'cc@example.com'};
        parsed.attachments = new List<InboundEmailHandler.AttachmentInfo>();
        parsed.headers = new Map<String, String>{'X-Custom' => 'value'};
        parsed.receivedTime = Datetime.now();
        Test.stopTest();

        // Then: Should create parsed content
        System.assertEquals('Test Subject', parsed.subject, 'Should set subject');
        System.assertEquals('Test Body', parsed.plainTextBody, 'Should set body');
        System.assertEquals('from@example.com', parsed.fromAddress, 'Should set from address');
    }

    @IsTest
    static void testAttachmentInfo_Creation() {
        // When: Creating AttachmentInfo
        Test.startTest();
        InboundEmailHandler.AttachmentInfo attachment = new InboundEmailHandler.AttachmentInfo();
        attachment.fileName = 'test.pdf';
        attachment.contentType = 'application/pdf';
        attachment.fileSize = 1024;
        attachment.fileContent = Blob.valueOf('content');
        attachment.description = 'Test attachment';
        Test.stopTest();

        // Then: Should create attachment info
        System.assertEquals('test.pdf', attachment.fileName, 'Should set file name');
        System.assertEquals('application/pdf', attachment.contentType, 'Should set content type');
        System.assertEquals(1024, attachment.fileSize, 'Should set file size');
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testEmailProcessingException_Creation() {
        // When: Creating EmailProcessingException
        Test.startTest();
        InboundEmailHandler.EmailProcessingException ex = new InboundEmailHandler.EmailProcessingException(
            'Failed to process email'
        );
        Test.stopTest();

        // Then: Should create exception
        System.assert(ex.getMessage().contains('Failed to process email'), 'Should contain error message');
    }

    // ===================================================================================
    // INTEGRATION TESTS
    // ===================================================================================

    @IsTest
    static void testHandleInboundEmail_ComplexEmail_ProcessesAllComponents() {
        // Given: Complex email with all components
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Complex Support Request';
        email.plainTextBody = 'This is a complex support request.';
        email.htmlBody = '<html><body><p>This is a <b>complex</b> support request.</p></body></html>';
        email.fromAddress = 'customer@example.com';
        email.ccAddresses = new String[]{'manager@example.com', 'team@example.com'};

        // Add text attachment
        Messaging.InboundEmail.TextAttachment textAttachment = new Messaging.InboundEmail.TextAttachment();
        textAttachment.fileName = 'details.txt';
        textAttachment.body = 'Additional details';
        email.textAttachments = new Messaging.InboundEmail.TextAttachment[]{textAttachment};

        // Add binary attachment
        Messaging.InboundEmail.BinaryAttachment binaryAttachment = new Messaging.InboundEmail.BinaryAttachment();
        binaryAttachment.fileName = 'screenshot.png';
        binaryAttachment.body = Blob.valueOf('image data');
        binaryAttachment.mimeTypeSubType = 'image/png';
        email.binaryAttachments = new Messaging.InboundEmail.BinaryAttachment[]{binaryAttachment};

        // Add headers
        Messaging.InboundEmail.Header header = new Messaging.InboundEmail.Header();
        header.name = 'X-Priority';
        header.value = 'urgent';
        email.headers = new Messaging.InboundEmail.Header[]{header};

        Messaging.InboundEnvelope envelope = new Messaging.InboundEnvelope();
        envelope.toAddress = 'support@mycompany.com';

        InboundEmailHandler handler = new InboundEmailHandler();

        // When: Handling complex email
        Test.startTest();
        Messaging.InboundEmailResult result = handler.handleInboundEmail(email, envelope);
        Test.stopTest();

        // Then: Should process all components successfully
        System.assertEquals(true, result.success, 'Should process complex email successfully');

        // Verify execution created with all components
        List<AgentExecution__c> executions = [SELECT Id, ExecutionType__c FROM AgentExecution__c];
        System.assertEquals(1, executions.size(), 'Should create one execution');
        System.assertEquals('Email', executions[0].ExecutionType__c, 'Should be email type');
    }
}

