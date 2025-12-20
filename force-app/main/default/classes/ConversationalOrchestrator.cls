/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Orchestrator for conversational (chat-based) agent executions.
 * Handles AgentExecution__c creation and async dispatch strategy selection.
 */
public class ConversationalOrchestrator implements IAgentOrchestrator {
    private AIAgentDefinition__c agentDef;
    private static final String LOG_PREFIX = '[ConversationalOrch] ';

    /**
     * No-argument constructor for dynamic instantiation.
     */
    public ConversationalOrchestrator() {
        // No-op constructor for reflection-based instantiation
    }

    /**
     * Parameterized constructor for direct instantiation.
     *
     * @param agentDefinition Agent definition
     */
    public ConversationalOrchestrator(AIAgentDefinition__c agentDefinition) {
        initialize(agentDefinition);
    }

    /**
     * Initializes orchestrator with agent definition.
     *
     * @param agentDefinition Agent definition configuration
     */
    public void initialize(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AgentOrchestratorException('Agent definition is required for ConversationalOrchestrator');
        }
        this.agentDef = agentDefinition;
    }

    /**
     * Initiates a conversational execution. Creates or updates the AgentExecution__c record,
     * then immediately hands off to async context based on async dispatch type setting.
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

                // Check if synchronous execution is enabled for conversational turns (initial LLM call only)
                AIAgentSettings__c agentSettings = AIAgentSettings__c.getInstance(agentDef.DeveloperName__c);
                if (agentSettings != null && agentSettings.ExecuteInitialLLMCallSynchronously__c == true) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Executing initial LLM call synchronously');
                    return executeSynchronously(executionId, payload, logPrefix);
                }

                // Update execution status to processing for async path
                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.updateStatus(
                    executionId,
                    'Processing',
                    AIAgentConstants.STATUS_PROCESSING,
                    payload.turnIdentifier,
                    'Processing conversational turn'
                );
            } else {
                // Create new AgentExecution__c record
                AgentStateService agentStateService = new AgentStateService();
                String executionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');

                executionId = agentStateService.createExecution(
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

            // Determine async strategy based ONLY on AsyncDispatchType__c
            String asyncDispatchType = agentDef.AsyncDispatchType__c != null ? agentDef.AsyncDispatchType__c : 'Low';

            if ('High'.equalsIgnoreCase(asyncDispatchType)) {
                // High dispatch type: Use Platform Event for high-throughput, fire-and-forget processing
                publishPlatformEvent(executionId, payload, logPrefix);
                return new AgentExecutionService.ExecutionResult(
                    executionId,
                    AIAgentConstants.STATUS_PROCESSING,
                    'Processing message asynchronously'
                );
            } else {
                // Low dispatch type: Use Queueable for guaranteed sequential processing
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
     * Publishes a Platform Event for high dispatch type scenarios.
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
            AgentExecutionId__c = executionId,
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
     * Enqueues a Queueable job for low dispatch type scenarios.
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
     * Executes a conversational turn synchronously without queueable overhead.
     * This method performs the LLM callout directly and processes the result in the same transaction.
     * No DML is performed before the callout to avoid CalloutException.
     *
     * @param executionId The existing AgentExecution__c ID
     * @param payload The execution payload containing user message and context
     * @param logPrefix Logging prefix for debug output
     * @return ExecutionResult with the outcome of the synchronous execution
     */
    private AgentExecutionService.ExecutionResult executeSynchronously(
        Id executionId,
        AgentExecutionService.ExecutionPayload payload,
        String logPrefix
    ) {
        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, payload.turnIdentifier, payload.userId);

            // Log user input
            decisionLogger.logUserInput('User Input Received', payload.userMessage, null);

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = payload.userMessage;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                payload.userId,
                agentDef.Id,
                agentDef.LLMConfiguration__c,
                payload.turnIdentifier,
                1, // Turn count for conversational turns
                payload.currentRecordId,
                false, // Not a final error turn
                decisionLogger
            );

            // Execute LLM interaction (callout happens here, before any DML)
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new AgentOrchestratorException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service (DML happens here, after callout)
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                payload.userId,
                payload.userId, // execution user is same as original user for synchronous execution
                agentDef.Id,
                payload.turnIdentifier,
                1,
                currentUserMessageData,
                payload.currentRecordId,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Synchronous execution completed. Outcome: ' + outcome);

            // Determine status based on outcome
            String status = AIAgentConstants.STATUS_IDLE;
            String message = 'Turn completed';

            if (outcome == OrchestrationService.OUTCOME_FAILED) {
                status = AIAgentConstants.STATUS_FAILED;
                message = 'Turn failed';
            } else if (outcome == OrchestrationService.OUTCOME_QUEUED_ACTION || outcome == OrchestrationService.OUTCOME_QUEUED_FOLLOWUP) {
                status = AIAgentConstants.STATUS_PROCESSING;
                message = 'Processing tool actions';
            } else if (outcome == OrchestrationService.OUTCOME_AWAITING_CONFIRMATION) {
                status = AIAgentConstants.STATUS_IDLE;
                message = 'Awaiting user confirmation';
            }

            return new AgentExecutionService.ExecutionResult(executionId, status, message);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Synchronous execution failed: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());

            // Mark turn as failed
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(
                    executionId,
                    payload.turnIdentifier,
                    'Synchronous execution failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution state after error: ' + failEx.getMessage());
            }

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_FAILED, 'Execution failed: ' + e.getMessage());
        }
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
