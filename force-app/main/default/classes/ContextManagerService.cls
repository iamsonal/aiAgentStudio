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
            // Safely get the SObject type name
            try {
                this.type = recordId.getSObjectType().getDescribe().getName();
            } catch (Exception e) {
                // Fallback to a generic type if we can't determine the SObject type
                this.type = 'Unknown';
            }
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
            if (exponent < 0)
                return 0.0;
            if (exponent == 0)
                return 1.0;

            // Use repeated multiplication for efficiency
            Decimal result = 1.0;
            for (Integer i = 0; i < exponent; i++) {
                result *= base;
            }
            return result;
        }

        private Decimal calculateLogBoost(Integer value) {
            if (value <= 1)
                return 0.0;

            // Use Math.log10 for accuracy
            return Math.log10(value) * 10; // Simplified but more accurate
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
     * Retrieves context items for an execution with dynamic scoring.
     * Main method for the unified execution model.
     *
     * @param executionId   The AgentExecution__c identifier (required)
     * @param currentTurn   The current conversation turn, used for temporal calculations (optional)
     * @return              List of ContextItem objects sorted by relevance
     * @throws              None (returns empty list on error)
     */
    public List<ContextItem> getContextLedger(Id executionId, Integer currentTurn) {
        if (executionId == null)
            return new List<ContextItem>();

        try {
            List<AgentExecution__c> executions = [
                SELECT ContextHistoryJson__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty() || String.isBlank(executions[0].ContextHistoryJson__c)) {
                return new List<ContextItem>();
            }

            List<ContextItem> ledger = parseLedger(executions[0].ContextHistoryJson__c);
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
     * Retrieves context items for a session, filtered by context type and minimum relevance score,
     * with dynamic scoring based on the current conversation turn.
     *
     * @param sessionId    The chat session identifier
     * @param currentTurn  The current conversation turn, used for temporal calculations
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
     * Organizes context items into hierarchical categories for LLM prompt construction,
     * using dynamic scoring based on the current conversation turn.
     *
     * @param sessionId   The chat session identifier
     * @param currentTurn The current conversation turn, used for temporal calculations
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
     * @description
     * Commits context changes for AgentExecution__c records.
     * Main method for the unified execution model.
     *
     * @param executionId             The ID of the AgentExecution__c to update
     * @param currentTurn             The current turn number for temporal scoring
     * @param pageContextId           The ID of the record representing the user's current page context (can be null)
     * @param newRecordFromActionId   The ID of a record created by an agent action (can be null)
     * @throws                     ContextManagementException if the execution is not found or ledger is oversized
     */
    public void commitExecutionTurnContext(Id executionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (executionId == null || (pageContextId == null && newRecordFromActionId == null)) {
            return;
        }

        String logPrefix = '[ContextManager.Commit ' + executionId + '] ';

        try {
            // Handle AgentExecution__c
            List<AgentExecution__c> executions = [
                SELECT Id, ContextHistoryJson__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                throw new ContextManagementException('No AgentExecution__c found for executionId: ' + executionId);
            }

            String currentContextJson = executions[0].ContextHistoryJson__c;
            List<ContextItem> ledger = parseLedger(currentContextJson);
            Map<Id, ContextItem> ledgerMap = buildLedgerMap(ledger);

            // Process page context with intelligent type detection
            if (pageContextId != null) {
                processPageContext(ledgerMap, ledger, pageContextId, currentTurn);
            }

            // Process action-generated records with relationship tracking
            if (newRecordFromActionId != null) {
                processActionContext(ledgerMap, ledger, newRecordFromActionId, currentTurn, pageContextId);
            }

            // Apply pruning and optimization
            pruneLedger(ledger);

            // Persist with size validation
            String serializedLedger = JSON.serialize(ledger);
            validateLedgerSize(serializedLedger);

            // Update the AgentExecution__c record
            AgentExecution__c execution = new AgentExecution__c(
                Id = executionId,
                ContextHistoryJson__c = serializedLedger,
                LastActivityTime__c = Datetime.now()
            );
            update execution;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Context ledger updated. Item count: ' + ledger.size() + ', Serialized size: ' + serializedLedger.length() + ' chars.'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context commit failed: ' + e.getMessage());
            throw new ContextManagementException('Context commit failed: ' + e.getMessage(), e);
        }
    }

    // --- PRIVATE HELPER METHODS ---

    /**
     * Processes action-generated records with relationship tracking.
     *
     * @param ledgerMap          Map of existing context items by ID
     * @param ledger            List of context items
     * @param newRecordId       ID of the new record created by action
     * @param currentTurn       Current turn number
     * @param pageContextId     Current page context ID
     */
    private void processActionContext(
        Map<Id, ContextItem> ledgerMap,
        List<ContextItem> ledger,
        Id newRecordId,
        Integer currentTurn,
        Id pageContextId
    ) {
        if (newRecordId == null)
            return;

        try {
            // Create new context item for the action-generated record
            ContextItem newItem = new ContextItem(newRecordId, ContextType.ACTION_GENERATED, currentTurn, pageContextId);
            ledger.add(newItem);

            // Update parent-child relationships if there's a page context
            if (pageContextId != null) {
                for (ContextItem existingItem : ledger) {
                    if (existingItem.id == String.valueOf(pageContextId)) {
                        existingItem.addChild(String.valueOf(newRecordId));
                        break;
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ContextManagerService.processActionContext] Failed to process action context: ' + e.getMessage());
        }
    }

    /**
     * Applies pruning and optimization to the context ledger.
     *
     * @param ledger List of context items to prune
     */
    private void pruneLedger(List<ContextItem> ledger) {
        if (ledger == null || ledger.isEmpty())
            return;

        try {
            // Remove items with very low relevance scores (below 0.1)
            for (Integer i = ledger.size() - 1; i >= 0; i--) {
                ContextItem item = ledger[i];
                if (item.status == ContextStatus.ACTIVE && item.relevanceScore < 0.1) {
                    ledger.remove(i);
                }
            }

            // Limit total items to prevent oversized ledgers (max 100 items)
            if (ledger.size() > 100) {
                // Sort by relevance and keep top 100
                ledger.sort();
                while (ledger.size() > 100) {
                    ledger.remove(ledger.size() - 1);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ContextManagerService.pruneLedger] Failed to prune ledger: ' + e.getMessage());
        }
    }

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
            try {
                if (item.status == ContextStatus.ACTIVE) {
                    item.updateRelevance(currentTurn);
                    activeItems.add(item);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ContextManagerService] Failed to update relevance for item ' + item.id + ': ' + e.getMessage());
                // Continue processing other items
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

            // Promote to primary if it's the current page, but respect pinned items
            if (existing.contextType != ContextType.PINNED) {
                // Even pinned items might benefit from a relevance boost when accessed
                if (existing.contextType != ContextType.IMPLICIT_PRIMARY) {
                    existing.contextType = ContextType.IMPLICIT_PRIMARY;
                    existing.relevanceScore = existing.calculateInitialRelevance(ContextType.IMPLICIT_PRIMARY);
                }
            }
        } else {
            ContextItem newItem = new ContextItem(pageContextId, ContextType.IMPLICIT_PRIMARY, currentTurn, null);
            ledger.add(newItem);
        }
    }

    /**
     * Processes a new action-generated context item, establishing relationships to the page context if present.
     *
     * @param ledgerMap     Map of Id to ContextItem (may be stale)
     * @param ledger        List of ContextItem objects (up-to-date)
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

            // Update parent-child relationship by iterating over the up-to-date ledger
            // This ensures we find parents that were just added in this transaction
            if (pageContextId != null) {
                for (ContextItem potentialParent : ledger) {
                    if (potentialParent.id == String.valueOf(pageContextId)) {
                        potentialParent.addChild(String.valueOf(newRecordId));
                        break;
                    }
                }
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
    @TestVisible
    private List<ContextItem> optimizeLedger(List<ContextItem> ledger, Integer currentTurn) {
        // Update all relevance scores
        for (ContextItem item : ledger) {
            item.updateRelevance(currentTurn);
        }

        // Sort by relevance (already implemented in compareTo)
        ledger.sort();

        // Prune if over limit, but preserve pinned items correctly
        if (ledger.size() > MAX_CONTEXT_ITEMS) {
            List<ContextItem> optimized = new List<ContextItem>();
            List<ContextItem> pinnedItems = new List<ContextItem>();
            List<ContextItem> activeItems = new List<ContextItem>();

            // Separate pinned items from active items
            for (ContextItem item : ledger) {
                if (item.contextType == ContextType.PINNED) {
                    pinnedItems.add(item);
                } else if (item.status == ContextStatus.ACTIVE) {
                    activeItems.add(item);
                }
                // Pruned/archived items are not added to either list
            }

            // Add all pinned items (they're always kept)
            optimized.addAll(pinnedItems);

            // Calculate how many active items we can add while staying within the limit
            Integer remainingSlots = MAX_CONTEXT_ITEMS - pinnedItems.size();

            // Add active items up to the remaining slots
            for (Integer i = 0; i < Math.min(remainingSlots, activeItems.size()); i++) {
                optimized.add(activeItems[i]);
            }

            // Mark any remaining active items as pruned
            for (Integer i = remainingSlots; i < activeItems.size(); i++) {
                activeItems[i].status = ContextStatus.PRUNED;
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

        List<ContextItem> parsedItems = new List<ContextItem>();
        try {
            List<Object> rawItems = (List<Object>) JSON.deserializeUntyped(jsonLedger);

            for (Object rawItem : rawItems) {
                Map<String, Object> props = (Map<String, Object>) rawItem;

                Id recordId = Id.valueOf((String) props.get('id'));
                ContextType ctxType = ContextType.valueOf((String) props.get('contextType'));
                Integer turnAdded = props.get('turnAdded') == null ? null : ((Decimal) props.get('turnAdded')).intValue();
                Id sourceId = props.get('sourceId') != null ? Id.valueOf((String) props.get('sourceId')) : null;

                ContextItem item = new ContextItem(recordId, ctxType, turnAdded, sourceId);

                // Populate remaining fields not set by constructor
                if (props.containsKey('status') && props.get('status') != null) {
                    item.status = ContextStatus.valueOf((String) props.get('status'));
                }
                if (props.containsKey('lastAccessed') && props.get('lastAccessed') != null) {
                    item.lastAccessed = ((Decimal) props.get('lastAccessed')).intValue();
                }
                if (props.containsKey('accessCount') && props.get('accessCount') != null) {
                    item.accessCount = ((Decimal) props.get('accessCount')).intValue();
                }
                if (props.containsKey('relevanceScore') && props.get('relevanceScore') != null) {
                    item.relevanceScore = (Decimal) JSON.deserialize(JSON.serialize(props.get('relevanceScore')), Decimal.class);
                }

                if (props.containsKey('childIds') && props.get('childIds') != null) {
                    List<String> children = new List<String>();
                    for (Object childObj : (List<Object>) props.get('childIds')) {
                        children.add((String) childObj);
                    }
                    item.childIds = children;
                }

                if (props.containsKey('metadata') && props.get('metadata') != null) {
                    item.metadata = (Map<String, Object>) props.get('metadata');
                }

                if (isValidContextItem(item)) {
                    parsedItems.add(item);
                } else {
                    System.debug(LoggingLevel.WARN, '[ContextManagerService] Skipping invalid context item during parsing: ' + JSON.serialize(props));
                }
            }
            return parsedItems;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService.parseLedger] Ledger JSON corruption or mapping error: ' +
                    e.getMessage() +
                    ' | Stack: ' +
                    e.getStackTraceString()
            );
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
