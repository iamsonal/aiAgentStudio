/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Resolves relevant context records for an execution by combining stored references with provider-based enrichment.
 */
public inherited sharing class ContextResolverService {
    public class ProviderDefinition {
        public String providerKey { get; private set; }
        public String apexClassName { get; private set; }
        public String defaultScope { get; private set; }
        public Boolean supportsFieldSetProjection { get; private set; }
        public Boolean supportsProjectionDefinition { get; private set; }
        public Boolean isActive { get; private set; }
        public String description { get; private set; }

        public ProviderDefinition(ContextProviderDefinition__mdt record) {
            this.providerKey = record.ProviderKey__c;
            this.apexClassName = record.ApexClassName__c;
            this.defaultScope = record.DefaultScope__c;
            this.supportsFieldSetProjection = record.SupportsFieldSetProjection__c;
            this.supportsProjectionDefinition = record.SupportsProjectionDefinition__c;
            this.isActive = record.IsActive__c;
            this.description = record.Description__c;
        }
    }

    public class ProjectionDefinition {
        public String projectionKey { get; private set; }
        public String rootObjectApiName { get; private set; }
        public String fieldSetName { get; private set; }
        public Integer recordLimit { get; private set; }
        public Boolean excludeIdFields { get; private set; }
        public Boolean includeRecordUrls { get; private set; }
        public String description { get; private set; }

        public ProjectionDefinition(ContextProjectionDefinition__mdt record) {
            this.projectionKey = record.ProjectionKey__c;
            this.rootObjectApiName = record.RootObjectApiName__c;
            this.fieldSetName = record.FieldSetName__c;
            this.recordLimit = record.RecordLimit__c == null ? null : record.RecordLimit__c.intValue();
            this.excludeIdFields = record.ExcludeIdFields__c;
            this.includeRecordUrls = record.IncludeRecordUrls__c;
            this.description = record.Description__c;
        }
    }

    public class ResolvedContextBlock {
        public AgentContextConfig__c config { get; private set; }
        public List<SObject> records { get; private set; }
        public String providerKey { get; private set; }
        public String sectionName { get; private set; }
        public ProjectionDefinition projectionDefinition { get; private set; }

        public ResolvedContextBlock(
            AgentContextConfig__c configRecord,
            List<SObject> resolvedRecords,
            String resolvedProviderKey,
            String resolvedSectionName,
            ProjectionDefinition projectionDef
        ) {
            this.config = configRecord;
            this.records = resolvedRecords == null ? new List<SObject>() : resolvedRecords;
            this.providerKey = resolvedProviderKey;
            this.sectionName = resolvedSectionName;
            this.projectionDefinition = projectionDef;
        }
    }

    public class ResolutionResult {
        public List<SObject> recordsToLoad { get; private set; }
        public List<ResolvedContextBlock> contextBlocks { get; private set; }
        public List<String> warnings { get; private set; }
        public String longTermContextSummary { get; private set; }

        public ResolutionResult() {
            this.recordsToLoad = new List<SObject>();
            this.contextBlocks = new List<ResolvedContextBlock>();
            this.warnings = new List<String>();
            this.longTermContextSummary = '';
        }

        public void addBlock(ResolvedContextBlock block) {
            if (block == null || block.records == null || block.records.isEmpty()) {
                return;
            }
            this.contextBlocks.add(block);
            this.recordsToLoad.addAll(block.records);
        }

        public void addWarning(String warningMessage) {
            if (String.isNotBlank(warningMessage)) {
                this.warnings.add(warningMessage);
            }
        }
    }

    public class ResolutionException extends AIAgentException {
    }

    private final ContextManagerService contextReferences;
    private final Map<String, IAgentContextProvider> providerCache = new Map<String, IAgentContextProvider>();
    @TestVisible
    private static Map<String, IAgentContextProvider> testProviderOverrides = new Map<String, IAgentContextProvider>();

    public ContextResolverService() {
        this(new ContextManagerService());
    }

    @TestVisible
    private ContextResolverService(ContextManagerService referenceService) {
        this.contextReferences = referenceService;
    }

    @TestVisible
    static void setTestProviderOverride(String providerKey, IAgentContextProvider provider) {
        if (String.isBlank(providerKey)) {
            return;
        }
        if (provider == null) {
            testProviderOverrides.remove(providerKey);
            return;
        }
        testProviderOverrides.put(providerKey, provider);
    }

    @TestVisible
    static void clearTestProviderOverrides() {
        testProviderOverrides.clear();
    }

    public ResolutionResult resolve(Id executionId, Id agentDefinitionId, Id userId, Id immediatePageRecordId, Integer currentTurn) {
        String logPrefix = '[CtxResolverSvc Exec:' + executionId + '] ';
        ResolutionResult result = new ResolutionResult();
        String activeChannel = RuntimeRegistryService.getInteractionChannel(null, executionId);

        List<AgentContextConfig__c> configs = queryApplicableConfigs(agentDefinitionId, logPrefix);
        if (configs.isEmpty()) {
            System.debug(LoggingLevel.WARN, logPrefix + 'No active context provider configs found for agent definition.');
            return result;
        }

        Map<String, ProviderDefinition> providerDefinitions = getProviderDefinitions(collectProviderKeys(configs));
        Map<String, ProjectionDefinition> projectionDefinitions = getProjectionDefinitions(collectProjectionKeys(configs));

        Set<String> seenRecordIds = new Set<String>();
        for (AgentContextConfig__c config : configs) {
            if (!isChannelApplicable(config, activeChannel)) {
                handleFailure(
                    config,
                    'Context binding "' + config.AdminLabel__c + '" is restricted to specific channels but no matching runtime channel was available.',
                    null,
                    result
                );
                continue;
            }

            ProviderDefinition providerDef = providerDefinitions.get(config.ProviderDefinition__c);
            if (providerDef == null || providerDef.isActive != true || String.isBlank(providerDef.apexClassName)) {
                handleFailure(config, 'No active provider definition was found for "' + config.ProviderDefinition__c + '".', null, result);
                continue;
            }

            ProjectionDefinition projectionDef = projectionDefinitions.get(config.ProjectionDefinition__c);

            try {
                Set<Id> anchorIds = resolveAnchorIds(executionId, userId, immediatePageRecordId, config);
                if ('Record'.equalsIgnoreCase(config.Scope__c) && anchorIds.isEmpty()) {
                    continue;
                }

                List<SObject> providerRecords = invokeProvider(config, providerDef, anchorIds, userId, logPrefix);
                providerRecords = applyOverlapMode(providerRecords, config.OverlapMode__c, seenRecordIds);
                if (providerRecords.isEmpty()) {
                    continue;
                }

                String sectionName = String.isNotBlank(config.OutputSectionName__c) ? config.OutputSectionName__c : config.AdminLabel__c;
                ResolvedContextBlock block = new ResolvedContextBlock(config, providerRecords, providerDef.providerKey, sectionName, projectionDef);
                result.addBlock(block);
            } catch (Exception e) {
                handleFailure(config, 'Context binding "' + config.AdminLabel__c + '" failed: ' + e.getMessage(), e, result);
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Context resolution complete. Total records loaded: ' + result.recordsToLoad.size());
        return result;
    }

    private Set<String> collectProviderKeys(List<AgentContextConfig__c> configs) {
        Set<String> providerKeys = new Set<String>();
        for (AgentContextConfig__c config : configs) {
            if (String.isNotBlank(config.ProviderDefinition__c)) {
                providerKeys.add(config.ProviderDefinition__c);
            }
        }
        return providerKeys;
    }

    private Set<String> collectProjectionKeys(List<AgentContextConfig__c> configs) {
        Set<String> projectionKeys = new Set<String>();
        for (AgentContextConfig__c config : configs) {
            if (String.isNotBlank(config.ProjectionDefinition__c)) {
                projectionKeys.add(config.ProjectionDefinition__c);
            }
        }
        return projectionKeys;
    }

    private Map<String, ProviderDefinition> getProviderDefinitions(Set<String> providerKeys) {
        Map<String, ProviderDefinition> definitionsByKey = new Map<String, ProviderDefinition>();
        if (providerKeys == null || providerKeys.isEmpty()) {
            return definitionsByKey;
        }

        for (ContextProviderDefinition__mdt record : [
            SELECT
                ProviderKey__c,
                ApexClassName__c,
                DefaultScope__c,
                SupportsFieldSetProjection__c,
                SupportsProjectionDefinition__c,
                IsActive__c,
                Description__c
            FROM ContextProviderDefinition__mdt
            WHERE ProviderKey__c IN :providerKeys
        ]) {
            definitionsByKey.put(record.ProviderKey__c, new ProviderDefinition(record));
        }
        return definitionsByKey;
    }

    private Map<String, ProjectionDefinition> getProjectionDefinitions(Set<String> projectionKeys) {
        Map<String, ProjectionDefinition> definitionsByKey = new Map<String, ProjectionDefinition>();
        if (projectionKeys == null || projectionKeys.isEmpty()) {
            return definitionsByKey;
        }

        for (ContextProjectionDefinition__mdt record : [
            SELECT ProjectionKey__c, RootObjectApiName__c, FieldSetName__c, RecordLimit__c, ExcludeIdFields__c, IncludeRecordUrls__c, Description__c
            FROM ContextProjectionDefinition__mdt
            WHERE ProjectionKey__c IN :projectionKeys
        ]) {
            definitionsByKey.put(record.ProjectionKey__c, new ProjectionDefinition(record));
        }
        return definitionsByKey;
    }

    private Boolean isChannelApplicable(AgentContextConfig__c config, String activeChannel) {
        if (String.isBlank(config.ApplicableChannels__c)) {
            return true;
        }
        if (String.isBlank(activeChannel)) {
            return false;
        }

        String normalizedChannels = config.ApplicableChannels__c.toLowerCase().replaceAll('\\s', '').replace(';', ',');
        return normalizedChannels.split(',').contains(activeChannel.toLowerCase());
    }

    private Set<Id> resolveAnchorIds(Id executionId, Id userId, Id immediatePageRecordId, AgentContextConfig__c config) {
        Set<Id> anchorIds = new Set<Id>();
        String scope = String.isBlank(config.Scope__c) ? 'Record' : config.Scope__c;

        if ('Record'.equalsIgnoreCase(scope)) {
            anchorIds.addAll(gatherRecordAnchors(executionId, immediatePageRecordId, config));
        } else if ('User'.equalsIgnoreCase(scope)) {
            if (userId != null) {
                anchorIds.add(userId);
            }
        } else if ('Session'.equalsIgnoreCase(scope)) {
            Id sessionId = resolveSessionId(executionId);
            if (sessionId != null) {
                anchorIds.add(sessionId);
            }
        }

        return anchorIds;
    }

    private Set<Id> gatherRecordAnchors(Id executionId, Id immediatePageRecordId, AgentContextConfig__c config) {
        Set<Id> relevantIds = new Set<Id>();
        if (immediatePageRecordId != null) {
            relevantIds.add(immediatePageRecordId);
        }

        String freshnessPolicy = String.isBlank(config.FreshnessPolicy__c) ? 'Current Only' : config.FreshnessPolicy__c;
        if (!'Current Only'.equalsIgnoreCase(freshnessPolicy)) {
            relevantIds.addAll(this.contextReferences.getRelevantRecordIds(executionId, freshnessPolicy));
        }

        return filterAnchorsByApplicableObjects(relevantIds, config.ApplicableObjects__c);
    }

    private Set<Id> filterAnchorsByApplicableObjects(Set<Id> anchorIds, String applicableObjects) {
        if (anchorIds == null || anchorIds.isEmpty() || String.isBlank(applicableObjects)) {
            return anchorIds == null ? new Set<Id>() : anchorIds;
        }

        Set<String> allowedObjectNames = new Set<String>();
        for (String objectName : applicableObjects.split(';')) {
            if (String.isNotBlank(objectName)) {
                allowedObjectNames.add(objectName.trim().toLowerCase());
            }
        }

        Set<Id> filteredIds = new Set<Id>();
        for (Id anchorId : anchorIds) {
            if (anchorId == null) {
                continue;
            }
            String objectName = anchorId.getSObjectType().getDescribe().getName().toLowerCase();
            if (allowedObjectNames.contains(objectName)) {
                filteredIds.add(anchorId);
            }
        }
        return filteredIds;
    }

    private List<SObject> invokeProvider(AgentContextConfig__c config, ProviderDefinition providerDef, Set<Id> anchorIds, Id userId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Invoking provider: ' + providerDef.providerKey + ' | Anchor count: ' + anchorIds.size());
        IAgentContextProvider provider = getProviderInstance(providerDef);
        Map<String, List<SObject>> providerResult = provider.getContext(anchorIds, userId, config.ProviderConfigJson__c);
        List<SObject> records = new List<SObject>();
        if (providerResult != null) {
            for (List<SObject> bucket : providerResult.values()) {
                if (bucket != null) {
                    records.addAll(bucket);
                }
            }
        }
        return records;
    }

    private IAgentContextProvider getProviderInstance(ProviderDefinition providerDef) {
        if (testProviderOverrides.containsKey(providerDef.providerKey)) {
            return testProviderOverrides.get(providerDef.providerKey);
        }
        if (testProviderOverrides.containsKey(providerDef.apexClassName)) {
            return testProviderOverrides.get(providerDef.apexClassName);
        }

        if (!providerCache.containsKey(providerDef.providerKey)) {
            Type providerType = Type.forName(providerDef.apexClassName);
            if (providerType == null) {
                throw new ResolutionException('Provider class not found: ' + providerDef.apexClassName);
            }
            Object instance = providerType.newInstance();
            if (!(instance instanceof IAgentContextProvider)) {
                throw new ResolutionException('Class ' + providerDef.apexClassName + ' does not implement IAgentContextProvider.');
            }
            providerCache.put(providerDef.providerKey, (IAgentContextProvider) instance);
        }
        return providerCache.get(providerDef.providerKey);
    }

    private List<SObject> applyOverlapMode(List<SObject> providerRecords, String overlapMode, Set<String> seenRecordIds) {
        List<SObject> filteredRecords = new List<SObject>();
        if (providerRecords == null || providerRecords.isEmpty()) {
            return filteredRecords;
        }

        Set<String> localIds = new Set<String>();
        for (SObject record : providerRecords) {
            String recordKey = getRecordKey(record);
            if ('Suppress Duplicates'.equalsIgnoreCase(overlapMode) && String.isNotBlank(recordKey) && localIds.contains(recordKey)) {
                continue;
            }
            if ('Prefer Highest Priority'.equalsIgnoreCase(overlapMode) && String.isNotBlank(recordKey) && seenRecordIds.contains(recordKey)) {
                continue;
            }

            filteredRecords.add(record);
            if (String.isNotBlank(recordKey)) {
                localIds.add(recordKey);
                seenRecordIds.add(recordKey);
            }
        }
        return filteredRecords;
    }

    private String getRecordKey(SObject record) {
        if (record == null) {
            return null;
        }
        try {
            Object recordId = record.get('Id');
            return recordId == null ? null : String.valueOf(recordId);
        } catch (Exception e) {
            return null;
        }
    }

    private void handleFailure(AgentContextConfig__c config, String message, Exception cause, ResolutionResult result) {
        System.debug(LoggingLevel.ERROR, '[ContextResolverService] ' + message);
        String failureMode = String.isBlank(config.FailureMode__c) ? 'Skip On Error' : config.FailureMode__c;
        if ('Warn'.equalsIgnoreCase(failureMode)) {
            result.addWarning(message);
            return;
        }
        if ('Fail Resolution'.equalsIgnoreCase(failureMode)) {
            if (cause == null) {
                throw new ResolutionException(message);
            }
            throw new ResolutionException(message, cause);
        }
    }

    private Id resolveSessionId(Id executionId) {
        List<AgentExecution__c> executions = [
            SELECT InteractionSession__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        return executions.isEmpty() ? null : executions[0].InteractionSession__c;
    }

    private List<AgentContextConfig__c> queryApplicableConfigs(Id agentDefinitionId, String logPrefix) {
        try {
            return [
                SELECT
                    Id,
                    Name,
                    AIAgentDefinition__c,
                    AdminLabel__c,
                    ApplicableChannels__c,
                    ApplicableObjects__c,
                    FailureMode__c,
                    FieldSetName__c,
                    FreshnessPolicy__c,
                    IsActive__c,
                    OutputSectionName__c,
                    OverlapMode__c,
                    Priority__c,
                    ProjectionDefinition__c,
                    ProjectionMode__c,
                    ProviderConfigJson__c,
                    ProviderDefinition__c,
                    RecordLimit__c,
                    Scope__c
                FROM AgentContextConfig__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE
                ORDER BY Priority__c ASC, CreatedDate ASC
                LIMIT 50
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to query AgentContextConfig__c: ' + e.getMessage());
            throw new ResolutionException('Failed to query AgentContextConfig__c: ' + e.getMessage(), e);
        }
    }
}
