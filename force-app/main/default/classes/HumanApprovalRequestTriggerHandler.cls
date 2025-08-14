/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * HumanApprovalRequestTriggerHandler is the trigger handler for the HumanApprovalRequest__c object.
 *
 * Responsibilities:
 *   - Monitors approval status changes (Approved/Rejected) on HumanApprovalRequest__c records
 *   - Orchestrates the correct framework response for both approved and rejected AI agent actions
 *   - Integrates with Salesforce approval processes to provide robust, auditable human-in-the-loop oversight
 *   - Delegates to framework services for resuming or rejecting agent actions as appropriate
 *
 * This handler ensures that all approval and rejection events are processed consistently and that user experience
 * and auditability are preserved across the AI agent workflow.
 */
public with sharing class HumanApprovalRequestTriggerHandler {
    /**
     * Handles the after-update event for HumanApprovalRequest__c records.
     *
     * - Detects approval status changes (Approved/Rejected) by comparing new and old values.
     * - Delegates to ResumeApprovedFrameworkAction or HandleRejectedFrameworkAction as appropriate.
     * - Logs all status transitions for traceability.
     *
     * @param newRecords  List of updated HumanApprovalRequest__c records from Trigger.new.
     * @param oldMap      Map of old record versions from Trigger.oldMap.
     * @sideeffect May invoke framework services that update records, send notifications, or log actions.
     */
    public static void handleAfterUpdate(List<HumanApprovalRequest__c> newRecords, Map<Id, HumanApprovalRequest__c> oldMap) {
        List<Id> approvedRequestIds = new List<Id>();
        List<Id> rejectedRequestIds = new List<Id>();

        for (HumanApprovalRequest__c newRecord : newRecords) {
            HumanApprovalRequest__c oldRecord = oldMap.get(newRecord.Id);
            // Only process records where approval status has changed
            if (newRecord.ApprovalStatus__c != oldRecord.ApprovalStatus__c) {
                if (newRecord.ApprovalStatus__c == 'Approved') {
                    System.debug(LoggingLevel.INFO, '[HARTrigger] Approval detected for HumanApprovalRequest__c: ' + newRecord.Id);
                    approvedRequestIds.add(newRecord.Id);
                } else if (newRecord.ApprovalStatus__c == 'Rejected') {
                    System.debug(LoggingLevel.INFO, '[HARTrigger] Rejection detected for HumanApprovalRequest__c: ' + newRecord.Id);
                    rejectedRequestIds.add(newRecord.Id);
                } else {
                    System.debug(
                        LoggingLevel.DEBUG,
                        '[HARTrigger] ApprovalStatus__c changed to unhandled value: ' + newRecord.ApprovalStatus__c + ' for record: ' + newRecord.Id
                    );
                }
            }
        }

        if (!approvedRequestIds.isEmpty()) {
            System.debug(
                LoggingLevel.INFO,
                '[HARTrigger] Invoking ResumeApprovedFrameworkAction for ' + approvedRequestIds.size() + ' approved request(s).'
            );
            ResumeApprovedFrameworkAction.resumeAction(approvedRequestIds);
        }
        if (!rejectedRequestIds.isEmpty()) {
            System.debug(
                LoggingLevel.INFO,
                '[HARTrigger] Invoking HandleRejectedFrameworkAction for ' + rejectedRequestIds.size() + ' rejected request(s).'
            );
            HandleRejectedFrameworkAction.handleRejection(rejectedRequestIds);
        }
    }
}
