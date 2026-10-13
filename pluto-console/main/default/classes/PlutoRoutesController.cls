/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/** Read-only notification service choices from the optional HITL catalog. No static HITL dependency. */
public with sharing class PlutoRoutesController {
    public class ServiceOption {
        @AuraEnabled
        public String value { get; set; }
        @AuraEnabled
        public String label { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<ServiceOption> getNotificationServiceOptions() {
        List<ServiceOption> options = new List<ServiceOption>();
        Schema.SObjectType catalog = Schema.getGlobalDescribe().get('AgentNotificationService__mdt');
        if (catalog == null || !catalog.getDescribe().isAccessible())
            return options;
        for (
            SObject service : Database.queryWithBinds(
                'SELECT DeveloperName, MasterLabel FROM AgentNotificationService__mdt ORDER BY MasterLabel LIMIT 500',
                new Map<String, Object>(),
                AccessLevel.USER_MODE
            )
        ) {
            ServiceOption option = new ServiceOption();
            option.value = (String) service.get('DeveloperName');
            option.label = (String) service.get('MasterLabel') + ' (' + option.value + ')';
            options.add(option);
        }
        return options;
    }
}
