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
     * Now uses the unified AgentExecutionService for consistent execution flow.
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

            // Get the agent definition to use its developer name
            AIAgentDefinition__c agentDef = [
                SELECT Id, DeveloperName__c
                FROM AIAgentDefinition__c
                WHERE Id = :routingConfig.agentDefinitionId
                LIMIT 1
            ];

            // Build execution payload for unified service
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.userId = UserInfo.getUserId();
            payload.triggerSource = 'Email';
            payload.emailSubject = parsedEmail.subject;
            payload.emailBody = parsedEmail.plainTextBody;
            payload.emailFromAddress = parsedEmail.fromAddress;
            payload.emailToAddress = parsedEmail.toAddress;
            payload.emailCcAddresses = parsedEmail.ccAddresses;
            payload.emailHeaders = parsedEmail.headers;

            // Convert attachments
            if (parsedEmail.attachments != null) {
                payload.emailAttachments = new List<AgentExecutionService.EmailAttachment>();
                for (AttachmentInfo att : parsedEmail.attachments) {
                    AgentExecutionService.EmailAttachment attachment = new AgentExecutionService.EmailAttachment();
                    attachment.fileName = att.fileName;
                    attachment.contentType = att.contentType;
                    attachment.fileSize = att.fileSize;
                    attachment.fileContent = att.fileContent;
                    attachment.description = att.description;
                    payload.emailAttachments.add(attachment);
                }
            }

            // Use unified AgentExecutionService to initiate execution
            AgentExecutionService.ExecutionResult execResult = AgentExecutionService.startExecution(agentDef.DeveloperName__c, payload);

            if (execResult.success) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Successfully created email execution: ' + execResult.executionId);
                result.success = true;
                result.message = 'Email processed successfully. Execution ID: ' + execResult.executionId;
            } else {
                result.success = false;
                result.message = 'Email execution failed: ' + execResult.errorMessage;
            }

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

    // NOTE: createEmailExecution and publishEmailProcessingEvent methods removed
    // Email execution creation is now handled by EmailOrchestrator via AgentExecutionService

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

    // NOTE: buildEmailContentForProcessing and generateTurnIdentifier methods removed
    // Email content formatting and turn identifier generation are now handled by EmailOrchestrator
}
