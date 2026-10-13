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

trigger AgentRunIdentityGuard on AgentRun__c(before update, before delete) {
    if (Trigger.isDelete) {
        for (AgentRun__c run : Trigger.old) {
            if (!PayloadRetentionPurgeService.isRecordDeletionAuthorized() || run.PayloadPurgedAt__c == null || run.CompletedAt__c == null) {
                run.addError('Agent runs are deleted only by the record retention job after payload purge.');
            }
        }
        return;
    }
    AgentIdentityFreezeService.guardRuns(Trigger.oldMap, Trigger.new);
    AgentLifecycleInvariantService.guardRuns(Trigger.oldMap, Trigger.new);
}