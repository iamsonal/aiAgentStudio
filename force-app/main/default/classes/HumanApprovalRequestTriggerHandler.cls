/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Trigger handler for HumanApprovalRequest__c.
 *              Monitors changes from the approval process to invoke the appropriate framework logic.
 */
public with sharing class HumanApprovalRequestTriggerHandler {
    /**
     * @description Handles the after-update event, typically fired by the Approval Process.
     * @param newRecords List of updated HumanApprovalRequest__c records from Trigger.new.
     * @param oldMap Map of old record versions from Trigger.oldMap.
     */
    public static void handleAfterUpdate(List<HumanApprovalRequest__c> newRecords, Map<Id, HumanApprovalRequest__c> oldMap) {
        List<Id> approvedRequestIds = new List<Id>();
        List<Id> rejectedRequestIds = new List<Id>();

        for (HumanApprovalRequest__c newRecord : newRecords) {
            HumanApprovalRequest__c oldRecord = oldMap.get(newRecord.Id);

            if (newRecord.ApprovalStatus__c != oldRecord.ApprovalStatus__c) {
                if (newRecord.ApprovalStatus__c == 'Approved') {
                    approvedRequestIds.add(newRecord.Id);
                } else if (newRecord.ApprovalStatus__c == 'Rejected') {
                    rejectedRequestIds.add(newRecord.Id);
                }
            }
        }

        if (!approvedRequestIds.isEmpty()) {
            ResumeApprovedFrameworkAction.resumeAction(approvedRequestIds);
        }

        if (!rejectedRequestIds.isEmpty()) {
            HandleRejectedFrameworkAction.handleRejection(rejectedRequestIds);
        }
    }
}
