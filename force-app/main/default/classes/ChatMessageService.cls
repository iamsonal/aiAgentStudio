/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service for retrieving and saving raw ChatMessage__c SObjects.
 */
public inherited sharing class ChatMessageService {
    private static final Integer MAX_HISTORY_QUERY_LIMIT = 200;

    /**
     * @description Retrieves raw ChatMessage__c SObject records for a session.
     *              Typically used for UI display or as raw input for formatting elsewhere.
     * @param sessionId The ID of the ChatSession__c.
     * @param limitCount The maximum number of SObject messages to retrieve.
     * @param sortOrder The sort order ('ASC' or 'DESC').
     * @param olderThanTimestamp Optional pagination marker.
     * @return List of ChatMessage__c SObject records.
     */
    public static List<ChatMessage__c> getHistory(
        Id sessionId,
        Integer limitCount,
        String sortOrder,
        DateTime olderThanTimestamp
    ) {
        if (sessionId == null)
            return new List<ChatMessage__c>();
        Integer queryLimit = (limitCount != null &&
            limitCount > 0 &&
            limitCount <= MAX_HISTORY_QUERY_LIMIT)
            ? limitCount
            : MAX_HISTORY_QUERY_LIMIT;
        String effectiveSortOrder = ('DESC'.equalsIgnoreCase(sortOrder)) ? 'DESC' : 'ASC';
        if (olderThanTimestamp != null)
            effectiveSortOrder = 'DESC';

        List<String> whereClauses = new List<String>{ 'ChatSession__c = :sessionId' };
        if (olderThanTimestamp != null) {
            whereClauses.add('Timestamp__c < :olderThanTimestamp');
        }
        String whereClause = String.join(whereClauses, ' AND ');

        String queryString =
            'SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, ' +
            'AssistantToolCalls__c, ToolCallId__c, ParentMessage__c, ProcessingTimeMillis__c ' +
            'FROM ChatMessage__c ' +
            'WHERE ' +
            whereClause +
            ' ' +
            'ORDER BY Timestamp__c ' +
            effectiveSortOrder +
            ', Id ' +
            effectiveSortOrder +
            ' NULLS LAST ' +
            'LIMIT :queryLimit';
        return Database.query(queryString);
    }

    public static List<ChatMessage__c> getHistory(Id sessionId, Integer limitCount, String sortOrder) {
        return getHistory(sessionId, limitCount, sortOrder, null);
    }

    /**
     * @description Saves a list of ChatMessage__c SObject records.
     * @param messages List of ChatMessage__c records to insert.
     * @return List of Database.SaveResult objects.
     */
    public static List<Database.SaveResult> saveMessages(List<ChatMessage__c> messages) {
        List<Database.SaveResult> results = new List<Database.SaveResult>();
        if (messages == null || messages.isEmpty())
            return results;
        try {
            results = Database.insert(messages, false);
            Integer successCount = 0;
            Integer failureCount = 0;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    failureCount++; /* Basic Debug Log Error */
                }
            }
        } catch (Exception e) {
            throw e;
        }
        return results;
    }
}
