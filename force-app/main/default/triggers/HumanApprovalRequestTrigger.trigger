/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-07-01.
 */

trigger HumanApprovalRequestTrigger on HumanApprovalRequest__c (after update) {
    HumanApprovalRequestTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
}