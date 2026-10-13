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

/**
 * The event stream is append-only. Retention-specific payload minimization is
 * performed by a separately authorized service and never permits deletion.
 */
trigger AgentEventImmutabilityTrigger on AgentEvent__c(before update, before delete) {
    if (Trigger.isDelete) {
        for (AgentEvent__c eventRecord : Trigger.old) {
            eventRecord.addError('Agent lifecycle events are immutable.');
        }
    } else {
        for (Integer index = 0; index < Trigger.new.size(); index++) {
            AgentEvent__c oldRecord = Trigger.old[index];
            AgentEvent__c newRecord = Trigger.new[index];
            Boolean authorizedRetentionTransition =
                PayloadRetentionPurgeService.isEventPurgeAuthorized() &&
                newRecord.Payload__c == null &&
                newRecord.PayloadPurgedAt__c != null &&
                oldRecord.PayloadHash__c == newRecord.PayloadHash__c &&
                oldRecord.OriginalPayloadLength__c == newRecord.OriginalPayloadLength__c &&
                oldRecord.PayloadProtectionMode__c == newRecord.PayloadProtectionMode__c &&
                oldRecord.Sequence__c == newRecord.Sequence__c &&
                oldRecord.EventType__c == newRecord.EventType__c &&
                oldRecord.AgentRun__c == newRecord.AgentRun__c;
            if (!authorizedRetentionTransition) {
                newRecord.addError('Agent lifecycle events are immutable.');
            }
        }
    }
}