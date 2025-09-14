/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextResolverService orchestrates the resolution and aggregation of all relevant conversational context for an AI agent session.
 * It dynamically invokes context providers, groups and processes SObject records in bulk to avoid governor limits, and ensures
 * comprehensive context coverage for downstream consumers. The service is designed for extensibility, bulk safety, and clear diagnostics.
 *
 * Responsibilities:
 *   - Querying and filtering context provider configurations for a given agent definition
 *   - Gathering all relevant record and user IDs from the session context ledger and immediate page context
 *   - Grouping IDs by SObject type for efficient, bulk-safe provider invocation
 *   - Dynamically instantiating and invoking context providers, handling both record-based and user-centric providers
 *   - Aggregating and returning all resolved context records in a structured result object
 *   - Providing clear debug output and error handling for maintainability and troubleshooting
 */
public inherited sharing class ContextResolverService {
    // --- DTOs for structured results ---
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
     * Resolves and aggregates all relevant context for a session by orchestrating multiple context providers.
     *
     * This method processes both record-based and user-centric context, invoking providers in a bulk-safe manner
     * and returning all resolved records in a structured result. It is the main entry point for context gathering.
     *
     * @param sessionId              The chat session identifier.
     * @param agentDefinitionId      The agent configuration identifier.
     * @param userId                 The current user identifier.
     * @param immediatePageRecordId  The current page record (highest priority context).
     * @param currentTurn            The current conversation turn for recency evaluation.
     * @return                       ResolutionResult containing all resolved context data.
     * @throws                       ResolutionException if provider instantiation or config query fails.
     * @sideeffects                  Writes to debug logs; may invoke custom provider logic.
     */
    public ResolutionResult resolve(Id sessionId, Id agentDefinitionId, Id userId, Id immediatePageRecordId, Integer currentTurn) {
        String logPrefix = '[CtxResolverSvc Sess:' + sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting context resolution. Immediate page record: ' + immediatePageRecordId);

        ResolutionResult result = new ResolutionResult();
        List<AgentContextConfig__c> allConfigs = queryApplicableConfigs(agentDefinitionId, logPrefix);
        if (allConfigs.isEmpty()) {
            System.debug(LoggingLevel.WARN, logPrefix + 'No active context provider configs found for agent definition. Returning empty result.');
            return result;
        }

        // 1. Gather all unique relevant IDs from the page and history ledger.
        Set<Id> allRelevantIds = gatherAllRelevantIds(sessionId, immediatePageRecordId, currentTurn);
        if (allRelevantIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No record context found in session or page. Only user-centric providers will be invoked.');
        }

        // 2. Group the gathered IDs by their SObject type for bulk processing.
        Map<SObjectType, Set<Id>> idsToProcessByType = groupIdsBySObjectType(allRelevantIds);
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Grouped relevant IDs by SObject type: ' + idsToProcessByType.keySet());

        // 3. Process RECORD-CONTEXT providers in bulk, one SObject type at a time.
        // For each SObject type, invoke all applicable record-context providers in bulk
        for (SObjectType sObjType : idsToProcessByType.keySet()) {
            Set<Id> idsForThisType = idsToProcessByType.get(sObjType);
            List<AgentContextConfig__c> applicableConfigs = filterConfigsForType(allConfigs, sObjType, true);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Processing SObjectType: ' +
                    sObjType +
                    ' with ' +
                    idsForThisType.size() +
                    ' IDs and ' +
                    applicableConfigs.size() +
                    ' provider configs.'
            );
            for (AgentContextConfig__c config : applicableConfigs) {
                Map<String, List<SObject>> providerResult = invokeProvider(config, idsForThisType, userId, logPrefix);
                if (providerResult != null) {
                    for (List<SObject> records : providerResult.values()) {
                        result.recordsToLoad.addAll(records);
                    }
                }
            }
        }

        // 4. Process NON-RECORD-CONTEXT providers (e.g., User Details).
        List<AgentContextConfig__c> nonRecordContextConfigs = filterConfigsForType(allConfigs, null, false);
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Invoking ' + nonRecordContextConfigs.size() + ' user-centric (non-record) provider configs.');
        for (AgentContextConfig__c config : nonRecordContextConfigs) {
            // The "anchor" for a user-centric provider is the user themselves.
            Map<String, List<SObject>> providerResult = invokeProvider(config, new Set<Id>{ userId }, userId, logPrefix);
            if (providerResult != null) {
                for (List<SObject> records : providerResult.values()) {
                    result.recordsToLoad.addAll(records);
                }
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Context resolution complete. Total records loaded: ' + result.recordsToLoad.size());
        return result;
    }

    /**
     * Gathers all unique relevant record IDs from the immediate page context and the session's context ledger.
     *
     * @param sessionId             The chat session identifier.
     * @param immediatePageRecordId The current page record (if any).
     * @param currentTurn           The current conversation turn.
     * @return                      Set of all relevant record IDs for context resolution.
     */
    private Set<Id> gatherAllRelevantIds(Id sessionId, Id immediatePageRecordId, Integer currentTurn) {
        Set<Id> relevantIds = new Set<Id>();
        if (immediatePageRecordId != null) {
            relevantIds.add(immediatePageRecordId);
        }
        for (ContextManagerService.ContextItem item : this.contextLedger.getContextLedger(sessionId, currentTurn)) {
            relevantIds.add(Id.valueOf(item.id));
        }
        return relevantIds;
    }

    /**
     * Groups a set of record IDs by their SObject type for efficient, bulk-safe processing.
     *
     * @param ids   Set of record IDs to group.
     * @return      Map from SObjectType to set of IDs of that type.
     */
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

    /**
     * Filters a list of context provider configs for applicability to a given SObject type and context requirement.
     *
     * @param allConfigs            All available provider configs.
     * @param sObjType              The SObjectType to filter for (null for non-record context).
     * @param requiresRecordContext Whether the provider requires a record context.
     * @return                      List of configs applicable to the given type and context requirement.
     */
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
                // If it doesn't require record context, it's always applicable.
                filtered.add(config);
            }
        }
        return filtered;
    }

    /**
     * Dynamically instantiates and invokes a context provider for a set of anchor IDs.
     *
     * @param config      The provider configuration.
     * @param anchorIds   The set of IDs to anchor the provider invocation.
     * @param userId      The current user ID.
     * @param logPrefix   Prefix for debug log output.
     * @return            Map of context keys to lists of SObjects, or null if provider fails.
     */
    private Map<String, List<SObject>> invokeProvider(AgentContextConfig__c config, Set<Id> anchorIds, Id userId, String logPrefix) {
        try {
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Invoking provider: ' + config.ImplementationName__c + ' | Anchor count: ' + anchorIds.size()
            );
            IAgentContextProvider provider = getProviderInstance(config.ImplementationName__c);
            Map<String, List<SObject>> result = provider.getContext(anchorIds, userId, config.ImplementationConfigJson__c);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Provider ' + config.ImplementationName__c + ' returned ' + ((result != null) ? result.size() : 0) + ' context keys.'
            );
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Provider invocation failed (' + config.ImplementationName__c + '): ' + e.getMessage());
            return null;
        }
    }

    /**
     * Returns a cached or newly instantiated provider instance for the given class name.
     *
     * @param className   The fully qualified Apex class name.
     * @return            An instance of IAgentContextProvider.
     * @throws            ResolutionException if the class cannot be found or does not implement the interface.
     */
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

    /**
     * Queries all active context provider configs for a given agent definition, ordered by execution order.
     *
     * @param agentDefinitionId   The agent configuration identifier.
     * @param logPrefix           Prefix for debug log output.
     * @return                    List of applicable AgentContextConfig__c records.
     * @throws                    ResolutionException if the query fails.
     */
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
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to query AgentContextConfig__c: ' + e.getMessage());
            throw new ResolutionException('Failed to query AgentContextConfig__c: ' + e.getMessage(), e);
        }
    }
}
