/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

public with sharing class EventSubscriptionHelper {
    @AuraEnabled(Cacheable=true)
    public static String fetchSessionId() {
        try {
            return UserInfo.getSessionId();
        } catch (Exception e) {
            throw new AuraHandledException('Failed to fetch session ID: ' + e.getMessage());
        }
    }
}
