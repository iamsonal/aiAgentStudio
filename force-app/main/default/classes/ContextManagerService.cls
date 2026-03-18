/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Stores and resolves lightweight context references for an execution or interaction session.
 */
public inherited sharing class ContextManagerService {
    private static final Integer MAX_CONTEXT_DELTA_ITEMS_PER_TURN = AIAgentFrameworkSettings.getMaxContextDeltaItemsPerTurn();
    private static final Integer MAX_ACTIVE_CONTEXT_REFERENCES = AIAgentFrameworkSettings.getMaxActiveContextReferences();

    public class ContextManagementException extends AIAgentException {
    }

    public enum ReferenceRole {
        Primary,
        Mentioned,
        Created,
        Related
    }

    public enum ReferenceSource {
        PageContext,
        UserMention,
        ToolOutput,
        InternalSystem
    }

    public enum ReferenceStatus {
        Active,
        Inactive,
        Dropped
    }

    public class ContextDeltaItem {
        public String recordId;
        public ReferenceRole referenceRole;
        public ReferenceSource referenceSource;
        public String explanation;

        public ContextDeltaItem(Id targetRecordId, ReferenceRole role, ReferenceSource source, String note) {
            this.recordId = targetRecordId == null ? null : String.valueOf(targetRecordId);
            this.referenceRole = role;
            this.referenceSource = source;
            this.explanation = note;
        }
    }

    @TestVisible
    public class ContextReferenceItem {
        public String recordId;
        public String recordType;
        public Id interactionSessionId;
        public ReferenceRole referenceRole;
        public ReferenceSource referenceSource;
        public ReferenceStatus status;
        public Datetime lastUsedAt;
        public Integer useCount;
        public String explanation;

        public ContextReferenceItem(Id targetRecordId, ReferenceRole role, ReferenceSource source, String note) {
            this.recordId = String.valueOf(targetRecordId);
            this.recordType = describeRecordType(targetRecordId);
            this.referenceRole = role;
            this.referenceSource = source;
            this.status = ReferenceStatus.Active;
            this.lastUsedAt = Datetime.now();
            this.useCount = 1;
            this.explanation = note;
        }

        public ContextReferenceItem(ContextReference__c record) {
            this.recordId = record.RecordId__c;
            this.recordType = record.RecordType__c;
            this.interactionSessionId = record.InteractionSession__c;
            this.referenceRole = parseRole(record.ReferenceRole__c);
            this.referenceSource = parseSource(record.ReferenceSource__c);
            this.status = parseStatus(record.Status__c);
            this.lastUsedAt = record.LastUsedAt__c;
            this.useCount = record.UseCount__c == null ? 0 : record.UseCount__c.intValue();
            this.explanation = record.Explanation__c;
        }

        public ContextReference__c toRecord(Id executionId, Id interactionSessionId) {
            ContextReference__c record = new ContextReference__c();
            record.AgentExecution__c = executionId;
            record.InteractionSession__c = interactionSessionId;
            record.RecordId__c = this.recordId;
            record.RecordType__c = this.recordType;
            record.ReferenceRole__c = this.referenceRole.name();
            record.ReferenceSource__c = toPicklistValue(this.referenceSource);
            record.Status__c = this.status.name();
            record.LastUsedAt__c = this.lastUsedAt;
            record.UseCount__c = this.useCount;
            record.Explanation__c = this.explanation;
            return record;
        }
    }

    public ContextManagerService() {
    }

    /**
     * Returns active references for the execution, reusing session-scoped references when a session exists.
     */
    public List<ContextReferenceItem> getContextReferences(Id executionId) {
        if (executionId == null) {
            return new List<ContextReferenceItem>();
        }

        try {
            Id interactionSessionId = resolveSessionId(executionId);
            List<ContextReferenceItem> references = new List<ContextReferenceItem>();
            for (ContextReference__c record : queryReferences(executionId, interactionSessionId, true)) {
                try {
                    ContextReferenceItem item = new ContextReferenceItem(record);
                    if (item.referenceRole == null) {
                        System.debug(
                            LoggingLevel.WARN,
                            '[ContextManagerService.getContextReferences] Skipping context reference with invalid role. RecordId=' +
                                record.RecordId__c +
                                ', StoredRole=' +
                                record.ReferenceRole__c
                        );
                        continue;
                    }
                    references.add(item);
                } catch (Exception e) {
                    System.debug(
                        LoggingLevel.WARN,
                        '[ContextManagerService.getContextReferences] Skipping malformed context reference row ' + record.Id + ': ' + e.getMessage()
                    );
                }
            }
            sortContextReferences(references);
            return references;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.getContextReferences] Failed to retrieve references for execution ' + executionId + ': ' + e.getMessage()
            );
            return new List<ContextReferenceItem>();
        }
    }

    /**
     * Returns the set of valid Salesforce record IDs represented by active references.
     */
    public Set<Id> getRelevantRecordIds(Id executionId) {
        return getRelevantRecordIds(executionId, 'Session');
    }

    /**
     * Returns the set of valid Salesforce record IDs represented by active references,
     * filtered by the requested freshness policy.
     */
    public Set<Id> getRelevantRecordIds(Id executionId, String freshnessPolicy) {
        return getRelevantRecordIds(executionId, freshnessPolicy, null, null);
    }

    /**
     * Returns the set of valid Salesforce record IDs represented by active references,
     * filtered by freshness and optional role/source filters.
     */
    public Set<Id> getRelevantRecordIds(Id executionId, String freshnessPolicy, Set<ReferenceRole> roleFilter, Set<ReferenceSource> sourceFilter) {
        Set<Id> relevantIds = new Set<Id>();
        Datetime recentCutoff = Datetime.now().addDays(-7);
        Id interactionSessionId = resolveSessionId(executionId);
        for (ContextReferenceItem item : getContextReferences(executionId)) {
            if (String.isBlank(item.recordId)) {
                continue;
            }
            if (roleFilter != null && !roleFilter.isEmpty() && (item.referenceRole == null || !roleFilter.contains(item.referenceRole))) {
                continue;
            }
            if (sourceFilter != null && !sourceFilter.isEmpty() && (item.referenceSource == null || !sourceFilter.contains(item.referenceSource))) {
                continue;
            }
            if ('Session'.equalsIgnoreCase(freshnessPolicy) && interactionSessionId != null && item.interactionSessionId != interactionSessionId) {
                continue;
            }
            if ('Session'.equalsIgnoreCase(freshnessPolicy) && interactionSessionId == null) {
                continue;
            }
            if ('Recent'.equalsIgnoreCase(freshnessPolicy) && item.lastUsedAt != null && item.lastUsedAt < recentCutoff) {
                continue;
            }
            try {
                relevantIds.add(Id.valueOf(item.recordId));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Skipping invalid context record id: ' + item.recordId);
            }
        }
        return relevantIds;
    }

    /**
     * Refreshes the current page reference and optional created-record reference for the execution.
     */
    public void commitExecutionTurnContext(Id executionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (executionId == null || (pageContextId == null && newRecordFromActionId == null)) {
            return;
        }

        List<ContextDeltaItem> deltaItems = new List<ContextDeltaItem>();
        if (pageContextId != null) {
            deltaItems.add(
                new ContextDeltaItem(pageContextId, ReferenceRole.Primary, ReferenceSource.PageContext, 'Primary record in the current interaction.')
            );
        }
        if (newRecordFromActionId != null) {
            deltaItems.add(
                new ContextDeltaItem(newRecordFromActionId, ReferenceRole.Created, ReferenceSource.ToolOutput, 'Record created during agent execution.')
            );
        }
        commitContextDelta(executionId, currentTurn, deltaItems);
    }

    /**
     * Commits a typed set of context anchor deltas for the current turn.
     */
    public void commitContextDelta(Id executionId, Integer currentTurn, List<ContextDeltaItem> deltaItems) {
        if (executionId == null || deltaItems == null || deltaItems.isEmpty()) {
            return;
        }

        String logPrefix = '[ContextManager.Commit ' + executionId + '] ';

        try {
            Id interactionSessionId = resolveSessionId(executionId);
            List<ContextDeltaItem> normalizedDeltaItems = normalizeDeltaItems(deltaItems);
            if (normalizedDeltaItems.isEmpty()) {
                return;
            }

            Map<String, ContextReference__c> existingByReferenceKey = getExistingReferences(executionId, interactionSessionId, normalizedDeltaItems);
            normalizedDeltaItems = applyActiveReferenceCap(executionId, interactionSessionId, normalizedDeltaItems, existingByReferenceKey, logPrefix);
            if (normalizedDeltaItems.isEmpty()) {
                return;
            }
            Datetime touchedAt = Datetime.now();
            List<ContextReference__c> recordsToSave = new List<ContextReference__c>();
            for (ContextDeltaItem item : normalizedDeltaItems) {
                try {
                    recordsToSave.add(
                        prepareReference(
                            existingByReferenceKey.get(buildReferenceKey(item.recordId, item.referenceRole, item.referenceSource)),
                            executionId,
                            interactionSessionId,
                            Id.valueOf(item.recordId),
                            item.referenceRole,
                            item.referenceSource,
                            item.explanation,
                            touchedAt
                        )
                    );
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping invalid context delta item for record "' + item.recordId + '": ' + e.getMessage());
                }
            }
            if (recordsToSave.isEmpty()) {
                return;
            }

            upsertReferences(recordsToSave);
            System.debug(LoggingLevel.INFO, logPrefix + 'Context references updated. Count: ' + recordsToSave.size());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context reference update failed: ' + e.getMessage());
            throw new ContextManagementException('Context reference update failed: ' + e.getMessage(), e);
        }
    }

    /**
     * Builds the full turn-level delta list for the execution from page context, explicit tool outcomes,
     * structured mention metadata, and framework-owned source-record promotion.
     */
    public List<ContextDeltaItem> buildTurnContextDelta(Id executionId, Id pageContextId, List<ContextDeltaItem> outcomeDeltaItems) {
        List<ContextDeltaItem> deltaItems = new List<ContextDeltaItem>();

        if (pageContextId != null) {
            deltaItems.add(
                new ContextDeltaItem(pageContextId, ReferenceRole.Primary, ReferenceSource.PageContext, 'Primary record in the current interaction.')
            );
        }

        if (executionId != null) {
            try {
                AgentExecution__c execution = [
                    SELECT SourceRecordId__c, TriggerPayload__c
                    FROM AgentExecution__c
                    WHERE Id = :executionId
                    LIMIT 1
                ];

                if (execution.SourceRecordId__c != null && execution.SourceRecordId__c != pageContextId) {
                    deltaItems.add(
                        new ContextDeltaItem(
                            execution.SourceRecordId__c,
                            ReferenceRole.Related,
                            ReferenceSource.InternalSystem,
                            'Framework-resolved source record retained for working context.'
                        )
                    );
                }

                Map<String, Object> triggerPayload = parseTriggerPayload(execution.TriggerPayload__c);
                for (Id mentionedRecordId : parseRecordIdList(triggerPayload, 'mentionedRecordIds')) {
                    deltaItems.add(
                        new ContextDeltaItem(
                            mentionedRecordId,
                            ReferenceRole.Mentioned,
                            ReferenceSource.UserMention,
                            'Explicit structured record mention supplied with the runtime request.'
                        )
                    );
                }
                for (Id relatedRecordId : parseRecordIdList(triggerPayload, 'relatedRecordIds')) {
                    deltaItems.add(
                        new ContextDeltaItem(
                            relatedRecordId,
                            ReferenceRole.Related,
                            ReferenceSource.InternalSystem,
                            'Framework-supplied related record carried in runtime metadata.'
                        )
                    );
                }
                for (Id relatedRecordId : parseRecordIdList(triggerPayload, 'systemRecordIds')) {
                    deltaItems.add(
                        new ContextDeltaItem(
                            relatedRecordId,
                            ReferenceRole.Related,
                            ReferenceSource.InternalSystem,
                            'Framework-supplied system record carried in runtime metadata.'
                        )
                    );
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Failed to assemble turn context metadata: ' + e.getMessage());
            }
        }

        if (outcomeDeltaItems != null && !outcomeDeltaItems.isEmpty()) {
            deltaItems.addAll(outcomeDeltaItems);
        }

        return normalizeDeltaItems(deltaItems);
    }

    /**
     * Converts explicit action context effects into typed context delta items.
     */
    public List<ContextDeltaItem> buildDeltaItemsFromContextEffects(List<ActionOutcome.ContextEffect> contextEffects) {
        List<ContextDeltaItem> deltaItems = new List<ContextDeltaItem>();
        if (contextEffects == null) {
            return deltaItems;
        }

        for (ActionOutcome.ContextEffect effect : contextEffects) {
            if (effect == null || String.isBlank(effect.recordId) || String.isBlank(effect.referenceRole) || String.isBlank(effect.referenceSource)) {
                continue;
            }
            try {
                deltaItems.add(
                    new ContextDeltaItem(
                        Id.valueOf(effect.recordId),
                        ReferenceRole.valueOf(effect.referenceRole),
                        ReferenceSource.valueOf(effect.referenceSource),
                        effect.explanation
                    )
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Skipping invalid action context effect: ' + e.getMessage());
            }
        }
        return deltaItems;
    }

    /**
     * Produces a serializable payload of child-execution anchors that can be re-emitted by a parent runtime.
     */
    public List<Map<String, Object>> getPropagatableContextPayload(Id executionId) {
        List<Map<String, Object>> payloadItems = new List<Map<String, Object>>();
        if (executionId == null) {
            return payloadItems;
        }

        for (ContextReferenceItem item : getContextReferences(executionId)) {
            if (item == null || String.isBlank(item.recordId) || item.referenceRole == null || item.referenceSource == null) {
                continue;
            }
            if (item.referenceRole == ReferenceRole.Primary && item.referenceSource == ReferenceSource.PageContext) {
                continue;
            }
            payloadItems.add(
                new Map<String, Object>{
                    'recordId' => item.recordId,
                    'referenceRole' => item.referenceRole.name(),
                    'referenceSource' => item.referenceSource.name(),
                    'explanation' => item.explanation
                }
            );
        }
        return payloadItems;
    }

    /**
     * Rehydrates serialized context-effect payloads into typed context delta items.
     */
    public List<ContextDeltaItem> deserializePayloadContextEffects(Object payloadValue) {
        List<ContextDeltaItem> deltaItems = new List<ContextDeltaItem>();
        if (payloadValue == null || !(payloadValue instanceof List<Object>)) {
            return deltaItems;
        }

        for (Object rawItem : (List<Object>) payloadValue) {
            if (!(rawItem instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> item = (Map<String, Object>) rawItem;
            try {
                String recordId = (String) item.get('recordId');
                String roleName = (String) item.get('referenceRole');
                String sourceName = (String) item.get('referenceSource');
                if (String.isBlank(recordId) || String.isBlank(roleName) || String.isBlank(sourceName)) {
                    continue;
                }
                deltaItems.add(
                    new ContextDeltaItem(
                        Id.valueOf(recordId),
                        ReferenceRole.valueOf(roleName),
                        ReferenceSource.valueOf(sourceName),
                        (String) item.get('explanation')
                    )
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Skipping invalid propagated context payload item: ' + e.getMessage());
            }
        }

        return deltaItems;
    }

    private ContextReference__c prepareReference(
        ContextReference__c existingRecord,
        Id executionId,
        Id interactionSessionId,
        Id targetRecordId,
        ReferenceRole role,
        ReferenceSource source,
        String explanation,
        Datetime touchedAt
    ) {
        ContextReference__c record = existingRecord == null ? new ContextReference__c() : existingRecord;
        record.AgentExecution__c = executionId;
        record.InteractionSession__c = interactionSessionId;
        record.RecordId__c = String.valueOf(targetRecordId);
        record.RecordType__c = describeRecordType(targetRecordId);
        record.ReferenceRole__c = role.name();
        record.ReferenceSource__c = toPicklistValue(source);
        record.Status__c = ReferenceStatus.Active.name();
        record.LastUsedAt__c = touchedAt;
        Integer currentUseCount = record.UseCount__c == null ? 0 : record.UseCount__c.intValue();
        record.UseCount__c = currentUseCount + 1;
        if (String.isBlank(record.Explanation__c)) {
            record.Explanation__c = explanation;
        }
        return record;
    }

    private Map<String, ContextReference__c> getExistingReferences(Id executionId, Id interactionSessionId, List<ContextDeltaItem> deltaItems) {
        Map<String, ContextReference__c> referencesByKey = new Map<String, ContextReference__c>();
        if (deltaItems == null || deltaItems.isEmpty()) {
            return referencesByKey;
        }

        Set<String> recordIds = new Set<String>();
        for (ContextDeltaItem item : deltaItems) {
            if (item != null && String.isNotBlank(item.recordId)) {
                recordIds.add(item.recordId);
            }
        }
        if (recordIds.isEmpty()) {
            return referencesByKey;
        }

        List<ContextReference__c> existingRecords;
        if (interactionSessionId != null) {
            existingRecords = [
                SELECT
                    Id,
                    AgentExecution__c,
                    InteractionSession__c,
                    RecordId__c,
                    RecordType__c,
                    ReferenceRole__c,
                    ReferenceSource__c,
                    Status__c,
                    LastUsedAt__c,
                    UseCount__c,
                    Explanation__c
                FROM ContextReference__c
                WHERE InteractionSession__c = :interactionSessionId AND RecordId__c IN :recordIds
            ];
        } else {
            existingRecords = [
                SELECT
                    Id,
                    AgentExecution__c,
                    InteractionSession__c,
                    RecordId__c,
                    RecordType__c,
                    ReferenceRole__c,
                    ReferenceSource__c,
                    Status__c,
                    LastUsedAt__c,
                    UseCount__c,
                    Explanation__c
                FROM ContextReference__c
                WHERE AgentExecution__c = :executionId AND RecordId__c IN :recordIds
            ];
        }

        for (ContextReference__c record : existingRecords) {
            ReferenceRole role = parseRole(record.ReferenceRole__c);
            ReferenceSource source = parseSource(record.ReferenceSource__c);
            if (role == null || source == null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ContextManagerService] Skipping existing context reference with invalid role/source. RecordId=' +
                        record.RecordId__c +
                        ', Role=' +
                        record.ReferenceRole__c +
                        ', Source=' +
                        record.ReferenceSource__c
                );
                continue;
            }
            referencesByKey.put(buildReferenceKey(record.RecordId__c, role, source), record);
        }
        return referencesByKey;
    }

    private List<ContextReference__c> queryReferences(Id executionId, Id interactionSessionId, Boolean activeOnly) {
        String activeStatus = ReferenceStatus.Active.name();
        if (interactionSessionId != null) {
            if (activeOnly) {
                return [
                    SELECT
                        Id,
                        AgentExecution__c,
                        InteractionSession__c,
                        RecordId__c,
                        RecordType__c,
                        ReferenceRole__c,
                        ReferenceSource__c,
                        Status__c,
                        LastUsedAt__c,
                        UseCount__c,
                        Explanation__c
                    FROM ContextReference__c
                    WHERE InteractionSession__c = :interactionSessionId AND Status__c = :activeStatus
                    ORDER BY LastUsedAt__c DESC, UseCount__c DESC
                ];
            }
            return [
                SELECT
                    Id,
                    AgentExecution__c,
                    InteractionSession__c,
                    RecordId__c,
                    RecordType__c,
                    ReferenceRole__c,
                    ReferenceSource__c,
                    Status__c,
                    LastUsedAt__c,
                    UseCount__c,
                    Explanation__c
                FROM ContextReference__c
                WHERE InteractionSession__c = :interactionSessionId
                ORDER BY LastUsedAt__c DESC, UseCount__c DESC
            ];
        }

        if (activeOnly) {
            return [
                SELECT
                    Id,
                    AgentExecution__c,
                    InteractionSession__c,
                    RecordId__c,
                    RecordType__c,
                    ReferenceRole__c,
                    ReferenceSource__c,
                    Status__c,
                    LastUsedAt__c,
                    UseCount__c,
                    Explanation__c
                FROM ContextReference__c
                WHERE AgentExecution__c = :executionId AND Status__c = :activeStatus
                ORDER BY LastUsedAt__c DESC, UseCount__c DESC
            ];
        }
        return [
            SELECT
                Id,
                AgentExecution__c,
                InteractionSession__c,
                RecordId__c,
                RecordType__c,
                ReferenceRole__c,
                ReferenceSource__c,
                Status__c,
                LastUsedAt__c,
                UseCount__c,
                Explanation__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :executionId
            ORDER BY LastUsedAt__c DESC, UseCount__c DESC
        ];
    }

    private List<ContextReference__c> upsertReferences(List<ContextReference__c> recordsToSave) {
        if (recordsToSave == null || recordsToSave.isEmpty()) {
            return new List<ContextReference__c>();
        }

        List<ContextReference__c> toInsert = new List<ContextReference__c>();
        List<ContextReference__c> toUpdate = new List<ContextReference__c>();
        for (ContextReference__c record : recordsToSave) {
            if (record.Id == null) {
                toInsert.add(record);
            } else {
                toUpdate.add(record);
            }
        }

        List<ContextReference__c> saved = new List<ContextReference__c>();
        if (!toUpdate.isEmpty()) {
            Database.SaveResult[] updateResults = Database.update(toUpdate, false);
            for (Integer i = 0; i < updateResults.size(); i++) {
                if (updateResults[i].isSuccess()) {
                    saved.add(toUpdate[i]);
                } else {
                    logDmlErrors(updateResults[i], toUpdate[i], 'update');
                }
            }
        }

        if (!toInsert.isEmpty()) {
            Database.SaveResult[] insertResults = Database.insert(toInsert, false);
            for (Integer i = 0; i < insertResults.size(); i++) {
                if (insertResults[i].isSuccess()) {
                    saved.add(toInsert[i]);
                } else {
                    logDmlErrors(insertResults[i], toInsert[i], 'insert');
                }
            }
        }

        return saved;
    }

    private Id resolveSessionId(Id executionId) {
        if (executionId == null) {
            return null;
        }
        List<AgentExecution__c> executions = [
            SELECT InteractionSession__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        return executions.isEmpty() ? null : executions[0].InteractionSession__c;
    }

    private static String describeRecordType(Id recordId) {
        if (recordId == null) {
            return null;
        }
        try {
            return recordId.getSObjectType().getDescribe().getName();
        } catch (Exception e) {
            return 'Unknown';
        }
    }

    private static ReferenceRole parseRole(String storedValue) {
        if (String.isBlank(storedValue)) {
            return null;
        }
        try {
            return ReferenceRole.valueOf(storedValue);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ContextManagerService] Invalid stored context reference role: ' + storedValue);
            return null;
        }
    }

    private static ReferenceSource parseSource(String storedValue) {
        if (String.isBlank(storedValue)) {
            return ReferenceSource.InternalSystem;
        }
        if (storedValue == 'Page Context') {
            return ReferenceSource.PageContext;
        }
        if (storedValue == 'User Mention') {
            return ReferenceSource.UserMention;
        }
        if (storedValue == 'Tool Output') {
            return ReferenceSource.ToolOutput;
        }
        if (storedValue == 'System') {
            return ReferenceSource.InternalSystem;
        }
        return ReferenceSource.valueOf(storedValue);
    }

    private static String toPicklistValue(ReferenceSource source) {
        switch on source {
            when PageContext {
                return 'Page Context';
            }
            when UserMention {
                return 'User Mention';
            }
            when ToolOutput {
                return 'Tool Output';
            }
            when InternalSystem {
                return 'System';
            }
        }
        return 'System';
    }

    private static List<ContextDeltaItem> normalizeDeltaItems(List<ContextDeltaItem> deltaItems) {
        Map<String, ContextDeltaItem> dedupedByKey = new Map<String, ContextDeltaItem>();
        if (deltaItems == null) {
            return new List<ContextDeltaItem>();
        }

        for (ContextDeltaItem item : deltaItems) {
            if (item == null || String.isBlank(item.recordId) || item.referenceRole == null || item.referenceSource == null) {
                continue;
            }
            Id normalizedRecordId;
            try {
                normalizedRecordId = Id.valueOf(item.recordId);
            } catch (Exception e) {
                continue;
            }
            item.recordId = String.valueOf(normalizedRecordId);
            String key = buildReferenceKey(item.recordId, item.referenceRole, item.referenceSource);
            if (!dedupedByKey.containsKey(key)) {
                dedupedByKey.put(key, item);
            }
        }

        List<ContextDeltaItem> filteredItems = filterAccessibleExistingDeltaItems(dedupedByKey.values());
        if (filteredItems.size() <= MAX_CONTEXT_DELTA_ITEMS_PER_TURN) {
            return filteredItems;
        }

        List<ContextDeltaItem> truncatedItems = new List<ContextDeltaItem>();
        for (Integer i = 0; i < MAX_CONTEXT_DELTA_ITEMS_PER_TURN; i++) {
            truncatedItems.add(filteredItems[i]);
        }
        return truncatedItems;
    }

    private static List<ContextDeltaItem> filterAccessibleExistingDeltaItems(List<ContextDeltaItem> deltaItems) {
        List<ContextDeltaItem> filteredItems = new List<ContextDeltaItem>();
        if (deltaItems == null || deltaItems.isEmpty()) {
            return filteredItems;
        }

        Map<String, List<ContextDeltaItem>> itemsByObject = new Map<String, List<ContextDeltaItem>>();
        Map<String, Set<Id>> idsByObject = new Map<String, Set<Id>>();
        for (ContextDeltaItem item : deltaItems) {
            if (item == null || String.isBlank(item.recordId)) {
                continue;
            }
            try {
                Id recordId = Id.valueOf(item.recordId);
                String objectApiName = recordId.getSObjectType().getDescribe().getName();
                if (!itemsByObject.containsKey(objectApiName)) {
                    itemsByObject.put(objectApiName, new List<ContextDeltaItem>());
                    idsByObject.put(objectApiName, new Set<Id>());
                }
                itemsByObject.get(objectApiName).add(item);
                idsByObject.get(objectApiName).add(recordId);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Skipping invalid context delta record id: ' + item.recordId);
            }
        }

        for (String objectApiName : itemsByObject.keySet()) {
            Set<Id> accessibleIds = queryAccessibleIds(objectApiName, idsByObject.get(objectApiName));
            for (ContextDeltaItem item : itemsByObject.get(objectApiName)) {
                if (accessibleIds.contains(Id.valueOf(item.recordId))) {
                    filteredItems.add(item);
                }
            }
        }

        return filteredItems;
    }

    private static Set<Id> queryAccessibleIds(String objectApiName, Set<Id> recordIds) {
        Set<Id> accessibleIds = new Set<Id>();
        if (String.isBlank(objectApiName) || recordIds == null || recordIds.isEmpty()) {
            return accessibleIds;
        }

        try {
            List<SObject> records = Database.queryWithBinds(
                'SELECT Id FROM ' + objectApiName + ' WHERE Id IN :recordIds',
                new Map<String, Object>{ 'recordIds' => new List<Id>(recordIds) },
                AccessLevel.USER_MODE
            );
            for (SObject record : records) {
                accessibleIds.add((Id) record.get('Id'));
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                '[ContextManagerService] Failed to validate accessible context anchors for ' + objectApiName + ': ' + e.getMessage()
            );
        }
        return accessibleIds;
    }

    private List<ContextDeltaItem> applyActiveReferenceCap(
        Id executionId,
        Id interactionSessionId,
        List<ContextDeltaItem> deltaItems,
        Map<String, ContextReference__c> existingByReferenceKey,
        String logPrefix
    ) {
        if (deltaItems == null || deltaItems.isEmpty()) {
            return new List<ContextDeltaItem>();
        }

        Integer activeReferenceCount = countActiveReferences(executionId, interactionSessionId);
        Integer availableNewSlots = Math.max(0, MAX_ACTIVE_CONTEXT_REFERENCES - activeReferenceCount);
        List<ContextDeltaItem> cappedItems = new List<ContextDeltaItem>();

        for (ContextDeltaItem item : deltaItems) {
            String referenceKey = buildReferenceKey(item.recordId, item.referenceRole, item.referenceSource);
            if (existingByReferenceKey.containsKey(referenceKey)) {
                cappedItems.add(item);
                continue;
            }
            if (availableNewSlots <= 0) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Skipping new context anchor because the active reference cap was reached: ' + item.recordId);
                continue;
            }
            cappedItems.add(item);
            availableNewSlots--;
        }

        return cappedItems;
    }

    private Integer countActiveReferences(Id executionId, Id interactionSessionId) {
        String activeStatus = ReferenceStatus.Active.name();
        if (interactionSessionId != null) {
            return [
                SELECT COUNT()
                FROM ContextReference__c
                WHERE InteractionSession__c = :interactionSessionId AND Status__c = :activeStatus
            ];
        }
        return [
            SELECT COUNT()
            FROM ContextReference__c
            WHERE AgentExecution__c = :executionId AND Status__c = :activeStatus
        ];
    }

    private static String buildReferenceKey(String recordId, ReferenceRole role, ReferenceSource source) {
        return String.valueOf(recordId) + '|' + String.valueOf(role) + '|' + String.valueOf(source);
    }

    private static Map<String, Object> parseTriggerPayload(String triggerPayload) {
        if (String.isBlank(triggerPayload)) {
            return new Map<String, Object>();
        }
        Object rawPayload = JSON.deserializeUntyped(triggerPayload);
        return rawPayload instanceof Map<String, Object> ? (Map<String, Object>) rawPayload : new Map<String, Object>();
    }

    private static List<Id> parseRecordIdList(Map<String, Object> payload, String key) {
        List<Id> recordIds = new List<Id>();
        if (payload == null || String.isBlank(key) || !payload.containsKey(key) || !(payload.get(key) instanceof List<Object>)) {
            return recordIds;
        }

        for (Object rawValue : (List<Object>) payload.get(key)) {
            try {
                if (rawValue != null) {
                    recordIds.add(Id.valueOf(String.valueOf(rawValue)));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Ignoring invalid record id in payload key "' + key + '": ' + rawValue);
            }
        }
        return recordIds;
    }

    private static void sortContextReferences(List<ContextReferenceItem> references) {
        if (references == null || references.size() < 2) {
            return;
        }

        Integer n = references.size();
        for (Integer i = 0; i < n - 1; i++) {
            for (Integer j = 0; j < n - i - 1; j++) {
                if (shouldSortAfter(references[j], references[j + 1])) {
                    ContextReferenceItem current = references[j];
                    references[j] = references[j + 1];
                    references[j + 1] = current;
                }
            }
        }
    }

    private static Boolean shouldSortAfter(ContextReferenceItem left, ContextReferenceItem right) {
        Integer leftPriority = getReferencePriority(left);
        Integer rightPriority = getReferencePriority(right);
        if (leftPriority != rightPriority) {
            return leftPriority > rightPriority;
        }

        Long leftLastUsed = left != null && left.lastUsedAt != null ? left.lastUsedAt.getTime() : 0L;
        Long rightLastUsed = right != null && right.lastUsedAt != null ? right.lastUsedAt.getTime() : 0L;
        if (leftLastUsed != rightLastUsed) {
            return leftLastUsed < rightLastUsed;
        }

        Integer leftUseCount = left != null && left.useCount != null ? left.useCount : 0;
        Integer rightUseCount = right != null && right.useCount != null ? right.useCount : 0;
        return leftUseCount < rightUseCount;
    }

    private static Integer getReferencePriority(ContextReferenceItem item) {
        if (item == null || item.referenceRole == null) {
            return 99;
        }

        if (item.referenceRole == ReferenceRole.Primary && item.referenceSource == ReferenceSource.PageContext) {
            return 1;
        }
        if (item.referenceRole == ReferenceRole.Created && item.referenceSource == ReferenceSource.ToolOutput) {
            return 2;
        }
        if (item.referenceRole == ReferenceRole.Mentioned && item.referenceSource == ReferenceSource.UserMention) {
            return 3;
        }
        if (item.referenceRole == ReferenceRole.Related && item.referenceSource == ReferenceSource.InternalSystem) {
            return 4;
        }
        return 10;
    }

    private static ReferenceStatus parseStatus(String storedValue) {
        if (String.isBlank(storedValue)) {
            return ReferenceStatus.Active;
        }
        return ReferenceStatus.valueOf(storedValue);
    }

    private void logDmlErrors(Database.SaveResult saveResult, ContextReference__c record, String operation) {
        List<String> errorMessages = new List<String>();
        for (Database.Error err : saveResult.getErrors()) {
            errorMessages.add(err.getStatusCode() + ': ' + err.getMessage());
            if (err.getFields() != null && !err.getFields().isEmpty()) {
                errorMessages.add('Fields: ' + String.join(err.getFields(), ', '));
            }
        }
        System.debug(
            LoggingLevel.ERROR,
            '[ContextManagerService] Failed to ' +
                operation +
                ' ContextReference for Execution=' +
                record.AgentExecution__c +
                ', RecordId=' +
                record.RecordId__c +
                '. Errors: ' +
                String.join(errorMessages, '; ')
        );
    }

    /**
     * @description
     * Selects and instantiates the appropriate memory manager implementation for the given strategy.
     *
     * - Returns a SummaryBufferMemoryManager for 'Summary Buffer' strategy
     * - Defaults to BufferWindowMemoryManager for all other or unknown strategies
     *
     * @param strategyName The configured memory strategy name.
     * @return IMemoryManager The selected memory manager implementation.
     */
    public static IMemoryManager getMemoryManager(String strategyName) {
        if ('Summary Buffer'.equalsIgnoreCase(strategyName)) {
            System.debug(LoggingLevel.INFO, '[ContextManagerService] Selected strategy: Summary Buffer. Instantiating SummaryBufferMemoryManager.');
            return new SummaryBufferMemoryManager();
        }
        System.debug(
            LoggingLevel.INFO,
            '[ContextManagerService] Selected strategy: ' + (strategyName ?? 'default') + '. Instantiating BufferWindowMemoryManager.'
        );
        return new BufferWindowMemoryManager();
    }
}
