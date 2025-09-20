/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * EventSubscriptionHelper provides secure, cacheable access to the current user's session ID for use in Lightning Web Component (LWC)
 * platform event subscriptions. This utility is designed for use by client-side code that requires authenticated session context
 * to establish or maintain event subscriptions, and encapsulates error handling for robust integration.
 *
 * Responsibilities:
 *   - Expose a static, cacheable method for retrieving the current session ID
 *   - Handle and report errors in a way suitable for Aura/LWC consumption
 *   - Ensure all output and documentation is clear, concise, and maintainable
 */
public with sharing class EventSubscriptionHelper {
    /**
     * Returns the current user's session ID for use in LWC platform event subscriptions.
     *
     * This method is marked cacheable for performance, and is intended for use by client-side code that needs
     * to establish or maintain authenticated event subscriptions. If session ID retrieval fails, an AuraHandledException
     * is thrown with a clear error message for UI consumption.
     *
     * @return  The current session ID as a String.
     * @throws  AuraHandledException if session ID retrieval fails for any reason.
     * @sideeffects  Writes to debug logs on error.
     */
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