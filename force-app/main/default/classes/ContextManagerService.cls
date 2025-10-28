/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Orchestrates lifecycle of conversational context for AI-driven chat sessions.
 * Uses ContextLedgerItem__c child records for scalability and performance.
 */
public inherited sharing class ContextManagerService {
    // --- CONSTANTS ---
    private static final Integer MAX_CONTEXT_ITEMS = 50;
    private static final Integer RELEVANCE_DECAY_THRESHOLD = 10; // turns
    private static final Decimal BASE_RELEVANCE_SCORE = 100.0;

    // Scoring algorithm constants (configurable in future via custom metadata)
    private static final Decimal AGE_DECAY_RATE = 0.99; // Slow decay per turn
    private static final Decimal RECENCY_DECAY_RATE = 0.95; // Fast decay per turn
    private static final Decimal AGE_WEIGHT = 0.3; // Weight for age decay
    private static final Decimal RECENCY_WEIGHT = 0.7; // Weight for recency decay
    private static final Decimal ACCESS_BOOST_MULTIPLIER = 20.0; // Multiplier for access frequency
    private static final Decimal RECENT_ACCESS_BOOST = 1.5; // Boost for recently accessed items
    private static final Integer RECENT_ACCESS_THRESHOLD = 2; // Turns threshold for "recent"
    private static final Decimal MIN_RELEVANCE_SCORE = 1.0; // Floor to prevent zero/negative
    private static final Decimal PINNED_RELEVANCE_SCORE = 9999.0; // PINNED items never decay

    // --- DEPENDENCIES ---
    private final ContextLedgerRepository repository;

    // --- EXCEPTIONS ---
    public class ContextManagementException extends AIAgentException {
    }

    // --- ENUMS ---
    public enum ContextType {
        IMPLICIT_PRIMARY, // User's current page (highest priority)
        IMPLICIT_SECONDARY, // Related to current page
        ACTION_GENERATED, // Created by agent action
        USER_MENTIONED, // Explicitly referenced by user
        SEARCH_RESULT, // Found via search action
        RELATED_RECORD, // Discovered through relationships
        PINNED, // User explicitly pinned
        BACKGROUND_CONTEXT // Supporting information
    }

    public enum ContextStatus {
        ACTIVE,
        ARCHIVED,
        PRUNED
    }

    // --- CORE DATA STRUCTURE ---
    @TestVisible
    public class ContextItem implements Comparable {
        public String id;
        public String type;
        public ContextType contextType;
        public ContextStatus status;
        public Integer turnAdded;
        public Integer lastAccessed;
        public Integer accessCount;
        public Decimal relevanceScore;
        public String sourceId;
        public List<String> childIds;
        public Map<String, Object> metadata;

        // Additional fields for improved tracking
        public ContextType originalContextType;
        public Datetime lastDataRefreshTime;

        public ContextItem(Id recordId, ContextType ctxType, Integer turn, Id source) {
            this.id = String.valueOf(recordId);
            // Safely get the SObject type name
            try {
                this.type = recordId.getSObjectType().getDescribe().getName();
            } catch (Exception e) {
                this.type = 'Unknown';
            }
            this.contextType = ctxType;
            this.originalContextType = ctxType;
            this.status = ContextStatus.ACTIVE;
            this.turnAdded = turn;
            this.lastAccessed = turn;
            this.accessCount = 1;
            this.relevanceScore = calculateInitialRelevance(ctxType);
            this.sourceId = source != null ? String.valueOf(source) : null;
            this.childIds = new List<String>();
            this.metadata = new Map<String, Object>();
            this.lastDataRefreshTime = Datetime.now();
        }

        /**
         * Constructor from ContextLedgerItem__c record.
         */
        public ContextItem(ContextLedgerItem__c record) {
            this.id = record.RecordId__c;
            this.type = record.RecordType__c;
            this.contextType = ContextManagerService.ContextType.valueOf(record.ContextType__c);
            this.status = ContextManagerService.ContextStatus.valueOf(record.Status__c);
            this.turnAdded = Integer.valueOf(record.TurnAdded__c);
            this.lastAccessed = Integer.valueOf(record.LastAccessedTurn__c);
            this.accessCount = Integer.valueOf(record.AccessCount__c);
            this.relevanceScore = record.RelevanceScore__c;
            this.sourceId = record.SourceRecordId__c;
            this.lastDataRefreshTime = record.LastDataRefreshTime__c;

            if (String.isNotBlank(record.OriginalContextType__c)) {
                this.originalContextType = ContextManagerService.ContextType.valueOf(record.OriginalContextType__c);
            } else {
                this.originalContextType = this.contextType;
            }

            // Parse child IDs from JSON
            if (String.isNotBlank(record.ChildRecordIds__c)) {
                try {
                    this.childIds = (List<String>) JSON.deserialize(record.ChildRecordIds__c, List<String>.class);
                } catch (Exception e) {
                    this.childIds = new List<String>();
                    System.debug(LoggingLevel.WARN, '[ContextManagerService] Failed to parse childIds: ' + e.getMessage());
                }
            } else {
                this.childIds = new List<String>();
            }

            // Parse metadata from JSON
            if (String.isNotBlank(record.Metadata__c)) {
                try {
                    this.metadata = (Map<String, Object>) JSON.deserializeUntyped(record.Metadata__c);
                } catch (Exception e) {
                    this.metadata = new Map<String, Object>();
                    System.debug(LoggingLevel.WARN, '[ContextManagerService] Failed to parse metadata: ' + e.getMessage());
                }
            } else {
                this.metadata = new Map<String, Object>();
            }
        }

        /**
         * Converts this ContextItem to a ContextLedgerItem__c record.
         */
        public ContextLedgerItem__c toRecord(Id executionId) {
            ContextLedgerItem__c record = new ContextLedgerItem__c();
            record.AgentExecution__c = executionId;
            record.RecordId__c = this.id;
            record.RecordType__c = this.type;
            record.ContextType__c = this.contextType.name();
            record.Status__c = this.status.name();
            record.TurnAdded__c = this.turnAdded;
            record.LastAccessedTurn__c = this.lastAccessed;
            record.AccessCount__c = this.accessCount;
            record.RelevanceScore__c = this.relevanceScore;
            record.SourceRecordId__c = this.sourceId;
            record.OriginalContextType__c = this.originalContextType != null ? this.originalContextType.name() : null;
            record.LastDataRefreshTime__c = this.lastDataRefreshTime;

            // Serialize child IDs to JSON
            if (this.childIds != null && !this.childIds.isEmpty()) {
                record.ChildRecordIds__c = JSON.serialize(this.childIds);
            }

            // Serialize metadata to JSON
            if (this.metadata != null && !this.metadata.isEmpty()) {
                record.Metadata__c = JSON.serialize(this.metadata);
            }

            return record;
        }

        /**
         * Calculates initial relevance score based on context type.
         */
        private Decimal calculateInitialRelevance(ContextType ctxType) {
            switch on ctxType {
                when IMPLICIT_PRIMARY {
                    return BASE_RELEVANCE_SCORE * 2.0;
                }
                when ACTION_GENERATED {
                    return BASE_RELEVANCE_SCORE * 1.8;
                }
                when USER_MENTIONED {
                    return BASE_RELEVANCE_SCORE * 1.6;
                }
                when PINNED {
                    return PINNED_RELEVANCE_SCORE; // Special value
                }
                when SEARCH_RESULT {
                    return BASE_RELEVANCE_SCORE * 1.2;
                }
                when IMPLICIT_SECONDARY {
                    return BASE_RELEVANCE_SCORE * 1.0;
                }
                when RELATED_RECORD {
                    return BASE_RELEVANCE_SCORE * 0.8;
                }
                when else {
                    return BASE_RELEVANCE_SCORE * 0.6;
                }
            }
        }

        /**
         * IMPROVED: Updates relevance score with fixed algorithm.
         * - PINNED items never decay
         * - Uses both age and recency
         * - Uses Math.pow() instead of custom loop
         * - Prevents negative/zero scores
         */
        public void updateRelevance(Integer currentTurn) {
            // CRITICAL FIX: PINNED items never decay
            if (this.contextType == ContextManagerService.ContextType.PINNED) {
                this.relevanceScore = PINNED_RELEVANCE_SCORE;
                return;
            }

            Integer turnsSinceAdded = currentTurn - this.turnAdded;
            Integer turnsSinceAccessed = currentTurn - this.lastAccessed;

            // Get base score for current context type
            Decimal baseScore = calculateInitialRelevance(this.contextType);

            // Calculate temporal decay factors using Math.pow() (FIX: no more custom loop)
            // Math.pow() requires Double, so we convert
            Decimal ageDecay = Decimal.valueOf(Math.pow(AGE_DECAY_RATE.doubleValue(), turnsSinceAdded));
            Decimal recencyDecay = Decimal.valueOf(Math.pow(RECENCY_DECAY_RATE.doubleValue(), turnsSinceAccessed));

            // Combined decay (recency matters more)
            Decimal combinedDecay = (ageDecay * AGE_WEIGHT) + (recencyDecay * RECENCY_WEIGHT);

            // Access frequency boost (square root for better scaling)
            Decimal accessBoost = Math.sqrt(this.accessCount) * ACCESS_BOOST_MULTIPLIER;

            // Recent access multiplier
            Decimal recentBoost = turnsSinceAccessed <= RECENT_ACCESS_THRESHOLD ? RECENT_ACCESS_BOOST : 1.0;

            // Calculate final score with floor to prevent negatives
            this.relevanceScore = (baseScore * combinedDecay * recentBoost) + accessBoost;
            this.relevanceScore = Math.max(this.relevanceScore, MIN_RELEVANCE_SCORE);

            // Archive very old, low-relevance items (but never PINNED)
            if (turnsSinceAccessed > RELEVANCE_DECAY_THRESHOLD && this.relevanceScore < 20) {
                this.status = ContextStatus.ARCHIVED;
            }
        }

        public void recordAccess(Integer currentTurn) {
            this.lastAccessed = currentTurn;
            this.accessCount++;
            updateRelevance(currentTurn);
        }

        public void addChild(String childId) {
            if (!this.childIds.contains(childId)) {
                this.childIds.add(childId);
            }
        }

        public void setMetadata(String key, Object value) {
            this.metadata.put(key, value);
        }

        public Object getMetadata(String key) {
            return this.metadata.get(key);
        }

        /**
         * IMPROVED: Comparison with null handling and type priority.
         */
        public Integer compareTo(Object compareTo) {
            if (compareTo == null)
                return -1;
            if (!(compareTo instanceof ContextItem)) {
                throw new IllegalArgumentException('Can only compare to ContextItem');
            }

            ContextItem other = (ContextItem) compareTo;

            // PINNED items always first
            if (this.contextType == ContextManagerService.ContextType.PINNED && other.contextType != ContextManagerService.ContextType.PINNED) {
                return -1;
            }
            if (other.contextType == ContextManagerService.ContextType.PINNED && this.contextType != ContextManagerService.ContextType.PINNED) {
                return 1;
            }

            // Then by status (ACTIVE before ARCHIVED before PRUNED)
            if (this.status != other.status) {
                return this.status.ordinal() - other.status.ordinal();
            }

            // Then by relevance score
            if (this.relevanceScore != other.relevanceScore) {
                return this.relevanceScore > other.relevanceScore ? -1 : 1;
            }

            // Then by last accessed
            if (this.lastAccessed != other.lastAccessed) {
                return this.lastAccessed > other.lastAccessed ? -1 : 1;
            }

            // Finally by access count
            return other.accessCount - this.accessCount;
        }

        public String getTemporalLabel(Integer currentTurn) {
            Integer turnsSince = currentTurn - this.lastAccessed;
            if (turnsSince == 0)
                return 'Current Turn';
            if (turnsSince == 1)
                return 'Last Turn';
            if (turnsSince <= 3)
                return turnsSince + ' turns ago';
            if (turnsSince <= 10)
                return 'Recently';
            return 'Earlier in conversation';
        }

        /**
         * Checks if context data needs refreshing (stale detection).
         */
        public Boolean needsRefresh() {
            if (this.lastDataRefreshTime == null)
                return true;
            // Refresh if older than 5 minutes
            Long ageMillis = Datetime.now().getTime() - this.lastDataRefreshTime.getTime();
            return ageMillis > 300000;
        }
    }

    // --- CONSTRUCTORS ---

    public ContextManagerService() {
        this(new ContextLedgerRepository());
    }

    @TestVisible
    public ContextManagerService(ContextLedgerRepository repo) {
        this.repository = repo;
    }

    // --- CORE PUBLIC METHODS ---

    /**
     * Retrieves context items for an execution with dynamic scoring.
     * Main method for the unified execution model.
     *
     * @param executionId   The AgentExecution__c identifier (required)
     * @param currentTurn   The current conversation turn, used for temporal calculations (optional)
     * @return              List of ContextItem objects sorted by relevance
     * @throws              None (returns empty list on error)
     */
    public List<ContextItem> getContextLedger(Id executionId, Integer currentTurn) {
        if (executionId == null) {
            return new List<ContextItem>();
        }

        try {
            // Query active items from repository
            List<ContextLedgerItem__c> records = repository.getActiveItemsForExecution(executionId);

            // Convert to ContextItem objects
            List<ContextItem> ledger = new List<ContextItem>();
            for (ContextLedgerItem__c record : records) {
                ledger.add(new ContextItem(record));
            }

            // Process for retrieval (update scores, sort)
            return processLedgerForRetrieval(ledger, currentTurn);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.getContextLedger] Failed to retrieve context ledger for execution ' + executionId + ': ' + e.getMessage()
            );
            return new List<ContextItem>();
        }
    }

    /**
     * Retrieves context items filtered by type and minimum relevance.
     */
    public List<ContextItem> getFilteredContext(Id executionId, Integer currentTurn, Set<ContextType> contextTypes, Decimal minRelevance) {
        List<ContextItem> allItems = getContextLedger(executionId, currentTurn);
        List<ContextItem> filtered = new List<ContextItem>();

        for (ContextItem item : allItems) {
            if (
                item.status == ContextStatus.ACTIVE &&
                item.relevanceScore >= minRelevance &&
                (contextTypes == null || contextTypes.contains(item.contextType))
            ) {
                filtered.add(item);
            }
        }

        return filtered;
    }

    /**
     * Organizes context items into hierarchical categories for LLM prompt construction.
     */
    public Map<String, List<ContextItem>> getStructuredContext(Id executionId, Integer currentTurn) {
        List<ContextItem> items = getContextLedger(executionId, currentTurn);
        Map<String, List<ContextItem>> structured = new Map<String, List<ContextItem>>();

        // Initialize categories
        structured.put('pinned', new List<ContextItem>()); // NEW: Separate pinned category
        structured.put('primary', new List<ContextItem>());
        structured.put('recent', new List<ContextItem>());
        structured.put('related', new List<ContextItem>());
        structured.put('background', new List<ContextItem>());
        structured.put('stale', new List<ContextItem>()); // NEW: Stale category

        for (ContextItem item : items) {
            String category = categorizeForPrompt(item, currentTurn);
            if (structured.containsKey(category)) {
                structured.get(category).add(item);
            }
        }

        return structured;
    }

    /**
     * IMPROVED: Commits context changes with deduplication and optimistic locking.
     *
     * @param executionId             The ID of the AgentExecution__c to update
     * @param currentTurn             The current turn number for temporal scoring
     * @param pageContextId           The ID of the record representing the user's current page context (can be null)
     * @param newRecordFromActionId   The ID of a record created by an agent action (can be null)
     * @throws                     ContextManagementException if critical error occurs
     */
    public void commitExecutionTurnContext(Id executionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (executionId == null || (pageContextId == null && newRecordFromActionId == null)) {
            return;
        }

        String logPrefix = '[ContextManager.Commit ' + executionId + '] ';

        try {
            // FIX: Query all items and build FRESH map
            List<ContextLedgerItem__c> existingRecords = repository.getAllItemsForExecution(executionId);
            List<ContextItem> ledger = new List<ContextItem>();
            Map<String, ContextItem> ledgerMapByRecordId = new Map<String, ContextItem>();

            for (ContextLedgerItem__c record : existingRecords) {
                ContextItem item = new ContextItem(record);
                ledger.add(item);
                ledgerMapByRecordId.put(item.id, item);
            }

            // FIX: Process with deduplication
            if (pageContextId != null) {
                String pageRecordIdStr = String.valueOf(pageContextId);
                processPageContextWithDeduplication(ledgerMapByRecordId, ledger, pageRecordIdStr, currentTurn);
            }

            if (newRecordFromActionId != null) {
                String actionRecordIdStr = String.valueOf(newRecordFromActionId);
                String pageRecordIdStr = pageContextId != null ? String.valueOf(pageContextId) : null;
                processActionContextWithDeduplication(ledgerMapByRecordId, ledger, actionRecordIdStr, currentTurn, pageRecordIdStr);
            }

            // Apply pruning (soft delete)
            pruneLedger(ledger, currentTurn);

            // Convert to records and upsert
            List<ContextLedgerItem__c> recordsToUpsert = new List<ContextLedgerItem__c>();
            for (ContextItem item : ledger) {
                recordsToUpsert.add(item.toRecord(executionId));
            }

            repository.upsertItems(recordsToUpsert);

            System.debug(LoggingLevel.INFO, logPrefix + 'Context ledger updated. Item count: ' + ledger.size());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context commit failed: ' + e.getMessage());
            throw new ContextManagementException('Context commit failed: ' + e.getMessage(), e);
        }
    }

    // --- PRIVATE HELPER METHODS ---

    /**
     * FIX: Process page context with deduplication.
     */
    private void processPageContextWithDeduplication(
        Map<String, ContextItem> ledgerMap,
        List<ContextItem> ledger,
        String pageContextId,
        Integer currentTurn
    ) {
        if (ledgerMap.containsKey(pageContextId)) {
            // Update existing
            ContextItem existing = ledgerMap.get(pageContextId);
            existing.recordAccess(currentTurn);

            // Promote to primary if not pinned
            if (
                existing.contextType != ContextManagerService.ContextType.PINNED &&
                existing.contextType != ContextManagerService.ContextType.IMPLICIT_PRIMARY
            ) {
                // Track original type before promotion
                if (existing.originalContextType == null) {
                    existing.originalContextType = existing.contextType;
                }
                existing.contextType = ContextType.IMPLICIT_PRIMARY;
                // Apply additive boost instead of replacement
                existing.relevanceScore += (BASE_RELEVANCE_SCORE * 0.5);
            }
        } else {
            // Create new
            try {
                Id recordId = Id.valueOf(pageContextId);
                ContextItem newItem = new ContextItem(recordId, ContextType.IMPLICIT_PRIMARY, currentTurn, null);
                ledger.add(newItem);
                ledgerMap.put(pageContextId, newItem);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[ContextManagerService] Invalid page context ID: ' + pageContextId);
            }
        }
    }

    /**
     * FIX: Process action context with deduplication and relationship tracking.
     */
    private void processActionContextWithDeduplication(
        Map<String, ContextItem> ledgerMap,
        List<ContextItem> ledger,
        String newRecordId,
        Integer currentTurn,
        String pageContextId
    ) {
        if (ledgerMap.containsKey(newRecordId)) {
            // Update existing
            ledgerMap.get(newRecordId).recordAccess(currentTurn);
        } else {
            // Create new
            try {
                Id recordId = Id.valueOf(newRecordId);
                Id sourceId = String.isNotBlank(pageContextId) ? Id.valueOf(pageContextId) : null;
                ContextItem newItem = new ContextItem(recordId, ContextType.ACTION_GENERATED, currentTurn, sourceId);
                newItem.setMetadata('createdByAgent', true);
                ledger.add(newItem);
                ledgerMap.put(newRecordId, newItem);

                // Update parent-child relationship
                if (String.isNotBlank(pageContextId) && ledgerMap.containsKey(pageContextId)) {
                    ledgerMap.get(pageContextId).addChild(newRecordId);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[ContextManagerService] Invalid action record ID: ' + newRecordId);
            }
        }
    }

    /**
     * FIX: Soft delete pruning instead of permanent deletion.
     */
    private void pruneLedger(List<ContextItem> ledger, Integer currentTurn) {
        if (ledger == null || ledger.isEmpty())
            return;

        try {
            // Soft delete items with very low relevance (except PINNED)
            for (ContextItem item : ledger) {
                if (
                    item.status == ContextManagerService.ContextStatus.ACTIVE &&
                    item.contextType != ContextManagerService.ContextType.PINNED && // Never prune PINNED
                    item.relevanceScore < 0.1
                ) {
                    item.status = ContextStatus.PRUNED;
                    item.setMetadata('prunedAt', Datetime.now());
                    item.setMetadata('prunedReason', 'Low relevance: ' + item.relevanceScore + ' at turn ' + currentTurn);
                }
            }

            // If still over limit, archive lowest-scoring items (but keep PINNED)
            List<ContextItem> activeItems = new List<ContextItem>();
            List<ContextItem> pinnedItems = new List<ContextItem>();

            for (ContextItem item : ledger) {
                if (item.status == ContextManagerService.ContextStatus.ACTIVE) {
                    if (item.contextType == ContextManagerService.ContextType.PINNED) {
                        pinnedItems.add(item);
                    } else {
                        activeItems.add(item);
                    }
                }
            }

            // Sort active items by relevance
            activeItems.sort();

            // Archive excess items beyond limit
            Integer maxActiveItems = MAX_CONTEXT_ITEMS - pinnedItems.size();
            if (activeItems.size() > maxActiveItems) {
                for (Integer i = maxActiveItems; i < activeItems.size(); i++) {
                    activeItems[i].status = ContextStatus.ARCHIVED;
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ContextManagerService.pruneLedger] Failed to prune ledger: ' + e.getMessage());
        }
    }

    /**
     * Updates relevance scores and sorts ledger.
     */
    private List<ContextItem> processLedgerForRetrieval(List<ContextItem> ledger, Integer currentTurn) {
        List<ContextItem> activeItems = new List<ContextItem>();

        for (ContextItem item : ledger) {
            try {
                if (item.status == ContextManagerService.ContextStatus.ACTIVE) {
                    item.updateRelevance(currentTurn);
                    activeItems.add(item);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Failed to update relevance for item ' + item.id + ': ' + e.getMessage());
            }
        }

        try {
            activeItems.sort();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ContextManagerService] Failed to sort context items: ' + e.getMessage());
        }

        return activeItems;
    }

    /**
     * IMPROVED: Categorization with pinned and stale categories.
     */
    private String categorizeForPrompt(ContextItem item, Integer currentTurn) {
        Integer turnsSinceAccessed = currentTurn - item.lastAccessed;

        // Special handling for pinned
        if (item.contextType == ContextManagerService.ContextType.PINNED) {
            return 'pinned';
        }

        // Primary context
        if (item.contextType == ContextManagerService.ContextType.IMPLICIT_PRIMARY) {
            return 'primary';
        }

        // Recent items (within last 2 turns)
        if (turnsSinceAccessed <= 2) {
            return 'recent';
        }

        // High-relevance items
        if (item.relevanceScore > BASE_RELEVANCE_SCORE * 1.5) {
            return 'related';
        }

        // Stale but still tracked
        if (turnsSinceAccessed > 10) {
            return 'stale';
        }

        return 'background';
    }
}
