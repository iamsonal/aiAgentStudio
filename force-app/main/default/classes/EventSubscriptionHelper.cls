/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides secure, cacheable access to the current user's session ID for use in LWC platform event subscriptions.
 */
public with sharing class EventSubscriptionHelper {
    @AuraEnabled(Cacheable=true)
    public static String fetchSessionId() {
        try {
            return UserInfo.getSessionId();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[EventSubscriptionHelper] Exception in fetchSessionId: ' + e.getTypeName() + ': ' + e.getMessage());
            throw new AuraHandledException('Unable to retrieve session ID. Please contact your administrator.');
        }
    }
}
