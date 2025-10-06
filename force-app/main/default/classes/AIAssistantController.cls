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
     * Processes a user message for a given agent execution.
     * CRITICAL: This method maintains the service user context switch via REST callout when required.
     * The RequiresServiceUserContext__c flag check MUST remain here because:
     *   - Platform Events DO NOT switch user context
     *   - Only the REST callout via Named Credential switches to the service user
     *   - Moving this logic into the orchestrator would bypass the context switch entirely
     *
     * @param sessionId      The ID of the agent execution (AgentExecution__c).
     * @param userMessage    The message content from the user.
     * @param currentRecordId The current record context, if any.
     * @param turnIdentifier The unique identifier for the current turn.
     * @return               A response map containing success, message, and error details for the UI.
     * @throws AuraHandledException for validation or access errors.
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
            // Get the agent definition to determine routing requirements
            AgentExecution__c execution = [
                SELECT
                    Id,
                    ProcessingStatus__c,
                    AIAgentDefinition__c,
                    AIAgentDefinition__r.DeveloperName__c,
                    AIAgentDefinition__r.IsActive__c,
                    AIAgentDefinition__r.RequiresServiceUserContext__c,
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

            // CRITICAL: Check if service user context switch is required
            // This check MUST stay here because the REST callout is the ONLY way to switch context
            if (execution.AIAgentDefinition__r.RequiresServiceUserContext__c) {
                // Make REST callout to switch to service user context via Named Credential
                AIAgentHttpClient.AIAgentMessageRequest httpRequest = new AIAgentHttpClient.AIAgentMessageRequest(
                    String.valueOf(sessionId),
                    String.valueOf(originalUserId),
                    String.valueOf(execution.AIAgentDefinition__c),
                    turnIdentifier,
                    userMessage,
                    currentRecordId != null ? String.valueOf(currentRecordId) : null
                );

                AIAgentHttpClient.AIAgentHttpResponse httpResponse = AIAgentHttpClient.processMessage(httpRequest);

                if (httpResponse.success) {
                    lwcResponse.put('success', true);
                    lwcResponse.put('message', httpResponse.outcome != null ? httpResponse.outcome : 'Processing...');
                } else {
                    lwcResponse.put('success', false);
                    lwcResponse.put('error', httpResponse.error ?? 'Agent processing failed via REST call.');
                }

                return lwcResponse;
            }

            // Process in current user context (no service user required)
            System.debug(LoggingLevel.INFO, logPrefix + 'Processing message in original user context (no service user required)');

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

            // Use unified AgentExecutionService to initiate/continue execution
            String agentDeveloperName = execution.AIAgentDefinition__r.DeveloperName__c;
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agentDeveloperName, payload);

            if (result.success) {
                lwcResponse.put('success', true);
                lwcResponse.put('message', result.message != null ? result.message : 'Processing...');
            } else {
                lwcResponse.put('success', false);
                lwcResponse.put('error', result.errorMessage != null ? result.errorMessage : 'Agent processing failed.');
            }

        } catch (AgentOrchestratorException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration error: ' + e.getMessage());
            lwcResponse.put('error', 'Processing error: ' + e.getMessage());
        } catch (Exception ex) {
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

            // Attempt to mark turn as failed
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(sessionId, turnIdentifier, 'Controller Error: ' + errorMsg, errorCode, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update session state: ' + failEx.getMessage());
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

        String selectedAgentDevName = null;
        try {
            // 1. DELEGATE AGENT SELECTION: Use the routing service to determine the correct agent.
            // This service handles the logic for explicit requests vs. fallback routing.
            selectedAgentDevName = AgentRoutingService.selectAgent(userId, recordId, requestedAgentDevName);

            // 2. GET AGENT CONFIGURATION for welcome message
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(selectedAgentDevName);
            if (agentDef == null) {
                throw new ConfigurationException(
                    'Internal Error: The selected agent (' + selectedAgentDevName + ') could not be found or is inactive.'
                );
            }

            // 3. CREATE EXECUTION using unified AgentExecutionService
            // Note: For session creation, we just create the execution record but don't initiate processing yet
            // Processing will begin when the first user message is sent
            ExecutionContextService executionContextService = new ExecutionContextService();
            String executionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');

            Id newExecutionId = executionContextService.createExecution(
                'Conversational', // ExecutionType__c
                agentDef.Id, // AIAgentDefinition__c
                'Chat', // TriggerSource__c
                executionLabel, // TriggerPayload__c (using label as trigger data)
                recordId, // SourceRecordId__c
                userId, // User__c
                null // ServiceUser__c (no service user needed for conversational)
            );

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
        Integer settingsLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
        Integer effectiveLimit = (limitCount != null && limitCount > 0) ? Math.min(limitCount, settingsLimit) : settingsLimit;
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
            Integer c = [SELECT COUNT() FROM AgentExecution__c WHERE Id = :executionId AND User__c = :UserInfo.getUserId() WITH USER_MODE];
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
                WITH USER_MODE
                ORDER BY LastActivityTime__c DESC NULLS LAST
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                return null; // No existing execution found
            }

            SessionDetails response = new SessionDetails();
            response.sessionId = executions[0].Id; // Returns AgentExecution__c ID for UI compatibility

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
     * Deletes all execution steps from a given step (by externalId) onward in an agent execution, enabling a 'start over' feature.
     * Now uses the unified ExecutionStep__c data model exclusively.
     *
     * @param sessionId  The ID of the agent execution.
     * @param externalId The external ID of the step to start over from.
     * @throws AuraHandledException for validation, access, or DML errors.
     */
    @AuraEnabled
    public static void startOverFromMessage(Id sessionId, String externalId) {
        // --- 1. SECURITY: Ensure the user has the specific custom permission ---
        //        if (!FeatureManagement.checkPermission('Can_Start_Over_AI_Chat')) {
        //            throw new AuraHandledException('You do not have the required permissions to perform this action.');
        //        }

        // --- 2. VALIDATION: Ensure the user owns the execution and the step belongs to it ---
        validateExecutionAccess(sessionId);
        String logPrefix = '[AIController.startOverFromMessage] ';

        try {
            // --- 3. LOGIC: Get the timestamp of the step to delete from ---
            // Query by the reliable ExternalId__c field (assuming ExecutionStep__c has this field)
            List<ExecutionStep__c> steps = [
                SELECT Timestamp__c
                FROM ExecutionStep__c
                WHERE ExternalId__c = :externalId AND AgentExecution__c = :sessionId
                WITH USER_MODE
                LIMIT 1
            ];

            if (steps.isEmpty()) {
                throw new AuraHandledException('Target step not found or does not belong to this execution.');
            }
            Datetime targetTimestamp = steps[0].Timestamp__c;

            // --- 4. DML: Delete the target step and all subsequent steps in a single, efficient operation ---
            List<ExecutionStep__c> stepsToDelete = [
                SELECT Id
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :sessionId AND Timestamp__c >= :targetTimestamp
            ];

            if (!stepsToDelete.isEmpty()) {
                System.debug(
                    logPrefix + 'Deleting ' + stepsToDelete.size() + ' steps from execution ' + sessionId + ' starting at ' + targetTimestamp
                );
                delete stepsToDelete;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error starting over from step with externalId ' + externalId + ': ' + e.getMessage());
            throw new AuraHandledException('An error occurred while deleting steps: ' + e.getMessage());
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
