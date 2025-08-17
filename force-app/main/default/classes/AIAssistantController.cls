/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAssistantController is the Lightning Web Component controller for the AI Agent Framework.
 * Responsibilities:
 *   - Manages the chat session lifecycle, including creation, validation, and access control
 *   - Processes user messages with intelligent routing between synchronous and asynchronous execution contexts
 *   - Provides secure, filtered access to conversation history for UI display
 *   - Surfaces operational and configuration issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended.
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

    /**
     * Processes a user message for a given chat session, routing between synchronous and asynchronous execution as needed.
     * Handles session validation, error handling, and returns a response map for the UI.
     *
     * @param sessionId      The ID of the chat session.
     * @param userMessage    The message content from the user.
     * @param currentRecordId The current record context, if any.
     * @param turnIdentifier The unique identifier for the current turn.
     * @return               A response map containing success, message, and error details for the UI.
     * @throws AuraHandledException for validation or access errors.
     */
    @AuraEnabled
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage, Id currentRecordId, String turnIdentifier) {
        String logPrefix = '[AIController Turn:' + turnIdentifier.left(8) + ' Sess:' + sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting message processing. Page context record: ' + currentRecordId);

        if (sessionId == null || String.isBlank(userMessage)) {
            throw new AuraHandledException('Session ID and User Message are required.');
        }
        validateSessionAccess(sessionId);
        Id originalUserId = UserInfo.getUserId();
        Exception controllerProcessingException = null;
        Map<String, Object> lwcResponse = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };

        LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
        currentUserMessageData.role = AIAgentConstants.ROLE_USER;
        currentUserMessageData.content = userMessage;

        // Instantiate services. The default constructors now correctly wire up all dependencies,
        // including the new ContextManagerService where needed.
        OrchestrationService orchestrationSvc = new OrchestrationService();

        try {
            ChatSession__c session = [
                SELECT
                    Id,
                    ProcessingStatus__c,
                    AIAgentDefinition__c,
                    AIAgentDefinition__r.LLMConfiguration__c,
                    AIAgentDefinition__r.IsActive__c,
                    AIAgentDefinition__r.RequiresServiceUserContext__c
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

            if (session.AIAgentDefinition__r.RequiresServiceUserContext__c) {
                AIAgentHttpClient.AIAgentMessageRequest httpRequest = new AIAgentHttpClient.AIAgentMessageRequest(
                    String.valueOf(sessionId),
                    String.valueOf(originalUserId),
                    String.valueOf(agentDefinitionId),
                    turnIdentifier,
                    userMessage,
                    currentRecordId != null ? String.valueOf(currentRecordId) : null
                );

                AIAgentHttpClient.AIAgentHttpResponse httpResponse = AIAgentHttpClient.processMessage(httpRequest);

                if (httpResponse.success) {
                    lwcResponse.put('success', true);
                    if (httpResponse.outcome == OrchestrationService.OUTCOME_COMPLETED) {
                        lwcResponse.put('message', 'Agent responded.');
                    } else if (httpResponse.outcome == OrchestrationService.OUTCOME_AWAITING_CONFIRMATION) {
                        lwcResponse.put('message', 'Awaiting user confirmation...');
                    } else {
                        lwcResponse.put('message', 'Processing...');
                    }
                } else {
                    lwcResponse.put('success', false);
                    lwcResponse.put('error', httpResponse.error ?? 'Agent processing failed via REST call.');
                }

                return lwcResponse;
            }

            // Process in current user context without switching
            System.debug(LoggingLevel.INFO, logPrefix + 'Processing message in original user context (no service user required)');
            String outcome = processMessageDirectly(
                sessionId,
                originalUserId,
                agentDefinitionId,
                llmConfigId,
                turnIdentifier,
                currentRecordId,
                currentUserMessageData,
                orchestrationSvc
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Message processing completed with outcome: ' + outcome);

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
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'UNHANDLED CONTROLLER EXCEPTION: (' + ex.getTypeName() + ') ' + errorMsg + '\nStack Trace: ' + ex.getStackTraceString()
            );
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
                    System.debug(LoggingLevel.WARN, logPrefix + 'Successfully updated session to FAILED state in controller cleanup');
                } catch (Exception finalEx) {
                    System.debug(
                        LoggingLevel.ERROR,
                        logPrefix + 'CRITICAL: Failed to update session state during controller cleanup: ' + finalEx.getMessage()
                    );
                }
            }
            System.debug(LoggingLevel.INFO, logPrefix + 'Message processing completed. Success: ' + lwcResponse.get('success'));
        }
        return lwcResponse;
    }

    /**
     * Creates a new chat session, intelligently determining the correct initial context based on user and page context.
     *   - For internal users on a record page, the context is the record.
     *   - For internal users on a homepage, there is no record context.
     *   - For community users, the context is the record page if present, otherwise it defaults to the user's own Contact record.
     *
     * @param recordId             The ID of the record the user is on, if any. Can be null.
     * @param requestedAgentDevName The developer name of the agent requested by the client, if any.
     * @return                     The SessionDetails wrapper containing the new session ID and welcome message.
     * @throws AuraHandledException for configuration errors or permissions issues.
     */
    @AuraEnabled
    public static SessionDetails createNewChatSession(Id recordId, String requestedAgentDevName) {
        Id userId = UserInfo.getUserId();
        String logPrefix = '[AIController.createNewChatSession] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting session creation. User: ' + userId);

        String selectedAgentDevName = null;
        try {
            // 1. DELEGATE AGENT SELECTION: Use the routing service to determine the correct agent.
            // This service handles the logic for explicit requests vs. fallback routing.
            selectedAgentDevName = AgentRoutingService.selectAgent(userId, recordId, requestedAgentDevName);

            // 2. GET AGENT CONFIGURATION: Retrieve the full agent definition using the selected name.
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(selectedAgentDevName);
            if (agentDef == null) {
                throw new ConfigurationException(
                    'Internal Error: The selected agent (' + selectedAgentDevName + ') could not be found or is inactive.'
                );
            }

            // 3. CREATE THE SESSION RECORD
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
            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully created new chat session: ' + newSessionId);

            // 4. PROCESS WELCOME MESSAGE
            String welcomeMessage = '';
            if (String.isNotBlank(agentDef.WelcomeMessageTemplate__c)) {
                String template = agentDef.WelcomeMessageTemplate__c;
                // Defensively handle cases where UserInfo might be sparse
                String firstName = String.isNotBlank(UserInfo.getFirstName()) ? UserInfo.getFirstName() : 'User';
                String fullName = String.isNotBlank(UserInfo.getName()) ? UserInfo.getName() : 'User';

                welcomeMessage = template.replace('{User.FirstName}', firstName).replace('{User.Name}', fullName);
            }

            // 5. CONSTRUCT THE RESPONSE DTO
            SessionDetails response = new SessionDetails();
            response.sessionId = newSessionId;
            response.welcomeMessage = welcomeMessage;
            response.transientMessagesEnabled = true;

            return response;
        } catch (AgentRoutingService.RoutingException rce) {
            System.debug(LoggingLevel.ERROR, '[AIController.createNewChatSession] Routing Configuration Error: ' + rce.getMessage());
            throw new AuraHandledException(rce.getMessage());
        } catch (AIAgentConfigService.ConfigurationException ce) {
            System.debug(
                LoggingLevel.ERROR,
                '[AIController.createNewChatSession] Post-Routing Agent Config Error for Agent "' + selectedAgentDevName + '": ' + ce.getMessage()
            );
            throw new AuraHandledException('Error retrieving selected agent details: ' + ce.getMessage());
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[AIController.createNewChatSession] Error creating session. Routed Agent was: "' +
                    selectedAgentDevName +
                    '". Error: ' +
                    e.getMessage()
            );
            if (e instanceof AuraHandledException) {
                throw e;
            } else {
                throw new AuraHandledException('Error creating session: ' + e.getMessage());
            }
        }
    }

    /**
     * Retrieves the chat history for a given session, applying filtering and pagination for UI display.
     *
     * @param sessionId              The ID of the chat session.
     * @param limitCount             The maximum number of messages to return.
     * @param oldestMessageTimestamp The timestamp to paginate older messages from.
     * @return                       A list of formatted message maps for the UI.
     * @throws AuraHandledException for validation or access errors.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getChatHistory(Id sessionId, Integer limitCount, DateTime oldestMessageTimestamp) {
        if (sessionId == null) {
            throw new AuraHandledException('Session ID required.');
        }
        Integer settingsLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? Math.min(limitCount, settingsLimit) : settingsLimit;
        validateSessionAccess(sessionId);

        List<Map<String, Object>> formattedMessagesForUi = new List<Map<String, Object>>();

        System.debug(
            LoggingLevel.DEBUG,
            '[AIController.getChatHistory] Session: ' + sessionId + ', Limit: ' + effectiveLimit + ', OlderThan: ' + oldestMessageTimestamp
        );
        try {
            // Note: We might need to query more records initially to ensure we have enough "displayable" messages after filtering.
            // Let's start by querying double the limit to have a good buffer.
            Integer queryLimitWithBuffer = effectiveLimit * 2;
            String sortOrder = 'DESC';

            // 1. Get RAW history from the service. No changes to the service itself.
            List<ChatMessage__c> rawMessages = ChatMessageService.getHistory(sessionId, queryLimitWithBuffer, sortOrder, oldestMessageTimestamp);

            // 2. Process and filter the raw messages
            for (ChatMessage__c msg : rawMessages) {
                String role = msg.Role__c?.toLowerCase();

                // a. SKIP all 'tool' role messages
                if (role == AIAgentConstants.ROLE_TOOL) {
                    continue;
                }

                // b. SKIP 'assistant' messages that have NO text content.
                //    This now covers both fully empty messages and those that ONLY contain tool calls.
                if (role == AIAgentConstants.ROLE_ASSISTANT && String.isBlank(msg.Content__c)) {
                    continue;
                }

                // Since we are now filtering out all non-text messages from the assistant,
                // the `finalContentForUi` logic is no longer needed. We just use msg.Content__c.
                Map<String, Object> fMsg = new Map<String, Object>{
                    'id' => msg.Id,
                    'role' => role,
                    'content' => msg.Content__c, // Always use the direct content now
                    'timestamp' => msg.Timestamp__c,
                    'externalId' => msg.ExternalId__c
                };

                formattedMessagesForUi.add(fMsg);

                if (formattedMessagesForUi.size() >= effectiveLimit) {
                    break;
                }
            }

            // The sort-reversal logic for pagination remains the same
            if ('DESC'.equals(sortOrder) && !formattedMessagesForUi.isEmpty()) {
                List<Map<String, Object>> reversed = new List<Map<String, Object>>();
                for (Integer i = formattedMessagesForUi.size() - 1; i >= 0; i--) {
                    reversed.add(formattedMessagesForUi[i]);
                }
                formattedMessagesForUi = reversed;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AIController.getChatHistory] Error session ' + sessionId + ': ' + e.getMessage());
            throw new AuraHandledException('Error retrieving chat history: ' + e.getMessage());
        }
        return formattedMessagesForUi;
    }

    /**
     * Validates that the current user has access to the specified chat session.
     *
     * @param sessionId The ID of the chat session to validate.
     * @throws AuraHandledException if the session is not found or access is denied.
     */
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
     * Retrieves details of the most recent, active chat session for the specified agent and user, including a processed welcome message.
     *
     * @param agentDeveloperName The developer name of the agent.
     * @param recordId           The current record context, if any.
     * @return                   SessionDetails wrapper containing the session ID and processed welcome message, or null if not found.
     */
    @AuraEnabled(Cacheable=true)
    public static SessionDetails getMostRecentSession(String agentDeveloperName, Id recordId) {
        Id userId = UserInfo.getUserId();

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            if (agentDef == null) {
                return null; // Agent not found or inactive
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
                return null; // No existing session found
            }

            SessionDetails response = new SessionDetails();
            response.sessionId = sessions[0].Id;

            // --- Start of Merged Logic ---
            String template = agentDef.WelcomeMessageTemplate__c;
            if (String.isNotBlank(template)) {
                String processedMessage = template.replace('{User.FirstName}', UserInfo.getFirstName());
                processedMessage = processedMessage.replace('{User.Name}', UserInfo.getName());
                response.welcomeMessage = processedMessage;
            }
            response.transientMessagesEnabled = true;

            return response;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Error getting most recent session details: ' + e.getMessage());
            return null;
        }
    }

    /**
     * Deletes all messages from a given message (by externalId) onward in a chat session, enabling a 'start over' feature.
     *
     * @param sessionId  The ID of the chat session.
     * @param externalId The external ID of the message to start over from.
     * @throws AuraHandledException for validation, access, or DML errors.
     */
    @AuraEnabled
    public static void startOverFromMessage(Id sessionId, String externalId) {
        // --- 1. SECURITY: Ensure the user has the specific custom permission ---
        //        if (!FeatureManagement.checkPermission('Can_Start_Over_AI_Chat')) {
        //            throw new AuraHandledException('You do not have the required permissions to perform this action.');
        //        }

        // --- 2. VALIDATION: Ensure the user owns the session and the message belongs to it ---
        validateSessionAccess(sessionId);
        String logPrefix = '[AIController.startOverFromMessage] ';

        try {
            // --- 3. LOGIC: Get the timestamp of the message to delete from ---
            // Query by the reliable ExternalId__c field now
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

            // --- 4. DML: Delete the target message and all subsequent messages in a single, efficient operation ---
            List<ChatMessage__c> messagesToDelete = [
                SELECT Id
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId AND Timestamp__c >= :targetTimestamp
            ];

            if (!messagesToDelete.isEmpty()) {
                System.debug(
                    logPrefix + 'Deleting ' + messagesToDelete.size() + ' messages from session ' + sessionId + ' starting at ' + targetTimestamp
                );
                delete messagesToDelete;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error starting over from message with externalId ' + externalId + ': ' + e.getMessage());
            throw new AuraHandledException('An error occurred while deleting messages: ' + e.getMessage());
        }
    }

    /**
     * Wrapper for chat session details, including session ID, welcome message, and UI flags.
     */
    public class SessionDetails {
        @AuraEnabled
        public Id sessionId { get; set; }
        @AuraEnabled
        public String welcomeMessage { get; set; }
        @AuraEnabled
        public Boolean transientMessagesEnabled { get; set; }
    }

    /**
     * Processes a message directly in the current user context, without switching to a service user.
     *
     * @param sessionId              The ID of the chat session.
     * @param userId                 The ID of the user.
     * @param agentDefinitionId      The ID of the agent definition.
     * @param llmConfigId            The ID of the LLM configuration.
     * @param turnIdentifier         The unique identifier for the current turn.
     * @param currentRecordId        The current record context, if any.
     * @param currentUserMessageData The message data from the user.
     * @param orchestrationSvc       The orchestration service instance.
     * @return                       The outcome string from the orchestration service.
     * @throws ControllerException if the LLM interaction returns null.
     */
    private static String processMessageDirectly(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id llmConfigId,
        String turnIdentifier,
        Id currentRecordId,
        LLMInteractionService.MessageData currentUserMessageData,
        OrchestrationService orchestrationSvc
    ) {
        Id originalUserId = userId;
        Id executionUserId = userId;

        // Instantiate LLMInteractionService with current user context
        LLMInteractionService interactionService = new LLMInteractionService(
            sessionId,
            originalUserId,
            agentDefinitionId,
            llmConfigId,
            turnIdentifier,
            1,
            currentRecordId,
            false
        );

        // Call the LLM interaction service
        LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

        if (llmResult == null) {
            throw new ControllerException('LLMInteractionService returned a null result.');
        }

        // Call OrchestrationService
        return orchestrationSvc.processLlmResult(
            llmResult,
            sessionId,
            originalUserId,
            executionUserId,
            agentDefinitionId,
            turnIdentifier,
            1,
            currentUserMessageData,
            currentRecordId
        );
    }
}
