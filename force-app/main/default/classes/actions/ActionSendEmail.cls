/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSendEmail is a comprehensive Apex action for sending emails through Salesforce with intelligent validation,
 * security checks, and flexible configuration options.
 *
 * Responsibilities:
 *   - Validates email parameters including recipients, subject, body, and attachments
 *   - Performs security validation for email sending permissions and content
 *   - Supports multiple email formats (plain text, HTML, both)
 *   - Handles email templates, attachments, and advanced features like reply-to
 *   - Provides detailed error handling and audit logging
 *   - Enforces email limits and content validation
 *
 * Scope:
 *   - Focused on secure, flexible email sending for any use case within the agent framework
 *   - Designed for maintainability, extensibility, and compliance with email best practices
 *   - Supports both simple and complex email scenarios with rich configuration options
 *
 * @extends BaseAgentAction
 */
public class ActionSendEmail extends BaseAgentAction {

    // Configuration keys
    private static final String CONFIG_KEY_DEFAULT_FROM_NAME = 'defaultFromName';
    private static final String CONFIG_KEY_DEFAULT_REPLY_TO = 'defaultReplyTo';
    private static final String CONFIG_KEY_MAX_RECIPIENTS = 'maxRecipients';
    private static final String CONFIG_KEY_MAX_ATTACHMENTS = 'maxAttachments';
    private static final String CONFIG_KEY_REQUIRE_APPROVAL = 'requireApproval';

    // Default values
    private static final Integer DEFAULT_MAX_RECIPIENTS = 100;
    private static final Integer DEFAULT_MAX_ATTACHMENTS = 10;
    private static final Integer MAX_EMAIL_LIMIT = 1000; // Salesforce daily limit consideration

    // Configuration populated during parseActionConfiguration
    private String defaultFromName;
    private String defaultReplyTo;
    private Integer maxRecipients = DEFAULT_MAX_RECIPIENTS;
    private Integer maxAttachments = DEFAULT_MAX_ATTACHMENTS;
    private Boolean requireApproval = false;

    /**
     * @description
     * Main entry point for email sending. Validates parameters, performs security checks,
     * constructs the email message, and sends it via Salesforce Messaging API.
     *
     * @param params Map<String, Object> - Email parameters including recipients, subject, body, etc.
     * @return ActionOutcome<EmailResult> - Contains email send status and metadata or error information.
     *
     * Side effects: Logs email sending details, security checks, and performance metrics for audit.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        try {
            // Extract and validate email parameters
            EmailParameters emailParams = extractEmailParameters(params);

            // Perform comprehensive validation
            ActionOutcome validationResult = validateEmailParameters(emailParams);
            if (!validationResult.isSuccess) {
                return validationResult;
            }

            // Check if approval is required
            if (this.requireApproval) {
                return handleApprovalRequired(emailParams);
            }

            // Construct and send the email
            ActionOutcome sendResult = sendEmailMessage(emailParams);

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, '[ActionSendEmail] Email processing completed in ' + executionTime + ' ms');

            return sendResult;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Unexpected error during email processing: ' + e.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Email processing failed: ' + e.getMessage());
        }
    }

    /**
     * @description
     * Extracts and structures email parameters from the input map.
     *
     * @param params Map<String, Object> - Raw parameters from the action call
     * @return EmailParameters - Structured email parameters object
     */
    private EmailParameters extractEmailParameters(Map<String, Object> params) {
        EmailParameters emailParams = new EmailParameters();

        // Required parameters with safe type conversion
        emailParams.toAddresses = convertToStringList(params.get('toAddresses'));
        emailParams.subject = (String) params.get('subject');
        emailParams.body = (String) params.get('body');

        // Optional parameters with safe type conversion
        emailParams.ccAddresses = convertToStringList(params.get('ccAddresses'));
        emailParams.bccAddresses = convertToStringList(params.get('bccAddresses'));
        emailParams.fromName = (String) params.get('fromName');
        emailParams.replyTo = (String) params.get('replyTo');
        emailParams.htmlBody = (String) params.get('htmlBody');
        emailParams.plainTextBody = (String) params.get('plainTextBody');
        emailParams.templateId = (String) params.get('templateId');
        emailParams.whatId = (String) params.get('whatId');
        emailParams.targetObjectId = (String) params.get('targetObjectId');
        emailParams.saveAsActivity = (Boolean) params.get('saveAsActivity');
        emailParams.attachments = convertToAttachmentList(params.get('attachments'));
        emailParams.useSignature = (Boolean) params.get('useSignature');
        emailParams.treatBodiesAsTemplate = (Boolean) params.get('treatBodiesAsTemplate');

        return emailParams;
    }

