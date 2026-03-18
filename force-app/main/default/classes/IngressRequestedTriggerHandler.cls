/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Processes staged ingress requests delivered through Platform Event
 * so runtime work happens under the configured subscriber user context.
 */
public inherited sharing class IngressRequestedTriggerHandler {
    public static void handle(List<IngressRequested__e> events) {
        List<Id> ingressEventIds = new List<Id>();
        if (events != null) {
            for (IngressRequested__e eventRecord : events) {
                if (eventRecord == null || String.isBlank(eventRecord.IngressEventId__c)) {
                    continue;
                }
                try {
                    ingressEventIds.add(Id.valueOf(eventRecord.IngressEventId__c));
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, '[IngressRequestedTriggerHandler] Skipping invalid ingress event Id: ' + eventRecord.IngressEventId__c);
                }
            }
        }
        if (!ingressEventIds.isEmpty()) {
            new IngressProcessingService().processStagedEvents(ingressEventIds, '[IngressRequestedTrigger] ');
        }
    }
}
