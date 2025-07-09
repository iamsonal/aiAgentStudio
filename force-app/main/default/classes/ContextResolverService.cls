/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service that intelligently resolves the context for a given turn.
 *              It gathers all relevant record IDs, groups them by SObjectType, and invokes the
 *              appropriate context providers in a bulk-safe manner to prevent hitting governor limits.
 */
public inherited sharing class ContextResolverService {
    public class ResolutionResult {
        public List<SObject> recordsToLoad { get; private set; }
        public String longTermContextSummary { get; private set; }

        public ResolutionResult() {
            this.recordsToLoad = new List<SObject>();
            this.longTermContextSummary = '';
        }
    }

    public class ResolutionException extends AIAgentException {
    }

    private final ContextManagerService contextLedger;
    private final Map<String, IAgentContextProvider> providerCache = new Map<String, IAgentContextProvider>();

    public ContextResolverService() {
        this(new ContextManagerService());
    }

    @TestVisible
    private ContextResolverService(ContextManagerService ledgerService) {
        this.contextLedger = ledgerService;
    }

    /**
     * @description Main method to resolve context for the current turn.
     * @param sessionId The ID of the chat session.
     * @param agentDefinitionId The ID of the agent definition.
     * @param userId The ID of the current user.
     * @param immediatePageRecordId The ID of the record the user is currently viewing (highest priority).
     * @param currentTurn The current turn number, for recency checks.
     * @return A ResolutionResult DTO containing records to load and summaries.
     */
    public ResolutionResult resolve(Id sessionId, Id agentDefinitionId, Id userId, Id immediatePageRecordId, Integer currentTurn) {
        String logPrefix = '[CtxResolverSvc Sess:' + sessionId + '] ';

        ResolutionResult result = new ResolutionResult();
        List<AgentContextConfig__c> allConfigs = queryApplicableConfigs(agentDefinitionId, logPrefix);
        if (allConfigs.isEmpty())
            return result;

        Set<Id> allRelevantIds = gatherAllRelevantIds(sessionId, immediatePageRecordId);
        if (allRelevantIds.isEmpty()) {
        }

        Map<SObjectType, Set<Id>> idsToProcessByType = groupIdsBySObjectType(allRelevantIds);

        for (SObjectType sObjType : idsToProcessByType.keySet()) {
            Set<Id> idsForThisType = idsToProcessByType.get(sObjType);
            List<AgentContextConfig__c> applicableConfigs = filterConfigsForType(allConfigs, sObjType, true);

            for (AgentContextConfig__c config : applicableConfigs) {
                Map<String, List<SObject>> providerResult = invokeProvider(config, idsForThisType, userId, logPrefix);
                if (providerResult != null) {
                    for (List<SObject> records : providerResult.values()) {
                        result.recordsToLoad.addAll(records);
                    }
                }
            }
        }

        List<AgentContextConfig__c> nonRecordContextConfigs = filterConfigsForType(allConfigs, null, false);
        for (AgentContextConfig__c config : nonRecordContextConfigs) {
            Map<String, List<SObject>> providerResult = invokeProvider(config, new Set<Id>{ userId }, userId, logPrefix);
            if (providerResult != null) {
                for (List<SObject> records : providerResult.values()) {
                    result.recordsToLoad.addAll(records);
                }
            }
        }

        return result;
    }

    private Set<Id> gatherAllRelevantIds(Id sessionId, Id immediatePageRecordId) {
        Set<Id> relevantIds = new Set<Id>();
        if (immediatePageRecordId != null) {
            relevantIds.add(immediatePageRecordId);
        }
        for (ContextManagerService.ContextItem item : this.contextLedger.getContextLedger(sessionId)) {
            relevantIds.add(Id.valueOf(item.id));
        }
        return relevantIds;
    }

    private Map<SObjectType, Set<Id>> groupIdsBySObjectType(Set<Id> ids) {
        Map<SObjectType, Set<Id>> mapByType = new Map<SObjectType, Set<Id>>();
        if (ids == null)
            return mapByType;

        for (Id recordId : ids) {
            SObjectType sObjType = recordId.getSObjectType();
            if (!mapByType.containsKey(sObjType)) {
                mapByType.put(sObjType, new Set<Id>());
            }
            mapByType.get(sObjType).add(recordId);
        }
        return mapByType;
    }

    private List<AgentContextConfig__c> filterConfigsForType(
        List<AgentContextConfig__c> allConfigs,
        SObjectType sObjType,
        Boolean requiresRecordContext
    ) {
        List<AgentContextConfig__c> filtered = new List<AgentContextConfig__c>();
        String sObjTypeName = (sObjType != null) ? sObjType.getDescribe().getName().toLowerCase() : null;

        for (AgentContextConfig__c config : allConfigs) {
            if (config.RequiresRecordContext__c != requiresRecordContext)
                continue;

            if (requiresRecordContext) {
                List<String> applicableTypes = String.isBlank(config.ApplicableSObjectTypes__c)
                    ? new List<String>()
                    : config.ApplicableSObjectTypes__c.toLowerCase().split(',');
                if (applicableTypes.contains(sObjTypeName)) {
                    filtered.add(config);
                }
            } else {
                filtered.add(config);
            }
        }
        return filtered;
    }

    private Map<String, List<SObject>> invokeProvider(AgentContextConfig__c config, Set<Id> anchorIds, Id userId, String logPrefix) {
        try {
            IAgentContextProvider provider = getProviderInstance(config.ImplementationName__c);
            return provider.getContext(anchorIds, userId, config.ImplementationConfigJson__c);
        } catch (Exception e) {
            return null;
        }
    }

    private IAgentContextProvider getProviderInstance(String className) {
        if (!providerCache.containsKey(className)) {
            Type providerType = Type.forName(className);
            if (providerType == null)
                throw new ResolutionException('Provider class not found: ' + className);
            Object instance = providerType.newInstance();
            if (!(instance instanceof IAgentContextProvider))
                throw new ResolutionException('Class ' + className + ' does not implement IAgentContextProvider.');
            providerCache.put(className, (IAgentContextProvider) instance);
        }
        return providerCache.get(className);
    }

    private List<AgentContextConfig__c> queryApplicableConfigs(Id agentDefinitionId, String logPrefix) {
        try {
            return [
                SELECT Id, Name, ImplementationName__c, ImplementationConfigJson__c, ApplicableSObjectTypes__c, RequiresRecordContext__c
                FROM AgentContextConfig__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE
                ORDER BY ExecutionOrder__c ASC
                LIMIT 50
            ];
        } catch (Exception e) {
            throw new ResolutionException('Failed to query AgentContextConfig__c: ' + e.getMessage(), e);
        }
    }
}