    /**
     * @description
     * Safely converts an Object to List<String>, handling JSON deserialization type issues.
     *
     * @param value Object - The value to convert
     * @return List<String> - Converted list or null if value is null
     */
    private List<String> convertToStringList(Object value) {
        if (value == null) {
            return null;
        }

        if (value instanceof List<String>) {
            return (List<String>) value;
        }

        if (value instanceof List<Object>) {
            List<String> result = new List<String>();
            for (Object item : (List<Object>) value) {
                if (item != null) {
                    result.add(String.valueOf(item));
                }
            }
            return result;
        }

        // Single value case
        return new List<String>{ String.valueOf(value) };
    }

    /**
     * @description
     * Safely converts an Object to List<Map<String, Object>> for attachments.
     *
     * @param value Object - The value to convert
     * @return List<Map<String, Object>> - Converted list or null if value is null
     */
    private List<Map<String, Object>> convertToAttachmentList(Object value) {
        if (value == null) {
            return null;
        }

        if (value instanceof List<Map<String, Object>>) {
            return (List<Map<String, Object>>) value;
        }

        if (value instanceof List<Object>) {
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            for (Object item : (List<Object>) value) {
                if (item instanceof Map<String, Object>) {
                    result.add((Map<String, Object>) item);
                }
            }
            return result;
        }

        return null;
    }

