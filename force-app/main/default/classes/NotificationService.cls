/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * NotificationService provides a focused API for sending custom platform notifications to Salesforce users.
 * It encapsulates integration with the Custom Notification framework, handling notification type lookup, message construction,
 * and delivery. The service ensures robust error handling, clear debug output, and graceful handling of missing configuration
 * or delivery failures. Its scope is limited to user-targeted notifications with optional record navigation, and it is designed
 * for easy extension to support additional notification types or delivery strategies in the future.
 */
public class NotificationService {
    private static final String NOTIFICATION_TYPE_API_NAME = 'AI_Agent_Action_Status';

    /**
     * Sends a custom notification to a specific user.
     *
     * Looks up the configured notification type, constructs the notification payload, and attempts delivery to the specified user.
     * If required parameters are missing or the notification type is not found, the method logs a warning or error and exits gracefully.
     *
     * @param recipientId The ID of the User to receive the notification. (Required)
     * @param title       The title of the notification. (Required)
     * @param body        The main body/message of the notification. (Required)
     * @param targetId    The ID of the record to navigate to when the notification is clicked (optional, e.g., AgentExecution__c ID).
     *
     * @throws None. All errors are handled internally and surfaced via debug logs.
     *
     * Side effects: Emits debug logs for parameter validation, notification type lookup, delivery success, and error conditions.
     */
    public static void sendUserNotification(Id recipientId, String title, String body, Id targetId) {
        String logPrefix = '[NotificationService] ';

        if (recipientId == null || String.isBlank(title) || String.isBlank(body)) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Notification not sent: missing required parameter(s) (recipientId, title, or body).');
            return;
        }

        try {
            // Lookup the custom notification type by API name. Fail gracefully if not found.
            List<CustomNotificationType> notificationTypes = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = :NOTIFICATION_TYPE_API_NAME
                LIMIT 1
            ];
            if (notificationTypes.isEmpty()) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Notification not sent: Custom notification type not found (' + NOTIFICATION_TYPE_API_NAME + ').');
                return;
            }

            // Construct and send the notification.
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle(title);
            notification.setBody(body);
            notification.setSenderId(UserInfo.getUserId());
            notification.setNotificationTypeId(notificationTypes[0].Id);
            if (targetId != null) {
                notification.setTargetId(targetId);
            }
            Set<String> recipients = new Set<String>{ recipientId };
            notification.send(recipients);
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Notification sent to user ' + recipientId + ' (type: ' + NOTIFICATION_TYPE_API_NAME + ', title: "' + title + '").'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Notification delivery failed for user ' + recipientId + ': ' + e.getMessage());
        }
    }
}
