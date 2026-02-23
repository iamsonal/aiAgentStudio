/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSendEmail sends outbound emails to one or more recipients using the native
 * Salesforce Messaging API. Supports two mutually exclusive composition modes:
 *
 *   1. Direct content  — LLM provides subject + HTML body inline.
 *   2. Template mode   — A Salesforce Email Template (classic or Lightning) is resolved by
 *                        DeveloperName or Id. Subject and body come from the template;
 *                        merge fields are populated via a target Contact/Lead/User record
 *                        and an optional related (What) record.
 *
 * Responsibilities:
 *   - Send HTML or plain-text emails to one or more recipients
 *   - Support optional CC and BCC recipients
 *   - Allow admins to pre-configure sender address, reply-to, and a default template
 *   - Validate all required arguments before attempting to send
 *   - Surface a structured result back to the LLM including recipient counts and tracking ID
 *
 * @ActionLabel Send Email
 * @ActionDescription Sends an outbound email via direct content or a Salesforce Email Template
 * @ActionHasVariants true
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionSendEmail extends BaseAgentAction {
    private static final Integer MAX_RECIPIENTS = 100;

    private ConfigDTO config;

    // =========================================================================
    // DTOs
    // =========================================================================

    /**
     * DTO for strongly-typed backend configuration (admin-controlled).
     */
    public class ConfigDTO {
        /**
         * @FieldSystem true
         * @FieldLabel Variant
         * @FieldType string
         * @FieldHelp Operating mode: "direct" (LLM supplies subject and body) or "template"
         * (a Salesforce Email Template supplies subject and body). Managed by the variant
         * picker UI, not surfaced as a standalone config field.
         */
        public String variant; // 'direct' | 'template'

        /**
         * @FieldLabel Sender Display Name
         * @FieldType string
         * @FieldHelp Display name shown as the email sender. Must be in "Name <email@example.com>"
         * format (e.g. "Support Team <support@acme.com>"). Only the name portion before the
         * angle brackets is applied; the actual From address is governed by org-wide email settings.
         */
        public String fromAddress;

        /**
         * @FieldLabel Reply-To Address
         * @FieldType string
         * @FieldHelp Optional reply-to email address applied to every email sent by this capability.
         */
        public String replyTo;

        /**
         * @FieldLabel Default Template Name
         * @FieldType string
         * @FieldHelp DeveloperName of the Salesforce Email Template to use when the LLM does not
         * supply a templateName argument. Only applicable in template variant.
         */
        public String defaultTemplateName;

        /**
         * @FieldLabel Default To Addresses
         * @FieldType array
         * @FieldHelp Fallback recipient email addresses used when the LLM does not supply any
         * toAddresses at runtime. If the LLM provides recipients, these defaults are ignored.
         */
        public List<String> defaultToAddresses;

        /**
         * @FieldLabel Always CC
         * @FieldType array
         * @FieldHelp Email addresses always included in CC on every email sent by this capability
         * (e.g. a compliance or audit mailbox). Merged with any CC addresses the LLM provides.
         */
        public List<String> defaultCcAddresses;

        /**
         * @FieldLabel Always BCC
         * @FieldType array
         * @FieldHelp Email addresses always included in BCC on every email sent by this capability.
         * Merged with any BCC addresses the LLM provides.
         */
        public List<String> defaultBccAddresses;

        /**
         * @FieldLabel Default Target Object ID
         * @FieldType string
         * @FieldHelp Fallback Contact, Lead, or User ID for template merge field resolution.
         * Supports $Context.RecordId to use the current record. Used when the LLM does not
         * provide a targetObjectId at runtime. Only applicable in template variant.
         */
        public String defaultTargetObjectId;

        /**
         * @FieldLabel Default Related Record ID
         * @FieldType string
         * @FieldHelp Salesforce record ID to associate the email activity with when saveAsActivity
         * is true. Supports $Context.RecordId to use the current record automatically. Used when
         * the LLM does not provide a whatObjectId at runtime.
         */
        public String defaultWhatObjectId;

        /**
         * @FieldLabel Save as Activity
         * @FieldType boolean
         * @FieldHelp When true, the sent email is logged as an email activity. Requires a related
         * record: set defaultWhatObjectId in config or provide whatObjectId as a parameter.
         * In template mode, the targetObjectId record is also used. Defaults to false.
         */
        public Boolean saveAsActivity;
    }

    /**
     * DTO for strongly-typed arguments provided by the LLM at runtime.
     *
     * Composition mode is determined by which fields are present:
     *   - Template mode : templateName OR templateId is provided
     *   - Direct mode   : subject AND body are provided (no template fields)
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel To Addresses
         * @FieldType array
         * @FieldRequired true
         * @FieldHelp List of recipient email addresses. At least one required.
         * Maximum 100 recipients total across To, CC, and BCC.
         */
        public List<String> toAddresses;

        /**
         * @FieldLabel Subject
         * @FieldType string
         * @FieldMaxLength 255
         * @FieldHelp Email subject line (required when not using a template).
         */
        public String subject;

        /**
         * @FieldLabel Body
         * @FieldType string
         * @FieldHelp Plain text email body (required in direct mode). For HTML-formatted emails,
         * use the template variant and a Salesforce Email Template instead.
         */
        public String body;

        /**
         * @FieldLabel CC Addresses
         * @FieldType array
         * @FieldHelp Optional list of CC recipient email addresses.
         */
        public List<String> ccAddresses;

        /**
         * @FieldLabel BCC Addresses
         * @FieldType array
         * @FieldHelp Optional list of BCC recipient email addresses.
         */
        public List<String> bccAddresses;

        /**
         * @FieldLabel Template Name
         * @FieldType string
         * @FieldHelp DeveloperName of the Salesforce Email Template to use. When provided,
         * the template supplies the subject and body; the "subject" and "body" arguments are ignored.
         * Overrides the defaultTemplateName backend configuration.
         */
        public String templateName;

        /**
         * @FieldLabel Target Object ID
         * @FieldType salesforce-id
         * @FieldHelp ID of a Contact, Lead, or User record used to resolve template merge fields.
         * Required when using a template.
         */
        public String targetObjectId;

        /**
         * @FieldLabel What Object ID
         * @FieldType salesforce-id
         * @FieldHelp Optional ID of a related record (e.g. Case, Opportunity) that provides
         * additional merge field data when using a template.
         */
        public String whatObjectId;
    }

    // =========================================================================
    // Entry point
    // =========================================================================

    /**
     * @description
     * Main entry point using Two-Pass Hybrid Deserialization.
     * Determines composition mode (direct vs. template), validates arguments,
     * builds and sends the email, and returns a structured result.
     *
     * @param params Map<String, Object> - Raw parameters deserialized from LLM arguments JSON
     * @return ActionOutcome<EmailSendResult> - Structured result with recipient counts and tracking ID
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        try {
            config = parseConfig();

            // Two-Pass Hybrid Deserialization: manually populate DTO from untyped map
            ArgumentsDTO args = new ArgumentsDTO();
            args.subject = ActionConfigUtils.getOptionalString(params, 'subject');
            args.body = ActionConfigUtils.getOptionalString(params, 'body');
            args.toAddresses = ActionConfigUtils.getOptionalStringList(params, 'toAddresses');
            args.ccAddresses = ActionConfigUtils.getOptionalStringList(params, 'ccAddresses');
            args.bccAddresses = ActionConfigUtils.getOptionalStringList(params, 'bccAddresses');
            args.templateName = ActionConfigUtils.getOptionalString(params, 'templateName');
            args.targetObjectId = ActionConfigUtils.getOptionalString(params, 'targetObjectId');
            args.whatObjectId = ActionConfigUtils.getOptionalString(params, 'whatObjectId');

            // Accept singular toAddress shorthand
            if (args.toAddresses.isEmpty()) {
                String singleTo = ActionConfigUtils.getOptionalString(params, 'toAddress');
                if (String.isNotBlank(singleTo)) {
                    args.toAddresses.add(singleTo);
                }
            }

            // Determine operating mode from the admin-configured variant
            Boolean usingTemplate = 'template'.equals(config.variant);

            // --- Apply backend defaults ---
            // toAddresses: config is a fallback only; LLM-provided values take full precedence
            if (args.toAddresses.isEmpty() && config.defaultToAddresses != null && !config.defaultToAddresses.isEmpty()) {
                args.toAddresses = new List<String>(config.defaultToAddresses);
            }

            // CC/BCC: always merge config policy addresses with LLM-provided ones (deduplicated)
            args.ccAddresses = mergeAddresses(config.defaultCcAddresses, args.ccAddresses);
            args.bccAddresses = mergeAddresses(config.defaultBccAddresses, args.bccAddresses);

            // whatObjectId: config default applies to both modes when LLM provides none
            if (String.isBlank(args.whatObjectId) && String.isNotBlank(config.defaultWhatObjectId)) {
                args.whatObjectId = config.defaultWhatObjectId;
            }

            // targetObjectId: config default applies in template mode when LLM provides none
            if (usingTemplate && String.isBlank(args.targetObjectId) && String.isNotBlank(config.defaultTargetObjectId)) {
                args.targetObjectId = config.defaultTargetObjectId;
            }

            // templateName: apply config default when LLM omits it
            if (usingTemplate && String.isBlank(args.templateName) && String.isNotBlank(config.defaultTemplateName)) {
                args.templateName = config.defaultTemplateName;
            }

            // --- Recipient validation (common to both modes) ---
            if (args.toAddresses.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'At least one recipient in "toAddresses" is required');
            }

            Integer totalRecipients = args.toAddresses.size() + args.ccAddresses.size() + args.bccAddresses.size();
            if (totalRecipients > MAX_RECIPIENTS) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Total recipient count (' + totalRecipients + ') exceeds the maximum of ' + MAX_RECIPIENTS
                );
            }

            // --- Mode-specific validation ---
            if (usingTemplate) {
                if (String.isBlank(args.targetObjectId)) {
                    return ActionOutcome.failure(
                        AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                        '"targetObjectId" (a Contact, Lead, or User ID) is required when using an email template'
                    );
                }
            } else {
                if (String.isBlank(args.subject)) {
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, '"subject" is required in direct mode');
                }
                if (args.subject.length() > 255) {
                    return ActionOutcome.failure(
                        AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                        '"subject" must not exceed 255 characters (current length: ' + args.subject.length() + ')'
                    );
                }
                if (String.isBlank(args.body)) {
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, '"body" is required in direct mode');
                }
            }

            System.debug(
                LoggingLevel.INFO,
                '[ActionSendEmail] Mode: ' +
                    (usingTemplate ? 'template (' + args.templateName + ')' : 'direct') +
                    '. Sending to ' +
                    args.toAddresses.size() +
                    ' recipient(s)'
            );

            ActionOutcome sendResult = buildAndSend(args, usingTemplate);
            if (!sendResult.isSuccess) {
                return sendResult;
            }

            String trackingId = (String) sendResult.data;
            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, '[ActionSendEmail] Email sent in ' + executionTime + ' ms. Tracking ID: ' + trackingId);

            return ActionOutcome.success(
                new EmailSendResult(
                    args.toAddresses.size(),
                    args.ccAddresses.size(),
                    args.bccAddresses.size(),
                    usingTemplate ? args.templateName : args.subject,
                    usingTemplate,
                    trackingId
                )
            );
        } catch (ActionConfigUtils.ArgumentValidationException ave) {
            System.debug(LoggingLevel.WARN, '[ActionSendEmail] Argument validation failed: ' + ave.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ave.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Unexpected error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Stack trace: ' + e.getStackTraceString());
            return ActionOutcome.fromException(e);
        }
    }

    // =========================================================================
    // Config parsing
    // =========================================================================

    /**
     * @description Parses the backend configuration into a ConfigDTO.
     * All fields are optional; safe defaults are applied when absent.
     */
    private ConfigDTO parseConfig() {
        ConfigDTO cfg = new ConfigDTO();
        cfg.saveAsActivity = false;

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            return cfg;
        }

        try {
            cfg.variant = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'variant');
            cfg.fromAddress = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'fromAddress');
            cfg.replyTo = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'replyTo');
            cfg.defaultTemplateName = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'defaultTemplateName');
            cfg.defaultToAddresses = ActionConfigUtils.getOptionalStringList(this.parsedActionConfig, 'defaultToAddresses');
            cfg.defaultCcAddresses = ActionConfigUtils.getOptionalStringList(this.parsedActionConfig, 'defaultCcAddresses');
            cfg.defaultBccAddresses = ActionConfigUtils.getOptionalStringList(this.parsedActionConfig, 'defaultBccAddresses');
            cfg.defaultTargetObjectId = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'defaultTargetObjectId');
            cfg.defaultWhatObjectId = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'defaultWhatObjectId');
            cfg.saveAsActivity = ActionConfigUtils.getOptionalBoolean(this.parsedActionConfig, 'saveAsActivity', false);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ActionSendEmail] Failed to parse backend config: ' + e.getMessage());
        }

        return cfg;
    }

    // =========================================================================
    // Email construction and sending
    // =========================================================================

    /**
     * @description
     * Constructs a Messaging.SingleEmailMessage in the appropriate mode and sends it.
     * Marks the transaction as unsafe since email delivery is a non-retryable side effect.
     *
     * @param args          Validated runtime arguments
     * @param usingTemplate True when template mode is active
     * @return ActionOutcome whose data is a UUID tracking ID string on success
     */
    private ActionOutcome buildAndSend(ArgumentsDTO args, Boolean usingTemplate) {
        try {
            Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();

            // Common fields
            email.setToAddresses(args.toAddresses);
            email.setSaveAsActivity(config.saveAsActivity);

            if (!args.ccAddresses.isEmpty()) {
                email.setCcAddresses(args.ccAddresses);
            }
            if (!args.bccAddresses.isEmpty()) {
                email.setBccAddresses(args.bccAddresses);
            }
            if (String.isNotBlank(config.fromAddress)) {
                applyDisplayName(email, config.fromAddress);
            }
            if (String.isNotBlank(config.replyTo)) {
                email.setReplyTo(config.replyTo);
            }

            // Mode-specific fields
            if (usingTemplate) {
                ActionOutcome templateResult = applyTemplate(email, args);
                if (!templateResult.isSuccess) {
                    return templateResult;
                }
            } else {
                email.setSubject(args.subject);
                email.setPlainTextBody(args.body);

                // Associate with a related record so saveAsActivity logs on that record
                if (String.isNotBlank(args.whatObjectId)) {
                    try {
                        email.setWhatId(Id.valueOf(args.whatObjectId));
                    } catch (System.StringException se) {
                        return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid "whatObjectId" format: ' + args.whatObjectId);
                    }
                }
            }

            TransactionContext.getInstance().markUnsafeOperation('Email sent via ActionSendEmail');

            List<Messaging.SendEmailResult> results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });

            Messaging.SendEmailResult sendResult = results[0];
            if (!sendResult.isSuccess()) {
                List<String> errors = new List<String>();
                for (Messaging.SendEmailError err : sendResult.getErrors()) {
                    errors.add(err.getMessage());
                }
                String errorMsg = String.join(errors, '; ');
                System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Send failed: ' + errorMsg);
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, 'Email delivery failed: ' + errorMsg);
            }

            return ActionOutcome.success(generateTrackingId());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendEmail] Unexpected error during send: ' + e.getMessage());
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description
     * Resolves the Email Template by DeveloperName, then applies the template ID,
     * targetObjectId, and optional whatObjectId to the email message.
     * When a template is used, subject and body are NOT set — the template owns them.
     *
     * @param email The email message to configure
     * @param args  Runtime arguments containing templateName, targetObjectId, whatObjectId
     * @return ActionOutcome indicating success, or CONFIG_ERROR if the template is not found
     */
    private ActionOutcome applyTemplate(Messaging.SingleEmailMessage email, ArgumentsDTO args) {
        // Guard: templateName must be set by this point (either LLM-provided or config default)
        if (String.isBlank(args.templateName)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'No email template configured. Either set "defaultTemplateName" in the capability\'s backend configuration, or instruct the LLM to supply a "templateName" argument at runtime.'
            );
        }

        // Resolve template Id from DeveloperName
        List<EmailTemplate> templates = [
            SELECT Id, Name
            FROM EmailTemplate
            WHERE DeveloperName = :args.templateName
            WITH USER_MODE
            LIMIT 1
        ];

        if (templates.isEmpty()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Email template not found: "' + args.templateName + '". Verify the DeveloperName is correct and the template is active.'
            );
        }

        email.setTemplateId(templates[0].Id);

        // targetObjectId is mandatory for Salesforce template merge (Contact, Lead, or User)
        try {
            email.setTargetObjectId(Id.valueOf(args.targetObjectId));
        } catch (System.StringException se) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid "targetObjectId" format: ' + args.targetObjectId);
        }

        // whatObjectId provides merge fields from a related record (e.g. Case, Opportunity)
        if (String.isNotBlank(args.whatObjectId)) {
            try {
                email.setWhatId(Id.valueOf(args.whatObjectId));
            } catch (System.StringException se) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid "whatObjectId" format: ' + args.whatObjectId);
            }
        }

        System.debug(
            LoggingLevel.DEBUG,
            '[ActionSendEmail] Template "' +
                args.templateName +
                '" (Id: ' +
                templates[0].Id +
                ') applied. ' +
                'Target: ' +
                args.targetObjectId +
                (String.isNotBlank(args.whatObjectId) ? ', What: ' + args.whatObjectId : '')
        );

        return ActionOutcome.success();
    }

    /**
     * @description
     * Merges two address lists, deduplicating case-insensitively.
     * Admin-configured policy addresses (base) come first; runtime addresses are appended.
     * Either list may be null or empty.
     *
     * @param base    Admin-configured addresses (e.g. compliance BCC from config defaults)
     * @param runtime LLM-provided addresses for this specific email
     * @return        Merged, deduplicated list
     */
    @TestVisible
    private List<String> mergeAddresses(List<String> base, List<String> runtime) {
        Set<String> seen = new Set<String>();
        List<String> merged = new List<String>();

        for (String addr : (base != null ? base : new List<String>())) {
            String lower = addr.toLowerCase();
            if (seen.add(lower)) {
                merged.add(addr);
            }
        }
        for (String addr : (runtime != null ? runtime : new List<String>())) {
            String lower = addr.toLowerCase();
            if (seen.add(lower)) {
                merged.add(addr);
            }
        }

        return merged;
    }

    /**
     * @description
     * Extracts the display name from a "Name <email>" formatted string and sets it
     * as the sender display name on the email. Only the display name portion is applied
     * because Salesforce governs the actual From address via org-wide email settings.
     *
     * @param email        The email message to configure
     * @param senderString Raw sender string from backend config — must be in "Name <email>" format
     */
    private void applyDisplayName(Messaging.SingleEmailMessage email, String senderString) {
        String trimmed = senderString.trim();
        if (trimmed.contains('<') && trimmed.contains('>')) {
            String displayName = trimmed.substring(0, trimmed.indexOf('<')).trim();
            if (String.isNotBlank(displayName)) {
                email.setSenderDisplayName(displayName);
            }
        }
    }

    /**
     * @description Generates a UUID-like tracking identifier for the sent email.
     * @return Hex-encoded UUID string in 8-4-4-4-12 format
     */
    private String generateTrackingId() {
        String hex = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        return hex.substring(0, 8) + '-' + hex.substring(8, 12) + '-' + hex.substring(12, 16) + '-' + hex.substring(16, 20) + '-' + hex.substring(20);
    }

    // =========================================================================
    // Result wrapper
    // =========================================================================

    /**
     * @description Result wrapper returned to the LLM after a successful email send.
     */
    public class EmailSendResult {
        @AuraEnabled
        public Integer toCount;
        @AuraEnabled
        public Integer ccCount;
        @AuraEnabled
        public Integer bccCount;
        @AuraEnabled
        public String subjectOrTemplate;
        @AuraEnabled
        public Boolean templateUsed;
        @AuraEnabled
        public String trackingId;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Map<String, Object> metadata;

        public EmailSendResult(Integer toCount, Integer ccCount, Integer bccCount, String subjectOrTemplate, Boolean templateUsed, String trackingId) {
            this.toCount = toCount;
            this.ccCount = ccCount;
            this.bccCount = bccCount;
            this.subjectOrTemplate = subjectOrTemplate;
            this.templateUsed = templateUsed;
            this.trackingId = trackingId;

            Integer total = toCount + ccCount + bccCount;
            this.message =
                'Email sent successfully to ' +
                total +
                ' recipient(s)' +
                (templateUsed ? ' using template "' + subjectOrTemplate + '"' : ' with subject "' + subjectOrTemplate + '"');

            this.metadata = new Map<String, Object>{
                'toCount' => toCount,
                'ccCount' => ccCount,
                'bccCount' => bccCount,
                'totalRecipients' => total,
                'templateUsed' => templateUsed,
                'trackingId' => trackingId,
                'sentAt' => System.now(),
                'success' => true
            };
        }
    }
}
