/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Controller exposing Asynchronous AI Agent Framework functionality.
 *              Handles session creation, initiates async message processing via Queueables,
 *              and retrieves basic message history for UI display.
 *              Relies on Platform Events for signalling response completion to LWC.
 *              Minimal logging via System.debug.
 */
public with sharing class AIAssistantController {
    private static final String DEFAULT_AGENT_DEV_NAME = 'Sales_Assistant';
    private static final Integer HISTORY_MESSAGE_LIMIT = 50;

    @AuraEnabled
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage) {
        Integer seq = 0;

        if (sessionId == null) {
            throw new AuraHandledException('Session ID cannot be null.');
        }
        if (String.isBlank(userMessage)) {
            throw new AuraHandledException('User message cannot be blank.');
        }
        validateSessionAccess(sessionId);

        Id currentUserId = UserInfo.getUserId();
        Map<String, Object> response = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };
        ChatSession__c sessionRef = null;

        ChatMessage__c userMessageSObject = new ChatMessage__c(
            ChatSession__c = sessionId,
            Role__c = 'user',
            Content__c = userMessage,
            Timestamp__c = Datetime.now(),
            ExternalId__c = FrameworkUtils.generateUUID()
        );
        String turnIdentifier = userMessageSObject.ExternalId__c;

        OrchestrationLogger.logStep(
            sessionId,
            turnIdentifier,
            seq++,
            OrchestrationLogger.TYPE_USER_PROMPT,
            OrchestrationLogger.STATUS_INIT,
            'Received user message via controller.',
            userMessageSObject,
            null,
            null,
            null,
            0L,
            null,
            null,
            null,
            null,
            null
        );

        try {
            sessionRef = [
                SELECT Id, ProcessingStatus__c, AIAgentDefinition__c, AIAgentDefinition__r.LLMConfiguration__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (sessionRef == null) {
                throw new AuraHandledException('Chat session not found.');
            }

            if (
                sessionRef.ProcessingStatus__c != null &&
                sessionRef.ProcessingStatus__c != 'Idle' &&
                sessionRef.ProcessingStatus__c != 'Failed'
            ) {
                throw new AuraHandledException(
                    'The assistant is currently processing. Status: ' + sessionRef.ProcessingStatus__c
                );
            }

            ChatSession__c sessionUpdate = new ChatSession__c(
                Id = sessionId,
                ProcessingStatus__c = AIAgentConstants.STATUS_QUEUED_FOR_PROCESSING,
                LastActivityTime__c = userMessageSObject.Timestamp__c,
                NextExpectedStatus__c = AIAgentConstants.NEXT_EXPECTED_PREPARE_LLM,
                CurrentTurnIdentifier__c = turnIdentifier,
                LastProcessingError__c = null,
                CurrentJobId__c = null
            );

            Database.SaveResult srUserMsg = Database.insert(userMessageSObject, false);
            Database.SaveResult srSessionUpd = Database.update(sessionUpdate, false);

            if (!srUserMsg.isSuccess() || !srSessionUpd.isSuccess()) {
                String dmlError = 'Failed initial DML.';
                if (!srUserMsg.isSuccess())
                    dmlError += ' Msg Save Error: ' + srUserMsg.getErrors()[0].getMessage();
                if (!srSessionUpd.isSuccess())
                    dmlError += ' Session Update Error: ' + srSessionUpd.getErrors()[0].getMessage();

                throw new AuraHandledException('Failed to initiate agent request.');
            }

            PrepareLLMCallQueueable prepJob = new PrepareLLMCallQueueable(
                sessionId,
                currentUserId,
                sessionRef.AIAgentDefinition__c,
                turnIdentifier,
                1
            );
            Id jobId = System.enqueueJob(prepJob);

            OrchestrationLogger.logStep(
                sessionId,
                turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_SUCCESS,
                'Dispatched PrepareLLMCall job: ' + jobId,
                new Map<String, Object>{ 'jobClass' => 'PrepareLLMCallQueueable', 'jobId' => jobId },
                null,
                null,
                null,
                0L,
                srUserMsg.getId(),
                null,
                null,
                sessionRef.AIAgentDefinition__r.LLMConfiguration__c,
                null
            );

            Database.update(new ChatSession__c(Id = sessionId, CurrentJobId__c = jobId), false);

            OrchestrationLogger.commitLogs();

            response.put('success', true);
            response.put('message', 'Request received, processing asynchronously...');
        } catch (Exception e) {
            throw new AuraHandledException('Error processing request: ' + e.getMessage());
        }
        return response;
    }

    @AuraEnabled
    public static Id createNewChatSession(String agentDeveloperName, Id recordId) {
        String targetAgentDevName = String.isBlank(agentDeveloperName) ? DEFAULT_AGENT_DEV_NAME : agentDeveloperName;

        Id newSessionId = null;
        Id userId = UserInfo.getUserId();
        String label = 'Chat - ' + Datetime.now().format('MM/dd HH:mm');

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(targetAgentDevName);

            ChatSession__c session = new ChatSession__c(
                AIAgentDefinition__c = agentDef.Id,
                SessionLabel__c = label,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                Status__c = 'Active',
                ProcessingStatus__c = 'Idle',
                OwnerId = userId,
                User__c = userId,
                RelatedRecordId__c = recordId
            );
            if (!Schema.SObjectType.ChatSession__c.isCreateable()) {
                throw new AuraHandledException('Permission denied creating Chat Session.');
            }
            Database.insert(session, true);
            newSessionId = session.Id;
        } catch (AIAgentConfigService.ConfigurationException ce) {
            throw new AuraHandledException(ce.getMessage());
        } catch (Exception e) {
            if (e instanceof AuraHandledException) {
                throw e;
            } else {
                throw new AuraHandledException('Error creating session: ' + e.getMessage());
            }
        }
        return newSessionId;
    }

    @AuraEnabled
    public static List<Map<String, Object>> getChatHistory(
        Id sessionId,
        Integer limitCount,
        DateTime oldestMessageTimestamp
    ) {
        if (sessionId == null) {
            throw new AuraHandledException('Session ID required.');
        }
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? limitCount : HISTORY_MESSAGE_LIMIT;
        validateSessionAccess(sessionId);
        List<Map<String, Object>> formattedMessages = new List<Map<String, Object>>();

        try {
            String sortOrder = (oldestMessageTimestamp != null) ? 'DESC' : 'ASC';
            List<ChatMessage__c> messages = ChatMessageService.getHistory(
                sessionId,
                effectiveLimit,
                sortOrder,
                oldestMessageTimestamp
            );

            for (ChatMessage__c msg : messages) {
                String role = msg.Role__c?.toLowerCase();
                if (role == 'user' || role == 'assistant' || role == 'system') {
                    formattedMessages.add(
                        new Map<String, Object>{
                            'id' => msg.Id,
                            'role' => role,
                            'content' => msg.Content__c,
                            'timestamp' => msg.Timestamp__c,
                            'externalId' => msg.ExternalId__c
                        }
                    );
                }
            }
            if ('DESC'.equals(sortOrder) && !formattedMessages.isEmpty()) {
                List<Map<String, Object>> reversed = new List<Map<String, Object>>();
                for (Integer i = formattedMessages.size() - 1; i >= 0; i--) {
                    reversed.add(formattedMessages[i]);
                }
                formattedMessages = reversed;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving chat history.');
        }
        return formattedMessages;
    }

    private static void validateSessionAccess(Id sessionId) {
        try {
            Integer c = [SELECT COUNT() FROM ChatSession__c WHERE Id = :sessionId AND OwnerId = :UserInfo.getUserId()];
            if (c == 0)
                throw new AuraHandledException('Chat session not found or access denied.');
        } catch (Exception e) {
            throw new AuraHandledException('Error verifying session access.');
        }
    }

    @AuraEnabled(Cacheable=true)
    public static ChatMessage__c getChatMessageById(Id messageId) {
        if (messageId == null) {
            throw new AuraHandledException('Message ID cannot be null.');
        }
        validateSessionAccessForMessage(messageId);

        List<ChatMessage__c> messages = [
            SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, TokensUsed__c, ProcessingTimeMillis__c
            FROM ChatMessage__c
            WHERE Id = :messageId
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        if (messages.isEmpty()) {
            throw new AuraHandledException('Chat message content not found.');
        }
        return messages[0];
    }

    private static void validateSessionAccessForMessage(Id messageId) {
        Id userId = UserInfo.getUserId();
        List<AggregateResult> results = [
            SELECT COUNT(Id) recordCount
            FROM ChatMessage__c
            WHERE Id = :messageId AND ChatSession__r.OwnerId = :userId
        ];
        if (results.isEmpty() || (Decimal) results[0].get('recordCount') == 0) {
            throw new AuraHandledException('Message not found or access denied.');
        }
    }

    /**
     * @description Retrieves a list of previous chat sessions for the current user and a specific agent,
     *              optionally filtered by a related record ID. Returns simplified data for LWC dropdown.
     * @param agentDeveloperName The Developer Name of the AIAgentDefinition__c.
     * @param recordId Optional Salesforce ID of a related record to filter sessions.
     * @return List of maps, each containing { sessionId, displayLabel, sessionName, sessionLabel }.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getPreviousChatSessions(String agentDeveloperName, Id recordId) {
        Id userId = UserInfo.getUserId();
        List<Map<String, String>> sessionInfos = new List<Map<String, String>>();

        if (String.isBlank(agentDeveloperName)) {
            throw new AuraHandledException('Agent Developer Name is required.');
        }

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            Id agentDefId = agentDef.Id;

            List<String> whereClauses = new List<String>();
            whereClauses.add('OwnerId = :userId');
            whereClauses.add('AIAgentDefinition__c = :agentDefId');

            if (recordId != null) {
                whereClauses.add('RelatedRecordId__c = :recordId');
            }

            String whereClause = String.join(whereClauses, ' AND ');

            List<ChatSession__c> sessions = Database.query(
                'SELECT Id, Name, SessionLabel__c, StartTime__c ' +
                    'FROM ChatSession__c ' +
                    'WHERE ' +
                    whereClause +
                    ' ' +
                    'ORDER BY LastActivityTime__c DESC NULLS LAST ' +
                    'LIMIT 50'
            );
            /* Alternative SOQL using bind variables (safer if inputs were less controlled)
             * List<ChatSession__c> sessions = [
             *      SELECT Id, Name, SessionLabel__c, StartTime__c
             *      FROM ChatSession__c
             *      WHERE OwnerId = :userId
             *      AND AIAgentDefinition__c = :agentDefId
             *      AND (RelatedRecordId__c = :recordId OR :recordId = null)
             *      ORDER BY LastActivityTime__c DESC NULLS LAST
             *      LIMIT 50
             * ];
             */

            for (ChatSession__c sess : sessions) {
                String displayLabel = String.isNotBlank(sess.SessionLabel__c)
                    ? sess.SessionLabel__c
                    : (sess.Name +
                      (sess.StartTime__c != null ? ' (' + sess.StartTime__c.format('MM/dd HH:mm') + ')' : ''));

                sessionInfos.add(
                    new Map<String, String>{
                        'sessionId' => sess.Id,
                        'displayLabel' => displayLabel.abbreviate(80),
                        'sessionName' => sess.Name,
                        'sessionLabel' => sess.SessionLabel__c
                    }
                );
            }
        } catch (AIAgentConfigService.ConfigurationException ce) {
            throw new AuraHandledException(
                'Could not find active agent configuration: ' + agentDeveloperName + '. ' + ce.getMessage()
            );
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving session list: ' + e.getMessage());
        }

        return sessionInfos;
    }
}
