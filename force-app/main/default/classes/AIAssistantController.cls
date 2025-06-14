/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Controller exposing AI Agent Framework functionality.
 *              Handles session creation/retrieval, initiates SYNCHRONOUS message processing,
 *              dispatches asynchronous work (actions/follow-up) when needed.
 */
public with sharing class AIAssistantController {
    private static final String DEFAULT_AGENT_DEV_NAME = 'Sales_Assistant';
    private static final Integer HISTORY_MESSAGE_LIMIT = 50;

    public class ControllerException extends AIAgentException {
    }
    public class ConfigurationException extends AIAgentException {
    }
    public class OrchestrationException extends AIAgentException {
    }

    public class ActionRequest {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String arguments;
    }

    @AuraEnabled
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage, Id currentRecordId) {
        String turnIdentifier = UuidUtils.generateUUID();
        String logPrefix = '[AIController Turn:' + turnIdentifier.left(8) + ' Sess:' + sessionId + '] ';

        if (sessionId == null || String.isBlank(userMessage)) {
            throw new AuraHandledException('Session ID and User Message are required.');
        }
        validateSessionAccess(sessionId);

        Id currentUserId = UserInfo.getUserId();
        Exception controllerProcessingException = null;
        Map<String, Object> lwcResponse = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };

        LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
        currentUserMessageData.role = AIAgentConstants.ROLE_USER;
        currentUserMessageData.content = userMessage;

        MessagePersistenceService msgSvc = new MessagePersistenceService();
        TurnLifecycleService turnSvc = new TurnLifecycleService();
        ActionExecutionService actionSvc = new ActionExecutionService();
        OrchestrationDispatchService dispatchSvc = new OrchestrationDispatchService(turnSvc);

        OrchestrationService orchestrationSvc = new OrchestrationService(msgSvc, turnSvc, actionSvc, dispatchSvc);

        try {
            ChatSession__c session = [
                SELECT Id, ProcessingStatus__c, AIAgentDefinition__c, AIAgentDefinition__r.LLMConfiguration__c, AIAgentDefinition__r.IsActive__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
            ];

            if (session.ProcessingStatus__c != AIAgentConstants.STATUS_IDLE && session.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
                throw new AuraHandledException('Assistant is currently busy (Status: ' + session.ProcessingStatus__c + '). Please wait.');
            }

            Id agentDefinitionId = session.AIAgentDefinition__c;
            Id llmConfigId = session.AIAgentDefinition__r.LLMConfiguration__c;

            if (
                agentDefinitionId == null ||
                llmConfigId == null ||
                session.AIAgentDefinition__r == null ||
                !session.AIAgentDefinition__r.IsActive__c
            ) {
                throw new ConfigurationException('Agent Definition is missing, inactive, or lacks required LLM Configuration on the Session.');
            }

            Id turnRecordContextId = currentRecordId;

            LLMInteractionService interactionService = new LLMInteractionService(
                sessionId,
                currentUserId,
                agentDefinitionId,
                llmConfigId,
                turnIdentifier,
                1,
                turnRecordContextId
            );

            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new ControllerException('LLMInteractionService returned a null result.');
            }

            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                sessionId,
                currentUserId,
                agentDefinitionId,
                turnRecordContextId,
                turnIdentifier,
                1,
                currentUserMessageData
            );

            if (outcome == OrchestrationService.OUTCOME_FAILED) {
                lwcResponse.put('success', false);
                try {
                    ChatSession__c latestSessionState = [SELECT LastProcessingError__c FROM ChatSession__c WHERE Id = :sessionId];
                    lwcResponse.put('error', latestSessionState?.LastProcessingError__c ?? 'Agent processing failed.');
                } catch (Exception queryEx) {
                    lwcResponse.put('error', 'Agent processing failed.');
                }
            } else if (outcome == OrchestrationService.OUTCOME_COMPLETED) {
                lwcResponse.put('success', true);
                lwcResponse.put('message', 'Agent responded.');
            } else {
                lwcResponse.put('success', true);
                lwcResponse.put('message', 'Processing...');
                if (outcome == OrchestrationService.OUTCOME_AWAITING_CONFIRMATION) {
                    lwcResponse.put('message', 'Awaiting user confirmation...');
                }
            }
        } catch (Exception ex) {
            controllerProcessingException = ex;
            String errorMsg = ex.getMessage();
            String errorCode = (ex instanceof ConfigurationException)
                ? AIAgentConstants.ERR_CODE_CONFIG_ERROR
                : AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

            lwcResponse.put('error', 'An internal error occurred: ' + errorMsg);
            lwcResponse.put('errorCode', errorCode);
            if (!(ex instanceof AuraHandledException)) {
                throw new AuraHandledException(errorMsg);
            } else {
                throw ex;
            }
        } finally {
            if (controllerProcessingException != null && !(controllerProcessingException instanceof AuraHandledException)) {
                try {
                    TurnLifecycleService tls = new TurnLifecycleService();
                    String finalErrorMsg = ('Controller Error: ' + controllerProcessingException.getMessage()).abbreviate(1000);
                    tls.failTurn(sessionId, turnIdentifier, finalErrorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
                } catch (Exception finalEx) {
                }
            }
        }
        return lwcResponse;
    }

    /**
     * @description Creates a new chat session, intelligently determining the correct initial context.
     *              - For internal users on a record page, the context is the record.
     *              - For internal users on a homepage, there is no record context.
     *              - For community users, the context is the record page if present, otherwise it defaults
     *                to the user's own Contact record, making the agent user-centric.
     * @param recordId The ID of the record the user is on, if any. Can be null.
     * @return The ID of the newly created ChatSession__c record.
     * @throws AuraHandledException for configuration errors or permissions issues.
     */
    @AuraEnabled
    public static Id createNewChatSession(Id recordId, String requestedAgentDevName) {
        Id newSessionId = null;
        Id userId = UserInfo.getUserId();
        String logPrefix = '[AIController.createNewChatSession] ';

        String selectedAgentDevName = null;
        try {
            selectedAgentDevName = AgentRoutingService.selectAgent(userId, recordId, requestedAgentDevName);
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(selectedAgentDevName);
            if (agentDef == null) {
                throw new ConfigurationException(
                    'Internal Error: The selected agent (' + selectedAgentDevName + ') could not be found or is inactive.'
                );
            }

            String sessionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');
            ChatSession__c session = new ChatSession__c(
                AIAgentDefinition__c = agentDef.Id,
                SessionLabel__c = sessionLabel,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                OwnerId = userId,
                User__c = userId
            );

            Database.insert(session, true);
            newSessionId = session.Id;
        } catch (AgentRoutingService.RoutingException rce) {
            throw new AuraHandledException(rce.getMessage());
        } catch (AIAgentConfigService.ConfigurationException ce) {
            throw new AuraHandledException('Error retrieving selected agent details: ' + ce.getMessage());
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
    public static List<Map<String, Object>> getChatHistory(Id sessionId, Integer limitCount, DateTime oldestMessageTimestamp) {
        if (sessionId == null) {
            throw new AuraHandledException('Session ID required.');
        }
        Integer settingsLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? Math.min(limitCount, settingsLimit) : settingsLimit;
        validateSessionAccess(sessionId);

        List<Map<String, Object>> formattedMessagesForUi = new List<Map<String, Object>>();

        try {
            Integer queryLimitWithBuffer = effectiveLimit * 2;
            String sortOrder = (oldestMessageTimestamp != null) ? 'DESC' : 'ASC';

            List<ChatMessage__c> rawMessages = ChatMessageService.getHistory(sessionId, queryLimitWithBuffer, sortOrder, oldestMessageTimestamp);

            for (ChatMessage__c msg : rawMessages) {
                String role = msg.Role__c?.toLowerCase();

                if (role == AIAgentConstants.ROLE_TOOL) {
                    continue;
                }

                if (role == AIAgentConstants.ROLE_ASSISTANT && String.isBlank(msg.Content__c)) {
                    continue;
                }

                Map<String, Object> fMsg = new Map<String, Object>{
                    'id' => msg.Id,
                    'role' => role,
                    'content' => msg.Content__c,
                    'timestamp' => msg.Timestamp__c,
                    'externalId' => msg.ExternalId__c
                };

                formattedMessagesForUi.add(fMsg);

                if (formattedMessagesForUi.size() >= effectiveLimit) {
                    break;
                }
            }

            if ('DESC'.equals(sortOrder) && !formattedMessagesForUi.isEmpty()) {
                List<Map<String, Object>> reversed = new List<Map<String, Object>>();
                for (Integer i = formattedMessagesForUi.size() - 1; i >= 0; i--) {
                    reversed.add(formattedMessagesForUi[i]);
                }
                formattedMessagesForUi = reversed;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving chat history: ' + e.getMessage());
        }
        return formattedMessagesForUi;
    }

    @AuraEnabled(cacheable=true)
    public static ChatSession__c getSessionStatus(Id sessionId) {
        if (sessionId == null) {
            throw new AuraHandledException('Session ID is required to get status.');
        }
        validateSessionAccess(sessionId);

        List<ChatSession__c> sessions = [
            SELECT Id, ProcessingStatus__c, CurrentStepDescription__c
            FROM ChatSession__c
            WHERE Id = :sessionId
            WITH USER_MODE
        ];
        if (sessions.isEmpty()) {
            throw new AuraHandledException('Session not found or access denied.');
        }
        return sessions[0];
    }

    @AuraEnabled
    public static List<Map<String, String>> getPreviousChatSessions(String agentDeveloperName, Id recordId) {
        Id userId = UserInfo.getUserId();
        List<Map<String, String>> sessionInfos = new List<Map<String, String>>();

        if (String.isBlank(agentDeveloperName)) {
            agentDeveloperName = DEFAULT_AGENT_DEV_NAME;
        }

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            Id agentDefId = agentDef.Id;

            List<String> whereClauses = new List<String>{ 'OwnerId = :userId', 'AIAgentDefinition__c = :agentDefId' };
            Map<String, Object> bindVars = new Map<String, Object>{ 'userId' => userId, 'agentDefId' => agentDefId };

            String whereClause = String.join(whereClauses, ' AND ');
            String query =
                'SELECT Id, Name, SessionLabel__c, StartTime__c FROM ChatSession__c WHERE ' +
                whereClause +
                ' ORDER BY LastActivityTime__c DESC NULLS LAST LIMIT 50';
            List<ChatSession__c> sessions = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);

            for (ChatSession__c sess : sessions) {
                String displayLabel = String.isNotBlank(sess.SessionLabel__c)
                    ? sess.SessionLabel__c
                    : (sess.Name + (sess.StartTime__c != null ? ' (' + sess.StartTime__c.format('MM/dd HH:mm') + ')' : ''));
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
            throw new AuraHandledException('Could not find active agent config for "' + agentDeveloperName + '": ' + ce.getMessage());
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving session list: ' + e.getMessage());
        }
        return sessionInfos;
    }

    private static void validateSessionAccess(Id sessionId) {
        try {
            Integer c = [SELECT COUNT() FROM ChatSession__c WHERE Id = :sessionId AND OwnerId = :UserInfo.getUserId() WITH USER_MODE];
            if (c == 0)
                throw new AuraHandledException('Chat session not found or access denied.');
        } catch (Exception e) {
            throw new AuraHandledException('Error verifying session access: ' + e.getMessage());
        }
    }
}
