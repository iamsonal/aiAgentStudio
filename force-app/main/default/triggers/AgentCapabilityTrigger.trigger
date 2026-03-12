/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

trigger AgentCapabilityTrigger on AgentCapability__c(
    before insert, before update,
    after insert, after update, after delete, after undelete
) {
    if (Trigger.isBefore) {
        AgentCapabilityTriggerHandler.handleTrigger(Trigger.new, Trigger.oldMap);
    }
    if (Trigger.isAfter) {
        AgentCapabilityTriggerHandler.handleAfterTrigger(
            Trigger.new, Trigger.old, Trigger.operationType
        );
    }
}
