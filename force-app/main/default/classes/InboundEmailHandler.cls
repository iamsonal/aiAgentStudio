/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * InboundEmailHandler processes incoming emails and creates AgentExecution__c records for email-triggered agent processing.
 * This class implements the DML phase of the email front door pattern, ensuring proper separation of DML and callout operations.
 *
 * Responsibilities:
 *   - Parses inbound email content, attachments, and headers
 *   - Routes emails to appropriate AI agents based on configuration
 *   - Creates AgentExecution__c and ExecutionStep__c records (DML phase)
 *   - Publishes AsyncFrameworkRequest__e events for async processing (callout phase)
 *   - Handles email routing, filtering, and error scenarios
 *
 * This class implements the Messaging.InboundEmailHandler interface for Salesforce Email Services.
 */
public class InboundEmailHandler implements Messaging.InboundEmailHandler {

    /**
     * Exception thrown when email processing configuration is invalid or missing.
     */
    public class EmailProcessingException extends Exception {}

    /**
     * Data structure for email routing configuration.
     */
    public class EmailRoutingConfig {
        public Id agentDefinitionId;
        public String routingRule;
        public String fromAddressPattern;
        public String toAddressPattern;
        public String subjectPattern;
        public Boolean isActive;
        public Integer priority;
    }

    /**
     * Data structure for parsed email content.
     */
    public class ParsedEmailContent {
        public String subject;
        public String plainTextBody;
        public String htmlBody;
        public String fromAddress;
        public String toAddress;
        public List<String> ccAddresses;
        public List<AttachmentInfo> attachments;
        public Map<String, String> headers;
        public Datetime receivedTime;
    }

    /**
     * Data structure for email attachment information.
     */
    public class AttachmentInfo {
        public String fileName;
        public String contentType;
        public Integer fileSize;
        public Blob fileContent;
        public String description;
    }

    /**
     * Main entry point for processing inbound emails.
     * Implements the Messaging.InboundEmailHandler interface.
     *
     * @param email The inbound email message
     * @param envelope The email envelope information
     * @return Messaging.InboundEmailResult indicating processing success/failure
     */
    public Messaging.InboundEmailResult handleInboundEmail(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        String logPrefix = '[InboundEmailHandler] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing inbound email from: ' + email.fromAddress + ', Subject: ' + email.subject);

        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

        try {
            // Parse the email content
            ParsedEmailContent parsedEmail = parseEmailContent(email, envelope);

            // Route the email to appropriate agent
            EmailRoutingConfig routingConfig = routeEmail(parsedEmail);

            if (routingConfig == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'No routing configuration found for email. Skipping processing.');
                result.success = true; // Don't bounce emails that can't be routed
                result.message = 'Email received but no agent routing configured';
                return result;
            }

            // Create AgentExecution__c and related records (DML Phase)
            Id executionId = createEmailExecution(parsedEmail, routingConfig);

            // Publish platform event for async processing (Callout Phase)
            publishEmailProcessingEvent(executionId, parsedEmail, routingConfig);

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully created email execution: ' + executionId);

