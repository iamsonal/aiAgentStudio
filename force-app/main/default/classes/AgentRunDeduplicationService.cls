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
 * Builds race-safe correlated-start identities and reconstructs the original
 * public start result without exposing runs that the caller cannot read.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public inherited sharing class AgentRunDeduplicationService {
    public static String deduplicationKey(Id definitionId, String externalCorrelationKey) {
        if (definitionId == null || String.isBlank(externalCorrelationKey)) {
            return null;
        }
        return CanonicalJson.sha256(CanonicalJson.serialize(new List<Object>{ String.valueOf(definitionId), externalCorrelationKey.trim() }));
    }

    /**
     * Keyed by the org trust key because the raw input may hold sensitive
     * values, and the hash outlives payload retention.
     */
    public static String requestHash(Id definitionId, Id anchorRecordId, Id parentRunId, String input, String invocationEntryPoint, Id executionIdentityId) {
        String canonical = CanonicalJson.serialize(
            new List<Object>{
                String.valueOf(definitionId),
                anchorRecordId == null ? null : String.valueOf(anchorRecordId),
                parentRunId == null ? null : String.valueOf(parentRunId),
                input,
                invocationEntryPoint,
                executionIdentityId == null ? null : String.valueOf(executionIdentityId)
            }
        );
        return EncodingUtil.convertToHex(Crypto.generateMac('HmacSHA256', Blob.valueOf(canonical), TrustKeyProvider.currentKey())).toLowerCase();
    }

    public static AgentKernelModels.StartResult findVisibleExisting(String deduplicationKey, String expectedRequestHash) {
        if (String.isBlank(deduplicationKey)) {
            return null;
        }
        List<AgentRun__c> runs = [
            SELECT Id, Status__c, Revision__c, AnchorRecordId__c, ParentRun__c, ExternalCorrelationKey__c, InvocationEntryPoint__c, StartRequestHash__c
            FROM AgentRun__c
            WHERE StartDeduplicationKey__c = :deduplicationKey
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            return null;
        }
        AgentRun__c run = runs[0];
        // The system key must remain queryable even when it is hidden by FLS.
        // No hash or run data is compared or returned until this user-mode
        // visibility guard succeeds.
        AgentKernelAccessGuard.assertRunReadable(run.Id);
        if (String.isBlank(expectedRequestHash) || !expectedRequestHash.equals(run.StartRequestHash__c)) {
            throw new AgentKernelException.CorrelationConflictException('The external correlation key is already associated with a different start request.');
        }
        List<AgentCommand__c> commands = [
            SELECT Id, ExpectedRunRevision__c, OperationKey__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :run.Id
            WITH SYSTEM_MODE
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT 1
        ];
        if (commands.isEmpty()) {
            throw new AgentKernelException.InvalidTransitionException('The correlated run has no initial command.');
        }
        AgentKernelModels.StartResult result = new AgentKernelModels.StartResult();
        result.runId = run.Id;
        result.commandId = commands[0].Id;
        // The run's current revision, so the caller can control the run it got back.
        result.revision = run.Revision__c;
        result.operationKey = commands[0].OperationKey__c;
        result.anchorRecordId = String.isBlank(run.AnchorRecordId__c) ? null : (Id) run.AnchorRecordId__c;
        result.parentRunId = run.ParentRun__c;
        result.externalCorrelationKey = run.ExternalCorrelationKey__c;
        result.invocationEntryPoint = run.InvocationEntryPoint__c;
        result.deduplicated = true;
        result.runStatus = run.Status__c;
        return result;
    }
}
