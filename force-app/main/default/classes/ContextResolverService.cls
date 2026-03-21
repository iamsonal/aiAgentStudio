/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Resolves relevant context records for an execution by loading the
 * configured context definition for each active agent binding.
 */
public inherited sharing class ContextResolverService {
    public class ContextDefinition {
        public String contextKey { get; private set; }
        public String definitionMode { get; private set; }
        public String defaultScope { get; private set; }
        public String apexClassName { get; private set; }
        public String rootObjectApiName { get; private set; }
        public String fieldSetName { get; private set; }
        public Integer recordLimit { get; private set; }
        public Boolean excludeIdFields { get; private set; }
        public Boolean includeRecordUrls { get; private set; }
        public Boolean isActive { get; private set; }
        public String description { get; private set; }

        public ContextDefinition(ContextDefinition__mdt record) {
            this.contextKey = record.ContextKey__c;
            this.definitionMode = record.DefinitionMode__c;
            this.defaultScope = record.DefaultScope__c;
            this.apexClassName = record.ApexClassName__c;
            this.rootObjectApiName = record.RootObjectApiName__c;
            this.fieldSetName = record.FieldSetName__c;
            this.recordLimit = record.RecordLimit__c == null ? null : record.RecordLimit__c.intValue();
            this.excludeIdFields = record.ExcludeIdFields__c;
            this.includeRecordUrls = record.IncludeRecordUrls__c;
            this.isActive = record.IsActive__c;
            this.description = record.Description__c;
        }
    }

    public class ResolvedContextBlock {
        public AgentContextConfig__c config { get; private set; }
        public List<SObject> records { get; private set; }
        public String contextKey { get; private set; }
        public String sectionName { get; private set; }
        public ContextDefinition contextDefinition { get; private set; }

        public ResolvedContextBlock(
            AgentContextConfig__c configRecord,
            List<SObject> resolvedRecords,
            String resolvedContextKey,
            String resolvedSectionName,
            ContextDefinition definitionRecord
        ) {
            this.config = configRecord;
            this.records = resolvedRecords == null ? new List<SObject>() : resolvedRecords;
            this.contextKey = resolvedContextKey;
            this.sectionName = resolvedSectionName;
            this.contextDefinition = definitionRecord;
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

    private final Map<String, IAgentContextProvider> providerCache = new Map<String, IAgentContextProvider>();
    @TestVisible
    private static Map<String, IAgentContextProvider> testProviderOverrides = new Map<String, IAgentContextProvider>();

    public ContextResolverService() {
    }

    @TestVisible
    static void setTestProviderOverride(String contextKey, IAgentContextProvider provider) {
        if (String.isBlank(contextKey)) {
            return;
        }
        if (provider == null) {
            testProviderOverrides.remove(contextKey);
            return;
        }
        testProviderOverrides.put(contextKey, provider);
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

        Map<String, ContextDefinition> contextDefinitions = getContextDefinitions(collectContextKeys(configs));
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

            ContextDefinition contextDefinition = contextDefinitions.get(config.ContextDefinition__c);
            if (contextDefinition == null || contextDefinition.isActive != true) {
                handleFailure(config, 'No active context definition was found for "' + config.ContextDefinition__c + '".', null, result);
                continue;
            }

            try {
                validateContextDefinition(config, contextDefinition);

                Set<Id> anchorIds = resolveAnchorIds(executionId, userId, immediatePageRecordId, contextDefinition.defaultScope);
                if (!'Global'.equalsIgnoreCase(contextDefinition.defaultScope) && anchorIds.isEmpty()) {
                    continue;
                }

                List<SObject> resolvedRecords = resolveContextRecords(config, contextDefinition, anchorIds, userId, logPrefix);
                if (resolvedRecords.isEmpty()) {
                    continue;
                }

                String sectionName = config.AdminLabel__c;
                ResolvedContextBlock block = new ResolvedContextBlock(config, resolvedRecords, contextDefinition.contextKey, sectionName, contextDefinition);
                result.addBlock(block);
            } catch (Exception e) {
                handleFailure(config, 'Context binding "' + config.AdminLabel__c + '" failed: ' + e.getMessage(), e, result);
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Context resolution complete. Total records loaded: ' + result.recordsToLoad.size());
        return result;
    }

    private Set<String> collectContextKeys(List<AgentContextConfig__c> configs) {
        Set<String> contextKeys = new Set<String>();
        for (AgentContextConfig__c config : configs) {
            if (String.isNotBlank(config.ContextDefinition__c)) {
                contextKeys.add(config.ContextDefinition__c);
            }
        }
        return contextKeys;
    }

    private Map<String, ContextDefinition> getContextDefinitions(Set<String> contextKeys) {
        Map<String, ContextDefinition> definitionsByKey = new Map<String, ContextDefinition>();
        if (contextKeys == null || contextKeys.isEmpty()) {
            return definitionsByKey;
        }

        for (ContextDefinition__mdt record : [
            SELECT
                ContextKey__c,
                DefinitionMode__c,
                DefaultScope__c,
                ApexClassName__c,
                RootObjectApiName__c,
                FieldSetName__c,
                RecordLimit__c,
                ExcludeIdFields__c,
                IncludeRecordUrls__c,
                IsActive__c,
                Description__c
            FROM ContextDefinition__mdt
            WHERE ContextKey__c IN :contextKeys
        ]) {
            definitionsByKey.put(record.ContextKey__c, new ContextDefinition(record));
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

    private Set<Id> resolveAnchorIds(Id executionId, Id userId, Id immediatePageRecordId, String scope) {
        Set<Id> anchorIds = new Set<Id>();

        if ('Record'.equalsIgnoreCase(scope)) {
            anchorIds.addAll(resolvePrimaryRecordAnchors(executionId, immediatePageRecordId));
        } else if ('User'.equalsIgnoreCase(scope)) {
            if (userId != null) {
                anchorIds.add(userId);
            }
        } else if ('Session'.equalsIgnoreCase(scope)) {
            Id sessionId = resolveSessionId(executionId);
            if (sessionId != null) {
                anchorIds.add(sessionId);
            }
        } else if ('Global'.equalsIgnoreCase(scope)) {
            return anchorIds;
        }

        return anchorIds;
    }

    private Set<Id> resolvePrimaryRecordAnchors(Id executionId, Id immediatePageRecordId) {
        Set<Id> anchorIds = new Set<Id>();
        if (immediatePageRecordId != null) {
            anchorIds.add(immediatePageRecordId);
            return anchorIds;
        }

        for (ContextReference__c record : [
            SELECT RecordId__c
            FROM ContextReference__c
            WHERE
                AgentExecution__c = :executionId
                AND ReferenceRole__c = :ContextManagerService.ReferenceRole.Primary.name()
                AND Status__c = :ContextManagerService.ReferenceStatus.Active.name()
            ORDER BY LastUsedAt__c DESC, CreatedDate DESC
            LIMIT 5
        ]) {
            if (String.isBlank(record.RecordId__c)) {
                continue;
            }
            try {
                anchorIds.add((Id) record.RecordId__c);
            } catch (Exception ignored) {
                // Ignore malformed record ids in the ledger.
            }
        }
        return anchorIds;
    }

    private void validateContextDefinition(AgentContextConfig__c config, ContextDefinition contextDefinition) {
        if ('Apex Provider'.equalsIgnoreCase(contextDefinition.definitionMode)) {
            if (String.isBlank(contextDefinition.apexClassName)) {
                throw new ResolutionException(
                    'Context binding "' + config.AdminLabel__c + '" points to Apex Provider mode but the definition has no Apex class.'
                );
            }
            return;
        }

        if ('Field Set'.equalsIgnoreCase(contextDefinition.definitionMode)) {
            if (String.isBlank(contextDefinition.rootObjectApiName) || String.isBlank(contextDefinition.fieldSetName)) {
                throw new ResolutionException(
                    'Context binding "' + config.AdminLabel__c + '" points to Field Set mode but the definition is missing the root object or field set.'
                );
            }
            return;
        }

        throw new ResolutionException(
            'Context binding "' + config.AdminLabel__c + '" points to an unsupported definition mode: ' + contextDefinition.definitionMode
        );
    }

    private List<SObject> resolveContextRecords(
        AgentContextConfig__c config,
        ContextDefinition contextDefinition,
        Set<Id> anchorIds,
        Id userId,
        String logPrefix
    ) {
        if ('Field Set'.equalsIgnoreCase(contextDefinition.definitionMode)) {
            return loadFieldSetContext(anchorIds, contextDefinition);
        }
        return invokeProvider(config, contextDefinition, anchorIds, userId, logPrefix);
    }

    private List<SObject> invokeProvider(AgentContextConfig__c config, ContextDefinition contextDefinition, Set<Id> anchorIds, Id userId, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Invoking context definition: ' + contextDefinition.contextKey + ' | Anchor count: ' + anchorIds.size());
        IAgentContextProvider provider = getProviderInstance(contextDefinition);
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

    private List<SObject> loadFieldSetContext(Set<Id> anchorIds, ContextDefinition contextDefinition) {
        Set<Id> matchingAnchorIds = new Set<Id>();
        for (Id anchorId : anchorIds) {
            if (anchorId != null && anchorId.getSObjectType().getDescribe().getName().equalsIgnoreCase(contextDefinition.rootObjectApiName)) {
                matchingAnchorIds.add(anchorId);
            }
        }
        if (matchingAnchorIds.isEmpty()) {
            return new List<SObject>();
        }

        Schema.SObjectType sObjectType = Schema.getGlobalDescribe().get(contextDefinition.rootObjectApiName);
        if (sObjectType == null) {
            throw new ResolutionException('Unknown root object for context definition: ' + contextDefinition.rootObjectApiName);
        }

        Schema.FieldSet fieldSet = sObjectType.getDescribe().fieldSets.getMap().get(contextDefinition.fieldSetName);
        if (fieldSet == null) {
            throw new ResolutionException('Field set not found: ' + contextDefinition.rootObjectApiName + '.' + contextDefinition.fieldSetName);
        }

        Set<String> selectFields = new Set<String>{ 'Id' };
        for (Schema.FieldSetMember member : fieldSet.getFields()) {
            String fieldPath = member.getFieldPath();
            if (String.isNotBlank(fieldPath) && !fieldPath.contains('.')) {
                selectFields.add(fieldPath);
            }
        }

        List<String> selectFieldList = new List<String>();
        selectFieldList.addAll(selectFields);
        selectFieldList.sort();

        String soql = 'SELECT ' + String.join(selectFieldList, ', ') + ' FROM ' + contextDefinition.rootObjectApiName + ' WHERE Id IN :matchingAnchorIds';
        if (contextDefinition.recordLimit != null) {
            soql += ' LIMIT ' + contextDefinition.recordLimit;
        }
        return Database.query(soql);
    }

    private IAgentContextProvider getProviderInstance(ContextDefinition contextDefinition) {
        if (testProviderOverrides.containsKey(contextDefinition.contextKey)) {
            return testProviderOverrides.get(contextDefinition.contextKey);
        }
        if (testProviderOverrides.containsKey(contextDefinition.apexClassName)) {
            return testProviderOverrides.get(contextDefinition.apexClassName);
        }

        if (!providerCache.containsKey(contextDefinition.contextKey)) {
            Type providerType = Type.forName(contextDefinition.apexClassName);
            if (providerType == null) {
                throw new ResolutionException('Provider class not found: ' + contextDefinition.apexClassName);
            }
            Object instance = providerType.newInstance();
            if (!(instance instanceof IAgentContextProvider)) {
                throw new ResolutionException('Class ' + contextDefinition.apexClassName + ' does not implement IAgentContextProvider.');
            }
            providerCache.put(contextDefinition.contextKey, (IAgentContextProvider) instance);
        }
        return providerCache.get(contextDefinition.contextKey);
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
                    AIAgentDefinition__c,
                    AdminLabel__c,
                    ApplicableChannels__c,
                    ContextDefinition__c,
                    FailureMode__c,
                    IsActive__c,
                    Priority__c,
                    ProviderConfigJson__c
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
