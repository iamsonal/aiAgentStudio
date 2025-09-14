/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextManagerService orchestrates the lifecycle of conversational context for AI-driven chat sessions.
 * It manages a ledger of context items, dynamically scoring and prioritizing them using recency, access patterns,
 * hierarchical relationships, and temporal decay. The service supports context pruning, pinning, and categorization
 * to optimize prompt construction for LLMs, while ensuring efficient storage and robust error handling.
 *
 * Responsibilities:
 * - Maintain and update a context ledger per chat session, tracking context items and their relationships.
 * - Dynamically score, filter, and categorize context items for prompt optimization and memory management.
 * - Prune, archive, or pin context items based on relevance, recency, and user actions.
 * - Provide robust error handling, debug output, and extensible metadata for context enrichment.
 */
public inherited sharing class ContextManagerService {
    // --- CONSTANTS ---
    private static final Integer MAX_CONTEXT_ITEMS = 50;
    private static final Integer RELEVANCE_DECAY_THRESHOLD = 10; // turns
    private static final Decimal BASE_RELEVANCE_SCORE = 100.0;

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

        public ContextItem(Id recordId, ContextType ctxType, Integer turn, Id source) {
            this.id = String.valueOf(recordId);
            this.type = recordId.getSObjectType().getDescribe().getName();
            this.contextType = ctxType;
            this.status = ContextStatus.ACTIVE;
            this.turnAdded = turn;
            this.lastAccessed = turn;
            this.accessCount = 1;
            this.relevanceScore = calculateInitialRelevance(ctxType);
            this.sourceId = source != null ? String.valueOf(source) : null;
            this.childIds = new List<String>();
            this.metadata = new Map<String, Object>();
        }

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
                    return BASE_RELEVANCE_SCORE * 1.5;
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

        public void updateRelevance(Integer currentTurn) {
            // Temporal decay factor
            Integer turnsSinceAdded = currentTurn - this.turnAdded;
            Integer turnsSinceAccessed = currentTurn - this.lastAccessed;

            // Calculate temporal decay using exponential decay formula
            Decimal temporalDecay = calculateExponentialDecay(0.95, turnsSinceAccessed);
            Decimal accessBoost = calculateLogBoost(this.accessCount + 1) * 10;

            this.relevanceScore = (this.relevanceScore * temporalDecay) + accessBoost;

            // Boost for recently accessed items
            if (turnsSinceAccessed <= 2) {
                this.relevanceScore *= 1.3;
            }

            // Archive very old, low-relevance items
            if (turnsSinceAccessed > RELEVANCE_DECAY_THRESHOLD && this.relevanceScore < 20) {
                this.status = ContextStatus.ARCHIVED;
            }
        }

        private Decimal calculateExponentialDecay(Decimal base, Integer exponent) {
            if (exponent == 0)
                return 1.0;
            if (exponent == 1)
                return base;

            Decimal result = 1.0;
            for (Integer i = 0; i < exponent; i++) {
                result *= base;
            }
            return result;
        }

        private Decimal calculateLogBoost(Integer value) {
            if (value <= 1)
                return 0.0;

            // Approximate natural log using series expansion for small values
            Decimal x = value - 1.0;
            if (x > 10) {
                // For larger values, use a simplified approximation
                return 2.3 * Math.log10(value);
            }

            // Taylor series approximation: ln(1+x) ≈ x - x²/2 + x³/3 - x⁴/4
            Decimal result = x;
            Decimal term = x;
            for (Integer n = 2; n <= 4; n++) {
                term *= -x;
                result += term / n;
            }
            return result;
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

        public Integer compareTo(Object compareTo) {
            ContextItem other = (ContextItem) compareTo;

            // Primary sort: relevance score (descending)
            if (this.relevanceScore > other.relevanceScore)
                return -1;
            if (this.relevanceScore < other.relevanceScore)
                return 1;

            // Secondary sort: last accessed (descending)
            if (this.lastAccessed > other.lastAccessed)
                return -1;
            if (this.lastAccessed < other.lastAccessed)
                return 1;

            // Tertiary sort: access count (descending)
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
    }

    // --- CORE PUBLIC METHODS ---

    /**
     * Retrieves and dynamically scores context items for a chat session, applying recency, access patterns,
     * and temporal decay to maintain optimal prioritization. Only active items are returned, sorted by relevance.
     *
     * @param sessionId   The chat session identifier (required)
     * @param currentTurn The current conversation turn, used for temporal calculations
     * @return            List of active ContextItem objects, sorted by descending relevance
     * @throws            None (returns empty list on error)
     */
    public List<ContextItem> getContextLedger(Id sessionId, Integer currentTurn) {
        if (sessionId == null)
            return new List<ContextItem>();

        try {
            List<ChatSession__c> sessions = [
                SELECT EntityHistoryJson__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
            ];

            if (sessions.isEmpty() || String.isBlank(sessions[0].EntityHistoryJson__c)) {
                return new List<ContextItem>();
            }

            List<ContextItem> ledger = parseLedger(sessions[0].EntityHistoryJson__c);
            return processLedgerForRetrieval(ledger, currentTurn);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.getContextLedger] Failed to retrieve context ledger for session ' + sessionId + ': ' + e.getMessage()
            );
            return new List<ContextItem>();
        }
    }

    /**
     * Legacy compatibility overload: Retrieves context items for a session without applying temporal relevance scoring.
     *
     * @param sessionId The chat session identifier
     * @return          List of ContextItem objects (may not reflect current turn relevance)
     */
    public List<ContextItem> getContextLedger(Id sessionId) {
        return getContextLedger(sessionId, 0);
    }

    /**
     * Retrieves context items for a session, filtered by context type and minimum relevance score.
     *
     * @param sessionId    The chat session identifier
     * @param currentTurn  The current conversation turn
     * @param contextTypes Set of ContextType values to include (null for all types)
     * @param minRelevance Minimum relevance score for inclusion
     * @return             List of filtered ContextItem objects
     */
    public List<ContextItem> getFilteredContext(Id sessionId, Integer currentTurn, Set<ContextType> contextTypes, Decimal minRelevance) {
        List<ContextItem> allItems = getContextLedger(sessionId, currentTurn);
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
     * Items are grouped by priority and recency for optimal prompt effectiveness.
     *
     * @param sessionId   The chat session identifier
     * @param currentTurn The current conversation turn
     * @return            Map of category names to lists of ContextItem objects
     */
    public Map<String, List<ContextItem>> getStructuredContext(Id sessionId, Integer currentTurn) {
        List<ContextItem> items = getContextLedger(sessionId, currentTurn);
        Map<String, List<ContextItem>> structured = new Map<String, List<ContextItem>>();

        // Initialize categories
        structured.put('primary', new List<ContextItem>());
        structured.put('recent', new List<ContextItem>());
        structured.put('related', new List<ContextItem>());
        structured.put('background', new List<ContextItem>());

        for (ContextItem item : items) {
            String category = categorizeForPrompt(item, currentTurn);
            if (structured.containsKey(category)) {
                structured.get(category).add(item);
            }
        }

        return structured;
    }

    /**
     * Commits the current turn's context to the session ledger, updating relationships and optimizing the ledger.
     * Maintains parent-child relationships, applies pruning, and persists changes atomically.
     *
     * @param sessionId             The chat session identifier
     * @param currentTurn           The current conversation turn
     * @param pageContextId         The current page record being viewed (optional)
     * @param newRecordFromActionId Record created during agent action execution (optional)
     * @throws                     ContextManagementException if the session is not found or ledger is oversized
     */
    public void commitTurnContext(Id sessionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (sessionId == null || (pageContextId == null && newRecordFromActionId == null)) {
            return;
        }

        String logPrefix = '[ContextManager.Commit ' + sessionId + '] ';

        try {
            // Lock session for atomic update to prevent concurrent modifications
            List<ChatSession__c> sessions = [
                SELECT Id, EntityHistoryJson__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty()) {
                throw new ContextManagementException('No ChatSession__c found for sessionId: ' + sessionId);
            }

            ChatSession__c session = sessions[0];
            List<ContextItem> ledger = parseLedger(session.EntityHistoryJson__c);
            Map<Id, ContextItem> ledgerMap = buildLedgerMap(ledger);

            // Process page context with intelligent type detection
            if (pageContextId != null) {
                processPageContext(ledgerMap, ledger, pageContextId, currentTurn);
            }

            // Process action-generated records with relationship tracking
            if (newRecordFromActionId != null) {
                processActionGeneratedContext(ledgerMap, ledger, newRecordFromActionId, pageContextId, currentTurn);
            }

            // Update all item relevance scores and prune if necessary
            ledger = optimizeLedger(ledger, currentTurn);

            // Persist with size validation
            String serializedLedger = JSON.serialize(ledger);
            validateLedgerSize(serializedLedger);

            session.EntityHistoryJson__c = serializedLedger;
            update session;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Context ledger updated. Item count: ' + ledger.size() + ', Serialized size: ' + serializedLedger.length() + ' chars.'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context commit failed: ' + e.getMessage());
            throw new ContextManagementException('Context commit failed: ' + e.getMessage(), e);
        }
    }

    /**
     * Adds or updates a context item in the session ledger, updating metadata and relationships as needed.
     * If the item exists, its access and metadata are updated; otherwise, a new item is created.
     *
     * @param sessionId   The chat session identifier
     * @param recordId    The record to add or update
     * @param contextType The context item type
     * @param currentTurn The current conversation turn
     * @param sourceId    Optional parent record for relationship tracking
     * @param metadata    Additional metadata for context enrichment (optional)
     */
    public void addContextItem(Id sessionId, Id recordId, ContextType contextType, Integer currentTurn, Id sourceId, Map<String, Object> metadata) {
        if (sessionId == null || recordId == null)
            return;

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, EntityHistoryJson__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty())
                return;

            ChatSession__c session = sessions[0];
            List<ContextItem> ledger = parseLedger(session.EntityHistoryJson__c);
            Map<Id, ContextItem> ledgerMap = buildLedgerMap(ledger);

            if (ledgerMap.containsKey(recordId)) {
                // Update existing item
                ContextItem existing = ledgerMap.get(recordId);
                existing.recordAccess(currentTurn);
                if (metadata != null) {
                    existing.metadata.putAll(metadata);
                }
            } else {
                // Create new item
                ContextItem newItem = new ContextItem(recordId, contextType, currentTurn, sourceId);
                if (metadata != null) {
                    newItem.metadata.putAll(metadata);
                }
                ledger.add(newItem);

                // Update parent-child relationships
                if (sourceId != null && ledgerMap.containsKey(sourceId)) {
                    ledgerMap.get(sourceId).addChild(String.valueOf(recordId));
                }
            }

            ledger = optimizeLedger(ledger, currentTurn);
            session.EntityHistoryJson__c = JSON.serialize(ledger);
            update session;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.addContextItem] Failed to add/update context item ' +
                    recordId +
                    ' for session ' +
                    sessionId +
                    ': ' +
                    e.getMessage()
            );
        }
    }

    /**
     * Pins a context item for a session, marking it as permanently relevant to prevent pruning.
     *
     * @param sessionId   The chat session identifier
     * @param recordId    The record to pin
     * @param currentTurn The current conversation turn
     */
    public void pinContextItem(Id sessionId, Id recordId, Integer currentTurn) {
        addContextItem(sessionId, recordId, ContextType.PINNED, currentTurn, null, new Map<String, Object>{ 'pinned' => true });
    }

    /**
     * Removes a context item from the session ledger, or archives it if pinned.
     *
     * @param sessionId The chat session identifier
     * @param recordId  The record to remove or archive
     */
    public void removeContextItem(Id sessionId, Id recordId) {
        if (sessionId == null || recordId == null)
            return;

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, EntityHistoryJson__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessions.isEmpty())
                return;

            ChatSession__c session = sessions[0];
            List<ContextItem> ledger = parseLedger(session.EntityHistoryJson__c);

            for (Integer i = ledger.size() - 1; i >= 0; i--) {
                if (ledger[i].id == String.valueOf(recordId)) {
                    if (ledger[i].contextType == ContextType.PINNED) {
                        ledger[i].status = ContextStatus.ARCHIVED;
                    } else {
                        ledger.remove(i);
                    }
                    break;
                }
            }

            session.EntityHistoryJson__c = JSON.serialize(ledger);
            update session;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.removeContextItem] Failed to remove context item ' +
                    recordId +
                    ' for session ' +
                    sessionId +
                    ': ' +
                    e.getMessage()
            );
        }
    }

    // --- PRIVATE HELPER METHODS ---

    /**
     * Updates relevance scores for all active items in the ledger and returns them sorted by relevance.
     *
     * @param ledger      The list of ContextItem objects
     * @param currentTurn The current conversation turn
     * @return            List of active ContextItem objects, sorted by relevance
     */
    private List<ContextItem> processLedgerForRetrieval(List<ContextItem> ledger, Integer currentTurn) {
        List<ContextItem> activeItems = new List<ContextItem>();

        for (ContextItem item : ledger) {
            if (item.status == ContextStatus.ACTIVE) {
                item.updateRelevance(currentTurn);
                activeItems.add(item);
            }
        }

        activeItems.sort();
        return activeItems;
    }

    /**
     * Builds a map of record Id to ContextItem for efficient lookup and update.
     *
     * @param ledger The list of ContextItem objects
     * @return       Map from Id to ContextItem
     */
    private Map<Id, ContextItem> buildLedgerMap(List<ContextItem> ledger) {
        Map<Id, ContextItem> ledgerMap = new Map<Id, ContextItem>();
        for (ContextItem item : ledger) {
            try {
                ledgerMap.put(Id.valueOf(item.id), item);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManager] Skipping invalid record ID in ledger: ' + item.id);
            }
        }
        return ledgerMap;
    }

    /**
     * Processes the current page context, promoting or creating a primary context item as needed.
     *
     * @param ledgerMap     Map of Id to ContextItem
     * @param ledger        List of ContextItem objects
     * @param pageContextId The current page record Id
     * @param currentTurn   The current conversation turn
     */
    private void processPageContext(Map<Id, ContextItem> ledgerMap, List<ContextItem> ledger, Id pageContextId, Integer currentTurn) {
        if (ledgerMap.containsKey(pageContextId)) {
            ContextItem existing = ledgerMap.get(pageContextId);
            existing.recordAccess(currentTurn);

            // Promote to primary if it's the current page
            if (existing.contextType != ContextType.IMPLICIT_PRIMARY && existing.contextType != ContextType.PINNED) {
                existing.contextType = ContextType.IMPLICIT_PRIMARY;
                existing.relevanceScore = existing.calculateInitialRelevance(ContextType.IMPLICIT_PRIMARY);
            }
        } else {
            ContextItem newItem = new ContextItem(pageContextId, ContextType.IMPLICIT_PRIMARY, currentTurn, null);
            ledger.add(newItem);
        }
    }

    /**
     * Processes a new action-generated context item, establishing relationships to the page context if present.
     *
     * @param ledgerMap     Map of Id to ContextItem
     * @param ledger        List of ContextItem objects
     * @param newRecordId   The new record Id created by agent action
     * @param pageContextId The current page record Id (optional)
     * @param currentTurn   The current conversation turn
     */
    private void processActionGeneratedContext(
        Map<Id, ContextItem> ledgerMap,
        List<ContextItem> ledger,
        Id newRecordId,
        Id pageContextId,
        Integer currentTurn
    ) {
        if (ledgerMap.containsKey(newRecordId)) {
            ledgerMap.get(newRecordId).recordAccess(currentTurn);
        } else {
            ContextItem newItem = new ContextItem(newRecordId, ContextType.ACTION_GENERATED, currentTurn, pageContextId);
            newItem.setMetadata('createdByAgent', true);
            ledger.add(newItem);

            // Update parent-child relationship
            if (pageContextId != null && ledgerMap.containsKey(pageContextId)) {
                ledgerMap.get(pageContextId).addChild(String.valueOf(newRecordId));
            }
        }
    }

    /**
     * Optimizes the ledger by updating relevance, sorting, and pruning excess items (except pinned).
     *
     * @param ledger      The list of ContextItem objects
     * @param currentTurn The current conversation turn
     * @return            Optimized list of ContextItem objects
     */
    private List<ContextItem> optimizeLedger(List<ContextItem> ledger, Integer currentTurn) {
        // Update all relevance scores
        for (ContextItem item : ledger) {
            item.updateRelevance(currentTurn);
        }

        // Sort by relevance
        ledger.sort();

        // Prune if over limit (keep pinned items)
        if (ledger.size() > MAX_CONTEXT_ITEMS) {
            List<ContextItem> optimized = new List<ContextItem>();
            Integer addedCount = 0;

            for (ContextItem item : ledger) {
                if (item.contextType == ContextType.PINNED || item.status == ContextStatus.ACTIVE && addedCount < MAX_CONTEXT_ITEMS) {
                    optimized.add(item);
                    if (item.contextType != ContextType.PINNED) {
                        addedCount++;
                    }
                } else {
                    item.status = ContextStatus.PRUNED;
                }
            }

            return optimized;
        }

        return ledger;
    }

    /**
     * Categorizes a context item for prompt structuring based on type, recency, and relevance.
     *
     * @param item        The ContextItem to categorize
     * @param currentTurn The current conversation turn
     * @return            Category name as String
     */
    private String categorizeForPrompt(ContextItem item, Integer currentTurn) {
        Integer turnsSinceAccessed = currentTurn - item.lastAccessed;

        if (item.contextType == ContextType.IMPLICIT_PRIMARY) {
            return 'primary';
        }

        if (turnsSinceAccessed <= 1 || item.contextType == ContextType.ACTION_GENERATED) {
            return 'recent';
        }

        if (item.relevanceScore > BASE_RELEVANCE_SCORE) {
            return 'related';
        }

        return 'background';
    }

    /**
     * Validates the serialized ledger size to prevent exceeding field storage limits.
     * Throws ContextManagementException if the ledger is too large.
     *
     * @param serializedLedger The JSON string of the ledger
     * @throws                 ContextManagementException if size exceeds 30,000 chars
     */
    private void validateLedgerSize(String serializedLedger) {
        if (serializedLedger.length() > 30000) {
            // Leave buffer for 32KB limit
            throw new ContextManagementException('Context ledger too large: ' + serializedLedger.length() + ' chars. Consider pruning.');
        }
    }

    /**
     * Parses the JSON ledger string into a list of ContextItem objects, recovering from corruption if needed.
     *
     * @param jsonLedger The JSON string representing the ledger
     * @return           List of valid ContextItem objects (empty if parsing fails)
     */
    @TestVisible
    private List<ContextItem> parseLedger(String jsonLedger) {
        if (String.isBlank(jsonLedger)) {
            return new List<ContextItem>();
        }

        try {
            List<ContextItem> items = (List<ContextItem>) JSON.deserialize(jsonLedger, List<ContextItem>.class);

            // Validate and clean up items
            List<ContextItem> validItems = new List<ContextItem>();
            for (ContextItem item : items) {
                if (isValidContextItem(item)) {
                    validItems.add(item);
                }
            }

            return validItems;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ContextManagerService.parseLedger] Ledger JSON corruption detected for input: ' + e.getMessage());
            return new List<ContextItem>();
        }
    }

    /**
     * Validates the integrity of a ContextItem (checks for required fields and valid Id).
     *
     * @param item The ContextItem to validate
     * @return     True if valid, false otherwise
     */
    private Boolean isValidContextItem(ContextItem item) {
        if (item == null || String.isBlank(item.id) || String.isBlank(item.type)) {
            return false;
        }

        try {
            Id.valueOf(item.id); // Validate ID format
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
