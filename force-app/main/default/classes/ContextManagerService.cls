/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for managing the "Context Ledger" of relevant entities for a chat session.
 *              It abstracts the serialization and state management of the EntityHistoryJson__c field.
 */
public inherited sharing class ContextManagerService {
    public class ContextManagementException extends AIAgentException {
    }

    @TestVisible
    public class ContextItem implements Comparable {
        public String id;
        public String type;
        public String contextType;
        public String status = 'Active';
        public Integer turnAdded;
        public Integer lastAccessed;
        public String sourceId;

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
     * @description Gets the full context ledger from the session.
     * @param sessionId The ID of the ChatSession__c.
     * @return A List of ContextItem objects. Returns an empty list on error or if none exist.
     */
    public List<ContextItem> getContextLedger(Id sessionId) {
        if (sessionId == null)
            return new List<ContextItem>();
        try {
            List<ChatSession__c> sessions = [SELECT EntityHistoryJson__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1];
            if (sessions.isEmpty() || String.isBlank(sessions[0].EntityHistoryJson__c)) {
                return new List<ContextItem>();
            }
            return parseLedger(sessions[0].EntityHistoryJson__c);
        } catch (Exception e) {
            return new List<ContextItem>();
        }
    }

    /**
     * @description (NEW) Transaction-safe method to commit context changes for a completed turn.
     *              This method performs DML and should only be called AFTER the LLM callout.
     * @param sessionId The ID of the chat session.
     * @param currentTurn The integer number of the turn that just completed.
     * @param pageContextId The ID of the record on the user's page during the turn. Can be null.
     * @param newRecordFromActionId The ID of a new record created by an action during the turn. Can be null.
     */
    public void commitTurnContext(Id sessionId, Integer currentTurn, Id pageContextId, Id newRecordFromActionId) {
        if (sessionId == null)
            return;
        if (pageContextId == null && newRecordFromActionId == null)
            return;

        String logPrefix = '[CtxMgrSvc.Commit Sess:' + sessionId + '] ';

        try {
            List<ChatSession__c> sessions = [SELECT Id, EntityHistoryJson__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1 FOR UPDATE];
            if (sessions.isEmpty())
                throw new ContextManagementException('Chat Session ' + sessionId + ' not found for commit.');

            ChatSession__c session = sessions[0];
            List<ContextItem> ledger = parseLedger(session.EntityHistoryJson__c);
            Map<Id, ContextItem> ledgerMap = new Map<Id, ContextItem>();
            for (ContextItem item : ledger) {
                ledgerMap.put(Id.valueOf(item.id), item);
            }

            if (pageContextId != null) {
                if (ledgerMap.containsKey(pageContextId)) {
                    ledgerMap.get(pageContextId).lastAccessed = currentTurn;
                } else {
                    ledger.add(createContextItem(pageContextId, 'Implicit', currentTurn, null));
                }
            }

            if (newRecordFromActionId != null) {
                if (ledgerMap.containsKey(newRecordFromActionId)) {
                    ledgerMap.get(newRecordFromActionId).lastAccessed = currentTurn;
                } else {
                    Id sourceId = pageContextId;
                    ledger.add(createContextItem(newRecordFromActionId, 'ActionGenerated', currentTurn, sourceId));
                }
            }

            session.EntityHistoryJson__c = JSON.serialize(ledger);
            update session;
        } catch (Exception e) {
            throw new ContextManagementException('Could not update session context ledger: ' + e.getMessage(), e);
        }
    }

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

    @TestVisible
    private List<ContextItem> parseLedger(String jsonLedger) {
        if (String.isBlank(jsonLedger)) {
            return new List<ContextItem>();
        }
        try {
            return (List<ContextItem>) JSON.deserialize(jsonLedger, List<ContextItem>.class);
        } catch (Exception e) {
            return new List<ContextItem>();
        }
    }
}
