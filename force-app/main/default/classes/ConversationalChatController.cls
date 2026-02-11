/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Lightning Web Component controller for conversational chat sessions. Thin UI layer that delegates execution logic to AgentExecutionService.
 */
public with sharing class ConversationalChatController {
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
     * Processes a user message for a given agent execution. Delegates to AgentExecutionService for all routing logic.
     */
    @AuraEnabled
    public static Map<String, Object> sendMessage(Id sessionId, String userMessage, Id currentRecordId, String turnIdentifier) {
        String logPrefix = '[AIController Turn:' + turnIdentifier.left(8) + ' Exec:' + sessionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting message processing for AgentExecution. Page context record: ' + currentRecordId);

        if (sessionId == null || String.isBlank(userMessage)) {
            throw new AuraHandledException('Execution ID and User Message are required.');
        }
        validateExecutionAccess(sessionId);
        Id originalUserId = UserInfo.getUserId();
        Map<String, Object> lwcResponse = new Map<String, Object>{ 'success' => false, 'sessionId' => sessionId };

        try {
            // Get the agent execution details
            AgentExecution__c execution = [
                SELECT
                    Id,
                    ProcessingStatus__c,
                    AIAgentDefinition__c,
                    AIAgentDefinition__r.DeveloperName__c,
                    AIAgentDefinition__r.IsActive__c,
                    User__c,
                    ServiceUser__c
                FROM AgentExecution__c
                WHERE Id = :sessionId
                LIMIT 1
            ];

            if (execution.ProcessingStatus__c != AIAgentConstants.STATUS_IDLE && execution.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
                throw new AuraHandledException('Assistant is currently busy (Status: ' + execution.ProcessingStatus__c + '). Please wait.');
            }

            if (execution.AIAgentDefinition__r == null || !execution.AIAgentDefinition__r.IsActive__c) {
                throw new ConfigurationException('Agent Definition is missing or inactive on the AgentExecution.');
            }

            // Build execution payload for unified service
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.userId = originalUserId;
            payload.serviceUserId = execution.ServiceUser__c;
            payload.triggerSource = 'Chat';
            payload.sourceRecordId = null; // Set during session creation
            payload.userMessage = userMessage;
            payload.currentRecordId = currentRecordId;
            payload.turnIdentifier = turnIdentifier;
            payload.existingExecutionId = sessionId; // Continue existing execution

            // Delegate to AgentExecutionService - it will handle service user context switching if needed
            String agentDeveloperName = execution.AIAgentDefinition__r.DeveloperName__c;
            System.debug(LoggingLevel.INFO, logPrefix + 'Delegating to AgentExecutionService for agent: ' + agentDeveloperName);
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agentDeveloperName, payload);

            if (result.success) {
                lwcResponse.put('success', true);
                lwcResponse.put('message', result.message != null ? result.message : 'Processing...');
            } else {
                lwcResponse.put('success', false);
                lwcResponse.put('error', result.errorMessage != null ? result.errorMessage : 'Agent processing failed.');
            }
        } catch (AIAgentException.OrchestrationException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration error: ' + e.getMessage());
            lwcResponse.put('error', 'Processing error: ' + e.getMessage());
        } catch (Exception ex) {
            String errorMsg = ex.getMessage();
            String errorCode = (ex instanceof ConfigurationException) ? AIAgentConstants.ERR_CODE_CONFIG_ERROR : AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
            System.debug(LoggingLevel.ERROR, logPrefix + ex.getTypeName() + ': ' + errorMsg + '\n' + ex.getStackTraceString());
            lwcResponse.put('error', 'An internal error occurred: ' + errorMsg);
            lwcResponse.put('errorCode', errorCode);

            // Attempt to mark turn as failed - may fail if execution is invalid
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(sessionId, turnIdentifier, 'Controller Error: ' + errorMsg, errorCode, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state: ' + failEx.getMessage());
            }
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Message processing completed. Success: ' + lwcResponse.get('success'));
        return lwcResponse;
    }

    /**
     * Creates a new agent execution for conversational interaction, intelligently determining the correct initial context
     * based on user and page context. This method now uses the unified AgentExecutionService.
     *   - For internal users on a record page, the context is the record.
     *   - For internal users on a homepage, there is no record context.
     *   - For community users, the context is the record page if present, otherwise it defaults to the user's own Contact record.
     *
     * @param recordId             The ID of the record the user is on, if any. Can be null.
     * @param requestedAgentDevName The developer name of the agent requested by the client, if any.
     * @return                     The SessionDetails wrapper containing the new execution ID and welcome message.
     * @throws AuraHandledException for configuration errors or permissions issues.
     */
    @AuraEnabled
    public static SessionDetails createNewChatSession(Id recordId, String requestedAgentDevName) {
        Id userId = UserInfo.getUserId();
        String logPrefix = '[AIController.createNewChatSession] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting session creation. User: ' + userId);

        try {
            // 1. VALIDATE AGENT NAME IS PROVIDED
            if (String.isBlank(requestedAgentDevName)) {
                throw new ConfigurationException('Agent developer name is required.');
            }

            // 2. GET AGENT CONFIGURATION for welcome message
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(requestedAgentDevName);
            if (agentDef == null) {
                throw new ConfigurationException('Internal Error: The selected agent (' + requestedAgentDevName + ') could not be found or is inactive.');
            }

            // 3. CREATE EXECUTION using unified AgentExecutionService
            // Note: For session creation, we just create the execution record but don't initiate processing yet
            // Processing will begin when the first user message is sent
            AgentStateService agentStateService = new AgentStateService();
            String executionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');

            Id newExecutionId = agentStateService.createExecution('Conversational', agentDef.Id, 'Chat', executionLabel, recordId, userId, null);

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully created new agent execution: ' + newExecutionId);

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
            response.sessionId = newExecutionId; // Now returns AgentExecution__c ID
            response.welcomeMessage = welcomeMessage;
            response.transientMessagesEnabled = true;

            return response;
        } catch (AIAgentConfigService.ConfigurationException ce) {
            System.debug(
                LoggingLevel.ERROR,
                '[AIController.createNewChatSession] Post-Routing Agent Config Error for Agent "' + requestedAgentDevName + '": ' + ce.getMessage()
            );
            throw new AuraHandledException('Error retrieving selected agent details: ' + ce.getMessage());
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[AIController.createNewChatSession] Error creating session. Routed Agent was: "' + requestedAgentDevName + '". Error: ' + e.getMessage()
            );
            if (e instanceof AuraHandledException) {
                throw e;
            } else {
                throw new AuraHandledException('Error creating session: ' + e.getMessage());
            }
        }
    }

    /**
     * Retrieves the execution history for a given agent execution, applying filtering and pagination for UI display.
     * Now uses the unified AgentExecution__c and ExecutionStep__c data model exclusively.
     *
     * @param sessionId              The ID of the agent execution (AgentExecution__c).
     * @param limitCount             The maximum number of steps to return.
     * @param oldestMessageTimestamp The timestamp to paginate older steps from.
     * @return                       A list of formatted step maps for the UI.
     * @throws AuraHandledException for validation or access errors.
     */
    @AuraEnabled
    public static List<Map<String, Object>> getChatHistory(Id sessionId, Integer limitCount, DateTime oldestMessageTimestamp) {
        if (sessionId == null) {
            throw new AuraHandledException('Execution ID required.');
        }
        // Use hardcoded UI history limit (20 messages) for chat display
        Integer uiHistoryLimit = 20;
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? Math.min(limitCount, uiHistoryLimit) : uiHistoryLimit;
        validateExecutionAccess(sessionId);

        List<Map<String, Object>> formattedMessagesForUi = new List<Map<String, Object>>();

        System.debug(
            LoggingLevel.DEBUG,
            '[AIController.getChatHistory] Session: ' + sessionId + ', Limit: ' + effectiveLimit + ', OlderThan: ' + oldestMessageTimestamp
        );
        try {
            // Note: We might need to query more records initially to ensure we have enough "displayable" steps after filtering.
            // Let's start by querying double the limit to have a good buffer.
            Integer queryLimitWithBuffer = effectiveLimit * 2;
            String sortOrder = 'DESC';

            // 1. Get RAW history from the ExecutionStepService using the unified data model
            ExecutionStepService executionStepService = new ExecutionStepService();
            List<ExecutionStep__c> rawSteps = getExecutionStepsWithTimestampPagination(
                executionStepService,
                sessionId,
                queryLimitWithBuffer,
                sortOrder,
                oldestMessageTimestamp
            );

            // 2. Process and filter the raw steps
            for (ExecutionStep__c step : rawSteps) {
                String role = step.StepRole__c?.toLowerCase();

                // a. SKIP all 'tool' role steps
                if (role == AIAgentConstants.ROLE_TOOL) {
                    continue;
                }

                // b. SKIP internal system steps for UI display
                if (step.IsInternal__c == true) {
                    continue;
                }

                // c. SKIP 'assistant' steps that have NO text content.
                //    This covers both fully empty steps and those that ONLY contain tool calls.
                if (role == AIAgentConstants.ROLE_ASSISTANT && String.isBlank(step.Content__c)) {
                    continue;
                }

                // d. Format step for UI display
                Map<String, Object> fStep = new Map<String, Object>{
                    'id' => step.Id,
                    'role' => role,
                    'content' => step.Content__c,
                    'timestamp' => step.Timestamp__c,
                    'stepType' => step.StepType__c,
                    'turnIdentifier' => step.TurnIdentifier__c,
                    'processingTimeMs' => step.ProcessingDuration__c
                };

                formattedMessagesForUi.add(fStep);

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
     * Helper method to retrieve ExecutionStep__c records with timestamp pagination support.
     * This bridges the gap until ExecutionStepService has native timestamp pagination support.
     *
     * @param executionStepService The ExecutionStepService instance
     * @param executionId The execution ID
     * @param limitCount The maximum number of steps to retrieve
     * @param sortOrder The sort order ('ASC' or 'DESC')
     * @param olderThanTimestamp The timestamp boundary for pagination
     * @return List of ExecutionStep__c records
     */
    private static List<ExecutionStep__c> getExecutionStepsWithTimestampPagination(
        ExecutionStepService executionStepService,
        Id executionId,
        Integer limitCount,
        String sortOrder,
        DateTime olderThanTimestamp
    ) {
        // For now, use the basic getHistory method and apply timestamp filtering
        // This can be optimized in ExecutionStepService later with native timestamp pagination
        List<ExecutionStep__c> allSteps = executionStepService.getHistory(executionId, limitCount, sortOrder, null, false);

        if (olderThanTimestamp == null) {
            return allSteps;
        }

        // Apply timestamp filtering
        List<ExecutionStep__c> filteredSteps = new List<ExecutionStep__c>();
        for (ExecutionStep__c step : allSteps) {
            if (step.Timestamp__c < olderThanTimestamp) {
                filteredSteps.add(step);
            }
        }

        return filteredSteps;
    }

    /**
     * Validates that the current user has access to the specified agent execution.
     *
     * @param executionId The ID of the agent execution to validate.
     * @throws AuraHandledException if the execution is not found or access is denied.
     */
    private static void validateExecutionAccess(Id executionId) {
        try {
            Integer c = [SELECT COUNT() FROM AgentExecution__c WHERE Id = :executionId AND User__c = :UserInfo.getUserId()];
            if (c == 0)
                throw new AuraHandledException('Agent execution not found or access denied.');
        } catch (Exception e) {
            throw new AuraHandledException('Error verifying execution access: ' + e.getMessage());
        }
    }

    /**
     * Retrieves details of the most recent, active agent execution for the specified agent and user, including a processed welcome message.
     * Now uses the unified AgentExecution__c data model exclusively.
     *
     * @param agentDeveloperName The developer name of the agent.
     * @param recordId           The current record context, if any.
     * @return                   SessionDetails wrapper containing the execution ID and processed welcome message, or null if not found.
     */
    @AuraEnabled(Cacheable=true)
    public static SessionDetails getMostRecentSession(String agentDeveloperName, Id recordId) {
        Id userId = UserInfo.getUserId();

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            if (agentDef == null) {
                return null; // Agent not found or inactive
            }

            List<AgentExecution__c> executions = [
                SELECT Id
                FROM AgentExecution__c
                WHERE User__c = :userId AND AIAgentDefinition__c = :agentDef.Id AND ExecutionType__c = 'Conversational'
                ORDER BY LastActivityTime__c DESC NULLS LAST
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                return null; // No existing execution found
            }

            SessionDetails response = new SessionDetails();
            response.sessionId = executions[0].Id; // Returns AgentExecution__c ID for UI compatibility

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
     * Deletes all execution steps and related decision steps from a given step (by turnIdentifier) onward in an agent execution,
     * enabling a 'start over' feature. This method deletes ExecutionStep__c records and related decision steps (if addons deployed)
     * to ensure a complete cleanup of the conversation history from the specified point.
     *
     * @param sessionId      The ID of the agent execution.
     * @param turnIdentifier The turn identifier of the step to start over from.
     * @throws AuraHandledException for validation, access, or DML errors.
     */
    @AuraEnabled
    public static void startOverFromMessage(Id sessionId, String turnIdentifier) {
        validateExecutionAccess(sessionId);
        String logPrefix = '[AIController.startOverFromMessage] ';

        try {
            // First, find all steps with the target turn identifier to get the earliest timestamp
            List<ExecutionStep__c> targetSteps = [
                SELECT Timestamp__c
                FROM ExecutionStep__c
                WHERE TurnIdentifier__c = :turnIdentifier AND AgentExecution__c = :sessionId
                ORDER BY Timestamp__c ASC
            ];

            if (targetSteps.isEmpty()) {
                throw new AuraHandledException('Target step not found or does not belong to this execution.');
            }

            // Use the earliest timestamp of the target turn to ensure we delete the entire turn
            Datetime targetTimestamp = targetSteps[0].Timestamp__c;

            // Delete all steps from the target timestamp onwards (including the target turn)
            List<ExecutionStep__c> stepsToDelete = [
                SELECT Id, TurnIdentifier__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :sessionId AND Timestamp__c >= :targetTimestamp
            ];

            if (!stepsToDelete.isEmpty()) {
                // Collect unique turn identifiers
                Set<String> turnIdentifiersToDelete = new Set<String>();
                for (ExecutionStep__c step : stepsToDelete) {
                    if (String.isNotBlank(step.TurnIdentifier__c)) {
                        turnIdentifiersToDelete.add(step.TurnIdentifier__c);
                    }
                }

                System.debug(
                    logPrefix +
                        'Deleting ' +
                        stepsToDelete.size() +
                        ' execution steps and related decision steps from execution ' +
                        sessionId +
                        ' starting at ' +
                        targetTimestamp
                );

                // Delete the execution steps. We rely on class sharing + explicit execution ownership checks.
                delete stepsToDelete;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error starting over from step with turnIdentifier ' + turnIdentifier + ': ' + e.getMessage());
            throw new AuraHandledException('An error occurred while deleting steps: ' + e.getMessage());
        }
    }

    /**
     * Provides secure, cacheable access to the current user's session ID for use in LWC platform event subscriptions.
     *
     * @return The current user's session ID
     * @throws AuraHandledException if unable to retrieve session ID
     */
    @AuraEnabled(Cacheable=true)
    public static String fetchSessionId() {
        try {
            Map<String, Object> currentSession = Auth.SessionManagement.getCurrentSession();
            String sessionId = null;
            if (currentSession != null) {
                if (currentSession.containsKey('SessionId')) {
                    sessionId = (String) currentSession.get('SessionId');
                } else if (currentSession.containsKey('sessionId')) {
                    sessionId = (String) currentSession.get('sessionId');
                }
            }
            if (String.isBlank(sessionId)) {
                throw new AuraHandledException('Unable to retrieve session ID. Please contact your administrator.');
            }
            return sessionId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ConversationalChatController] Exception in fetchSessionId: ' + e.getTypeName() + ': ' + e.getMessage());
            throw new AuraHandledException('Unable to retrieve session ID. Please contact your administrator.');
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
}