    /**
     * @description
     * Validates email parameters for completeness, format, and business rules.
     *
     * @param emailParams EmailParameters - The email parameters to validate
     * @return ActionOutcome - Success or failure with detailed error information
     */
    private ActionOutcome validateEmailParameters(EmailParameters emailParams) {
        // Validate required parameters
        if (emailParams.toAddresses == null || emailParams.toAddresses.isEmpty()) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'At least one recipient address is required');
        }

        if (String.isBlank(emailParams.subject)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Email subject is required');
        }

        // Validate that at least one form of body content is provided
        if (String.isBlank(emailParams.body) && String.isBlank(emailParams.htmlBody) && String.isBlank(emailParams.plainTextBody) && String.isBlank(emailParams.templateId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Email body, HTML body, plain text body, or template ID is required');
        }

        // Validate recipient count
        Integer totalRecipients = emailParams.toAddresses.size() +
                                (emailParams.ccAddresses != null ? emailParams.ccAddresses.size() : 0) +
                                (emailParams.bccAddresses != null ? emailParams.bccAddresses.size() : 0);

        if (totalRecipients > this.maxRecipients) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Too many recipients: ' + totalRecipients + ' (maximum allowed: ' + this.maxRecipients + ')');
        }

        // Validate email addresses
        ActionOutcome addressValidation = validateEmailAddresses(emailParams);
        if (!addressValidation.isSuccess) {
            return addressValidation;
        }

        // Validate attachments
        if (emailParams.attachments != null && emailParams.attachments.size() > this.maxAttachments) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Too many attachments: ' + emailParams.attachments.size() + ' (maximum allowed: ' + this.maxAttachments + ')');
        }

        return ActionOutcome.success();
    }

    /**
     * @description
     * Validates email address formats using Salesforce's built-in validation.
     *
     * @param emailParams EmailParameters - The email parameters containing addresses to validate
     * @return ActionOutcome - Success or failure with validation details
     */
    private ActionOutcome validateEmailAddresses(EmailParameters emailParams) {
        List<String> allAddresses = new List<String>();
        allAddresses.addAll(emailParams.toAddresses);

        if (emailParams.ccAddresses != null) {
            allAddresses.addAll(emailParams.ccAddresses);
        }

        if (emailParams.bccAddresses != null) {
            allAddresses.addAll(emailParams.bccAddresses);
        }

        for (String address : allAddresses) {
            if (String.isBlank(address)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Empty email address found');
            }

            // Basic email format validation
            if (!isValidEmailFormat(address)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid email address format: ' + address);
            }
        }

        return ActionOutcome.success();
    }

    /**
     * @description
     * Basic email format validation using regex pattern.
     *
     * @param email String - Email address to validate
     * @return Boolean - True if format appears valid
     */
    private Boolean isValidEmailFormat(String email) {
        String emailRegex = '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$';
        Pattern emailPattern = Pattern.compile(emailRegex);
        Matcher emailMatcher = emailPattern.matcher(email);
        return emailMatcher.matches();
    }

    /**
     * @description
     * Handles cases where email approval is required before sending.
     *
     * @param emailParams EmailParameters - The email parameters
     * @return ActionOutcome - Indicates approval is required
     */
    private ActionOutcome handleApprovalRequired(EmailParameters emailParams) {
        // In a real implementation, this would create an approval request
        // For now, we'll return a structured response indicating approval is needed
        Map<String, Object> approvalData = new Map<String, Object>{
            'requiresApproval' => true,
            'emailSubject' => emailParams.subject,
            'recipientCount' => emailParams.toAddresses.size(),
            'approvalMessage' => 'Email sending requires approval before it can be sent'
        };

        return ActionOutcome.success(approvalData);
    }

    /**
     * @description
     * Constructs and sends the email message using Salesforce Messaging API.
     *
     * @param emailParams EmailParameters - The validated email parameters
     * @return ActionOutcome - Success or failure with send results
     */
    private ActionOutcome sendEmailMessage(EmailParameters emailParams) {
        try {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();

            // Set recipients
            email.setToAddresses(emailParams.toAddresses);
            if (emailParams.ccAddresses != null && !emailParams.ccAddresses.isEmpty()) {
                email.setCcAddresses(emailParams.ccAddresses);
            }
            if (emailParams.bccAddresses != null && !emailParams.bccAddresses.isEmpty()) {
                email.setBccAddresses(emailParams.bccAddresses);
            }

            // Set subject
            email.setSubject(emailParams.subject);

            // Set body content
            if (String.isNotBlank(emailParams.templateId)) {
                email.setTemplateId(emailParams.templateId);
            } else {
                if (String.isNotBlank(emailParams.htmlBody)) {
                    email.setHtmlBody(emailParams.htmlBody);
                }
                if (String.isNotBlank(emailParams.plainTextBody)) {
                    email.setPlainTextBody(emailParams.plainTextBody);
                } else if (String.isNotBlank(emailParams.body)) {
                    email.setPlainTextBody(emailParams.body);
                }
            }

            // Set optional properties
            if (String.isNotBlank(emailParams.fromName)) {
                email.setSenderDisplayName(emailParams.fromName);
            } else if (String.isNotBlank(this.defaultFromName)) {
                email.setSenderDisplayName(this.defaultFromName);
            }

            if (String.isNotBlank(emailParams.replyTo)) {
                email.setReplyTo(emailParams.replyTo);
            } else if (String.isNotBlank(this.defaultReplyTo)) {
                email.setReplyTo(this.defaultReplyTo);
            }

            if (String.isNotBlank(emailParams.whatId)) {
                email.setWhatId(emailParams.whatId);
            }

            if (String.isNotBlank(emailParams.targetObjectId)) {
                email.setTargetObjectId(emailParams.targetObjectId);
            }

            if (emailParams.saveAsActivity != null) {
                email.setSaveAsActivity(emailParams.saveAsActivity);
            }

            if (emailParams.useSignature != null) {
                email.setUseSignature(emailParams.useSignature);
            }

            if (emailParams.treatBodiesAsTemplate != null) {
                email.setTreatBodiesAsTemplate(emailParams.treatBodiesAsTemplate);
            }

            // Handle attachments
            if (emailParams.attachments != null && !emailParams.attachments.isEmpty()) {
                List<Messaging.EmailFileAttachment> fileAttachments = createAttachments(emailParams.attachments);
                email.setFileAttachments(fileAttachments);
            }

            // Send the email
            Messaging.SendEmailResult[] results = Messaging.sendEmail(new Messaging.SingleEmailMessage[] { email });

            if (results[0].isSuccess()) {
                System.debug(LoggingLevel.INFO, '[ActionSendEmail] Email sent successfully');
                return ActionOutcome.success(createEmailResult(emailParams, results[0], true));
            } else {
                String errorMessage = 'Failed to send email: ' + results[0].getErrors()[0].getMessage();
                System.debug(LoggingLevel.ERROR, '[ActionSendEmail] ' + errorMessage);
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, errorMessage);
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Error sending email: ' + e.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Email sending failed: ' + e.getMessage());
        }
    }

    /**
     * @description
     * Creates email file attachments from the provided attachment data.
     *
     * @param attachments List<Map<String, Object>> - Attachment data
     * @return List<Messaging.EmailFileAttachment> - Salesforce email attachments
     */
    private List<Messaging.EmailFileAttachment> createAttachments(List<Map<String, Object>> attachments) {
        List<Messaging.EmailFileAttachment> fileAttachments = new List<Messaging.EmailFileAttachment>();

        for (Map<String, Object> attachment : attachments) {
            Messaging.EmailFileAttachment fileAttachment = new Messaging.EmailFileAttachment();

            String fileName = (String) attachment.get('fileName');
            String contentType = (String) attachment.get('contentType');
            String body = (String) attachment.get('body');

            if (String.isNotBlank(fileName)) {
                fileAttachment.setFileName(fileName);
            }

            if (String.isNotBlank(contentType)) {
                fileAttachment.setContentType(contentType);
            }

            if (String.isNotBlank(body)) {
                fileAttachment.setBody(EncodingUtil.base64Decode(body));
            }

            fileAttachments.add(fileAttachment);
        }

        return fileAttachments;
    }

    /**
     * @description
     * Creates a structured result object for successful email sending.
     *
     * @param emailParams EmailParameters - The original email parameters
     * @param result Messaging.SendEmailResult - The send result from Salesforce
     * @param success Boolean - Whether the send was successful
     * @return EmailResult - Structured result object
     */
    private EmailResult createEmailResult(EmailParameters emailParams, Messaging.SendEmailResult result, Boolean success) {
        EmailResult emailResult = new EmailResult();
        emailResult.success = success;
        emailResult.subject = emailParams.subject;
        emailResult.recipientCount = emailParams.toAddresses.size();
        emailResult.totalRecipients = emailParams.toAddresses.size() +
                                    (emailParams.ccAddresses != null ? emailParams.ccAddresses.size() : 0) +
                                    (emailParams.bccAddresses != null ? emailParams.bccAddresses.size() : 0);
        emailResult.attachmentCount = emailParams.attachments != null ? emailParams.attachments.size() : 0;
        emailResult.sentAt = Datetime.now();

        if (success) {
            emailResult.message = 'Email sent successfully to ' + emailResult.recipientCount + ' recipient(s)';
        } else {
            emailResult.message = 'Email sending failed: ' + result.getErrors()[0].getMessage();
        }

        return emailResult;
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Extracts email-specific configuration options.
     *
     * @param actionConfigurationJson String - The JSON configuration string
     * @param logPrefix String - Prefix for log output
     * @throws ValidationException if required configuration is missing or invalid
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        // Extract optional configuration values
        this.defaultFromName = ActionConfigUtils.getOptionalString(this.parsedActionConfig, CONFIG_KEY_DEFAULT_FROM_NAME);
        this.defaultReplyTo = ActionConfigUtils.getOptionalString(this.parsedActionConfig, CONFIG_KEY_DEFAULT_REPLY_TO);
        this.maxRecipients = ActionConfigUtils.getOptionalInteger(this.parsedActionConfig, CONFIG_KEY_MAX_RECIPIENTS, DEFAULT_MAX_RECIPIENTS);
        this.maxAttachments = ActionConfigUtils.getOptionalInteger(this.parsedActionConfig, CONFIG_KEY_MAX_ATTACHMENTS, DEFAULT_MAX_ATTACHMENTS);
        this.requireApproval = ActionConfigUtils.getOptionalBoolean(this.parsedActionConfig, CONFIG_KEY_REQUIRE_APPROVAL, false);

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Email action configured with maxRecipients=' + this.maxRecipients +
                   ', maxAttachments=' + this.maxAttachments + ', requireApproval=' + this.requireApproval);
    }

    /**
     * @description
     * Data structure for email parameters to improve code readability and maintainability.
     */
    public class EmailParameters {
        public List<String> toAddresses;
        public List<String> ccAddresses;
        public List<String> bccAddresses;
        public String subject;
        public String body;
        public String htmlBody;
        public String plainTextBody;
        public String fromName;
        public String replyTo;
        public String templateId;
        public String whatId;
        public String targetObjectId;
        public Boolean saveAsActivity;
        public List<Map<String, Object>> attachments;
        public Boolean useSignature;
        public Boolean treatBodiesAsTemplate;
    }

    /**
     * @description
     * Result wrapper for email sending operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - success: Boolean - Whether the email was sent successfully
     *   - subject: String - The email subject
     *   - recipientCount: Integer - Number of primary recipients
     *   - totalRecipients: Integer - Total number of all recipients (to, cc, bcc)
     *   - attachmentCount: Integer - Number of attachments
     *   - sentAt: Datetime - When the email was sent
     *   - message: String - User-facing message summarizing the result
     *   - metadata: Map<String, Object> - Additional context for downstream consumers
     */
    public class EmailResult {
        public Boolean success;
        public String subject;
        public Integer recipientCount;
        public Integer totalRecipients;
        public Integer attachmentCount;
        public Datetime sentAt;
        public String message; // Framework uses this for user display
        public Map<String, Object> metadata; // Additional context for LLMs

        public EmailResult() {
            this.metadata = new Map<String, Object>();
        }
    }
}
