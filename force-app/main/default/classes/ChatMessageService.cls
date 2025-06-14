/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service for retrieving and saving raw ChatMessage__c SObjects.
 *              Handles query limits and allows basic pagination/sorting for history retrieval.
 */
public inherited sharing class ChatMessageService {
    /**
     * @description Retrieves raw ChatMessage__c records for a session. Used for UI or raw history needs.
     * @param sessionId The ID of the ChatSession__c.
     * @param limitCount Max messages to retrieve (uses Framework Setting default if null/invalid).
     * @param sortOrder Sort order ('ASC' or 'DESC'). Default 'ASC'.
     * @param olderThanTimestamp Optional pagination marker (usually used with 'DESC' sort).
     * @return List of ChatMessage__c SObject records.
     */
    public static List<ChatMessage__c> getHistory(Id sessionId, Integer limitCount, String sortOrder, DateTime olderThanTimestamp) {
        if (sessionId == null)
            return new List<ChatMessage__c>();

        Integer settingsLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        Integer queryLimit = (limitCount != null && limitCount > 0) ? Math.min(limitCount, settingsLimit) : settingsLimit;
        String effectiveSortOrder = ('DESC'.equalsIgnoreCase(sortOrder)) ? 'DESC' : 'ASC';

        List<String> whereClauses = new List<String>{ 'ChatSession__c = :sessionId' };
        Map<String, Object> bindMap = new Map<String, Object>{ 'sessionId' => sessionId };

        if (olderThanTimestamp != null) {
            whereClauses.add('Timestamp__c < :olderThanTimestamp');
            bindMap.put('olderThanTimestamp', olderThanTimestamp);
        }
        String whereClause = String.join(whereClauses, ' AND ');

        String query =
            'SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, ' +
            'AssistantToolCalls__c, ToolCallId__c, ParentMessage__c, ' +
            'TokensUsed__c, ProcessingTimeMillis__c, RecordContextId__c, RecordContextData__c ' +
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

        bindMap.put('queryLimit', queryLimit);

        return Database.queryWithBinds(query, bindMap, AccessLevel.USER_MODE);
    }

    public static List<ChatMessage__c> getHistory(Id sessionId, Integer limitCount, String sortOrder) {
        return getHistory(sessionId, limitCount, sortOrder, null);
    }

    /**
     * @description Saves a list of ChatMessage__c SObject records, allowing partial success.
     * @param messages List of ChatMessage__c records to insert.
     * @return List of Database.SaveResult objects.
     * @throws DmlException if Database.insert throws an exception beyond SaveResult errors.
     */
    public static List<Database.SaveResult> saveMessages(List<ChatMessage__c> messages) {
        if (messages == null || messages.isEmpty())
            return new List<Database.SaveResult>();

        List<ChatMessage__c> messagesToInsert = new List<ChatMessage__c>();
        for (ChatMessage__c msg : messages) {
            if (msg != null) {
                messagesToInsert.add(msg);
            }
        }
        if (messagesToInsert.isEmpty()) {
            return new List<Database.SaveResult>();
        }

        try {
            List<Database.SaveResult> results = Database.insert(messagesToInsert, false);

            Integer successCount = 0;
            Integer failureCount = 0;
            List<String> errorMsgs = new List<String>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    failureCount++;

                    String recordErrors = '';
                    for (Database.Error err : results[i].getErrors()) {
                        recordErrors +=
                            '[Code:' +
                            err.getStatusCode() +
                            ', Fields:' +
                            String.join(err.getFields(), ',') +
                            ', Msg:' +
                            err.getMessage() +
                            '] ';
                    }

                    errorMsgs.add('Index ' + i + ': ' + recordErrors);
                }
            }
            if (failureCount > 0 || successCount > 0) {
                if (failureCount > 0) {
                }
            }
            return results;
        } catch (Exception e) {
            throw e;
        }
    }
}
