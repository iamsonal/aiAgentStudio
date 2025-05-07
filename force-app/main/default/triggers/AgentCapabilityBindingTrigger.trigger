/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


trigger AgentCapabilityBindingTrigger on AgentCapabilityBinding__c(before insert, before update) {
    AgentCapabilityBindingTriggerHandler.handleTrigger(Trigger.new, Trigger.old, Trigger.operationType);
}
