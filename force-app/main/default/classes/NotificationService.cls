/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service to send custom platform notifications to users.
 */
public class NotificationService {
    private static final String NOTIFICATION_TYPE_API_NAME = 'AI_Agent_Action_Status';

    /**
     * @description Sends a custom notification to a specific user.
     * @param recipientId The ID of the User to receive the notification.
     * @param title The title of the notification.
     * @param body The main body/message of the notification.
     * @param targetId The ID of the record to navigate to when the notification is clicked (e.g., ChatSession__c ID).
     */
    public static void sendUserNotification(Id recipientId, String title, String body, Id targetId) {
        String logPrefix = '[NotificationService] ';
        if (recipientId == null || String.isBlank(title) || String.isBlank(body)) {
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
                return;
            }

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
        } catch (Exception e) {
        }
    }
}
