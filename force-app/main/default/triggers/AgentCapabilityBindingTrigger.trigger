/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-04-14.
 */

trigger AgentCapabilityBindingTrigger on AgentCapabilityBinding__c(before insert, before update) {
    AgentCapabilityBindingTriggerHandler.handleTrigger(Trigger.new, Trigger.old, Trigger.operationType);
}