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
 * Register as the sandbox post-copy class. A copied vault holds production
 * originals that no sandbox operator is authorized to resolve, so this rotates
 * the fingerprint key and purges every live trust mapping in bounded chunks.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentCoreSandboxPostCopy implements SandboxPostCopy {
    public void runApexClass(SandboxContext context) {
        TrustKeyProvider.rotate();
        System.enqueueJob(new VaultPurge());
    }

    public class VaultPurge implements Queueable {
        public void execute(QueueableContext context) {
            List<AgentTrustToken__c> mappings = [
                SELECT Id
                FROM AgentTrustToken__c
                WHERE PurgedAt__c = NULL
                WITH SYSTEM_MODE
                LIMIT 2000
                FOR UPDATE
            ];
            Integer purged = TrustService.purgeCopiedVault(mappings);
            AgentOperationsLog.emit(LoggingLevel.INFO, 'SANDBOX_VAULT_PURGED', null, null, purged, null);
            if (purged == 2000 && !Test.isRunningTest()) {
                System.enqueueJob(new VaultPurge());
            }
        }
    }
}
