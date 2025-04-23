/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for gathering and formatting context data for AI Agents
 *              based on declarative config (ContextGraphSource__c) or Apex providers.
 *              Handles record/user anchors, performs RUNTIME validation of schema & permissions,
 *              and executes queries securely. Designed to be resilient to single-source failures.
 * @strategy Assumes configuration records (ContextGraphSource__c) have undergone deep validation
 *           on save via the trigger. This service focuses on safe parsing, runtime validation,
 *           secure execution, and graceful error handling.
 */
public inherited sharing class ContextService {
    private static final Integer MAX_GRAPH_DEPTH = 3;
    private static final String LOG_PREFIX = '[ContextService] ';
    private static final String IMPL_DECLARATIVE = 'Declarative';
    private static final String IMPL_APEX = 'Apex';
    private static final String LINK_DIRECT = 'Direct';
    private static final String LINK_PARENT = 'Parent Lookup';
    private static final String LINK_CHILD = 'Child Relationship';
    private static final String ANCHOR_RECORD = 'Record Anchored';
    private static final String ANCHOR_USER = 'User Anchored';

    @TestVisible
    private class ContextDataBlock implements Comparable {
        String label;
        String sourceDevName;
        Integer executionOrder;
        List<SObject> records = new List<SObject>();

        ContextDataBlock(ContextGraphSource__c source) {
            if (source == null)
                throw new ContextConfigurationException('Cannot create ContextDataBlock with null source.');
            this.label = determineLabel(source);
            this.sourceDevName = source.SourceDeveloperName__c;

            this.executionOrder = (source.ExecutionOrder__c != null) ? Integer.valueOf(source.ExecutionOrder__c) : 999;
        }

        private String determineLabel(ContextGraphSource__c source) {
            if (String.isNotBlank(source.ContextLabel__c))
                return source.ContextLabel__c;
            if (String.isNotBlank(source.Description__c))
                return source.Description__c;
            return source.SourceDeveloperName__c;
        }

        public Integer compareTo(Object compareToObject) {
            ContextDataBlock compareToBlock = (ContextDataBlock) compareToObject;
            if (this.executionOrder == compareToBlock.executionOrder)
                return 0;

            return (this.executionOrder > compareToBlock.executionOrder) ? 1 : -1;
        }
    }

    private class FieldSortComparator implements Comparator<String> {
        public Integer compare(String field1, String field2) {
            String field1Lower = field1.toLowerCase();
            String field2Lower = field2.toLowerCase();
            boolean f1IsName = field1Lower.equals('name');
            boolean f2IsName = field2Lower.equals('name');
            if (f1IsName && !f2IsName)
                return -1;
            if (!f1IsName && f2IsName)
                return 1;
            return field1Lower.compareTo(field2Lower);
        }
    }

    private ContextQueryBuilder queryBuilder;
    private Map<String, ContextDataBlock> aggregatedContextBlocks;
    private Set<String> visitedPaths;
    private Id requestingUserId;

    private Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();
    private Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();

    public ContextService() {
        this.queryBuilder = new ContextQueryBuilder();
        this.aggregatedContextBlocks = new Map<String, ContextDataBlock>();
        this.visitedPaths = new Set<String>();
        this.requestingUserId = UserInfo.getUserId();
    }

    /**
     * @description Gathers context based on agent definition and an optional primary record ID.
     *              Handles both User-Anchored and Record-Anchored sources. Aggregates results.
     * @param agentDefId ID of the AIAgentDefinition__c.
     * @param primaryRecordId Optional ID of the primary record context.
     * @return Map where Key is the display Label for the context block, Value is List<SObject> results.
     *         Returns potentially partial results if some sources failed processing.
     */
    public Map<String, List<SObject>> gatherContext(Id agentDefId, Id primaryRecordId) {
        String gatherLogPrefix =
            LOG_PREFIX +
            'gatherContext Agent:' +
            agentDefId +
            ' Record:' +
            primaryRecordId +
            ' User:' +
            this.requestingUserId +
            ' ';

        this.aggregatedContextBlocks.clear();
        this.visitedPaths.clear();
        this.sObjectTypeCache.clear();
        this.fieldDescribeCache.clear();

        try {
            AIAgentDefinition__c agentDef = getAgentDefinition(agentDefId);
            Boolean combineContext = agentDef?.CombineRecordAndUserContext__c == true;

            List<ContextGraphSource__c> relevantSources = getResolvedSourcesForAgent(agentDefId);
            if (relevantSources.isEmpty()) {
                return new Map<String, List<SObject>>();
            }

            Map<Id, SObjectType> recordAnchors = new Map<Id, SObjectType>();
            if (primaryRecordId != null) {
                try {
                    recordAnchors.put(primaryRecordId, primaryRecordId.getSObjectType());
                } catch (Exception e) {
                    primaryRecordId = null;
                }
            }

            Boolean processUserSources = (primaryRecordId == null || combineContext);
            Boolean processRecordSources = (primaryRecordId != null && !recordAnchors.isEmpty());

            if (processUserSources) {
                processSourcesForAnchor(null, this.requestingUserId, relevantSources, 0);
            }
            if (processRecordSources) {
                processSourcesForAnchor(recordAnchors, this.requestingUserId, relevantSources, 0);
            }

            return formatGatheredBlocks(this.aggregatedContextBlocks);
        } catch (Exception e) {
            handleGatheringError(e);
            return new Map<String, List<SObject>>();
        }
    }

    /**
     * @description Formats the gathered structured context map into a single string for the LLM prompt.
     *              Orders blocks by ExecutionOrder and adds labels.
     * @param structuredContext Map as returned by gatherContext (or instance variable after running gather).
     * @param primaryRecordId Optional ID used to tailor the initial heading.
     * @return A formatted context string, or null if no context was gathered.
     */
    public String formatContextForLLM(Map<String, List<SObject>> structuredContext, Id primaryRecordId) {
        final String formatLogPrefix = LOG_PREFIX + 'formatContextForLLM ';

        Map<String, ContextDataBlock> blocksToFormat = this.aggregatedContextBlocks;

        if (blocksToFormat == null || blocksToFormat.isEmpty()) {
            return null;
        }

        Integer truncationLength = AIAgentFrameworkSettings.getDefaultContextTruncationLength();
        List<String> finalContextStrings = new List<String>();

        String primaryRecordLabel = 'CONTEXT DATA';
        if (primaryRecordId != null) {
            try {
                SObjectType recordType = primaryRecordId.getSObjectType();
                if (recordType != null) {
                    primaryRecordLabel = String.format(
                        'CONTEXT RELEVANT TO {0} (ID: {1}):',
                        new List<String>{ recordType.getDescribe().getLabel(), String.valueOf(primaryRecordId) }
                    );
                } else {
                    primaryRecordLabel = String.format(
                        'CONTEXT RELEVANT TO RECORD (ID: {0}):',
                        new List<String>{ String.valueOf(primaryRecordId) }
                    );
                }
            } catch (Exception e) {
            }
        } else {
            primaryRecordLabel = 'GENERAL CONTEXT DATA:';
        }
        finalContextStrings.add(primaryRecordLabel);

        List<ContextDataBlock> sortedBlocks = new List<ContextDataBlock>(blocksToFormat.values());
        try {
            sortedBlocks.sort();
        } catch (Exception sortEx) {
        }

        Map<String, Integer> labelCollisionCounters = new Map<String, Integer>();
        Integer totalRecordCount = 0;
        for (ContextDataBlock block : sortedBlocks) {
            if (block.records == null || block.records.isEmpty())
                continue;

            totalRecordCount += block.records.size();
            String finalLabel = block.label;

            Integer count = labelCollisionCounters.containsKey(finalLabel.toLowerCase())
                ? labelCollisionCounters.get(finalLabel.toLowerCase())
                : 0;
            count++;
            labelCollisionCounters.put(finalLabel.toLowerCase(), count);
            if (count > 1) {
                finalLabel = finalLabel + ' (' + count + ')';
            }

            finalContextStrings.add('  --- ' + finalLabel + ' (' + block.records.size() + ' Record(s)) ---');

            List<String> formattedRecordStrings = new List<String>();
            Integer recordCounter = 0;
            for (SObject record : block.records) {
                recordCounter++;
                String formattedRecord = formatSingleRecord(record, truncationLength);
                if (String.isNotBlank(formattedRecord)) {
                    String recordPrefix = (block.records.size() > 1) ? '    ' + recordCounter + '. ' : '    ';

                    formattedRecordStrings.add(recordPrefix + formattedRecord.replace('\n', '\n' + recordPrefix));
                }
            }
            finalContextStrings.addAll(formattedRecordStrings);
        }

        if (finalContextStrings.size() <= 1) {
            return null;
        }

        String finalString = String.join(finalContextStrings, '\n');

        return finalString;
    }

    /**
     * @description Recursive function to process context sources for a given set of anchor IDs at a specific graph depth.
     * @param recordAnchors Map of Record ID -> SObjectType for Record Anchored sources. Null if processing User Anchored.
     * @param currentUserId The ID of the user making the request.
     * @param allAgentSources List of all *potentially* relevant sources for the agent.
     * @param currentDepth Current recursion depth.
     */
    private void processSourcesForAnchor(
        Map<Id, SObjectType> recordAnchors,
        Id currentUserId,
        List<ContextGraphSource__c> allAgentSources,
        Integer currentDepth
    ) {
        String processLogPrefix = LOG_PREFIX + 'processSources Lvl:' + currentDepth + ' ';

        if (currentDepth > MAX_GRAPH_DEPTH) {
            return;
        }

        if (allAgentSources == null || allAgentSources.isEmpty()) {
            return;
        }

        String anchorType = (recordAnchors == null || recordAnchors.isEmpty()) ? ANCHOR_USER : ANCHOR_RECORD;
        Set<Id> anchorIds = (anchorType == ANCHOR_USER) ? new Set<Id>{ currentUserId } : recordAnchors.keySet();

        if (anchorIds.isEmpty()) {
            return;
        }

        String idsString = String.join(new List<Id>(anchorIds), ', ');

        Map<Id, SObjectType> nextLevelAnchors = new Map<Id, SObjectType>();

        for (Id anchorId : anchorIds) {
            SObjectType anchorObjType = null;
            try {
                anchorObjType = (anchorType == ANCHOR_RECORD) ? recordAnchors?.get(anchorId) : User.SObjectType;

                if (
                    anchorType == ANCHOR_RECORD && (anchorObjType == null || anchorId.getSObjectType() != anchorObjType)
                ) {
                    continue;
                }
            } catch (Exception typeEx) {
                continue;
            }

            for (ContextGraphSource__c source : allAgentSources) {
                String sourceLogPrefix =
                    processLogPrefix +
                    ' Src:' +
                    source?.SourceDeveloperName__c +
                    ' Anchor:' +
                    anchorId +
                    ' ';

                if (!shouldProcessSource(source, anchorType, anchorObjType)) {
                    continue;
                }

                String visitKey = anchorId + ':' + source.SourceDeveloperName__c?.toLowerCase();
                if (visitedPaths.contains(visitKey)) {
                    continue;
                }
                visitedPaths.add(visitKey);

                List<SObject> resultsForThisSource = null;
                String implType = String.isNotBlank(source.ImplementationType__c)
                    ? source.ImplementationType__c
                    : IMPL_DECLARATIVE;

                try {
                    if (implType == IMPL_DECLARATIVE) {
                        resultsForThisSource = handleDeclarativeSource(
                            source,
                            anchorId,
                            anchorObjType,
                            nextLevelAnchors,
                            sourceLogPrefix
                        );
                    } else if (implType == IMPL_APEX) {
                        resultsForThisSource = handleApexSource(source, anchorId, currentUserId, sourceLogPrefix);
                    } else {
                    }

                    if (resultsForThisSource != null && !resultsForThisSource.isEmpty()) {
                        String blockKey = source.SourceDeveloperName__c.toLowerCase();

                        if (!this.aggregatedContextBlocks.containsKey(blockKey)) {
                            this.aggregatedContextBlocks.put(blockKey, new ContextDataBlock(source));
                        }
                        this.aggregatedContextBlocks.get(blockKey).records.addAll(resultsForThisSource);
                    } else {
                    }
                } catch (Exception ex) {
                    handleSourceProcessingError(ex, source, anchorId);
                }
            }
        }

        if (!nextLevelAnchors.isEmpty() && currentDepth < MAX_GRAPH_DEPTH) {
            Integer nextLevelSize = nextLevelAnchors.size();

            if (nextLevelSize > 100) {
            }

            processSourcesForAnchor(nextLevelAnchors, currentUserId, allAgentSources, currentDepth + 1);
        } else {
            String reason = nextLevelAnchors.isEmpty() ? 'no next anchors found' : 'max depth reached';
        }
    }

    /** Checks basic prerequisites for processing a source against the current anchor */
    private Boolean shouldProcessSource(
        ContextGraphSource__c source,
        String currentAnchorType,
        SObjectType currentAnchorObjType
    ) {
        if (source == null || !source.IsActive__c || source.SourceType__c != currentAnchorType) {
            return false;
        }

        if (currentAnchorType == ANCHOR_RECORD) {
            if (String.isBlank(source.StartingSObjectApiName__c) || currentAnchorObjType == null) {
                return false;
            }

            String sourceStartObj = source.StartingSObjectApiName__c.toLowerCase();
            String anchorObjName = currentAnchorObjType.getDescribe().getName().toLowerCase();
            if (sourceStartObj != anchorObjName) {
                return false;
            }
        }

        return true;
    }

    /**
     * @description Handles context gathering for a Declarative source.
     * @return List<SObject> results, or NULL if a fatal error occurs for this source path, or empty list if query runs but finds nothing/fails non-fatally.
     */
    private List<SObject> handleDeclarativeSource(
        ContextGraphSource__c source,
        Id anchorId,
        SObjectType anchorObjType,
        Map<Id, SObjectType> nextLevelAnchors,
        String logPrefix
    ) {
        if (source == null) {
            logSourceError(logPrefix, 'Source cannot be null', null);
            return null;
        }
        String linkType = source.LinkType__c ?? LINK_DIRECT;
        String detailApiName = source.LinkDetailApiName__c;
        String targetApiName = source.TargetSObjectApiName__c;
        String sourceType = source.SourceType__c;

        SObjectType targetSObjectType = ContextUtils.getSObjectType(targetApiName);
        if (targetSObjectType == null) {
            logSourceError(logPrefix, 'Runtime: Target SObject "' + targetApiName + '" inaccessible.', source);
            return null;
        }
        if (String.isBlank(source.TargetFieldSetName__c)) {
            logSourceError(logPrefix, 'Runtime: Target FieldSet Name is blank.', source);
            return null;
        }

        List<Id> targetIdsToQuery = null;
        Map<String, Id> parentIdFilterMap = new Map<String, Id>();
        Boolean pathDeterminationSuccess = true;

        try {
            if (sourceType == ANCHOR_USER) {
                String ownerField = 'OwnerId';

                if (!ContextUtils.isFieldFilterable(targetSObjectType, ownerField)) {
                    logSourceError(
                        logPrefix,
                        'Runtime (User Anchor): Cannot filter Target "' +
                            targetApiName +
                            '" by OwnerId (field not filterable/accessible).',
                        source
                    );
                    pathDeterminationSuccess = false;
                } else {
                    parentIdFilterMap.put(ownerField, anchorId);
                }

                if (linkType == LINK_PARENT || linkType == LINK_CHILD) {
                    logSourceError(
                        logPrefix,
                        'Config Warning (User Anchor): LinkType "' +
                            linkType +
                            '" is likely inappropriate for User Anchored sources. Ignoring link detail.',
                        source
                    );
                }
            } else if (sourceType == ANCHOR_RECORD) {
                if (linkType == LINK_DIRECT) {
                    if (anchorObjType != targetSObjectType) {
                        logSourceError(
                            logPrefix,
                            'Runtime Config Error: LinkType=Direct - Anchor (' +
                                anchorObjType.getDescribe().getName() +
                                ') must match Target (' +
                                targetSObjectType.getDescribe().getName() +
                                ').',
                            source
                        );
                        pathDeterminationSuccess = false;
                    } else {
                        targetIdsToQuery = new List<Id>{ anchorId };
                    }
                } else if (linkType == LINK_PARENT) {
                    if (String.isBlank(detailApiName)) {
                        logSourceError(logPrefix, 'Config Error: LinkType=Parent missing LinkDetail.', source);
                        pathDeterminationSuccess = false;
                    } else {
                        targetIdsToQuery = getParentLookupIds(anchorId, anchorObjType, detailApiName, logPrefix);
                        if (targetIdsToQuery == null) {
                            pathDeterminationSuccess = false;
                        } else if (targetIdsToQuery.isEmpty()) {
                            return new List<SObject>();
                        }
                    }
                } else if (linkType == LINK_CHILD) {
                    if (String.isBlank(detailApiName)) {
                        logSourceError(logPrefix, 'Config Error: LinkType=Child missing LinkDetail.', source);
                        pathDeterminationSuccess = false;
                    } else {
                        String parentLookupField = getParentLookupFieldForChildRel(
                            anchorObjType,
                            detailApiName,
                            targetSObjectType,
                            logPrefix
                        );
                        if (parentLookupField == null) {
                            logSourceError(
                                logPrefix,
                                'Runtime Error: Could not determine/access lookup field for Child Rel "' +
                                    detailApiName +
                                    '".',
                                source
                            );
                            pathDeterminationSuccess = false;
                        } else {
                            parentIdFilterMap.put(parentLookupField, anchorId);
                        }
                    }
                } else {
                    logSourceError(logPrefix, 'Unsupported LinkType for Record Anchor: ' + linkType, source);
                    pathDeterminationSuccess = false;
                }
            } else {
                logSourceError(logPrefix, 'Invalid SourceType encountered: ' + sourceType, source);
                pathDeterminationSuccess = false;
            }

            if (!pathDeterminationSuccess) {
                return new List<SObject>();
            }
        } catch (Exception pathEx) {
            logSourceError(logPrefix, 'Exception determining query path: ' + pathEx.getMessage(), source);

            return null;
        }

        ContextQueryBuilder.QueryDetails qd = null;
        List<SObject> results = new List<SObject>();
        try {
            qd = queryBuilder.buildDeclarativeQuery(source, targetIdsToQuery, parentIdFilterMap);
            if (qd.hasErrors) {
                logSourceError(logPrefix, 'Query Build failed: ' + qd.errorMessage, source);
                return null;
            }

            results = Database.queryWithBinds(qd.soqlQuery, qd.bindMap, AccessLevel.USER_MODE);
        } catch (Exception queryEx) {
            processQueryException(queryEx, qd?.soqlQuery ?? 'Query Not Built', logPrefix);
            return new List<SObject>();
        }

        if (sourceType == ANCHOR_RECORD && linkType != LINK_DIRECT && !results.isEmpty()) {
            try {
                SObjectType resType = targetSObjectType ?? ContextUtils.getSObjectType(targetApiName);
                if (resType != null) {
                    for (SObject record : results) {
                        nextLevelAnchors.put(record.Id, resType);
                    }
                }
            } catch (Exception anchorEx) {
                logSourceError(
                    logPrefix,
                    'Non-fatal error processing results for next level anchors: ' + anchorEx.getMessage(),
                    source
                );
            }
        }
        return results;
    }

    /**
     * @description Handles context gathering for an Apex source.
     * @return List<SObject> results, or NULL if a fatal error occurs.
     */
    private List<SObject> handleApexSource(ContextGraphSource__c source, Id anchorId, Id userId, String logPrefix) {
        String className = source.ProviderClassName__c;
        String providerConfigJson = source.ProviderConfiguration__c;

        if (String.isBlank(className)) {
            logError(logPrefix, 'Runtime Config Error: Apex Impl requires ProviderClassName. Skipping source.', source);
            return null;
        }

        try {
            IAgentContextProvider provider = getProviderInstance(className);

            Map<String, List<SObject>> providerMap = provider.getContext(anchorId, userId, providerConfigJson);

            List<SObject> providerResults = new List<SObject>();
            if (providerMap != null && !providerMap.isEmpty()) {
                for (String key : providerMap.keySet()) {
                    if (providerMap.get(key) != null && !providerMap.get(key).isEmpty()) {
                        providerResults.addAll(providerMap.get(key));
                    }
                }
            } else {
            }

            Integer limitConfig = (source.RecordLimit__c != null &&
                source.RecordLimit__c > 0)
                ? source.RecordLimit__c.intValue()
                : null;
            if (limitConfig != null && providerResults.size() > limitConfig) {
                while (providerResults.size() > limitConfig) {
                    providerResults.remove(providerResults.size() - 1);
                }
            }
            return providerResults;
        } catch (Exception e) {
            logError(logPrefix, 'Error executing Apex Provider "' + className + '": ' + e.getMessage(), source);

            return null;
        }
    }

    /** Safely retrieves SObjectType using instance cache, returns null on error */
    private SObjectType safeGetSObjectType(String apiName) {
        if (String.isBlank(apiName))
            return null;
        String lowerApiName = apiName.toLowerCase();
        if (!sObjectTypeCache.containsKey(lowerApiName)) {
            SObjectType objType = null;
            try {
                objType = Schema.getGlobalDescribe().get(lowerApiName);
            } catch (Exception e) {
            }
            sObjectTypeCache.put(lowerApiName, objType);
        }
        return sObjectTypeCache.get(lowerApiName);
    }

    /** Gets and caches the Field Map for an SObject type using instance cache */
    private Map<String, SObjectField> getAndCacheObjectFields(SObjectType sObjType) {
        if (sObjType == null)
            return new Map<String, SObjectField>();
        String typeName = sObjType.getDescribe().getName();
        if (!fieldDescribeCache.containsKey(typeName)) {
            Map<String, SObjectField> fieldMap = new Map<String, SObjectField>();
            try {
                fieldMap = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
            } catch (Exception e) {
            }
            fieldDescribeCache.put(typeName, fieldMap);
        }
        return fieldDescribeCache.get(typeName);
    }

    /** Helper to load Agent Definition via service */
    private AIAgentDefinition__c getAgentDefinition(Id agentDefId) {
        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefId);
            if (agentDef == null) {
                throw new ContextConfigurationException('Active Agent Definition not found for ID: ' + agentDefId);
            }
            return agentDef;
        } catch (Exception e) {
            throw new ContextConfigurationException(
                'Failed to load Agent Definition ' + agentDefId + ': ' + e.getMessage(),
                e
            );
        }
    }

    /** Fetches active, relevant ContextGraphSource__c records for the agent */
    private List<ContextGraphSource__c> getResolvedSourcesForAgent(Id agentDefId) {
        String resolveLogPrefix = LOG_PREFIX + 'getResolvedSources Agent:' + agentDefId + ' ';
        List<ContextGraphSource__c> resolvedSources = new List<ContextGraphSource__c>();
        Set<String> sourceNamesNeeded = new Set<String>();
        Set<String> recipeNamesNeeded = new Set<String>();

        try {
            List<AgentContextBinding__c> bindings = [
                SELECT ContextName__c, BindingType__c
                FROM AgentContextBinding__c
                WHERE AIAgentDefinition__c = :agentDefId AND IsActive__c = TRUE
                ORDER BY BindingOrder__c ASC NULLS LAST
            ];

            if (bindings.isEmpty()) {
                return resolvedSources;
            }

            for (AgentContextBinding__c binding : bindings) {
                if (binding.BindingType__c == 'Source') {
                    sourceNamesNeeded.add(binding.ContextName__c);
                } else if (binding.BindingType__c == 'Recipe') {
                    recipeNamesNeeded.add(binding.ContextName__c);
                }
            }
            if (sourceNamesNeeded.isEmpty() && recipeNamesNeeded.isEmpty()) {
                return resolvedSources;
            }

            List<ContextGraphSource__c> candidateSources = [
                SELECT
                    Id,
                    SourceDeveloperName__c,
                    Description__c,
                    SourceType__c,
                    StartingSObjectApiName__c,
                    LinkType__c,
                    LinkDetailApiName__c,
                    ImplementationType__c,
                    ProviderClassName__c,
                    ProviderConfiguration__c,
                    TargetSObjectApiName__c,
                    TargetFieldSetName__c,
                    FilterBy__c,
                    OrderBy__c,
                    RecordLimit__c,
                    ContextLabel__c,
                    RecipeName__c,
                    ExecutionOrder__c,
                    IsActive__c
                FROM ContextGraphSource__c
                WHERE
                    IsActive__c = TRUE
                    AND (SourceDeveloperName__c IN :sourceNamesNeeded
                    OR RecipeName__c IN :recipeNamesNeeded)
                ORDER BY RecipeName__c, ExecutionOrder__c ASC NULLS LAST, SourceDeveloperName__c ASC
            ];

            if (candidateSources.isEmpty()) {
                return resolvedSources;
            }

            Map<String, ContextGraphSource__c> nameToSourceMap = new Map<String, ContextGraphSource__c>();
            Map<String, List<ContextGraphSource__c>> recipeToSourcesMap = new Map<String, List<ContextGraphSource__c>>();
            for (ContextGraphSource__c src : candidateSources) {
                if (String.isNotBlank(src.SourceDeveloperName__c)) {
                    nameToSourceMap.put(src.SourceDeveloperName__c.toLowerCase(), src);
                }
                if (String.isNotBlank(src.RecipeName__c)) {
                    String recipeKey = src.RecipeName__c.toLowerCase();
                    if (!recipeToSourcesMap.containsKey(recipeKey)) {
                        recipeToSourcesMap.put(recipeKey, new List<ContextGraphSource__c>());
                    }
                    recipeToSourcesMap.get(recipeKey).add(src);
                }
            }

            Set<Id> addedSourceIds = new Set<Id>();
            for (AgentContextBinding__c binding : bindings) {
                String contextNameLower = binding.ContextName__c.toLowerCase();
                String contextNameOriginal = binding.ContextName__c;

                if (binding.BindingType__c == 'Source' && sourceNamesNeeded.contains(contextNameOriginal)) {
                    ContextGraphSource__c directSource = nameToSourceMap.get(contextNameLower);
                    if (directSource != null && !addedSourceIds.contains(directSource.Id)) {
                        resolvedSources.add(directSource);
                        addedSourceIds.add(directSource.Id);
                    } else if (directSource == null) {
                    }
                } else if (binding.BindingType__c == 'Recipe' && recipeNamesNeeded.contains(contextNameOriginal)) {
                    List<ContextGraphSource__c> sourcesInRecipe = recipeToSourcesMap.get(contextNameLower);
                    if (sourcesInRecipe != null && !sourcesInRecipe.isEmpty()) {
                        for (ContextGraphSource__c recipeSrc : sourcesInRecipe) {
                            if (!addedSourceIds.contains(recipeSrc.Id)) {
                                resolvedSources.add(recipeSrc);
                                addedSourceIds.add(recipeSrc.Id);
                            }
                        }
                    } else {
                    }
                }
            }
        } catch (Exception e) {
            throw new ContextConfigurationException('Error resolving context sources for Agent ' + agentDefId, e);
        }

        return resolvedSources;
    }

    /** Formats the map of aggregated blocks into the final structure for the public API */
    private Map<String, List<SObject>> formatGatheredBlocks(Map<String, ContextDataBlock> gatheredBlocks) {
        String formatLogPrefix = LOG_PREFIX + 'formatGatheredBlocks ';
        Map<String, List<SObject>> finalContext = new Map<String, List<SObject>>();
        if (gatheredBlocks == null || gatheredBlocks.isEmpty()) {
            return finalContext;
        }

        List<ContextDataBlock> sortedBlocks = new List<ContextDataBlock>(gatheredBlocks.values());
        try {
            sortedBlocks.sort();
        } catch (Exception sortEx) {
        }

        Map<String, Integer> labelCollisionCounters = new Map<String, Integer>();
        for (ContextDataBlock block : sortedBlocks) {
            if (block.records != null && !block.records.isEmpty()) {
                String finalLabel = block.label;
                Integer count = labelCollisionCounters.get(finalLabel.toLowerCase());
                if (count == null)
                    count = 0;
                count++;
                labelCollisionCounters.put(finalLabel.toLowerCase(), count);

                if (count > 1) {
                    finalLabel = finalLabel + ' (' + count + ')';
                }

                finalContext.put(finalLabel, block.records);
            }
        }

        return finalContext;
    }

    /** Formats a single SObject record into a readable string using describe info */
    private String formatSingleRecord(SObject record, Integer truncationLength) {
        if (record == null)
            return '';
        truncationLength = (truncationLength != null && truncationLength > 0) ? truncationLength : 5000;
        List<String> parts = new List<String>();
        Map<String, Object> fieldMap = null;
        try {
            fieldMap = record.getPopulatedFieldsAsMap();
        } catch (Exception e) {
            return '[Error formatting record: ' +
                record.getSObjectType()?.getDescribe()?.getName() +
                ' ' +
                record.Id +
                ']';
        }

        if (fieldMap == null || fieldMap.isEmpty()) {
            return '[Record has no populated fields]';
        }

        Map<String, Schema.SObjectField> describeFieldMap = getAndCacheObjectFields(record.getSObjectType());

        List<String> fieldApiNames = new List<String>(fieldMap.keySet());
        try {
            fieldApiNames.sort(new FieldSortComparator());
        } catch (Exception e) {
        }

        for (String fieldApiName : fieldApiNames) {
            if (
                fieldApiName.equalsIgnoreCase('Id') ||
                fieldApiName.equalsIgnoreCase('LastModifiedDate') ||
                fieldApiName.equalsIgnoreCase('LastModifiedById') ||
                fieldApiName.equalsIgnoreCase('CreatedDate') ||
                fieldApiName.equalsIgnoreCase('CreatedById') ||
                fieldApiName.equalsIgnoreCase('SystemModstamp') ||
                fieldApiName.equalsIgnoreCase('IsDeleted')
            ) {
                continue;
            }

            Object value = fieldMap.get(fieldApiName);

            if (value != null && !(value instanceof String && String.isBlank((String) value))) {
                String formattedValue = String.valueOf(value);

                if (value instanceof String && formattedValue.length() > truncationLength) {
                    formattedValue = formattedValue.left(truncationLength - 18) + '... [truncated]';
                }

                String fieldLabel = fieldApiName;
                if (describeFieldMap.containsKey(fieldApiName.toLowerCase())) {
                    try {
                        fieldLabel = describeFieldMap.get(fieldApiName.toLowerCase()).getDescribe().getLabel();
                    } catch (Exception e) {
                        /* Ignore label describe error */
                    }
                }
                parts.add(fieldLabel + ': ' + formattedValue);
            }
        }

        return String.join(parts, '\n');
    }

    /** Wrapper for getParentLookupIds returning null on error */
    private static List<Id> getParentLookupIds(
        Id anchorId,
        SObjectType anchorObjType,
        String lookupFieldApiName,
        String logPrefix
    ) {
        if (anchorObjType == null || String.isBlank(lookupFieldApiName)) {
            logSourceError(logPrefix, 'getParentLookupIds invalid input', null);

            return new List<Id>();
        }

        if (!ContextUtils.isFieldAccessible(anchorObjType, lookupFieldApiName)) {
            logSourceError(logPrefix, 'Parent lookup field "' + lookupFieldApiName + '" not accessible.', null);
            return new List<Id>();
        }

        SObject recordResult = null;
        try {
            String query = String.format(
                'SELECT {0} FROM {1} WHERE Id = :anchorId WITH USER_MODE LIMIT 1',
                new List<String>{ lookupFieldApiName, anchorObjType.getDescribe().getName() }
            );

            List<SObject> parentRefs = Database.query(query);

            if (!parentRefs.isEmpty()) {
                recordResult = parentRefs[0];
                Object lookupValue = recordResult.get(lookupFieldApiName);

                if (lookupValue instanceof Id) {
                    return new List<Id>{ (Id) lookupValue };
                } else {
                    return new List<Id>();
                }
            } else {
                return new List<Id>();
            }
        } catch (Exception e) {
            processQueryException(e, 'Parent Lookup: ' + lookupFieldApiName, logPrefix);

            return new List<Id>();
        }
    }

    /** Wrapper for getParentLookupFieldForChildRel returning null on error/inaccessible */
    private static String getParentLookupFieldForChildRel(
        SObjectType parentType,
        String childRelName,
        SObjectType childType,
        String logPrefix
    ) {
        if (parentType == null || childType == null || String.isBlank(childRelName)) {
            return null;
        }

        try {
            for (Schema.ChildRelationship cr : parentType.getDescribe().getChildRelationships()) {
                if (cr.getChildSObject() == childType && childRelName.equalsIgnoreCase(cr.getRelationshipName())) {
                    Schema.SObjectField fieldOnChild = cr.getField();

                    if (
                        fieldOnChild != null &&
                        ContextUtils.isFieldAccessible(childType, fieldOnChild.getDescribe().getName())
                    ) {
                        String foundFieldName = fieldOnChild.getDescribe().getName();

                        return foundFieldName;
                    } else if (fieldOnChild != null) {
                        logSourceError(
                            logPrefix,
                            'Child Rel "' +
                                childRelName +
                                '" field "' +
                                fieldOnChild.getDescribe().getName() +
                                '" inaccessible.',
                            null
                        );
                        return null;
                    } else {
                        logSourceError(
                            logPrefix,
                            'Child Rel "' + childRelName + '" metadata inconsistency - field is null.',
                            null
                        );
                        return null;
                    }
                }
            }

            logSourceError(
                logPrefix,
                'Child Relationship "' +
                    childRelName +
                    '" not found between Parent "' +
                    parentType.getDescribe().getName() +
                    '" and Child "' +
                    childType.getDescribe().getName() +
                    '".',
                null
            );
        } catch (Exception e) {
            logSourceError(
                logPrefix,
                'Error describing child relationships for Parent "' +
                    parentType.getDescribe().getName() +
                    '": ' +
                    e.getMessage(),
                null
            );
        }
        return null;
    }

    /** Instantiates Apex provider */
    private IAgentContextProvider getProviderInstance(String className) {
        try {
            Type providerType = Type.forName(className);
            if (providerType == null) {
                throw new ContextConfigurationException('Apex Provider class not found: ' + className);
            }
            Object instance = providerType.newInstance();
            if (!(instance instanceof IAgentContextProvider)) {
                throw new ContextConfigurationException(
                    'Class ' + className + ' does not implement IAgentContextProvider.'
                );
            }
            return (IAgentContextProvider) instance;
        } catch (Exception e) {
            throw new ContextConfigurationException(
                'Failed to instantiate Apex provider ' + className + ': ' + e.getMessage(),
                e
            );
        }
    }

    /** Logs gathering error (no longer throws) */
    private void handleGatheringError(Exception e) {
        if (
            e instanceof ContextConfigurationException ||
            e instanceof ContextGatheringException ||
            e instanceof ContextProviderException
        ) {
            /* Already specific types */
        } else {
        }
    }

    /** Logs source processing error */
    private void handleSourceProcessingError(Exception ex, ContextGraphSource__c source, Id anchorId) {
        logError(
            LOG_PREFIX + ' HandleSrcErr',
            'Failure processing Source="' +
                source?.SourceDeveloperName__c +
                '", Anchor=' +
                anchorId +
                '. Error: ' +
                ex.getMessage(),
            source
        );
        if (
            !(ex instanceof ContextConfigurationException ||
            ex instanceof ContextProviderException ||
            ex instanceof QueryException ||
            ex.getMessage().contains('AccessDecision'))
        ) {
        }
    }

    /** Consistent error logging helper */
    private static void logError(String prefix, String message, ContextGraphSource__c source) {
    }

    /** Process query execution exceptions helper */
    private static void processQueryException(Exception ex, String soql, String logPrefix) {
        if (
            ex instanceof QueryException &&
            (ex.getMessage().contains('insufficient access right') ||
            ex.getMessage().contains('permission') ||
            ex.getMessage().contains('security enforced'))
        ) {
        } else {
        }
    }

    private static void logSourceError(String prefix, String message, ContextGraphSource__c source) {
        if (source?.Id != null) {
        }
    }

    public class ContextConfigurationException extends AIAgentException {
    }
    public class ContextGatheringException extends AIAgentException {
    }
    public class ContextProviderException extends AIAgentException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }
}
