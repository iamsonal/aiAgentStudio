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
    public class ContextManagementException extends AIAgentException {
    }

    public enum ReferenceRole {
        Primary,
        Mentioned,
        Created,
        Related,
        Background
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

    @TestVisible
    public class ContextReferenceItem {
        public String recordId;
        public String recordType;
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
                references.add(new ContextReferenceItem(record));
            }
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
        return getRelevantRecordIds(executionId, 'Persistent');
    }

    /**
     * Returns the set of valid Salesforce record IDs represented by active references,
     * filtered by the requested freshness policy.
     */
    public Set<Id> getRelevantRecordIds(Id executionId, String freshnessPolicy) {
        Set<Id> relevantIds = new Set<Id>();
        Datetime recentCutoff = Datetime.now().addDays(-7);
        for (ContextReferenceItem item : getContextReferences(executionId)) {
            if (String.isBlank(item.recordId)) {
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

        String logPrefix = '[ContextManager.Commit ' + executionId + '] ';

        try {
            Id interactionSessionId = resolveSessionId(executionId);
            Set<String> recordIds = new Set<String>();
            if (pageContextId != null) {
                recordIds.add(String.valueOf(pageContextId));
            }
            if (newRecordFromActionId != null) {
                recordIds.add(String.valueOf(newRecordFromActionId));
            }

            Map<String, ContextReference__c> existingByRecordId = getExistingReferences(executionId, interactionSessionId, recordIds);
            Datetime touchedAt = Datetime.now();
            List<ContextReference__c> recordsToSave = new List<ContextReference__c>();

            if (pageContextId != null) {
                recordsToSave.add(
                    prepareReference(
                        existingByRecordId.get(String.valueOf(pageContextId)),
                        executionId,
                        interactionSessionId,
                        pageContextId,
                        ReferenceRole.Primary,
                        ReferenceSource.PageContext,
                        'Primary record in the current interaction.',
                        touchedAt
                    )
                );
            }

            if (newRecordFromActionId != null) {
                recordsToSave.add(
                    prepareReference(
                        existingByRecordId.get(String.valueOf(newRecordFromActionId)),
                        executionId,
                        interactionSessionId,
                        newRecordFromActionId,
                        ReferenceRole.Created,
                        ReferenceSource.ToolOutput,
                        'Record created during agent execution.',
                        touchedAt
                    )
                );
            }

            upsertReferences(recordsToSave);
            System.debug(LoggingLevel.INFO, logPrefix + 'Context references updated. Count: ' + recordsToSave.size());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context reference update failed: ' + e.getMessage());
            throw new ContextManagementException('Context reference update failed: ' + e.getMessage(), e);
        }
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

    private Map<String, ContextReference__c> getExistingReferences(Id executionId, Id interactionSessionId, Set<String> recordIds) {
        Map<String, ContextReference__c> referencesByRecordId = new Map<String, ContextReference__c>();
        if (recordIds == null || recordIds.isEmpty()) {
            return referencesByRecordId;
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
            referencesByRecordId.put(record.RecordId__c, record);
        }
        return referencesByRecordId;
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
            return ReferenceRole.Background;
        }
        return ReferenceRole.valueOf(storedValue);
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
