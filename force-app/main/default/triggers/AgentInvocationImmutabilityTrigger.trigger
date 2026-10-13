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
 * Invocation evidence is immutable except for authorized removal of retained
 * payload text after its retention period. Hashes and metadata remain intact.
 */
trigger AgentInvocationImmutabilityTrigger on AgentInvocation__c(before update, before delete) {
    if (Trigger.isDelete) {
        if (PayloadRetentionPurgeService.isRecordDeletionAuthorized()) {
            return;
        }
        for (AgentInvocation__c invocation : Trigger.old) {
            invocation.addError('Agent invocation evidence is immutable.');
        }
    } else {
        for (Integer index = 0; index < Trigger.new.size(); index++) {
            if (!InvocationEvidenceService.isAuthorizedPurgeTransition(Trigger.old[index], Trigger.new[index])) {
                Trigger.new[index].addError('Agent invocation evidence is immutable.');
            }
        }
    }
}