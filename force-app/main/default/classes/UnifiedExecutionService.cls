/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * UnifiedExecutionService provides a high-level interface for creating and managing AgentExecution__c records
 * in the unified agentic framework. This service demonstrates how to create and process executions for
 * different execution types (Conversational, Batch, Scheduled, Email, Trigger, API) using the new data model.
 *
 * This service serves as an example of how entry points should create and manage AgentExecution__c records,
 * enabling the framework's new universal capabilities.
 */
public inherited sharing class UnifiedExecutionService {
    public class UnifiedExecutionException extends AIAgentException {
    }

    /**
     * Creates a new AgentExecution__c record and initiates processing through the unified framework.
     * This method demonstrates the new execution pattern for non-conversational agent invocations.
     *
     * @param executionType The type of execution (Conversational, Batch, Scheduled, Email, Trigger, API)
     * @param agentDefinitionId The AI agent definition to execute
     * @param triggerSource The source that initiated this execution (e.g., 'Schedule', 'DataChange', 'API', 'Email')
     * @param triggerPayload JSON payload from the trigger source
     * @param sourceRecordId Optional record ID that is the primary context
     * @param userId The user context for this execution
     * @param initialMessage Optional initial message/content for the execution
     * @return Id of the created AgentExecution__c record
     */
    public Id createAndExecuteAgent(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        String initialMessage
    ) {
        String logPrefix = '[UnifiedExecutionService] ';

        try {
            // Create the AgentExecution__c record
            ExecutionContextService executionContextService = new ExecutionContextService();
            Id executionId = executionContextService.createExecution(
                executionType,
                agentDefinitionId,
                triggerSource,
                triggerPayload,
                sourceRecordId,
                userId,
                null // serviceUserId - could be set for elevated permissions
            );

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Created AgentExecution__c: ' + executionId + ' Type: ' + executionType + ' Source: ' + triggerSource
            );

            // Create initial execution step if message provided
            if (String.isNotBlank(initialMessage)) {
                ExecutionStepService executionStepService = new ExecutionStepService();
                String turnIdentifier = generateTurnIdentifier();

                // Update execution with turn identifier
                executionContextService.updateStatus(
                    executionId,
                    'Processing',
                    AIAgentConstants.STATUS_PROCESSING,
                    turnIdentifier,
                    'Processing initial input'
                );

                // Create initial step
                executionStepService.createStep(
                    executionId,
                    'TriggerInput',
                    'Trigger',
                    initialMessage,
                    'Text',
                    turnIdentifier,
                    1,
                    null, // toolCallId
                    null, // toolName
                    null, // toolArguments
                    null, // toolResult
                    JSON.serialize(new Map<String, Object>{ 'executionType' => executionType, 'triggerSource' => triggerSource }),
                    false // isInternal
                );

                // Process through LLM if this is an interactive execution type
                if (shouldProcessThroughLLM(executionType)) {
                    processExecutionThroughLLM(executionId, agentDefinitionId, userId, turnIdentifier, initialMessage);
                }
            }

            return executionId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create and execute agent: ' + e.getMessage());
            throw new UnifiedExecutionException('Failed to create and execute agent: ' + e.getMessage());
        }
    }

    /**
     * Processes an existing AgentExecution__c through the LLM interaction and orchestration pipeline.
     * This demonstrates how to use the unified services for non-conversational executions.
     *
     * @param executionId The AgentExecution__c ID to process
     * @param agentDefinitionId The agent definition ID
     * @param userId The user context
     * @param turnIdentifier The turn identifier
     * @param initialMessage The initial message/input to process
     */
    private void processExecutionThroughLLM(Id executionId, Id agentDefinitionId, Id userId, String turnIdentifier, String initialMessage) {
        String logPrefix = '[UnifiedExecutionService.processLLM] ';

        try {
            // Load agent configuration
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentConfig == null) {
                throw new UnifiedExecutionException('Agent definition not found: ' + agentDefinitionId);
            }

            // Initialize decision logger for the execution
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, userId);

            // Create user message data for LLM processing
            LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
            userMessageData.role = AIAgentConstants.ROLE_USER;
            userMessageData.content = initialMessage;

            // Create LLM interaction service with unified constructor
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                userId,
                agentDefinitionId,
                agentConfig.LLMConfiguration__c,
                turnIdentifier,
                1, // Turn count
                null, // currentPageRecordId
                false, // isFinalErrorTurn
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(userMessageData);

            if (llmResult == null) {
                throw new UnifiedExecutionException('LLM interaction returned null result');
            }

            // Process the LLM result through orchestration service
            OrchestrationService orchestrationService = new OrchestrationService();
            String outcome = orchestrationService.processLlmResult(
                llmResult,
                executionId,
                userId,
                UserInfo.getUserId(), // executionUserId
                agentDefinitionId,
                turnIdentifier,
                1, // currentTurnCount
                userMessageData,
                null, // currentPageRecordId
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to process execution through LLM: ' + e.getMessage());

            // Mark execution as failed
            try {
                ExecutionContextService executionContextService = new ExecutionContextService();
                executionContextService.updateStatus(
                    executionId,
                    'Failed',
                    AIAgentConstants.STATUS_FAILED,
                    turnIdentifier,
                    'LLM processing failed: ' + e.getMessage()
                );
            } catch (Exception updateEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + updateEx.getMessage());
            }

            throw new UnifiedExecutionException('LLM processing failed: ' + e.getMessage());
        }
    }

    /**
     * Determines if an execution type should be processed through the LLM pipeline.
     *
     * @param executionType The execution type to check
     * @return Boolean true if should process through LLM, false otherwise
     */
    private Boolean shouldProcessThroughLLM(String executionType) {
        // Define which execution types should go through LLM processing
        Set<String> llmEnabledTypes = new Set<String>{ 'Conversational', 'Email', 'API' };
        return llmEnabledTypes.contains(executionType);
    }

    /**
     * Generates a unique turn identifier for execution tracking.
     *
     * @return String unique turn identifier
     */
    private String generateTurnIdentifier() {
        return 'turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }

    /**
     * Example method showing how to create an API-triggered agent execution.
     * This would be called from REST endpoints or other API entry points.
     *
     * @param agentDeveloperName The developer name of the agent to execute
     * @param apiPayload The API request payload
     * @param contextRecordId Optional context record ID
     * @return Map<String, Object> containing execution results
     */
    public Map<String, Object> executeAgentViaAPI(String agentDeveloperName, Map<String, Object> apiPayload, Id contextRecordId) {
        String logPrefix = '[UnifiedExecutionService.executeViaAPI] ';

        try {
            // Load agent definition
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            if (agentConfig == null) {
                throw new UnifiedExecutionException('Agent not found: ' + agentDeveloperName);
            }

            // Extract message from API payload
            String message = (String) apiPayload.get('message');
            if (String.isBlank(message)) {
                throw new UnifiedExecutionException('API payload must contain a "message" field');
            }

            // Create and execute the agent
            Id executionId = createAndExecuteAgent(
                'API',
                agentConfig.Id,
                'REST_API',
                JSON.serialize(apiPayload),
                contextRecordId,
                UserInfo.getUserId(),
                message
            );

            // Return execution details
            return new Map<String, Object>{ 'success' => true, 'executionId' => executionId, 'message' => 'Agent execution initiated successfully' };
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'API execution failed: ' + e.getMessage());
            return new Map<String, Object>{ 'success' => false, 'error' => e.getMessage() };
        }
    }
}