            result.success = true;
            result.message = 'Email processed successfully. Execution ID: ' + executionId;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing inbound email: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString());

            result.success = false;
            result.message = 'Email processing failed: ' + e.getMessage();

            // Optionally create a failed execution record for tracking
            try {
                createFailedEmailExecution(email, envelope, e.getMessage());
            } catch (Exception logEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to log email processing error: ' + logEx.getMessage());
            }
        }

        return result;
    }

    /**
     * Parses the inbound email into a structured format.
     *
     * @param email The inbound email message
     * @param envelope The email envelope information
     * @return ParsedEmailContent structured email data
     */
    private ParsedEmailContent parseEmailContent(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope) {
        ParsedEmailContent parsed = new ParsedEmailContent();

        parsed.subject = email.subject ?? '';
        parsed.plainTextBody = email.plainTextBody ?? '';
        parsed.htmlBody = email.htmlBody ?? '';
        parsed.fromAddress = email.fromAddress ?? '';
        parsed.toAddress = envelope.toAddress ?? '';
        parsed.receivedTime = Datetime.now();

        // Parse CC addresses
        parsed.ccAddresses = new List<String>();
        if (email.ccAddresses != null) {
            for (String ccAddress : email.ccAddresses) {
                parsed.ccAddresses.add(ccAddress);
            }
        }

        // Parse attachments
        parsed.attachments = new List<AttachmentInfo>();
        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment textAttachment : email.textAttachments) {
                AttachmentInfo attachment = new AttachmentInfo();
                attachment.fileName = textAttachment.fileName;
                attachment.contentType = 'text/plain';
                attachment.fileContent = Blob.valueOf(textAttachment.body ?? '');
                attachment.fileSize = attachment.fileContent.size();
                attachment.description = 'Text attachment';
                parsed.attachments.add(attachment);
            }
        }

        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment binaryAttachment : email.binaryAttachments) {
                AttachmentInfo attachment = new AttachmentInfo();
                attachment.fileName = binaryAttachment.fileName;
                attachment.contentType = binaryAttachment.mimeTypeSubType ?? 'application/octet-stream';
                attachment.fileContent = binaryAttachment.body;
                attachment.fileSize = attachment.fileContent.size();
                attachment.description = 'Binary attachment';
                parsed.attachments.add(attachment);
            }
        }

        // Parse headers
        parsed.headers = new Map<String, String>();
        if (email.headers != null) {
            for (Messaging.InboundEmail.Header header : email.headers) {
                parsed.headers.put(header.name, header.value);
            }
        }

        return parsed;
    }

    /**
     * Routes the email to an appropriate AI agent based on configuration.
     * This method would typically query custom metadata or configuration objects.
     *
     * @param parsedEmail The parsed email content
     * @return EmailRoutingConfig routing configuration or null if no match
     */
    private EmailRoutingConfig routeEmail(ParsedEmailContent parsedEmail) {
        String logPrefix = '[InboundEmailHandler.routeEmail] ';

        try {
            // Query for active AI agents that can handle email processing
            List<AIAgentDefinition__c> emailAgents = [
                SELECT Id, DeveloperName__c, Name, IsActive__c,
                       LLMConfiguration__c, EnableEmailProcessing__c
                FROM AIAgentDefinition__c
                WHERE IsActive__c = true
                AND EnableEmailProcessing__c = true
                ORDER BY Name
                LIMIT 10
            ];

            if (emailAgents.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'No active email-enabled agents found');
                return null;
            }

            // For now, use the first available agent
            // In a production system, you would implement sophisticated routing logic
            // based on email content, sender, subject patterns, etc.
            AIAgentDefinition__c selectedAgent = emailAgents[0];

            EmailRoutingConfig config = new EmailRoutingConfig();
            config.agentDefinitionId = selectedAgent.Id;
            config.routingRule = 'DefaultEmailAgent';
            config.fromAddressPattern = '*';
            config.toAddressPattern = '*';
            config.subjectPattern = '*';
            config.isActive = true;
            config.priority = 1;

            System.debug(LoggingLevel.INFO, logPrefix + 'Routed email to agent: ' + selectedAgent.DeveloperName__c);
            return config;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error routing email: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Creates AgentExecution__c and ExecutionStep__c records for the email (DML Phase).
     *
     * @param parsedEmail The parsed email content
     * @param routingConfig The routing configuration
     * @return Id of the created AgentExecution__c record
     */
    private Id createEmailExecution(ParsedEmailContent parsedEmail, EmailRoutingConfig routingConfig) {
        String logPrefix = '[InboundEmailHandler.createEmailExecution] ';

        // Use ExecutionContextService for consistent execution creation
        ExecutionContextService executionContextService = new ExecutionContextService();

        // Create execution metadata
        Map<String, Object> emailMetadata = new Map<String, Object>{
            'emailSubject' => parsedEmail.subject,
            'fromAddress' => parsedEmail.fromAddress,
            'toAddress' => parsedEmail.toAddress,
            'ccAddresses' => parsedEmail.ccAddresses,
            'hasAttachments' => !parsedEmail.attachments.isEmpty(),
            'attachmentCount' => parsedEmail.attachments.size(),
            'receivedTime' => parsedEmail.receivedTime,
            'routingRule' => routingConfig.routingRule
        };

        // Create the AgentExecution__c record
        Id executionId = executionContextService.createExecution(
            'Email', // ExecutionType__c
            routingConfig.agentDefinitionId, // AIAgentDefinition__c
            'Email', // TriggerSource__c
            JSON.serialize(emailMetadata), // TriggerPayload__c
            null, // SourceRecordId__c (could be set if email relates to a specific record)
            UserInfo.getUserId(), // User__c
            null // ServiceUser__c (could be set for elevated permissions)
        );

        // Create ExecutionStep__c records for email content
        ExecutionStepService executionStepService = new ExecutionStepService();
        String turnIdentifier = generateTurnIdentifier();

        // Update execution with turn identifier
        executionContextService.updateStatus(
            executionId,
            'Processing',
            AIAgentConstants.STATUS_PROCESSING,
            turnIdentifier,
            'Processing inbound email'
        );

        // Create main email content step
        String emailContent = buildEmailContentForProcessing(parsedEmail);
        executionStepService.createStep(
            executionId,
            'TriggerInput',
            'Email',
            emailContent,
            'Email',
            turnIdentifier,
            1,
            null, // toolCallId
            null, // toolName
            null, // toolArguments
            null, // toolResult
            JSON.serialize(emailMetadata),
            false // isInternal
        );

        // Create attachment steps if present
        for (Integer i = 0; i < parsedEmail.attachments.size(); i++) {
            AttachmentInfo attachment = parsedEmail.attachments[i];

            Map<String, Object> attachmentMetadata = new Map<String, Object>{
                'fileName' => attachment.fileName,
                'contentType' => attachment.contentType,
                'fileSize' => attachment.fileSize,
                'attachmentIndex' => i
            };

            executionStepService.createStep(
                executionId,
                'TriggerInput',
                'Attachment',
                'Attachment: ' + attachment.fileName + ' (' + attachment.contentType + ', ' + attachment.fileSize + ' bytes)',
                'Attachment',
                turnIdentifier,
                1,
                null, // toolCallId
                null, // toolName
                null, // toolArguments
                null, // toolResult
                JSON.serialize(attachmentMetadata),
                false // isInternal
            );
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Created execution ' + executionId + ' with ' + (1 + parsedEmail.attachments.size()) + ' steps');
        return executionId;
    }

    /**
     * Publishes AsyncFrameworkRequest__e event for async processing (Callout Phase).
     *
     * @param executionId The created execution ID
     * @param parsedEmail The parsed email content
     * @param routingConfig The routing configuration
     */
    private void publishEmailProcessingEvent(Id executionId, ParsedEmailContent parsedEmail, EmailRoutingConfig routingConfig) {
        String logPrefix = '[InboundEmailHandler.publishEmailProcessingEvent] ';

        try {
            // Create payload for async processing using the unified InitiateExecution pattern
            Map<String, Object> payload = new Map<String, Object>{
                'executionId' => executionId,
                'triggerSource' => 'Email',
                'agentDefinitionId' => routingConfig.agentDefinitionId,
                'emailSubject' => parsedEmail.subject,
                'emailBody' => parsedEmail.plainTextBody,
                'fromAddress' => parsedEmail.fromAddress,
                'toAddress' => parsedEmail.toAddress,
                'attachmentCount' => parsedEmail.attachments.size(),
                'routingRule' => routingConfig.routingRule,
                'priority' => routingConfig.priority
            };

            // Publish platform event using the unified InitiateExecution job type
            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = executionId,
                TurnIdentifier__c = null, // Will be set by the handler
                JobType__c = 'InitiateExecution',
                Payload__c = JSON.serialize(payload)
            );

            Database.SaveResult sr = EventBus.publish(event);
            if (!sr.isSuccess()) {
                throw new EmailProcessingException('Failed to publish email processing event: ' + sr.getErrors()[0].getMessage());
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Published email processing event for execution: ' + executionId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error publishing email processing event: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * Creates a failed execution record for tracking email processing errors.
     *
     * @param email The original email
     * @param envelope The email envelope
     * @param errorMessage The error that occurred
     */
    private void createFailedEmailExecution(Messaging.InboundEmail email, Messaging.InboundEnvelope envelope, String errorMessage) {
        try {
            // Create a minimal execution record to track the failure
            AgentExecution__c failedExecution = new AgentExecution__c(
                ExecutionType__c = 'Email',
                TriggerSource__c = 'Email',
                ExecutionStatus__c = 'Failed',
                ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                User__c = UserInfo.getUserId(),
                TriggerPayload__c = JSON.serialize(new Map<String, Object>{
                    'emailSubject' => email.subject,
                    'fromAddress' => email.fromAddress,
                    'toAddress' => envelope.toAddress,
                    'error' => errorMessage
                }),
                ExecutionMetadata__c = JSON.serialize(new Map<String, Object>{
                    'processingError' => errorMessage,
                    'failureTime' => Datetime.now()
                })
            );
            insert failedExecution;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[InboundEmailHandler] Failed to create failed execution record: ' + e.getMessage());
        }
    }

    /**
     * Builds formatted email content for agent processing.
     *
     * @param parsedEmail The parsed email content
     * @return String formatted email content
     */
    private String buildEmailContentForProcessing(ParsedEmailContent parsedEmail) {
        List<String> contentParts = new List<String>();

        contentParts.add('Email Subject: ' + parsedEmail.subject);
        contentParts.add('From: ' + parsedEmail.fromAddress);
        contentParts.add('To: ' + parsedEmail.toAddress);

        if (!parsedEmail.ccAddresses.isEmpty()) {
            contentParts.add('CC: ' + String.join(parsedEmail.ccAddresses, ', '));
        }

        contentParts.add('Received: ' + parsedEmail.receivedTime.format());
        contentParts.add('\n--- Email Body ---');

        // Prefer plain text, fall back to HTML
        if (String.isNotBlank(parsedEmail.plainTextBody)) {
            contentParts.add(parsedEmail.plainTextBody);
        } else if (String.isNotBlank(parsedEmail.htmlBody)) {
            contentParts.add('HTML Content:\n' + parsedEmail.htmlBody);
        }

        if (!parsedEmail.attachments.isEmpty()) {
            contentParts.add('\n--- Attachments ---');
            for (AttachmentInfo attachment : parsedEmail.attachments) {
                contentParts.add('- ' + attachment.fileName +
                               ' (' + attachment.contentType +
                               ', ' + attachment.fileSize + ' bytes)');
            }
        }

        return String.join(contentParts, '\n');
    }

    /**
     * Generates a unique turn identifier for execution tracking.
     *
     * @return String unique turn identifier
     */
    private String generateTurnIdentifier() {
        return 'email_turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
