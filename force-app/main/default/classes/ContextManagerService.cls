/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextManagerService is responsible for maintaining the "Context Ledger"—a structured, turn-by-turn record of relevant entities
 * associated with a chat session. It handles the serialization, deserialization, and transactional updates of the EntityHistoryJson__c
 * field on ChatSession__c, ensuring that context is accurately tracked and safely committed after each LLM interaction.
 *
 * This service abstracts the low-level details of context state management, providing robust, transaction-safe methods for
 * updating and retrieving the ledger. It is not responsible for context resolution logic, which is handled by ContextResolverService.
 *
 * Key responsibilities:
 *   - Retrieve the current context ledger for a session
 *   - Commit new context items for each completed turn, handling both implicit and action-generated entities
 *   - Ensure data integrity and prevent race conditions via record locking
 *   - Provide a clear, extensible schema for context items
 */
public inherited sharing class ContextManagerService {
    /**
     * Exception type for errors encountered during context management operations.
     */
    public class ContextManagementException extends AIAgentException {
    }

    /**
     * @description
     * Represents a single entry in the context ledger, capturing the relationship between a chat session and a relevant entity.
     * Implements Comparable for recency-based sorting (most recent first).
     *
     * Fields:
     *   - id: Record Id of the entity
     *   - type: SObject API Name
     *   - contextType: Nature of the context (e.g., Implicit, ActionGenerated, Pinned)
     *   - status: Current status (default 'Active')
     *   - turnAdded: Turn number when the item was added
     *   - lastAccessed: Most recent turn when the item was accessed
     *   - sourceId: Id of the parent context item, if any
     */
    @TestVisible
    public class ContextItem implements Comparable {
        public String id;
        public String type;
        public String contextType;
        public String status = 'Active';
        public Integer turnAdded;
        public Integer lastAccessed;
        public String sourceId;

        /**
         * Compares two ContextItems by turnAdded, for recency-based sorting (descending).
         * @param compareTo The object to compare to.
         * @return -1 if this is newer, 1 if older, 0 if equal.
         */
        public Integer compareTo(Object compareTo) {
            ContextItem other = (ContextItem) compareTo;
            if (this.turnAdded > other.turnAdded)
                return -1;
            if (this.turnAdded < other.turnAdded)
                return 1;
            return 0;
        }
    }

    /**
     * Retrieves the full context ledger for a given chat session.
     *
     * @param sessionId The Id of the ChatSession__c record.
     * @return List<ContextItem> The deserialized context ledger, or an empty list if none exists or on error.
     * @throws None. Errors are logged and an empty list is returned.
     */
    public List<ContextItem> getContextLedger(Id sessionId) {
        if (sessionId == null) {
            System.debug(LoggingLevel.WARN, '[ContextManagerService] getContextLedger called with null sessionId. Returning empty list.');
            return new List<ContextItem>();
        }
        try {
            List<ChatSession__c> sessions = [SELECT EntityHistoryJson__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1];
            if (sessions.isEmpty() || String.isBlank(sessions[0].EntityHistoryJson__c)) {
                System.debug(
                    LoggingLevel.INFO,
                    '[ContextManagerService] No context ledger found for session ' + sessionId + '. Returning empty list.'
                );
                return new List<ContextItem>();
            }
            return parseLedger(sessions[0].EntityHistoryJson__c);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService] Error retrieving context ledger for session ' + sessionId + ': ' + e.getMessage()
            );
            return new List<ContextItem>();
        }
    }

    /**
     * Transaction-safe method to commit context changes for a completed turn.
     *
     * This method should be called only after the LLM callout, as it performs DML.
     * It locks the session record to prevent race conditions, updates or adds context items for the current turn,
     * and persists the updated ledger.
     *
     * @param sessionId           The Id of the chat session (ChatSession__c).
     * @param currentTurn         The turn number that just completed.
     * @param pageContextId       The Id of the record on the user's page during the turn (nullable).
     * @param newRecordFromActionId The Id of a new record created by an action during the turn (nullable).
     * @throws ContextManagementException if the session cannot be found or the update fails.
     * @sideeffect Performs DML on ChatSession__c.
     */
    public void commitTurnContext(Id sessionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (sessionId == null) {
            System.debug(LoggingLevel.WARN, '[CtxMgrSvc.Commit] commitTurnContext called with null sessionId. No action taken.');
            return;
        }
        if (pageContextId == null && newRecordFromActionId == null) {
            System.debug(LoggingLevel.INFO, '[CtxMgrSvc.Commit Sess:' + sessionId + '] No context to commit for turn ' + currentTurn + '.');
            return;
        }

        String logPrefix = '[CtxMgrSvc.Commit Sess:' + sessionId + '] ';

        try {
            // Lock session record to prevent concurrent updates to the JSON blob
            List<ChatSession__c> sessions = [SELECT Id, EntityHistoryJson__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1 FOR UPDATE];
            if (sessions.isEmpty()) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Session not found. Cannot commit context.');
                throw new ContextManagementException('Chat Session ' + sessionId + ' not found for commit.');
            }

            ChatSession__c session = sessions[0];
            List<ContextItem> ledger = parseLedger(session.EntityHistoryJson__c);
            Map<Id, ContextItem> ledgerMap = new Map<Id, ContextItem>();
            for (ContextItem item : ledger) {
                ledgerMap.put(Id.valueOf(item.id), item);
            }

            // Update or add the immediate page context
            if (pageContextId != null) {
                if (ledgerMap.containsKey(pageContextId)) {
                    ledgerMap.get(pageContextId).lastAccessed = currentTurn;
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Updated lastAccessed for pageContextId ' + pageContextId + ' to turn ' + currentTurn + '.'
                    );
                } else {
                    ledger.add(createContextItem(pageContextId, 'Implicit', currentTurn, null));
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Added new Implicit context item for pageContextId ' + pageContextId + ' at turn ' + currentTurn + '.'
                    );
                }
            }

            // Update or add the newly created record from an action
            if (newRecordFromActionId != null) {
                if (ledgerMap.containsKey(newRecordFromActionId)) {
                    ledgerMap.get(newRecordFromActionId).lastAccessed = currentTurn;
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Updated lastAccessed for newRecordFromActionId ' + newRecordFromActionId + ' to turn ' + currentTurn + '.'
                    );
                } else {
                    Id sourceId = pageContextId;
                    ledger.add(createContextItem(newRecordFromActionId, 'ActionGenerated', currentTurn, sourceId));
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix +
                            'Added new ActionGenerated context item for newRecordFromActionId ' +
                            newRecordFromActionId +
                            ' at turn ' +
                            currentTurn +
                            '.'
                    );
                }
            }

            // Persist the updated ledger
            session.EntityHistoryJson__c = JSON.serialize(ledger);
            update session;
            System.debug(LoggingLevel.INFO, logPrefix + 'Committed turn context. Ledger now contains ' + ledger.size() + ' items.');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during commit: ' + e.getMessage());
            throw new ContextManagementException('Could not update session context ledger: ' + e.getMessage(), e);
        }
    }

    /**
     * Helper to construct a new ContextItem for the ledger.
     *
     * @param recordId   The Id of the entity record.
     * @param contextType The type of context (e.g., Implicit, ActionGenerated).
     * @param turn       The turn number when the item is added.
     * @param sourceId   The Id of the parent context item, if any.
     * @return ContextItem The constructed context item.
     */
    private ContextItem createContextItem(Id recordId, String contextType, Integer turn, Id sourceId) {
        ContextItem newItem = new ContextItem();
        newItem.id = recordId;
        newItem.type = recordId.getSObjectType().getDescribe().getName();
        newItem.contextType = contextType;
        newItem.turnAdded = turn;
        newItem.lastAccessed = turn;
        newItem.sourceId = (sourceId != null) ? String.valueOf(sourceId) : null;
        return newItem;
    }

    /**
     * Deserializes the context ledger JSON into a list of ContextItem objects.
     *
     * @param jsonLedger The JSON string representing the ledger.
     * @return List<ContextItem> The deserialized ledger, or an empty list if blank or on parse error.
     * @throws None. Errors are logged and an empty list is returned.
     */
    @TestVisible
    private List<ContextItem> parseLedger(String jsonLedger) {
        if (String.isBlank(jsonLedger)) {
            return new List<ContextItem>();
        }
        try {
            return (List<ContextItem>) JSON.deserialize(jsonLedger, List<ContextItem>.class);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ContextManagerService] Failed to parse context ledger JSON. Returning empty list. Error: ' + e.getMessage()
            );
            return new List<ContextItem>();
        }
    }
}
