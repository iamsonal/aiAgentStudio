/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


trigger ContextGraphSourceTrigger on ContextGraphSource__c (before insert, before update) {
    ContextGraphSourceTriggerHandler.handleTrigger(Trigger.new, Trigger.old, Trigger.operationType);
}