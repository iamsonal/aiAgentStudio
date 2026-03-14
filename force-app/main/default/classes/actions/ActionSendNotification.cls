/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSendNotification sends in-app notifications (bell icon alerts) to Salesforce users.
 * Provides a way for AI agents to deliver asynchronous feedback and draw user attention
 * to specific records or events.
 *
 * Responsibilities:
 *   - Send custom notifications to users
 *   - Support both standard and custom notification types
 *   - Link notifications to specific records
 *   - Validate notification targets and permissions
 *   - Handle both single and bulk notification sending
 *
 * @ActionLabel Send Notification
 * @ActionDescription Sends in-app notifications (bell icon alerts) to Salesforce users
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionSendNotification extends BaseAgentAction {
    private static final Integer MAX_RECIPIENTS = 100;

    private ConfigDTO config;

    /**
     * DTO for strongly-typed backend configuration.
     * Allows admins to pre-configure notification settings.
     */
    public class ConfigDTO {
        /**
         * @FieldLabel Default Notification Type
         * @FieldType string
         * @FieldHelp The DeveloperName of the CustomNotificationType to use by default.
         * Can be overridden by the LLM at runtime via notificationTypeName argument.
         */
        public String notificationTypeName;

        /**
         * @FieldLabel Default Target ID
         * @FieldType salesforce-id
         * @FieldHelp Optional default record ID to link notifications to if not specified at runtime.
         */
        public String defaultTargetId;
    }

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Recipient IDs
         * @FieldType array
         * @FieldRequired true
         * @FieldHelp List of User IDs to send notifications to
         */
        public List<String> recipientIds;

        /**
         * @FieldLabel Title
         * @FieldType string
         * @FieldRequired true
         * @FieldMaxLength 255
         * @FieldHelp Notification title
         */
        public String title;

        /**
         * @FieldLabel Body
         * @FieldType string
         * @FieldRequired true
         * @FieldMaxLength 5000
         * @FieldHelp Notification body/message text
         */
        public String body;

        /**
         * @FieldLabel Target ID
         * @FieldType salesforce-id
         * @FieldHelp Optional: Record ID to link the notification to
         */
        public String targetId;
    }

    /**
     * @description
     * Main entry point for sending notifications using Two-Pass Hybrid Deserialization.
     * Creates and sends in-app notifications to specified recipients.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<NotificationResult> - Contains notification sending results
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        try {
            // Parse backend configuration
            config = parseConfig();

            // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
            ArgumentsDTO args = new ArgumentsDTO();
            args.title = ActionConfigUtils.getRequiredString(params, 'title');
            args.body = ActionConfigUtils.getRequiredString(params, 'body');
            args.targetId = ActionConfigUtils.getOptionalString(params, 'targetId');

            // Recipients can be a single user ID or a list of user IDs
            args.recipientIds = new List<String>();
            Object recipientsParam = params.get('recipientIds');

            if (recipientsParam == null) {
                // Try singular form
                String recipientId = ActionConfigUtils.getOptionalString(params, 'recipientId');
                if (String.isNotBlank(recipientId)) {
                    args.recipientIds.add(recipientId);
                } else {
                    // Default to current user if no recipient specified
                    args.recipientIds.add(UserInfo.getUserId());
                }
            } else if (recipientsParam instanceof String) {
                args.recipientIds.add((String) recipientsParam);
            } else if (recipientsParam instanceof List<Object>) {
                List<Object> recipientsList = (List<Object>) recipientsParam;
                for (Object recipient : recipientsList) {
                    if (recipient instanceof String) {
                        args.recipientIds.add((String) recipient);
                    }
                }
            }

            // Validate required DTO parameters
            if (args.recipientIds.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'At least one recipient is required');
            }

            if (args.recipientIds.size() > MAX_RECIPIENTS) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Maximum ' + MAX_RECIPIENTS + ' recipients allowed per notification. Provided: ' + args.recipientIds.size()
                );
            }

            // Validate title and body length
            if (args.title.length() > 255) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Notification title cannot exceed 255 characters');
            }

            if (args.body.length() > 5000) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Notification body cannot exceed 5000 characters');
            }

            System.debug(LoggingLevel.INFO, '[ActionSendNotification] Sending notification to ' + args.recipientIds.size() + ' recipient(s)');

            // Resolve notification type from config (admin-controlled)
            Id notificationTypeId = null;
            if (String.isNotBlank(config.notificationTypeName)) {
                notificationTypeId = resolveNotificationTypeByName(config.notificationTypeName);
                if (notificationTypeId == null) {
                    System.debug(
                        LoggingLevel.WARN,
                        '[ActionSendNotification] Notification type "' + config.notificationTypeName + '" not found, using default'
                    );
                }
            }

            // Resolve target ID: runtime arg > config default
            String effectiveTargetId = String.isNotBlank(args.targetId) ? args.targetId : config.defaultTargetId;

            // Validate target record if specified
            Id validatedTargetId = null;
            if (String.isNotBlank(effectiveTargetId)) {
                ActionOutcome targetValidation = validateTargetRecord(effectiveTargetId);
                if (!targetValidation.isSuccess) {
                    return targetValidation;
                }
                validatedTargetId = (Id) targetValidation.data;
            }

            // Send notification
            ActionOutcome sendResult = sendNotifications(args.recipientIds, args.title, args.body, validatedTargetId, notificationTypeId);

            if (!sendResult.isSuccess) {
                return sendResult;
            }

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, '[ActionSendNotification] Notification sent successfully in ' + executionTime + ' ms');

            NotificationResult result = new NotificationResult(
                args.recipientIds.size(),
                args.title,
                String.valueOf(validatedTargetId),
                'Notification sent successfully to ' + args.recipientIds.size() + ' user(s)'
            );

            return ActionOutcome.success(result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendNotification] Unexpected error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[ActionSendNotification] Stack trace: ' + e.getStackTraceString());
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description
     * Parses the backend configuration into a ConfigDTO object.
     *
     * @return ConfigDTO with default settings, or empty ConfigDTO if no config
     */
    private ConfigDTO parseConfig() {
        ConfigDTO cfg = new ConfigDTO();

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            return cfg;
        }

        try {
            cfg.notificationTypeName = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'notificationTypeName');
            cfg.defaultTargetId = ActionConfigUtils.getOptionalString(this.parsedActionConfig, 'defaultTargetId');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ActionSendNotification] Failed to parse backend config: ' + e.getMessage());
        }

        return cfg;
    }

    /**
     * @description
     * Resolves a CustomNotificationType by its DeveloperName.
     *
     * @param typeName The notification type's DeveloperName
     * @return The notification type's Id, or null if not found
     */
    private Id resolveNotificationTypeByName(String typeName) {
        try {
            List<CustomNotificationType> types = [
                SELECT Id, DeveloperName
                FROM CustomNotificationType
                WHERE DeveloperName = :typeName
                WITH USER_MODE
                LIMIT 1
            ];

            return types.isEmpty() ? null : types[0].Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ActionSendNotification] Error resolving notification type: ' + e.getMessage());
            return null;
        }
    }

    /**
     * @description
     * Validates that the target record exists and the user has access to it.
     * objectApiName is derived exclusively from Schema.SObjectType.getDescribe() and is not
     * user-controlled input, making the dynamic SOQL safe from injection.
     *
     * @param targetId The record ID to validate
     * @return ActionOutcome containing validated Id or error
     */
    @SuppressWarnings('PMD.ApexSOQLInjection')
    private ActionOutcome validateTargetRecord(String targetId) {
        try {
            Id recordId = Id.valueOf(targetId);

            // Try to query the record to validate access
            // We use a generic approach with SObject
            SObjectType objectType = recordId.getSObjectType();
            String objectApiName = objectType.getDescribe().getName();

            String query = 'SELECT Id FROM ' + objectApiName + ' WHERE Id = :recordId WITH USER_MODE LIMIT 1';
            List<SObject> records = Database.query(query);

            if (records.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Target record not found: ' + targetId);
            }

            return ActionOutcome.success(recordId);
        } catch (System.StringException se) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid target record ID format: ' + targetId);
        } catch (System.QueryException qe) {
            String message = qe.getMessage().toLowerCase();
            if (message.contains('insufficient access') || message.contains('security')) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, 'You do not have permission to access the target record');
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to validate target record: ' + qe.getMessage());
        }
    }

    /**
     * @description
     * Sends notifications to the specified recipients using the Messaging.CustomNotification API.
     *
     * @param recipientIds List of user IDs to send notifications to
     * @param title Notification title
     * @param body Notification body
     * @param targetId Optional target record ID
     * @param notificationTypeId Optional custom notification type ID
     * @return ActionOutcome indicating success or failure
     */
    private ActionOutcome sendNotifications(List<String> recipientIds, String title, String body, Id targetId, Id notificationTypeId) {
        try {
            // Create custom notification
            Messaging.CustomNotification notification = new Messaging.CustomNotification();

            // Set notification type
            if (notificationTypeId != null) {
                notification.setNotificationTypeId(notificationTypeId);
            } else {
                // If no custom type specified, try to find a default one
                List<CustomNotificationType> defaultTypes = [
                    SELECT Id
                    FROM CustomNotificationType
                    WITH USER_MODE
                    LIMIT 1
                ];

                if (defaultTypes.isEmpty()) {
                    return ActionOutcome.failure(
                        AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                        'No CustomNotificationType found. Please create a custom notification type in Setup.'
                    );
                }
                notification.setNotificationTypeId(defaultTypes[0].Id);
            }

            // Set notification content
            notification.setTitle(title);
            notification.setBody(body);

            // Set target record if provided
            if (targetId != null) {
                notification.setTargetId(targetId);
            }

            // Send to recipients
            TransactionContext.getInstance().markUnsafeOperation('Custom notification sent');
            notification.send(new Set<String>(recipientIds));

            return ActionOutcome.success();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionSendNotification] Unexpected error sending notification: ' + e.getMessage());
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description
     * Result wrapper for notification sending operations.
     */
    public class NotificationResult {
        @AuraEnabled
        public Integer recipientCount;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String targetId;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Map<String, Object> metadata;

        public NotificationResult(Integer recipientCount, String title, String targetId, String message) {
            this.recipientCount = recipientCount;
            this.title = title;
            this.targetId = targetId;
            this.message = message;
            this.metadata = new Map<String, Object>{ 'recipientCount' => recipientCount, 'sentAt' => System.now(), 'success' => true };
        }
    }
}
