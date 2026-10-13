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
 * Resolves the current executable configuration for an AgentRun.
 *
 * Runs retain their durable lifecycle and execution-identity state, while
 * definitions, tools, context providers, and org policy are read from their
 * active authoring records when work executes.
 */
public without sharing class AgentRunConfigurationService {
    private static Map<Id, Id> definitionIdsByRun = new Map<Id, Id>();
    private static Map<Id, AgentRun__c> policySnapshotsByRun = new Map<Id, AgentRun__c>();

    /** Loads the definition and policy snapshot of many runs in one query, so later per-run calls do not query. */
    public static void preload(Set<Id> runIds) {
        if (runIds != null && !runIds.isEmpty()) {
            loadDefinitionIds(runIds);
        }
    }

    public static AgentDefinition__c getDefinition(Id runId) {
        return AgentConfigService.getActiveDefinition(definitionId(runId));
    }

    public static AgentExecutionPolicyService.Policy getExecutionPolicy(Id runId) {
        definitionId(runId);
        return AgentExecutionPolicyService.resolveForRun(policySnapshotsByRun.get(runId));
    }

    public static List<AgentTool__c> getTools(Id runId) {
        Map<Id, List<AgentTool__c>> toolsByRun = getToolsByRunIds(new Set<Id>{ runId });
        return toolsByRun.containsKey(runId) ? toolsByRun.get(runId) : new List<AgentTool__c>();
    }

    public static Map<Id, List<AgentTool__c>> getToolsByRunIds(Set<Id> runIds) {
        Map<Id, List<AgentTool__c>> result = new Map<Id, List<AgentTool__c>>();
        if (runIds == null || runIds.isEmpty()) {
            return result;
        }
        loadDefinitionIds(runIds);
        Set<Id> definitionIds = new Set<Id>();
        for (Id runId : runIds) {
            Id definitionId = definitionIdsByRun.get(runId);
            if (definitionId != null) {
                definitionIds.add(definitionId);
            }
        }
        Map<Id, List<AgentTool__c>> toolsByDefinition = AgentConfigService.getActiveToolsByDefinitionIds(definitionIds);
        for (Id runId : runIds) {
            Id definitionId = definitionIdsByRun.get(runId);
            List<AgentTool__c> configuredTools = definitionId != null && toolsByDefinition.containsKey(definitionId)
                ? toolsByDefinition.get(definitionId).clone()
                : new List<AgentTool__c>();
            result.put(runId, configuredTools);
        }
        return result;
    }

    public static AgentTool__c getTool(Id runId, String developerName) {
        if (String.isBlank(developerName)) {
            throw new AgentKernelException.ConfigurationException('Tool developer name is required.');
        }
        for (AgentTool__c tool : getTools(runId)) {
            if (tool.DeveloperName__c.equalsIgnoreCase(developerName.trim())) {
                return tool;
            }
        }
        throw new AgentKernelException.NotFoundException('The active run configuration has no tool with the requested name.');
    }

    /** The configuration hash of the run's current executable configuration. */
    public static String getConfigurationHash(Id runId) {
        return AgentConfigService.configurationHash(getDefinition(runId), getTools(runId), getContextProviders(runId));
    }

    /**
     * What the run's configuration changed to, and from what, for a Configuration
     * Changed event. The baseline is the fingerprint on the run's start or last
     * change event. Either part is left out when it can't be proven: the event was
     * protected or purged, or the configuration moved again since the command ran.
     */
    public static Map<String, Object> describeChange(Id runId, String previousHash, String currentHash) {
        Map<String, Object> result = new Map<String, Object>();
        Map<String, Object> current = AgentConfigService.configurationFingerprint(getDefinition(runId), getTools(runId), getContextProviders(runId));
        if (AgentConfigService.fingerprintHash(current) != currentHash) {
            return result;
        }
        result.put('configuration', current);
        Map<String, Object> previous = lastFingerprint(runId);
        if (previous != null && AgentConfigService.fingerprintHash(previous) == previousHash) {
            result.put('changes', AgentConfigService.configurationChanges(previous, current));
        }
        return result;
    }

    private static Map<String, Object> lastFingerprint(Id runId) {
        for (AgentEvent__c event : [
            SELECT Payload__c
            FROM AgentEvent__c
            WHERE
                AgentRun__c = :runId
                AND EventType__c IN (:AgentKernelModels.EVENT_RUN_STARTED, :AgentKernelModels.EVENT_CONFIGURATION_CHANGED)
                AND PayloadPurgedAt__c = NULL
            WITH SYSTEM_MODE
            ORDER BY Sequence__c DESC
            LIMIT 1
        ]) {
            if (String.isBlank(event.Payload__c)) {
                return null;
            }
            try {
                Object payload = JSON.deserializeUntyped(event.Payload__c);
                Object fingerprint = payload instanceof Map<String, Object> ? ((Map<String, Object>) payload).get('configuration') : null;
                return fingerprint instanceof Map<String, Object> ? (Map<String, Object>) fingerprint : null;
            } catch (JSONException truncated) {
                return null;
            }
        }
        return null;
    }

    public static List<AgentContextProvider__c> getContextProviders(Id runId) {
        return AgentConfigService.getActiveContextProviders(definitionId(runId));
    }

    private static Id definitionId(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.ConfigurationException('Run ID is required to resolve configuration.');
        }
        loadDefinitionIds(new Set<Id>{ runId });
        if (!definitionIdsByRun.containsKey(runId)) {
            throw new AgentKernelException.ConfigurationException('The run has no executable agent definition.');
        }
        return definitionIdsByRun.get(runId);
    }

    private static void loadDefinitionIds(Set<Id> runIds) {
        Set<Id> missingRunIds = new Set<Id>();
        for (Id runId : runIds) {
            if (runId != null && !definitionIdsByRun.containsKey(runId)) {
                missingRunIds.add(runId);
            }
        }
        if (missingRunIds.isEmpty()) {
            return;
        }
        for (AgentRun__c run : [
            SELECT
                AgentDefinition__c,
                MaxRetries__c,
                PayloadRetentionMode__c,
                PayloadRetentionDays__c,
                RecordRetentionDays__c,
                RetainedPayloadCharacters__c,
                SensitiveJsonKeys__c
            FROM AgentRun__c
            WHERE Id IN :missingRunIds
            WITH SYSTEM_MODE
        ]) {
            definitionIdsByRun.put(run.Id, run.AgentDefinition__c);
            policySnapshotsByRun.put(run.Id, run);
        }
    }
}
