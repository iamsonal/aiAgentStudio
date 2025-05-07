/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage) {
        String turnIdentifier = UuidUtils.generateUUID();
        String logPrefix = '[AIController Turn:' + turnIdentifier.left(8) + ' Sess:' + sessionId + '] ';

        if (sessionId == null || String.isBlank(userMessage)) {
            throw new AuraHandledException('Session ID and User Message are required.');
        }
        validateSessionAccess(sessionId);

        Id currentUserId = UserInfo.getUserId();
        Id agentDefinitionId = null;
        Id llmConfigId = null;
        Id relatedRecordId = null;
        Exception controllerProcessingException = null;
        Map<String, Object> lwcResponse = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };

        LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
        currentUserMessageData.role = AIAgentConstants.ROLE_USER;
        currentUserMessageData.content = userMessage;

        OrchestrationService orchestrationSvc = new OrchestrationService();

        try {
            ChatSession__c session = [
                SELECT
                    Id,
                    ProcessingStatus__c,
                    AIAgentDefinition__c,
                    RelatedRecordId__c,
                    AIAgentDefinition__r.LLMConfiguration__c,
                    AIAgentDefinition__r.IsActive__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];

            if (session.ProcessingStatus__c != AIAgentConstants.STATUS_IDLE && session.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
                throw new AuraHandledException('Assistant is currently busy (Status: ' + session.ProcessingStatus__c + '). Please wait.');
            }
            agentDefinitionId = session.AIAgentDefinition__c;
            llmConfigId = session.AIAgentDefinition__r.LLMConfiguration__c;
            relatedRecordId = session.RelatedRecordId__c;
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
                relatedRecordId
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
                relatedRecordId,
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

    @AuraEnabled
    public static Id createNewChatSession(Id recordId) {
        Id newSessionId = null;
        Id userId = UserInfo.getUserId();
        String label = 'Chat - ' + Datetime.now().format('MM/dd HH:mm');
        String selectedAgentDevName = null;

        try {
            selectedAgentDevName = AgentRoutingService.selectAgent(userId, recordId, null);

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(selectedAgentDevName);
            if (agentDef == null) {
                throw new ConfigurationException('Internal Error: Selected agent configuration could not be retrieved: ' + selectedAgentDevName);
            }

            ChatSession__c session = new ChatSession__c(
                AIAgentDefinition__c = agentDef.Id,
                SessionLabel__c = label,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                OwnerId = userId,
                User__c = userId,
                RelatedRecordId__c = recordId
            );
            if (!Schema.SObjectType.ChatSession__c.isCreateable()) {
                throw new AuraHandledException('Permission denied creating Chat Session.');
            }
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
        List<Map<String, Object>> formattedMessages = new List<Map<String, Object>>();

        try {
            String sortOrder = (oldestMessageTimestamp != null) ? 'DESC' : 'ASC';
            List<ChatMessage__c> messages = ChatMessageService.getHistory(sessionId, effectiveLimit, sortOrder, oldestMessageTimestamp);

            for (ChatMessage__c msg : messages) {
                String role = msg.Role__c?.toLowerCase();
                Map<String, Object> fMsg = new Map<String, Object>{
                    'id' => msg.Id,
                    'role' => role,
                    'content' => msg.Content__c,
                    'timestamp' => msg.Timestamp__c,
                    'externalId' => msg.ExternalId__c
                };

                if (role == AIAgentConstants.ROLE_ASSISTANT && String.isNotBlank(msg.AssistantToolCalls__c)) {
                    fMsg.put('toolCallsData', msg.AssistantToolCalls__c);
                }
                if (role == AIAgentConstants.ROLE_TOOL && String.isNotBlank(msg.Content__c) && String.isNotBlank(msg.ToolCallId__c)) {
                    fMsg.put('toolResultData', msg.Content__c);
                }
                formattedMessages.add(fMsg);
            }
            if ('DESC'.equals(sortOrder) && !formattedMessages.isEmpty()) {
                List<Map<String, Object>> reversed = new List<Map<String, Object>>();
                for (Integer i = formattedMessages.size() - 1; i >= 0; i--) {
                    reversed.add(formattedMessages[i]);
                }
                formattedMessages = reversed;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving chat history: ' + e.getMessage());
        }
        return formattedMessages;
    }

    @AuraEnabled(Cacheable=true)
    public static ChatMessage__c getChatMessageById(Id messageId) {
        if (messageId == null) {
            throw new AuraHandledException('Message ID cannot be null.');
        }
        validateSessionAccessForMessage(messageId);
        List<ChatMessage__c> messages = [
            SELECT Id, Role__c, Content__c, Timestamp__c, ExternalId__c, TokensUsed__c, ProcessingTimeMillis__c, AssistantToolCalls__c, ToolCallId__c
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
            if (recordId != null) {
                whereClauses.add('RelatedRecordId__c = :recordId');
                bindVars.put('recordId', recordId);
            }
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

    @AuraEnabled
    public static Map<String, Object> handleUserConfirmation(Id sessionId, Id assistantMessageId, Boolean approved, String confirmationRequestId) {
        String logPrefix = '[AIConfirmCtrl CfmID:' + confirmationRequestId?.left(8) + ' Sess:' + sessionId + '] ';

        if (sessionId == null || assistantMessageId == null || approved == null || String.isBlank(confirmationRequestId)) {
            throw new AuraHandledException('Session ID, Message ID, Approval Status, and Confirmation Request ID are required.');
        }
        validateSessionAccess(sessionId);

        Id currentUserId = UserInfo.getUserId();
        Map<String, Object> lwcResponse = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };
        String originalTurnIdentifier = null;
        Id agentDefinitionId = null;
        Id relatedRecordId = null;

        OrchestrationService orchestrationSvc = new OrchestrationService();
        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        MessagePersistenceService msgPersistenceSvc = new MessagePersistenceService();

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, AIAgentDefinition__c, RelatedRecordId__c, CurrentTurnIdentifier__c
                FROM ChatSession__c
                WHERE Id = :sessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (sessions.isEmpty())
                throw new ControllerException('Session not found for confirmation.');
            ChatSession__c session = sessions[0];

            if (session.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_USER_CONFIRMATION) {
                lwcResponse.put('success', false);
                lwcResponse.put('error', 'Session is not currently awaiting confirmation.');
                return lwcResponse;
            }
            agentDefinitionId = session.AIAgentDefinition__c;
            relatedRecordId = session.RelatedRecordId__c;
            originalTurnIdentifier = session.CurrentTurnIdentifier__c;
            if (String.isBlank(originalTurnIdentifier)) {
                throw new ControllerException('Internal Error: CurrentTurnIdentifier missing while AwaitingUserConfirmation.');
            }

            logPrefix =
                '[AIConfirmCtrl CfmID:' +
                confirmationRequestId?.left(8) +
                ' Turn:' +
                originalTurnIdentifier.left(8) +
                ' Sess:' +
                sessionId +
                '] ';

            List<ChatMessage__c> assistantMessages = [
                SELECT Id, PendingConfirmationActionDetails__c, Role__c
                FROM ChatMessage__c
                WHERE Id = :assistantMessageId AND ChatSession__c = :sessionId
                LIMIT 1
            ];
            if (assistantMessages.isEmpty() || assistantMessages[0].Role__c != AIAgentConstants.ROLE_ASSISTANT) {
                throw new ControllerException('Valid Assistant Message for confirmation not found.');
            }
            ChatMessage__c assistantMsg = assistantMessages[0];
            String pendingDetailsJson = assistantMsg.PendingConfirmationActionDetails__c;

            if (String.isBlank(pendingDetailsJson)) {
                lwcResponse.put('success', false);
                lwcResponse.put('error', 'This confirmation request may have already been processed or cancelled.');
                return lwcResponse;
            }

            if (!approved) {
                String rejectionContent = JSON.serialize(
                    new Map<String, String>{ 'status' => 'rejected', 'reason' => 'User did not approve the action.' }
                );
                String toolCallIdForRejection = null;
                try {
                    List<Object> rawToolCalls = (List<Object>) JSON.deserializeUntyped(pendingDetailsJson);
                    if (!rawToolCalls.isEmpty() && rawToolCalls[0] instanceof Map<String, Object>) {
                        toolCallIdForRejection = (String) ((Map<String, Object>) rawToolCalls[0]).get('id');
                    }
                } catch (Exception ignored) {
                }

                msgPersistenceSvc.saveToolResultMessage(
                    sessionId,
                    assistantMessageId,
                    toolCallIdForRejection,
                    rejectionContent,
                    null,
                    null,
                    0L,
                    logPrefix
                );

                turnLifecycleSvc.failTurn(
                    sessionId,
                    originalTurnIdentifier,
                    'Action rejected by user.',
                    AIAgentConstants.ERR_CODE_USER_REJECTED,
                    logPrefix
                );
                clearPendingActionDetails(assistantMessageId, logPrefix);
                lwcResponse.put('success', true);
                lwcResponse.put('message', 'Action cancelled.');
            } else {
                AIAssistantController.ActionRequest toolRequestToResume = parsePendingAction(pendingDetailsJson, logPrefix);
                AgentCapabilityBinding__c binding = AIAgentConfigService.getCapabilityBinding(agentDefinitionId, toolRequestToResume.name);
                validateBinding(binding, toolRequestToResume.name, logPrefix);
                Boolean runAsyncOnResume = binding.ActionDefinition__r.RunAsynchronously__c == true;

                String resumeOutcome = null;
                if (!runAsyncOnResume) {
                    resumeOutcome = orchestrationSvc.resumeApprovedSyncAction(
                        sessionId,
                        currentUserId,
                        agentDefinitionId,
                        relatedRecordId,
                        originalTurnIdentifier,
                        0 /* Cycle count is effectively reset/not strictly applicable here */,
                        assistantMessageId,
                        toolRequestToResume,
                        binding.ActionDefinition__c,
                        binding.Id,
                        binding.ActionConfiguration__c,
                        logPrefix
                    );
                } else {
                    resumeOutcome = orchestrationSvc.resumeApprovedAsyncAction(
                        sessionId,
                        currentUserId,
                        agentDefinitionId,
                        relatedRecordId,
                        originalTurnIdentifier,
                        0,
                        assistantMessageId,
                        toolRequestToResume,
                        binding.ActionDefinition__c,
                        binding.Id,
                        binding.ActionConfiguration__c,
                        logPrefix
                    );
                }

                if (resumeOutcome != null && resumeOutcome != OrchestrationService.OUTCOME_FAILED) {
                    lwcResponse.put('success', true);
                    lwcResponse.put('message', 'Action approved and processing initiated.');
                } else {
                    lwcResponse.put('success', false);

                    try {
                        ChatSession__c latestSessionState = [SELECT LastProcessingError__c FROM ChatSession__c WHERE Id = :sessionId];
                        lwcResponse.put('error', latestSessionState?.LastProcessingError__c ?? 'Agent failed to complete the action after approval.');
                    } catch (Exception qEx) {
                        lwcResponse.put('error', 'Agent failed to complete the action after approval.');
                    }
                }
            }
        } catch (Exception ex) {
            String errorMsg = ex.getMessage();

            lwcResponse.put('error', 'Internal error during confirmation: ' + errorMsg);

            if (String.isNotBlank(originalTurnIdentifier)) {
                try {
                    TurnLifecycleService tls = new TurnLifecycleService();
                    tls.failTurn(
                        sessionId,
                        originalTurnIdentifier,
                        ('Confirmation Error: ' + errorMsg).abbreviate(131072),
                        AIAgentConstants.ERR_CODE_CONFIRMATION_STATE_ERROR,
                        logPrefix
                    );
                } catch (Exception finalFailEx) {
                    /* Log to debug */
                }
            }
            if (!(ex instanceof AuraHandledException)) {
                throw new AuraHandledException(errorMsg);
            } else {
                throw ex;
            }
        }

        return lwcResponse;
    }

    private static void clearPendingActionDetails(Id assistantMessageId, String logPrefix) {
        try {
            update new ChatMessage__c(Id = assistantMessageId, PendingConfirmationActionDetails__c = null);
        } catch (DmlException e) {
        }
    }

    private static AIAssistantController.ActionRequest parsePendingAction(String pendingDetailsJson, String logPrefix) {
        try {
            List<Object> rawToolCallsList = (List<Object>) JSON.deserializeUntyped(pendingDetailsJson);
            if (!rawToolCallsList.isEmpty() && rawToolCallsList[0] instanceof Map<String, Object>) {
                Map<String, Object> callMap = (Map<String, Object>) rawToolCallsList[0];
                if ('function'.equalsIgnoreCase(String.valueOf(callMap.get('type'))) && callMap.get('function') instanceof Map<String, Object>) {
                    String toolCallId = String.valueOf(callMap.get('id'));
                    Map<String, Object> funcMap = (Map<String, Object>) callMap.get('function');
                    String funcName = String.valueOf(funcMap.get('name'));
                    Object argsObj = funcMap.get('arguments');
                    String argsJson = (argsObj instanceof String) ? (String) argsObj : null;

                    if (String.isNotBlank(toolCallId) && String.isNotBlank(funcName) && argsJson != null) {
                        AIAssistantController.ActionRequest req = new AIAssistantController.ActionRequest();
                        req.id = toolCallId;
                        req.name = funcName;
                        req.arguments = argsJson;
                        return req;
                    }
                }
            }
            throw new OrchestrationException('Failed to parse valid action from PendingConfirmationActionDetails__c JSON.');
        } catch (Exception e) {
            throw new OrchestrationException('Could not parse pending action: ' + e.getMessage(), e);
        }
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
    private static void validateBinding(AgentCapabilityBinding__c binding, String capabilityName, String logPrefix) {
        if (binding == null)
            throw new ConfigurationException('Active CapabilityBinding not found: "' + capabilityName + '"');
        if (binding.ActionDefinition__r == null || !binding.ActionDefinition__r.IsActive__c) {
            throw new ConfigurationException('Linked Action Definition inactive for capability: "' + capabilityName + '"');
        }
    }
    private static void validateSessionAccessForMessage(Id messageId) {
        Id userId = UserInfo.getUserId();
        try {
            List<AggregateResult> results = [
                SELECT COUNT(Id) recordCount
                FROM ChatMessage__c
                WHERE Id = :messageId AND ChatSession__r.OwnerId = :userId
            ];
            if (results.isEmpty() || (Decimal) results[0].get('recordCount') == 0) {
                throw new AuraHandledException('Message not found or access denied.');
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error verifying message access: ' + e.getMessage());
        }
    }
}
