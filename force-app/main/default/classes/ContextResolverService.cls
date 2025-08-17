/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextResolverService orchestrates the intelligent resolution of context for a chat session turn.
 * It aggregates all relevant record IDs (from both the current page and session history), groups them by SObjectType,
 * and invokes the appropriate context providers in a bulk-safe, governor-friendly manner. This service is responsible
 * for determining which records and contextual data should be loaded for the agent, leveraging configuration-driven
 * provider logic and ensuring extensibility for new context types.
 *
 * Key responsibilities:
 *   - Aggregate and deduplicate relevant entity IDs for a session turn
 *   - Group IDs by SObjectType for efficient, bulk-safe provider invocation
 *   - Dynamically resolve and invoke context providers based on configuration
 *   - Return a structured result containing all records and summaries needed for the agent
 *   - Handle errors gracefully and provide meaningful debug output for troubleshooting
 *
 * This class does not persist context state; it is focused on context resolution and provider orchestration.
 */
public inherited sharing class ContextResolverService {
    /**
     * DTO for the result of context resolution.
     *   - recordsToLoad: All SObjects to be loaded for the agent this turn.
     *   - longTermContextSummary: (Optional) Summary string for long-term context.
     */
    public class ResolutionResult {
        public List<SObject> recordsToLoad { get; private set; }
        public String longTermContextSummary { get; private set; }

        public ResolutionResult() {
            this.recordsToLoad = new List<SObject>();
            this.longTermContextSummary = '';
        }
    }

    /**
     * Exception type for errors encountered during context resolution.
     */
    public class ResolutionException extends AIAgentException {
    }

    private final ContextManagerService contextLedger;
    private final Map<String, IAgentContextProvider> providerCache = new Map<String, IAgentContextProvider>();

    /**
     * Constructs a ContextResolverService with a default ContextManagerService.
     */
    public ContextResolverService() {
        this(new ContextManagerService());
    }

    /**
     * Constructs a ContextResolverService with a provided ContextManagerService (for testing/mocking).
     * @param ledgerService The ContextManagerService to use for context ledger access.
     */
    @TestVisible
    private ContextResolverService(ContextManagerService ledgerService) {
        this.contextLedger = ledgerService;
    }

    /**
     * Resolves all relevant context for the current turn, orchestrating provider invocations in a bulk-safe manner.
     *
     * @param sessionId              The Id of the chat session.
     * @param agentDefinitionId      The Id of the agent definition.
     * @param userId                 The Id of the current user.
     * @param immediatePageRecordId  The Id of the record the user is currently viewing (highest priority).
     * @param currentTurn            The current turn number (for recency checks).
     * @return ResolutionResult      DTO containing all records to load and any long-term context summary.
     * @throws ResolutionException   If provider instantiation or config query fails.
     * @sideeffect Emits debug logs for key resolution steps and errors.
     */
    public ResolutionResult resolve(Id sessionId, Id agentDefinitionId, Id userId, Id immediatePageRecordId, Integer currentTurn) {
        String logPrefix = '[CtxResolverSvc Sess:' + sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Context resolution START. PageContextId=' + immediatePageRecordId + ', Turn=' + currentTurn);

        ResolutionResult result = new ResolutionResult();
        List<AgentContextConfig__c> allConfigs = queryApplicableConfigs(agentDefinitionId, logPrefix);
        if (allConfigs.isEmpty()) {
            System.debug(LoggingLevel.WARN, logPrefix + 'No applicable AgentContextConfig__c found. Returning empty result.');
            return result;
        }

        // Gather all unique relevant IDs from the page and history ledger.
        Set<Id> allRelevantIds = gatherAllRelevantIds(sessionId, immediatePageRecordId);
        if (allRelevantIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No relevant record IDs found. Only non-record context providers will be invoked.');
        }

        // Group the gathered IDs by their SObject type for bulk processing.
        Map<SObjectType, Set<Id>> idsToProcessByType = groupIdsBySObjectType(allRelevantIds);

        // Process RECORD-CONTEXT providers in bulk, one SObject type at a time.
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

        // Process NON-RECORD-CONTEXT providers (e.g., User Details).
        List<AgentContextConfig__c> nonRecordContextConfigs = filterConfigsForType(allConfigs, null, false);
        for (AgentContextConfig__c config : nonRecordContextConfigs) {
            // The "anchor" for a user-centric provider is the user themselves.
            Map<String, List<SObject>> providerResult = invokeProvider(config, new Set<Id>{ userId }, userId, logPrefix);
            if (providerResult != null) {
                for (List<SObject> records : providerResult.values()) {
                    result.recordsToLoad.addAll(records);
                }
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Context resolution END. Total records loaded: ' + result.recordsToLoad.size());
        return result;
    }

    /**
     * Aggregates all unique relevant record IDs for the current turn, including the immediate page context and session ledger.
     *
     * @param sessionId             The Id of the chat session.
     * @param immediatePageRecordId The Id of the record the user is currently viewing (nullable).
     * @return Set<Id>              All unique relevant record IDs.
     */
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

    /**
     * Groups a set of record IDs by their SObjectType for efficient, bulk-safe processing.
     *
     * @param ids Set of record IDs to group.
     * @return Map<SObjectType, Set<Id>> Map of SObjectType to set of IDs.
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
     * Filters AgentContextConfig__c records for applicability to a given SObjectType and context requirement.
     *
     * @param allConfigs            All configs to filter.
     * @param sObjType              The SObjectType to match (nullable for non-record context).
     * @param requiresRecordContext Whether the config must require record context.
     * @return List<AgentContextConfig__c> Filtered configs.
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
                filtered.add(config);
            }
        }
        return filtered;
    }

    /**
     * Instantiates and invokes a context provider for the given config and anchor IDs.
     *
     * @param config     The AgentContextConfig__c specifying the provider.
     * @param anchorIds  The set of anchor IDs to provide context for.
     * @param userId     The current user Id.
     * @param logPrefix  Prefix for debug output.
     * @return Map<String, List<SObject>> Provider result, or null on error.
     */
    private Map<String, List<SObject>> invokeProvider(AgentContextConfig__c config, Set<Id> anchorIds, Id userId, String logPrefix) {
        try {
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Invoking provider ' + config.ImplementationName__c + ' for ' + anchorIds.size() + ' anchor IDs.'
            );
            IAgentContextProvider provider = getProviderInstance(config.ImplementationName__c);
            Map<String, List<SObject>> result = provider.getContext(anchorIds, userId, config.ImplementationConfigJson__c);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Provider ' + config.ImplementationName__c + ' returned ' + ((result != null) ? result.size() : 0) + ' context buckets.'
            );
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception invoking provider ' + config.ImplementationName__c + ': ' + e.getMessage());
            return null;
        }
    }

    /**
     * Returns a cached or newly instantiated IAgentContextProvider for the given class name.
     *
     * @param className The fully qualified Apex class name.
     * @return IAgentContextProvider The provider instance.
     * @throws ResolutionException if the class cannot be found or does not implement the interface.
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
     * Queries all applicable AgentContextConfig__c records for the given agent definition.
     *
     * @param agentDefinitionId The Id of the agent definition.
     * @param logPrefix         Prefix for debug output.
     * @return List<AgentContextConfig__c> All applicable configs.
     * @throws ResolutionException if the query fails.
     */
    private List<AgentContextConfig__c> queryApplicableConfigs(Id agentDefinitionId, String logPrefix) {
        try {
            List<AgentContextConfig__c> configs = [
                SELECT Id, Name, ImplementationName__c, ImplementationConfigJson__c, ApplicableSObjectTypes__c, RequiresRecordContext__c
                FROM AgentContextConfig__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE
                ORDER BY ExecutionOrder__c ASC
                LIMIT 50
            ];
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Queried ' + configs.size() + ' AgentContextConfig__c records.');
            return configs;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception querying AgentContextConfig__c: ' + e.getMessage());
            throw new ResolutionException('Failed to query AgentContextConfig__c: ' + e.getMessage(), e);
        }
    }
}
