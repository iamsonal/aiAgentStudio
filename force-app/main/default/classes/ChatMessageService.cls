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
    public class PersistenceException extends AIAgentException {
    }

    public static List<ChatMessage__c> getHistory(Id sessionId, Integer limitCount, String sortOrder, Datetime olderThanTimestamp) {
        return getHistory(sessionId, limitCount, sortOrder, olderThanTimestamp, false);
    }

    /**
     * @description Retrieves raw ChatMessage__c records for a session. Used for UI or raw history needs.
     * @param sessionId The ID of the ChatSession__c.
     * @param limitCount Max messages to retrieve (uses Framework Setting default if null/invalid).
     * @param sortOrder Sort order ('ASC' or 'DESC'). Default 'ASC'.
     * @param olderThanTimestamp Optional pagination marker (usually used with 'DESC' sort).
     * @return List of ChatMessage__c SObject records.
     */
    public static List<ChatMessage__c> getHistory(
        Id sessionId,
        Integer limitCount,
        String sortOrder,
        Datetime olderThanTimestamp,
        Boolean onlyUnsummarized
    ) {
        if (sessionId == null)
            return new List<ChatMessage__c>();

        Integer settingsLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? limitCount : null;
        if (effectiveLimit != null) {
            effectiveLimit = Math.min(effectiveLimit, settingsLimit);
        }

        String effectiveSortOrder = ('DESC'.equalsIgnoreCase(sortOrder)) ? 'DESC' : 'ASC';

        List<String> whereClauses = new List<String>{ 'ChatSession__c = :sessionId' };
        Map<String, Object> bindMap = new Map<String, Object>{ 'sessionId' => sessionId };

        if (olderThanTimestamp != null) {
            whereClauses.add('Timestamp__c < :olderThanTimestamp');
            bindMap.put('olderThanTimestamp', olderThanTimestamp);
        }

        if (onlyUnsummarized) {
            whereClauses.add('IsSummarized__c = FALSE');
        }

        String whereClause = String.join(whereClauses, ' AND ');

        List<String> queryParts = new List<String>();
        queryParts.add('SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c,TurnIdentifier__c,');
        queryParts.add('AssistantToolCalls__c, ToolCallId__c, ParentMessage__c,');
        queryParts.add('TokensUsed__c, ProcessingTimeMillis__c, RecordContextId__c, RecordContextData__c');
        queryParts.add('FROM ChatMessage__c');
        queryParts.add('WHERE ' + whereClause);
        queryParts.add('ORDER BY Timestamp__c ' + effectiveSortOrder + ', Id ' + effectiveSortOrder + ' NULLS LAST');

        if (effectiveLimit != null) {
            queryParts.add('LIMIT :queryLimit');
            bindMap.put('queryLimit', effectiveLimit);
        }

        String finalQuery = String.join(queryParts, ' ');

        return Database.queryWithBinds(finalQuery, bindMap, AccessLevel.USER_MODE);
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

    /**
     * @description Retrieves a turn-aware chunk of chat history, ensuring the boundary turn is never incomplete.
     * @param sessionId The ID of the ChatSession__c.
     * @param baseLimit The base number of messages to fetch.
     * @param initialSortOrder The direction to fetch the initial chunk ('ASC' for oldest, 'DESC' for newest).
     * @return A chronologically sorted List<ChatMessage__c> representing the complete, turn-aware history chunk.
     */
    public static List<ChatMessage__c> getHistoryWithCompleteTurns(
        Id sessionId,
        Integer baseLimit,
        String initialSortOrder,
        Boolean onlyUnsummarized
    ) {
        String logPrefix = '[ChatMessageService.TurnAware] ';

        if (sessionId == null || baseLimit == null || baseLimit <= 0) {
            return new List<ChatMessage__c>();
        }

        List<ChatMessage__c> initialChunk = getHistory(sessionId, baseLimit, initialSortOrder, null, onlyUnsummarized);

        if (initialChunk.isEmpty()) {
            return new List<ChatMessage__c>();
        }

        ChatMessage__c boundaryMessage = initialChunk.get(initialChunk.size() - 1);
        String boundaryTurnId = boundaryMessage.TurnIdentifier__c;

        Map<Id, ChatMessage__c> allMessagesMap = new Map<Id, ChatMessage__c>();
        for (ChatMessage__c msg : initialChunk) {
            allMessagesMap.put(msg.Id, msg);
        }

        if (String.isNotBlank(boundaryTurnId)) {
            List<ChatMessage__c> fullBoundaryTurn = [
                SELECT
                    Id,
                    Role__c,
                    Content__c,
                    Timestamp__c,
                    ExternalId__c,
                    TurnIdentifier__c,
                    AssistantToolCalls__c,
                    ToolCallId__c,
                    ParentMessage__c,
                    IsSummarized__c,
                    RecordContextId__c,
                    RecordContextData__c
                FROM ChatMessage__c
                WHERE TurnIdentifier__c = :boundaryTurnId
            ];

            for (ChatMessage__c turnMsg : fullBoundaryTurn) {
                if (!allMessagesMap.containsKey(turnMsg.Id)) {
                    allMessagesMap.put(turnMsg.Id, turnMsg);
                }
            }
        }

        List<ChatMessage__c> finalMessages = sortMessages(allMessagesMap.values());

        return finalMessages;
    }

    private static List<ChatMessage__c> sortMessages(List<ChatMessage__c> messages) {
        List<MessageSorter> sorters = new List<MessageSorter>();
        for (ChatMessage__c msg : messages) {
            sorters.add(new MessageSorter(msg));
        }
        sorters.sort();

        List<ChatMessage__c> finalSortedList = new List<ChatMessage__c>();
        for (MessageSorter sorter : sorters) {
            finalSortedList.add(sorter.message);
        }
        return finalSortedList;
    }

    /** Helper class for robust chronological sorting. */
    private class MessageSorter implements Comparable {
        public ChatMessage__c message;
        public MessageSorter(ChatMessage__c msg) {
            this.message = msg;
        }
        public Integer compareTo(Object compareTo) {
            MessageSorter other = (MessageSorter) compareTo;
            if (this.message.Timestamp__c > other.message.Timestamp__c)
                return 1;
            if (this.message.Timestamp__c < other.message.Timestamp__c)
                return -1;
            if (this.message.Id > other.message.Id)
                return 1;
            if (this.message.Id < other.message.Id)
                return -1;
            return 0;
        }
    }

    public static Id saveUserMessage(
        Id sessionId,
        String turnIdentifier,
        LLMInteractionService.MessageData userMessageData,
        Id recordContextId,
        String logPrefix
    ) {
        if (userMessageData != null) {
            ChatMessage__c msgSobj = createMessageSObject(userMessageData, null, sessionId, turnIdentifier, logPrefix, turnIdentifier);
            msgSobj.RecordContextId__c = recordContextId;
            return insertMessage(msgSobj, logPrefix);
        }
        return null;
    }

    public static Id saveAssistantMessage(
        Id sessionId,
        String turnIdentifier,
        Id parentUserMessageId,
        LLMInteractionService.MessageData assistantMessageData,
        String capabilityName,
        String logPrefix
    ) {
        ChatMessage__c msgSobj = createMessageSObject(
            assistantMessageData,
            parentUserMessageId,
            sessionId,
            turnIdentifier,
            logPrefix,
            UuidUtils.generateUUID()
        );
        msgSobj.CapabilityName__c = capabilityName;
        return insertMessage(msgSobj, logPrefix);
    }

    public static Id saveAssistantMessageWithPendingAction(
        Id sessionId,
        String turnIdentifier,
        Id parentUserMessageId,
        LLMInteractionService.MessageData assistantMessageData,
        String pendingToolCallsListJson,
        String capabilityName,
        String logPrefix
    ) {
        ChatMessage__c msg = createMessageSObject(
            assistantMessageData,
            parentUserMessageId,
            sessionId,
            turnIdentifier,
            logPrefix,
            UuidUtils.generateUUID()
        );
        msg.PendingConfirmationActionDetails__c = pendingToolCallsListJson;
        msg.CapabilityName__c = capabilityName;
        return insertMessage(msg, logPrefix);
    }

    public static Id saveToolResultMessage(
        Id sessionId,
        String turnIdentifier,
        Id parentAssistantMessageId,
        String toolCallId,
        String toolResultContentJson,
        String internalDetails,
        String errorCode,
        Long actionDuration,
        Id recordContextId,
        String recordContextDataJson,
        String capabilityName,
        String logPrefix
    ) {
        if (String.isBlank(toolCallId) || parentAssistantMessageId == null) {
            throw new PersistenceException('ToolCallId and Parent Assistant Message ID are required to save tool result.');
        }

        LLMInteractionService.MessageData toolData = new LLMInteractionService.MessageData();
        toolData.role = AIAgentConstants.ROLE_TOOL;
        toolData.content = toolResultContentJson;
        toolData.processingTimeMs = actionDuration;

        ChatMessage__c msg = createMessageSObject(toolData, parentAssistantMessageId, sessionId, turnIdentifier, logPrefix, UuidUtils.generateUUID());
        msg.ToolCallId__c = toolCallId;
        msg.CapabilityName__c = capabilityName;
        msg.IsSuccess__c = String.isBlank(errorCode);

        if (recordContextId != null) {
            msg.RecordContextId__c = recordContextId;
            msg.RecordContextData__c = recordContextDataJson;
        }

        return insertMessage(msg, logPrefix);
    }

    private static ChatMessage__c createMessageSObject(
        LLMInteractionService.MessageData msgData,
        Id parentMsgId,
        Id sessionId,
        String turnIdentifier,
        String logPrefix,
        String externalIdToUse
    ) {
        if (msgData == null)
            throw new PersistenceException('MessageData cannot be null.');
        if (sessionId == null)
            throw new PersistenceException('SessionID is required.');
        if (String.isBlank(turnIdentifier))
            throw new PersistenceException('TurnIdentifier is required.');

        return new ChatMessage__c(
            ChatSession__c = sessionId,
            TurnIdentifier__c = turnIdentifier,
            Role__c = msgData.role,
            Content__c = msgData.content,
            AssistantToolCalls__c = msgData.assistantToolCallsJson,
            Timestamp__c = Datetime.now(),
            ExternalId__c = externalIdToUse,
            TokensUsed__c = msgData.tokensUsed,
            ProcessingTimeMillis__c = msgData.processingTimeMs,
            ParentMessage__c = parentMsgId
        );
    }

    private static Id insertMessage(ChatMessage__c msgToInsert, String logPrefix) {
        try {
            List<Database.SaveResult> results = saveMessages(new List<ChatMessage__c>{ msgToInsert });
            if (results != null && !results.isEmpty() && results[0].isSuccess()) {
                Id savedId = results[0].getId();

                return savedId;
            } else {
                String errorDetail = 'Unknown DML Error saving message.';
                if (results != null && !results.isEmpty() && results[0].getErrors().size() > 0) {
                    errorDetail = results[0].getErrors()[0].getMessage();
                }
                throw new DmlException('Failed to save ChatMessage (' + msgToInsert.Role__c + '). Error: ' + errorDetail);
            }
        } catch (Exception e) {
            throw new PersistenceException('Error saving ChatMessage (' + msgToInsert.Role__c + '): ' + e.getMessage(), e);
        }
    }
}
