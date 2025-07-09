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
    public class ControllerException extends AIAgentException {
    }
    public class ConfigurationException extends AIAgentException {
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
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage, Id currentRecordId, String turnIdentifier) {
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

        OrchestrationService orchestrationSvc = new OrchestrationService();

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

            LLMInteractionService interactionService = new LLMInteractionService(
                sessionId,
                currentUserId,
                agentDefinitionId,
                llmConfigId,
                turnIdentifier,
                1,
                currentRecordId,
                false
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
                turnIdentifier,
                1,
                currentUserMessageData,
                currentRecordId
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
                    String finalErrorMsg = ('Controller Error: ' + controllerProcessingException.getMessage());
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
    public static SessionDetails createNewChatSession(Id recordId, String requestedAgentDevName) {
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
            Id newSessionId = session.Id;

            String welcomeMessage = '';
            if (String.isNotBlank(agentDef.WelcomeMessageTemplate__c)) {
                String template = agentDef.WelcomeMessageTemplate__c;

                String firstName = String.isNotBlank(UserInfo.getFirstName()) ? UserInfo.getFirstName() : 'User';
                String fullName = String.isNotBlank(UserInfo.getName()) ? UserInfo.getName() : 'User';

                welcomeMessage = template.replace('{User.FirstName}', firstName).replace('{User.Name}', fullName);
            }

            SessionDetails response = new SessionDetails();
            response.sessionId = newSessionId;
            response.welcomeMessage = welcomeMessage;
            response.transientMessagesEnabled = AIAgentFrameworkSettings.useTransientMessages();

            return response;
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
            String sortOrder = 'DESC';

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

    private static void validateSessionAccess(Id sessionId) {
        try {
            Integer c = [SELECT COUNT() FROM ChatSession__c WHERE Id = :sessionId AND OwnerId = :UserInfo.getUserId() WITH USER_MODE];
            if (c == 0)
                throw new AuraHandledException('Chat session not found or access denied.');
        } catch (Exception e) {
            throw new AuraHandledException('Error verifying session access: ' + e.getMessage());
        }
    }

    /**
     * @description Retrieves details of the most recent, active chat session, including a processed welcome message.
     * @param agentDeveloperName The developer name of the agent.
     * @param recordId The current record context, if any.
     * @return SessionDetails wrapper containing the session ID and processed welcome message, or null.
     */
    @AuraEnabled(Cacheable=true)
    public static SessionDetails getMostRecentSession(String agentDeveloperName, Id recordId) {
        Id userId = UserInfo.getUserId();

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            if (agentDef == null) {
                return null;
            }

            List<ChatSession__c> sessions = [
                SELECT Id
                FROM ChatSession__c
                WHERE OwnerId = :userId AND AIAgentDefinition__c = :agentDef.Id
                WITH USER_MODE
                ORDER BY LastActivityTime__c DESC NULLS LAST
                LIMIT 1
            ];

            if (sessions.isEmpty()) {
                return null;
            }

            SessionDetails response = new SessionDetails();
            response.sessionId = sessions[0].Id;

            String template = agentDef.WelcomeMessageTemplate__c;
            if (String.isNotBlank(template)) {
                String processedMessage = template.replace('{User.FirstName}', UserInfo.getFirstName());
                processedMessage = processedMessage.replace('{User.Name}', UserInfo.getName());
                response.welcomeMessage = processedMessage;
            }
            response.transientMessagesEnabled = AIAgentFrameworkSettings.useTransientMessages();

            return response;
        } catch (Exception e) {
            return null;
        }
    }

    @AuraEnabled
    public static void startOverFromMessage(Id sessionId, String externalId) {
        validateSessionAccess(sessionId);
        String logPrefix = '[AIController.startOverFromMessage] ';

        try {
            List<ChatMessage__c> messages = [
                SELECT Timestamp__c
                FROM ChatMessage__c
                WHERE ExternalId__c = :externalId AND ChatSession__c = :sessionId
                WITH USER_MODE
                LIMIT 1
            ];

            if (messages.isEmpty()) {
                throw new AuraHandledException('Target message not found or does not belong to this session.');
            }
            Datetime targetTimestamp = messages[0].Timestamp__c;

            List<ChatMessage__c> messagesToDelete = [
                SELECT Id
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId AND Timestamp__c >= :targetTimestamp
            ];

            if (!messagesToDelete.isEmpty()) {
                delete messagesToDelete;
            }
        } catch (Exception e) {
            throw new AuraHandledException('An error occurred while deleting messages: ' + e.getMessage());
        }
    }

    public class SessionDetails {
        @AuraEnabled
        public Id sessionId { get; set; }
        @AuraEnabled
        public String welcomeMessage { get; set; }
        @AuraEnabled
        public Boolean transientMessagesEnabled { get; set; }
    }
}
