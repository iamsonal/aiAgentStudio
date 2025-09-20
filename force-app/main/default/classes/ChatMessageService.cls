/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ChatMessageService is the central service for managing ChatMessage__c records in conversational AI sessions.
 *
 * Responsibilities:
 *   - Provides robust, turn-aware retrieval of chat history, ensuring conversation integrity and context preservation
 *   - Supports flexible, paginated, and filtered access to message history for LLM and summarization workflows
 *   - Handles persistence of user, assistant, and tool messages with detailed error handling and logging
 *   - Ensures all message operations are auditable and maintainable, surfacing issues for troubleshooting
 *
 * This class is not intended for direct use outside the agent framework's messaging and memory subsystems.
 */
public inherited sharing class ChatMessageService {
    public class PersistenceException extends AIAgentException {
    }

    // Overloaded method for backward compatibility and use cases that don't need the summarization filter.
    public static List<ChatMessage__c> getHistory(Id sessionId, Integer limitCount, String sortOrder, Datetime olderThanTimestamp) {
        return getHistory(sessionId, limitCount, sortOrder, olderThanTimestamp, false);
    }

    /**
     * Retrieves ChatMessage__c records for a session with flexible filtering and pagination.
     * Supports summarization filtering and enforces framework-defined limits for performance.
     *
     * @param sessionId         The chat session identifier.
     * @param limitCount        Maximum messages to retrieve (framework default applied if null).
     * @param sortOrder         Chronological sort direction ('ASC' or 'DESC').
     * @param olderThanTimestamp Pagination boundary for efficient large dataset handling.
     * @param onlyUnsummarized  If true, only messages not yet processed by summarization are returned.
     * @return                  Ordered list of ChatMessage__c records matching criteria.
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
     * Persists a list of ChatMessage__c records with comprehensive error handling and partial success support.
     * Provides detailed logging for monitoring and troubleshooting conversation persistence issues.
     *
     * @param messages List of ChatMessage__c records to persist.
     * @return         List of Database.SaveResult objects with success/failure details for each record.
     * @throws         DmlException or PersistenceException on critical database errors.
     */
    public static List<Database.SaveResult> saveMessages(List<ChatMessage__c> messages) {
        if (messages == null || messages.isEmpty())
            return new List<Database.SaveResult>();

        // Filter out any null entries to avoid DML errors
        List<ChatMessage__c> messagesToInsert = new List<ChatMessage__c>();
        for (ChatMessage__c msg : messages) {
            if (msg != null) {
                messagesToInsert.add(msg);
            }
        }
        if (messagesToInsert.isEmpty()) {
            return new List<Database.SaveResult>();
        }

        System.debug(LoggingLevel.INFO, '[ChatMessageService] Persisting ' + messagesToInsert.size() + ' chat messages');
        try {
            List<Database.SaveResult> results = Database.insert(messagesToInsert, false); // Allow partial success

            // Count successes and failures, and collect error details for logging
            Integer successCount = 0;
            Integer failureCount = 0;
            List<String> errorMsgs = new List<String>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    failureCount++;
                    // Concatenate errors for this record
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
                    System.debug(LoggingLevel.ERROR, '[ChatMessageService] Message persistence failed at index ' + i + ': ' + recordErrors);
                    errorMsgs.add('Index ' + i + ': ' + recordErrors);
                }
            }
            if (failureCount > 0 || successCount > 0) {
                System.debug(
                    LoggingLevel.INFO,
                    '[ChatMessageService] Message Save Results: total=' +
                        messagesToInsert.size() +
                        ', success=' +
                        successCount +
                        ', failures=' +
                        failureCount
                );
                if (failureCount > 0) {
                    System.debug(LoggingLevel.WARN, '[ChatMessageService] Failure details: ' + String.join(errorMsgs, '; '));
                }
            }
            return results;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ChatMessageService] CRITICAL: Database error during message persistence: ' + e.getMessage());
            throw e; // Rethrow critical DML exception
        }
    }

    /**
     * Retrieves a precise number of complete conversation turns using an optimized two-step approach.
     * This method first identifies the exact turn identifiers to include, then fetches all messages
     * for those turns, ensuring complete turns and precise control over token consumption.
     *
     * @param sessionId         Chat session identifier.
     * @param turnLimit         Number of complete conversation turns to retrieve.
     * @param initialSortOrder  Retrieval direction for initial chunk ('ASC' or 'DESC').
     * @param onlyUnsummarized  If true, only unsummarized messages are included.
     * @return                  List of ChatMessage__c records representing complete conversation turns, in chronological order.
     */
    public static List<ChatMessage__c> getHistoryWithCompleteTurns(
        Id sessionId,
        Integer turnLimit,
        String initialSortOrder,
        Boolean onlyUnsummarized
    ) {
        String logPrefix = '[ChatMessageService.TurnOptimized] ';

        if (sessionId == null || turnLimit == null || turnLimit <= 0) {
            return new List<ChatMessage__c>();
        }

        String effectiveSortOrder = ('DESC'.equalsIgnoreCase(initialSortOrder)) ? 'DESC' : 'ASC';

        List<String> whereClauses = new List<String>{ 'ChatSession__c = :sessionId' };
        Map<String, Object> bindMap = new Map<String, Object>{
            'sessionId' => sessionId,
            'turnLimit' => turnLimit
        };

        if (onlyUnsummarized) {
            whereClauses.add('IsSummarized__c = FALSE');
        }

        String whereClause = String.join(whereClauses, ' AND ');

        try {
            // Step 1: Get the exact turn identifiers we want using aggregation
            String aggregateFunction = 'DESC'.equalsIgnoreCase(effectiveSortOrder) ? 'MAX(Timestamp__c)' : 'MIN(Timestamp__c)';
            String aggregateQuery = 'SELECT TurnIdentifier__c, ' + aggregateFunction + ' turnTime ' +
                'FROM ChatMessage__c ' +
                'WHERE ' + whereClause + ' AND TurnIdentifier__c != NULL ' +
                'GROUP BY TurnIdentifier__c ' +
                'ORDER BY ' + aggregateFunction + ' ' + effectiveSortOrder + ' ' +
                'LIMIT :turnLimit';

            List<AggregateResult> turnResults = Database.queryWithBinds(aggregateQuery, bindMap, AccessLevel.USER_MODE);

            if (turnResults.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No turns found matching criteria.');
                return new List<ChatMessage__c>();
            }

            // Step 2: Extract turn identifiers and fetch all messages for those turns
            Set<String> turnIdentifiersToInclude = new Set<String>();
            for (AggregateResult ar : turnResults) {
                String turnId = (String) ar.get('TurnIdentifier__c');
                if (String.isNotBlank(turnId)) {
                    turnIdentifiersToInclude.add(turnId);
                }
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Retrieved ' + turnIdentifiersToInclude.size() + ' turn identifiers for processing');

            // Step 3: Fetch all messages for the identified turns
            List<String> finalQueryParts = new List<String>();
            finalQueryParts.add('SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, TurnIdentifier__c,');
            finalQueryParts.add('AssistantToolCalls__c, ToolCallId__c, ParentMessage__c,');
            finalQueryParts.add('TokensUsed__c, ProcessingTimeMillis__c, RecordContextId__c, RecordContextData__c');
            finalQueryParts.add('FROM ChatMessage__c');
            finalQueryParts.add('WHERE ChatSession__c = :sessionId');
            finalQueryParts.add('AND TurnIdentifier__c IN :turnIdentifiersToInclude');
            finalQueryParts.add('ORDER BY Timestamp__c ASC, Id ASC NULLS LAST'); // Always return in chronological order

            String finalQuery = String.join(finalQueryParts, ' ');
            Map<String, Object> finalBindMap = new Map<String, Object>{
                'sessionId' => sessionId,
                'turnIdentifiersToInclude' => turnIdentifiersToInclude
            };

            List<ChatMessage__c> results = Database.queryWithBinds(finalQuery, finalBindMap, AccessLevel.USER_MODE);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Turn-optimized history retrieval complete: ' + results.size() + ' messages from ' + turnIdentifiersToInclude.size() + ' turns (unsummarized=' + onlyUnsummarized + ')'
            );

            return results;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve turn-based history: ' + e.getMessage());
            return new List<ChatMessage__c>();
        }
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

    /**
     * Helper class for robust chronological sorting of ChatMessage__c records.
     * Sorts by timestamp, then by ID to ensure consistent ordering even when timestamps are identical.
     */
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

    /**
     * Persists a user message for the given session and turn.
     *
     * @param sessionId        The chat session identifier.
     * @param turnIdentifier   The conversation turn identifier.
     * @param userMessageData  The user message data.
     * @param recordContextId  Optional record context ID to associate with the message.
     * @param logPrefix        Logging prefix for debug output.
     * @return                 The ID of the persisted ChatMessage__c record, or null if input is null.
     */
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

    /**
     * Persists an assistant message for the given session and turn.
     *
     * @param sessionId            The chat session identifier.
     * @param turnIdentifier       The conversation turn identifier.
     * @param parentUserMessageId  The ID of the user message this assistant message responds to.
     * @param assistantMessageData The assistant message data.
     * @param capabilityName       The capability or tool name associated with this message.
     * @param logPrefix            Logging prefix for debug output.
     * @return                     The ID of the persisted ChatMessage__c record.
     */
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

    /**
     * Persists an assistant message with pending tool calls for the given session and turn.
     *
     * @param sessionId                 The chat session identifier.
     * @param turnIdentifier            The conversation turn identifier.
     * @param parentUserMessageId       The ID of the user message this assistant message responds to.
     * @param assistantMessageData      The assistant message data.
     * @param pendingToolCallsListJson  JSON string of pending tool calls.
     * @param capabilityName            The capability or tool name associated with this message.
     * @param logPrefix                 Logging prefix for debug output.
     * @return                          The ID of the persisted ChatMessage__c record.
     */
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

    /**
     * Persists a tool result message for the given session and turn.
     *
     * @param sessionId             The chat session identifier.
     * @param turnIdentifier        The conversation turn identifier.
     * @param parentAssistantMessageId The ID of the assistant message this tool result is associated with.
     * @param toolCallId            The tool call identifier.
     * @param toolResultContentJson JSON string of the tool result content.
     * @param internalDetails       Internal details for logging (not persisted).
     * @param errorCode             Error code if the tool call failed, or null/blank if successful.
     * @param actionDuration        Duration of the tool action in milliseconds.
     * @param recordContextId       Optional record context ID to associate with the message.
     * @param recordContextDataJson Optional record context data as JSON.
     * @param capabilityName        The capability or tool name associated with this message.
     * @param logPrefix             Logging prefix for debug output.
     * @return                      The ID of the persisted ChatMessage__c record.
     * @throws                     PersistenceException if required fields are missing.
     */
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

    /**
     * Helper to construct a ChatMessage__c SObject from message data and context.
     * Throws PersistenceException if required fields are missing.
     *
     * @param msgData         The message data (required).
     * @param parentMsgId     The parent message ID, if any.
     * @param sessionId       The chat session ID (required).
     * @param turnIdentifier  The conversation turn identifier (required).
     * @param logPrefix       Logging prefix for debug output.
     * @param externalIdToUse The external ID to assign to the message.
     * @return                The constructed ChatMessage__c SObject.
     * @throws                PersistenceException if required fields are missing.
     */
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

    /**
     * Helper to persist a single ChatMessage__c record and return its ID.
     * Logs success or error details for traceability.
     *
     * @param msgToInsert The ChatMessage__c record to insert.
     * @param logPrefix   Logging prefix for debug output.
     * @return            The ID of the inserted record.
     * @throws            DmlException or PersistenceException on failure.
     */
    private static Id insertMessage(ChatMessage__c msgToInsert, String logPrefix) {
        try {
            List<Database.SaveResult> results = saveMessages(new List<ChatMessage__c>{ msgToInsert });
            if (results != null && !results.isEmpty() && results[0].isSuccess()) {
                Id savedId = results[0].getId();
                System.debug(LoggingLevel.INFO, logPrefix + 'Message persisted: role=' + msgToInsert.Role__c + ', id=' + savedId);
                return savedId;
            } else {
                String errorDetail = 'Unknown DML Error saving message.';
                if (results != null && !results.isEmpty() && results[0].getErrors().size() > 0) {
                    errorDetail = results[0].getErrors()[0].getMessage();
                }
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to save ChatMessage (' + msgToInsert.Role__c + '): ' + errorDetail);
                throw new DmlException('Failed to save ChatMessage (' + msgToInsert.Role__c + '). Error: ' + errorDetail);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception saving ChatMessage (' + msgToInsert.Role__c + '): ' + e.getMessage());
            throw new PersistenceException('Error saving ChatMessage (' + msgToInsert.Role__c + '): ' + e.getMessage(), e);
        }
    }
}
