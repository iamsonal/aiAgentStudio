/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ConversationalOrchestrator handles conversational (chat-based) agent executions.
 * This orchestrator:
 *   - Creates or updates AgentExecution__c for conversational interactions
 *   - Chooses async strategy based on Concurrency__c field:
 *     * Low concurrency: Uses Queueable for sequential, single-user scenarios
 *     * High concurrency: Uses Platform Events for concurrent, multi-user chat
 *   - Processes async results by invoking LLM and orchestrating the response
 *
 * Service User Context:
 *   - Service user context switching is handled at the entry point level (ConversationalChatController)
 *   - When RequiresServiceUserContext__c is true, ConversationalChatController routes through REST/Named Credential
 *   - By the time this orchestrator executes, we're already in the correct user context
 *   - This orchestrator doesn't need to know about service user requirements
 *
 * Async Strategy:
 *   - Low Concurrency: Enqueues ConversationalQueueable directly for stateful processing
 *   - High Concurrency: Publishes ProcessLLMMessage platform event for better scalability
 */
public class ConversationalOrchestrator implements IAgentOrchestrator {
    private final AIAgentDefinition__c agentDef;
    private static final String LOG_PREFIX = '[ConversationalOrch] ';

    public ConversationalOrchestrator(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AgentOrchestratorException('Agent definition is required for ConversationalOrchestrator');
        }
        this.agentDef = agentDefinition;
    }

    /**
     * Initiates a conversational execution. Creates or updates the AgentExecution__c record,
     * then immediately hands off to async context based on concurrency setting.
     */
    public AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Initiating conversational execution');

        try {
            // Validate conversational-specific fields
            if (String.isBlank(payload.userMessage)) {
                throw new AgentOrchestratorException('User message is required for conversational execution');
            }
            if (String.isBlank(payload.turnIdentifier)) {
                throw new AgentOrchestratorException('Turn identifier is required for conversational execution');
            }

            Id executionId;

            // Determine if this is a new execution or continuing an existing one
            if (payload.existingExecutionId != null) {
                // Validate access and status
                validateExecutionAccess(payload.existingExecutionId, payload.userId);
                executionId = payload.existingExecutionId;

                // Update execution status to processing
                ExecutionContextService execContextSvc = new ExecutionContextService();
                execContextSvc.updateStatus(
                    executionId,
                    'Processing',
                    AIAgentConstants.STATUS_PROCESSING,
                    payload.turnIdentifier,
                    'Processing conversational turn'
                );
            } else {
                // Create new AgentExecution__c record
                ExecutionContextService executionContextService = new ExecutionContextService();
                String executionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');

                executionId = executionContextService.createExecution(
                    'Conversational',
                    agentDef.Id,
                    payload.triggerSource,
                    executionLabel,
                    payload.sourceRecordId,
                    payload.userId,
                    payload.serviceUserId
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Created/updated execution: ' + executionId);

            // Determine async strategy based ONLY on Concurrency__c
            String concurrency = agentDef.Concurrency__c != null ? agentDef.Concurrency__c : 'Low';

            if ('High'.equalsIgnoreCase(concurrency)) {
                // High concurrency: Use Platform Event for better scalability
                publishPlatformEvent(executionId, payload, logPrefix);
                return new AgentExecutionService.ExecutionResult(
                    executionId,
                    AIAgentConstants.STATUS_PROCESSING,
                    'Processing message asynchronously'
                );
            } else {
                // Low concurrency: Use Queueable for stateful, sequential processing
                enqueueQueueable(executionId, payload, logPrefix);
                return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing message');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating conversational execution: ' + e.getMessage());
            throw new AgentOrchestratorException('Failed to initiate conversational execution: ' + e.getMessage());
        }
    }

    /**
     * Processes async results for conversational executions.
     * This is called by ConversationalQueueable after it completes LLM processing.
     */
    public void processAsyncResult(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = LOG_PREFIX + '[Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing async result');

        // For conversational agents, async processing happens in ConversationalQueueable or via ProcessLLMMessage event
        // This method is primarily for future extensibility
        System.debug(LoggingLevel.INFO, logPrefix + 'Async result processed');
    }

    /**
     * Publishes a Platform Event for high-concurrency or service-user scenarios.
     */
    private void publishPlatformEvent(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        Map<String, Object> llmPayload = new Map<String, Object>{
            'sessionId' => executionId,
            'originalUserId' => payload.userId,
            'agentDefinitionId' => agentDef.Id,
            'llmConfigurationId' => agentDef.LLMConfiguration__c,
            'turnIdentifier' => payload.turnIdentifier,
            'userMessage' => payload.userMessage,
            'currentRecordId' => payload.currentRecordId,
            'logPrefix' => logPrefix
        };

        AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
            SessionId__c = executionId,
            TurnIdentifier__c = payload.turnIdentifier,
            JobType__c = 'ProcessLLMMessage',
            Payload__c = JSON.serialize(llmPayload)
        );

        Database.SaveResult sr = EventBus.publish(event);
        if (!sr.isSuccess()) {
            String errMsg = logPrefix + 'EventBus.publish failed for ProcessLLMMessage: ' + JSON.serialize(sr.getErrors());
            System.debug(LoggingLevel.ERROR, errMsg);
            throw new AgentOrchestratorException('Failed to publish ProcessLLMMessage event: ' + errMsg);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Published ProcessLLMMessage platform event for execution: ' + executionId);
    }

    /**
     * Enqueues a Queueable job for low-concurrency scenarios.
     */
    private void enqueueQueueable(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        ConversationalQueueable queueable = new ConversationalQueueable(
            executionId,
            payload.userId,
            payload.userId, // execution user is same as original user for low concurrency
            agentDef.Id,
            agentDef.LLMConfiguration__c,
            payload.turnIdentifier,
            payload.currentRecordId,
            payload.userMessage
        );

        Id jobId = System.enqueueJob(queueable);
        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued ConversationalQueueable job: ' + jobId + ' for execution: ' + executionId);
    }

    /**
     * Validates that the user has access to the specified execution.
     */
    private void validateExecutionAccess(Id executionId, Id userId) {
        List<AgentExecution__c> executions = [
            SELECT Id, ProcessingStatus__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :executionId AND User__c = :userId
            LIMIT 1
        ];

        if (executions.isEmpty()) {
            throw new AgentOrchestratorException('Execution not found or access denied: ' + executionId);
        }

        AgentExecution__c execution = executions[0];
        if (execution.ProcessingStatus__c != AIAgentConstants.STATUS_IDLE && execution.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
            throw new AgentOrchestratorException('Execution is currently busy (Status: ' + execution.ProcessingStatus__c + ')');
        }
    }
}
