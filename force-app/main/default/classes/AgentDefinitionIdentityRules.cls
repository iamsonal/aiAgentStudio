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
 * Rules for who an agent's runs act as. An agent with an Agent Execution
 * Identity runs as the identity's user; one without runs as whoever starts it.
 * Enforced when definitions and tools are saved. error() repeats at preflight
 * and start because the org retry limit can change after a definition is saved.
 *
 * A run without an identity executes in the starting user's own job chain, so
 * no one else can approve it and scheduled recovery cannot continue it.
 */
public inherited sharing class AgentDefinitionIdentityRules {
    public static final String APPROVAL_UNSUPPORTED_MESSAGE = 'This agent has no Agent Execution Identity, so it runs as whoever starts it and cannot have tools that need approval: an approved call could not continue in that user\'s job chain. Set an Agent Execution Identity on the agent, or clear Always Require Approval and Approver Type.';
    public static final String CLEAR_IDENTITY_REFUSED_MESSAGE = 'This agent has tools that need approval, so it needs an Agent Execution Identity. Keep the identity, or clear Always Require Approval and Approver Type on those tools first.';

    public static String error(AgentDefinition__c definition) {
        return chainDepthError(definition);
    }

    /** Every command and retry of a run without an identity consumes one link of the starting user's Queueable chain. */
    public static String chainDepthError(AgentDefinition__c definition) {
        if (definition == null || ExecutionIdentityService.usesIdentity(definition) || definition.IsActive__c != true) {
            return null;
        }
        AsyncJobCostService.Estimate estimate;
        try {
            estimate = AsyncJobCostService.estimate(definition);
        } catch (Exception invalidBudget) {
            return null;
        }
        if (estimate.exceedsInitiatingUserChainDepth) {
            return 'An agent without an Agent Execution Identity can chain at most ' +
                AsyncJobCostService.MAXIMUM_INITIATING_USER_CHAIN_DEPTH +
                ' jobs per run. Lower Max Model Calls, Max Tool Calls, or the org retry limit, or set an Agent Execution Identity.';
        }
        return null;
    }

    public static void validateDefinitions(List<AgentDefinition__c> records, Map<Id, AgentDefinition__c> previousById) {
        Set<Id> identityIds = new Set<Id>();
        Set<Id> clearedIdentityIds = new Set<Id>();
        for (AgentDefinition__c record : records) {
            String error = error(record);
            if (error != null) {
                record.addError(error);
                continue;
            }
            AgentDefinition__c previous = previousById == null ? null : previousById.get(record.Id);
            Boolean identityTouched =
                previous == null ||
                previous.ExecutionIdentity__c != record.ExecutionIdentity__c ||
                previous.IsActive__c != record.IsActive__c;
            if (record.IsActive__c == true && record.ExecutionIdentity__c != null && identityTouched) {
                identityIds.add(record.ExecutionIdentity__c);
            }
            if (previous != null && previous.ExecutionIdentity__c != null && record.ExecutionIdentity__c == null) {
                clearedIdentityIds.add(record.Id);
            }
        }
        Set<Id> usableIdentityIds = usableIdentities(identityIds);
        Set<Id> approvalDefinitionIds = definitionsWithApprovalTools(clearedIdentityIds);
        for (AgentDefinition__c record : records) {
            if (identityIds.contains(record.ExecutionIdentity__c) && !usableIdentityIds.contains(record.ExecutionIdentity__c)) {
                record.addError('The selected Agent Execution Identity must be active and have an active user.');
            }
            if (approvalDefinitionIds.contains(record.Id)) {
                record.addError(AgentDefinition__c.ExecutionIdentity__c, CLEAR_IDENTITY_REFUSED_MESSAGE);
            }
        }
    }

    public static void validateTools(List<AgentTool__c> records) {
        Set<Id> definitionIds = new Set<Id>();
        for (AgentTool__c record : records) {
            if (record.IsActive__c == true && usesApproval(record) && record.AgentDefinition__c != null) {
                definitionIds.add(record.AgentDefinition__c);
            }
        }
        if (definitionIds.isEmpty()) {
            return;
        }
        Set<Id> withoutIdentityIds = new Map<Id, AgentDefinition__c>(
                [SELECT Id FROM AgentDefinition__c WHERE Id IN :definitionIds AND ExecutionIdentity__c = NULL WITH SYSTEM_MODE]
            )
            .keySet();
        for (AgentTool__c record : records) {
            if (record.IsActive__c == true && usesApproval(record) && withoutIdentityIds.contains(record.AgentDefinition__c)) {
                record.addError(APPROVAL_UNSUPPORTED_MESSAGE);
            }
        }
    }

    private static Boolean usesApproval(AgentTool__c record) {
        return record.RequiresApproval__c == true || !String.isBlank(record.ApproverType__c);
    }

    private static Set<Id> definitionsWithApprovalTools(Set<Id> definitionIds) {
        Set<Id> result = new Set<Id>();
        if (definitionIds.isEmpty()) {
            return result;
        }
        for (AgentTool__c tool : [
            SELECT AgentDefinition__c
            FROM AgentTool__c
            WHERE AgentDefinition__c IN :definitionIds AND IsActive__c = TRUE AND (RequiresApproval__c = TRUE OR ApproverType__c != NULL)
            WITH SYSTEM_MODE
        ]) {
            result.add(tool.AgentDefinition__c);
        }
        return result;
    }

    private static Set<Id> usableIdentities(Set<Id> identityIds) {
        Set<Id> usable = new Set<Id>();
        if (identityIds.isEmpty()) {
            return usable;
        }
        for (AgentExecutionIdentity__c identity : [
            SELECT Id, IsActive__c, PrincipalUser__r.IsActive
            FROM AgentExecutionIdentity__c
            WHERE Id IN :identityIds
            WITH SYSTEM_MODE
        ]) {
            if (identity.IsActive__c == true && identity.PrincipalUser__r.IsActive == true) {
                usable.add(identity.Id);
            }
        }
        return usable;
    }
}
