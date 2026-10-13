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
 * Supplies the org secret that keys trust-token fingerprints and correlated
 * start hashes. CommandLeaseRecoveryScheduler.install() provisions it, and the
 * sandbox post-copy class replaces it, so a run never creates it mid-flight.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class TrustKeyProvider {
    private static Blob cachedKey;
    private static Datetime cachedKeyCreatedAt;

    public static Blob currentKey() {
        if (cachedKey == null) {
            AgentTrustKey__c setting = AgentTrustKey__c.getOrgDefaults();
            if (setting == null || String.isBlank(setting.Key__c)) {
                throw missingKey();
            }
            cachedKey = EncodingUtil.base64Decode(setting.Key__c);
        }
        return cachedKey;
    }

    /**
     * When the current key was created. Rotation replaces the key record, so a
     * vault mapping created earlier belongs to a retired key and a copied org.
     */
    public static Datetime currentKeyCreatedAt() {
        if (cachedKeyCreatedAt == null) {
            AgentTrustKey__c setting = AgentTrustKey__c.getOrgDefaults();
            try {
                cachedKeyCreatedAt = setting == null ? null : setting.CreatedDate;
            } catch (SObjectException notReturned) {
                cachedKeyCreatedAt = null;
            }
            if (cachedKeyCreatedAt == null) {
                List<AgentTrustKey__c> keys = [
                    SELECT CreatedDate
                    FROM AgentTrustKey__c
                    WHERE SetupOwnerId = :UserInfo.getOrganizationId()
                    WITH SYSTEM_MODE
                    LIMIT 1
                ];
                if (keys.isEmpty()) {
                    throw missingKey();
                }
                cachedKeyCreatedAt = keys[0].CreatedDate;
            }
        }
        return cachedKeyCreatedAt;
    }

    /** Creates the org key when none exists. Safe to repeat. */
    public static void provision() {
        AgentTrustKey__c setting = AgentTrustKey__c.getOrgDefaults();
        if (setting != null && !String.isBlank(setting.Key__c)) {
            return;
        }
        Database.insert(
            new AgentTrustKey__c(SetupOwnerId = UserInfo.getOrganizationId(), Key__c = EncodingUtil.base64Encode(Crypto.generateAesKey(256))),
            AccessLevel.SYSTEM_MODE
        );
        cachedKey = null;
        cachedKeyCreatedAt = null;
    }

    private static AgentKernelException.ConfigurationException missingKey() {
        return new AgentKernelException.ConfigurationException(
            'The Agent Core trust key is missing. Run CommandLeaseRecoveryScheduler.install() as the Core administrator.'
        );
    }

    /** Replaces the org key, so fingerprints computed with the old key no longer match. */
    public static void rotate() {
        delete [SELECT Id FROM AgentTrustKey__c WHERE SetupOwnerId = :UserInfo.getOrganizationId() WITH SYSTEM_MODE];
        cachedKey = null;
        cachedKeyCreatedAt = null;
        provision();
    }
}
