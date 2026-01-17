/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides API for sending custom platform notifications to Salesforce users. Handles notification type lookup, message construction, and delivery.
 */
public class NotificationService {
    private static final String NOTIFICATION_TYPE_API_NAME = 'AI_Agent_Action_Status';
    public static void sendUserNotification(Id recipientId, String title, String body, Id targetId) {
        String logPrefix = '[NotificationService] ';

        if (recipientId == null || String.isBlank(title) || String.isBlank(body)) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Notification not sent: missing required parameter(s) (recipientId, title, or body).');
            return;
        }

        try {
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
