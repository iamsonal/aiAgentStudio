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

trigger AgentTrustTokenImmutabilityTrigger on AgentTrustToken__c(before update, before delete) {
    if (Trigger.isDelete) {
        for (AgentTrustToken__c record : Trigger.old) {
            record.addError('Trust token mappings cannot be deleted directly.');
        }
        return;
    }

    for (AgentTrustToken__c current : Trigger.new) {
        AgentTrustToken__c prior = Trigger.oldMap.get(current.Id);
        Boolean purgeOnly =
            TrustService.isPurgeAuthorized() &&
            current.AgentRun__c == prior.AgentRun__c &&
            current.Token__c == prior.Token__c &&
            current.Category__c == prior.Category__c &&
            current.ModelAuthored__c == prior.ModelAuthored__c &&
            current.ValueFingerprint__c == null &&
            prior.OriginalValue__c != null &&
            current.OriginalValue__c == null &&
            prior.PurgedAt__c == null &&
            current.PurgedAt__c != null;
        // Least privilege only: a model-authored value that org data also holds stops reaching every tool.
        Boolean provenanceDowngradeOnly =
            TrustService.isProvenanceDowngradeAuthorized() &&
            current.AgentRun__c == prior.AgentRun__c &&
            current.Token__c == prior.Token__c &&
            current.Category__c == prior.Category__c &&
            current.OriginalValue__c == prior.OriginalValue__c &&
            current.ValueFingerprint__c == prior.ValueFingerprint__c &&
            current.PurgedAt__c == prior.PurgedAt__c &&
            prior.ModelAuthored__c == true &&
            current.ModelAuthored__c == false;
        if (!purgeOnly && !provenanceDowngradeOnly) {
            current.addError('Trust token mappings are immutable except when Core purges the original value.');
        }
    }
}