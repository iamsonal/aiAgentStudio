/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Repository pattern implementation for ContextLedgerItem__c data access.
 * Provides abstraction layer between business logic and database operations,
 * enabling testability, maintainability, and separation of concerns.
 *
 * Key Features:
 * - Encapsulates all SOQL queries and DML operations for context ledger
 * - Supports bulk operations for efficient governor limit usage
 * - Provides filtering and sorting capabilities
 * - Includes optimistic locking via LastModifiedDate checks
 * - Type-safe query builders with fluent API
 */
public inherited sharing class ContextLedgerRepository {
    // --- CONSTANTS ---
    private static final String DEFAULT_ORDER_BY = 'RelevanceScore__c DESC, LastAccessedTurn__c DESC';
    private static final Integer DEFAULT_QUERY_LIMIT = 100;

    // --- QUERY RESULT WRAPPER ---
    public class QueryResult {
        public List<ContextLedgerItem__c> items { get; private set; }
        public Integer totalCount { get; private set; }
        public Boolean hasMore { get; private set; }

        public QueryResult(List<ContextLedgerItem__c> items, Integer totalCount, Boolean hasMore) {
            this.items = items != null ? items : new List<ContextLedgerItem__c>();
            this.totalCount = totalCount;
            this.hasMore = hasMore;
        }
    }

    // --- QUERY BUILDER ---
    public class LedgerQueryBuilder {
        private Id executionId;
        private Set<String> statuses;
        private Set<String> contextTypes;
        private Decimal minRelevanceScore;
        private Integer maxTurnsSinceAccess;
        private Integer currentTurn;
        private String orderBy;
        private Integer queryLimit;

        public LedgerQueryBuilder() {
            this.statuses = new Set<String>();
            this.contextTypes = new Set<String>();
            this.orderBy = DEFAULT_ORDER_BY;
            this.queryLimit = DEFAULT_QUERY_LIMIT;
        }

        public LedgerQueryBuilder forExecution(Id execId) {
            this.executionId = execId;
            return this;
        }

        public LedgerQueryBuilder withStatus(String status) {
            this.statuses.add(status);
            return this;
        }

        public LedgerQueryBuilder withStatuses(Set<String> statusSet) {
            this.statuses.addAll(statusSet);
            return this;
        }

        public LedgerQueryBuilder withContextType(String contextType) {
            this.contextTypes.add(contextType);
            return this;
        }

        public LedgerQueryBuilder withContextTypes(Set<String> types) {
            this.contextTypes.addAll(types);
            return this;
        }

        public LedgerQueryBuilder withMinRelevance(Decimal minScore) {
            this.minRelevanceScore = minScore;
            return this;
        }

        public LedgerQueryBuilder withMaxTurnsSinceAccess(Integer maxTurns, Integer currentTurnNum) {
            this.maxTurnsSinceAccess = maxTurns;
            this.currentTurn = currentTurnNum;
            return this;
        }

        public LedgerQueryBuilder orderBy(String orderByClause) {
            this.orderBy = orderByClause;
            return this;
        }

        public LedgerQueryBuilder limitTo(Integer recordLimit) {
            this.queryLimit = recordLimit;
            return this;
        }

        public String buildQuery() {
            List<String> conditions = new List<String>();

            if (executionId != null) {
                conditions.add('AgentExecution__c = :executionId');
            }

            if (!statuses.isEmpty()) {
                conditions.add('Status__c IN :statuses');
            }

            if (!contextTypes.isEmpty()) {
                conditions.add('ContextType__c IN :contextTypes');
            }

            if (minRelevanceScore != null) {
                conditions.add('RelevanceScore__c >= :minRelevanceScore');
            }

            if (maxTurnsSinceAccess != null && currentTurn != null) {
                Integer minLastAccessedTurn = currentTurn - maxTurnsSinceAccess;
                conditions.add('LastAccessedTurn__c >= ' + minLastAccessedTurn);
            }

            String whereClause = conditions.isEmpty() ? '' : ' WHERE ' + String.join(conditions, ' AND ');
            String orderByClause = String.isNotBlank(orderBy) ? ' ORDER BY ' + orderBy : '';
            String limitClause = queryLimit != null ? ' LIMIT ' + queryLimit : '';

            return 'SELECT Id, RecordId__c, RecordType__c, ContextType__c, Status__c, ' +
                'TurnAdded__c, LastAccessedTurn__c, AccessCount__c, RelevanceScore__c, ' +
                'SourceRecordId__c, ChildRecordIds__c, Metadata__c, OriginalContextType__c, ' +
                'LastDataRefreshTime__c, PrunedAt__c, PrunedReason__c, LastModifiedDate ' +
                'FROM ContextLedgerItem__c' +
                whereClause +
                orderByClause +
                limitClause;
        }

        public List<ContextLedgerItem__c> execute() {
            String query = buildQuery();
            return Database.query(query);
        }
    }

    // --- CREATE OPERATIONS ---

    /**
     * Inserts a single context ledger item.
     * @param item The item to insert
     * @return The inserted item with ID populated
     */
    public ContextLedgerItem__c insertItem(ContextLedgerItem__c item) {
        insert item;
        return item;
    }

    /**
     * Inserts multiple context ledger items in bulk.
     * @param items List of items to insert
     * @return List of inserted items with IDs populated
     */
    public List<ContextLedgerItem__c> insertItems(List<ContextLedgerItem__c> items) {
        if (items == null || items.isEmpty()) {
            return new List<ContextLedgerItem__c>();
        }
        insert items;
        return items;
    }

    /**
     * Upserts context ledger items based on composite key (ExecutionId + RecordId).
     * Note: Since Salesforce doesn't support upsert on composite keys natively,
     * this method queries first, then updates existing or inserts new.
     *
     * @param items Items to upsert
     * @return Upserted items with IDs
     */
    public List<ContextLedgerItem__c> upsertItems(List<ContextLedgerItem__c> items) {
        if (items == null || items.isEmpty()) {
            return new List<ContextLedgerItem__c>();
        }

        // Build map of execution + record ID to item
        Map<String, ContextLedgerItem__c> newItemsMap = new Map<String, ContextLedgerItem__c>();
        Set<Id> executionIds = new Set<Id>();
        Set<String> recordIds = new Set<String>();

        for (ContextLedgerItem__c item : items) {
            String compositeKey = item.AgentExecution__c + '_' + item.RecordId__c;
            newItemsMap.put(compositeKey, item);
            executionIds.add(item.AgentExecution__c);
            recordIds.add(item.RecordId__c);
        }

        // Query existing items
        List<ContextLedgerItem__c> existingItems = [
            SELECT Id, AgentExecution__c, RecordId__c
            FROM ContextLedgerItem__c
            WHERE AgentExecution__c IN :executionIds AND RecordId__c IN :recordIds
        ];

        // Update existing items
        List<ContextLedgerItem__c> toUpdate = new List<ContextLedgerItem__c>();
        for (ContextLedgerItem__c existing : existingItems) {
            String compositeKey = existing.AgentExecution__c + '_' + existing.RecordId__c;
            if (newItemsMap.containsKey(compositeKey)) {
                ContextLedgerItem__c newItem = newItemsMap.get(compositeKey);
                newItem.Id = existing.Id;
                toUpdate.add(newItem);
                newItemsMap.remove(compositeKey);
            }
        }

        // Insert new items (remaining in map)
        List<ContextLedgerItem__c> toInsert = newItemsMap.values();

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
        }

        List<ContextLedgerItem__c> result = new List<ContextLedgerItem__c>();
        result.addAll(toUpdate);
        result.addAll(toInsert);
        return result;
    }

    // --- READ OPERATIONS ---

    /**
     * Gets a query builder for fluent query construction.
     * @return New query builder instance
     */
    public LedgerQueryBuilder queryBuilder() {
        return new LedgerQueryBuilder();
    }

    /**
     * Retrieves all active context items for an execution, ordered by relevance.
     * @param executionId The execution ID
     * @return List of active context items
     */
    public List<ContextLedgerItem__c> getActiveItemsForExecution(Id executionId) {
        return queryBuilder()
            .forExecution(executionId)
            .withStatus('ACTIVE')
            .execute();
    }

    /**
     * Retrieves all context items for an execution (any status).
     * @param executionId The execution ID
     * @return List of all context items
     */
    public List<ContextLedgerItem__c> getAllItemsForExecution(Id executionId) {
        return queryBuilder()
            .forExecution(executionId)
            .execute();
    }

    /**
     * Gets a single context item by composite key (execution + record ID).
     * @param executionId The execution ID
     * @param recordId The tracked record ID
     * @return The context item, or null if not found
     */
    public ContextLedgerItem__c getItemByRecordId(Id executionId, String recordId) {
        List<ContextLedgerItem__c> items = [
            SELECT Id, RecordId__c, RecordType__c, ContextType__c, Status__c,
                TurnAdded__c, LastAccessedTurn__c, AccessCount__c, RelevanceScore__c,
                SourceRecordId__c, ChildRecordIds__c, Metadata__c, OriginalContextType__c,
                LastDataRefreshTime__c, PrunedAt__c, PrunedReason__c, LastModifiedDate
            FROM ContextLedgerItem__c
            WHERE AgentExecution__c = :executionId AND RecordId__c = :recordId
            LIMIT 1
        ];
        return items.isEmpty() ? null : items[0];
    }

    /**
     * Counts the number of items for an execution by status.
     * @param executionId The execution ID
     * @return Map of status to count
     */
    public Map<String, Integer> getCountsByStatus(Id executionId) {
        Map<String, Integer> counts = new Map<String, Integer>();

        for (AggregateResult ar : [
            SELECT Status__c, COUNT(Id) cnt
            FROM ContextLedgerItem__c
            WHERE AgentExecution__c = :executionId
            GROUP BY Status__c
        ]) {
            String status = (String) ar.get('Status__c');
            Integer count = (Integer) ar.get('cnt');
            counts.put(status, count);
        }

        return counts;
    }

    // --- UPDATE OPERATIONS ---

    /**
     * Updates a single context ledger item.
     * @param item The item to update
     */
    public void updateItem(ContextLedgerItem__c item) {
        update item;
    }

    /**
     * Updates multiple context ledger items in bulk.
     * @param items List of items to update
     */
    public void updateItems(List<ContextLedgerItem__c> items) {
        if (items == null || items.isEmpty()) {
            return;
        }
        update items;
    }

    /**
     * Updates an item with optimistic locking check.
     * @param item The item to update
     * @param expectedLastModified The expected LastModifiedDate
     * @return True if update succeeded, false if version conflict
     */
    public Boolean updateItemWithVersionCheck(ContextLedgerItem__c item, Datetime expectedLastModified) {
        // Verify the item hasn't been modified since it was read
        List<ContextLedgerItem__c> current = [
            SELECT LastModifiedDate
            FROM ContextLedgerItem__c
            WHERE Id = :item.Id
            LIMIT 1
        ];

        if (current.isEmpty()) {
            return false; // Item was deleted
        }

        if (expectedLastModified != null && current[0].LastModifiedDate != expectedLastModified) {
            return false; // Version conflict
        }

        update item;
        return true;
    }

    // --- DELETE OPERATIONS ---

    /**
     * Hard deletes context ledger items (use with caution).
     * Prefer soft delete by updating Status__c to 'PRUNED'.
     * @param items Items to delete
     */
    public void deleteItems(List<ContextLedgerItem__c> items) {
        if (items == null || items.isEmpty()) {
            return;
        }
        delete items;
    }

    /**
     * Soft deletes items by marking them as PRUNED.
     * @param items Items to soft delete
     * @param reason Reason for pruning
     */
    public void softDeleteItems(List<ContextLedgerItem__c> items, String reason) {
        if (items == null || items.isEmpty()) {
            return;
        }

        Datetime now = Datetime.now();
        for (ContextLedgerItem__c item : items) {
            item.Status__c = 'PRUNED';
            item.PrunedAt__c = now;
            item.PrunedReason__c = reason;
        }

        update items;
    }

    /**
     * Archives items by marking them as ARCHIVED (keeps in context but low priority).
     * @param items Items to archive
     */
    public void archiveItems(List<ContextLedgerItem__c> items) {
        if (items == null || items.isEmpty()) {
            return;
        }

        for (ContextLedgerItem__c item : items) {
            item.Status__c = 'ARCHIVED';
        }

        update items;
    }

    // --- BATCH OPERATIONS ---

    /**
     * Deletes all pruned items older than specified days (cleanup utility).
     * @param daysOld Number of days to retain pruned items
     * @return Number of items deleted
     */
    public Integer deletePrunedItemsOlderThan(Integer daysOld) {
        Datetime cutoffDate = Datetime.now().addDays(-daysOld);

        List<ContextLedgerItem__c> toDelete = [
            SELECT Id
            FROM ContextLedgerItem__c
            WHERE Status__c = 'PRUNED' AND PrunedAt__c < :cutoffDate
            LIMIT 10000
        ];

        if (!toDelete.isEmpty()) {
            delete toDelete;
        }

        return toDelete.size();
    }
}

