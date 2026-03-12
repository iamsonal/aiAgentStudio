/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Trigger on AgentExecution__c to handle child execution completion.
 * When a child execution completes or fails, notifies the parent pipeline or orchestrator.
 */
trigger AgentExecutionTrigger on AgentExecution__c(after update) {
    if (Trigger.isAfter && Trigger.isUpdate) {
        AgentExecutionTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}
