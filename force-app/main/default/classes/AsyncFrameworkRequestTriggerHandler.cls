/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AsyncFrameworkRequestTriggerHandler is the comprehensive platform event handler for AsyncFrameworkRequest__e events.
 * Responsibilities:
 *   - Provides intelligent routing and deserialization of event payloads to the appropriate processor classes
 *   - Supports multiple job types including initial LLM processing, action execution, and follow-up LLM processing
 *   - Ensures robust error handling and batch isolation for reliable event processing
 *   - Surfaces operational and routing issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended outside the framework.
 */
public class AsyncFrameworkRequestTriggerHandler {
    /**
     * Main event processing method that routes AsyncFrameworkRequest__e events to the appropriate handler based on job type.
     * Ensures batch isolation and robust error handling for each event.
     *
     * @param events List of AsyncFrameworkRequest__e platform events to process.
     */
    public static void handleEvents(List<AsyncFrameworkRequest__e> events) {
        System.debug(LoggingLevel.INFO, '[AsyncFrameworkRequestTriggerHandler] Processing ' + events.size() + ' AsyncFrameworkRequest__e event(s).');

        for (AsyncFrameworkRequest__e event : events) {
            try {
                String jobType = event.JobType__c;
                String payloadJson = event.Payload__c;

                if (String.isBlank(jobType) || String.isBlank(payloadJson)) {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestTriggerHandler] Skipping event: missing JobType or Payload. Event: ' + JSON.serialize(event)
                    );
                    continue;
                }

                if ('ExecuteAction'.equalsIgnoreCase(jobType)) {
                    handleExecuteAction(payloadJson);
                } else if ('FollowUpLLM'.equalsIgnoreCase(jobType)) {
                    handleFollowUpLLM(payloadJson);
                } else if ('ProcessLLMMessage'.equalsIgnoreCase(jobType)) {
                    handleProcessLLMMessage(payloadJson);
                } else if ('ProcessDataChange'.equalsIgnoreCase(jobType)) {
                    handleProcessDataChange(payloadJson);
                } else if ('ProcessBatchJob'.equalsIgnoreCase(jobType)) {
                    handleProcessBatchJob(payloadJson);
                } else if ('ProcessScheduledTask'.equalsIgnoreCase(jobType)) {
                    handleProcessScheduledTask(payloadJson);
                } else if ('ProcessEmailTrigger'.equalsIgnoreCase(jobType)) {
                    handleProcessEmailTrigger(payloadJson);
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestTriggerHandler] Unknown JobType received: ' +
                            jobType +
                            '. Valid types: ExecuteAction, FollowUpLLM, ProcessLLMMessage, ProcessDataChange, ProcessBatchJob, ProcessScheduledTask, ProcessEmailTrigger.'
                    );
                }
            } catch (Exception e) {
                // Isolate errors to prevent one bad event from stopping the entire batch
                System.debug(
                    LoggingLevel.ERROR,
                    '[AsyncFrameworkRequestTriggerHandler] Error processing AsyncFrameworkRequest__e event: ' +
                        e.getMessage() +
                        '\nStack Trace: ' +
                        e.getStackTraceString() +
                        '\nEvent: ' +
                        JSON.serialize(event)
                );
            }
        }
    }

    /**
     * Handles the ExecuteAction job type by deserializing the payload and invoking AsyncActionProcessor.
     *
     * @param payloadJson JSON payload containing action execution parameters.
     */
    private static void handleExecuteAction(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        // Deserialize the AgentCapability__c object from the payload
        AgentCapability__c capability = (AgentCapability__c) JSON.deserialize(JSON.serialize(params.get('capability')), AgentCapability__c.class);

        AsyncActionProcessor processor = new AsyncActionProcessor(
            (Id) params.get('sessionId'),
            (Id) params.get('originalUserId'),
            (Id) params.get('agentDefId'),
            (Id) params.get('parentAsstMsgId'),
            (String) params.get('toolCallId'),
            (String) params.get('llmArgsJson'),
            capability,
            (Id) params.get('relatedId'),
            (String) params.get('turnId'),
            (Integer) params.get('currentTurnCount')
        );
        processor.process(null);
    }

    /**
     * Handles the FollowUpLLM job type by deserializing the payload and invoking FollowUpLLMProcessor.
     *
     * @param payloadJson JSON payload containing follow-up LLM processing parameters.
     */
    private static void handleFollowUpLLM(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        // Extract final error flag with safe type checking
        Boolean isFinalError = false;
        if (params.containsKey('isFinalErrorTurn') && params.get('isFinalErrorTurn') instanceof Boolean) {
            isFinalError = (Boolean) params.get('isFinalErrorTurn');
        }

        FollowUpLLMProcessor processor = new FollowUpLLMProcessor(
            (Id) params.get('sessionId'),
            (Id) params.get('userId'),
            (Id) params.get('agentDefId'),
            (String) params.get('turnId'),
            (Integer) params.get('nextTurnCount'),
            isFinalError
        );
        processor.process(null);
    }

    /**
     * Handles the ProcessLLMMessage job type by deserializing the payload and executing initial LLM processing.
     *
     * @param payloadJson JSON payload containing initial LLM processing parameters.
     */
    private static void handleProcessLLMMessage(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        Id sessionId = (Id) params.get('sessionId');
        Id originalUserId = (Id) params.get('originalUserId');
        Id agentDefinitionId = (Id) params.get('agentDefinitionId');
        Id llmConfigurationId = (Id) params.get('llmConfigurationId');
        String turnIdentifier = (String) params.get('turnIdentifier');
        String userMessage = (String) params.get('userMessage');
        Id currentRecordId = (Id) params.get('currentRecordId');
        String logPrefix = (String) params.get('logPrefix');

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AsyncFrameworkRequestTriggerHandler] Starting initial LLM message processing via Platform Event. SessionId=' +
                sessionId +
                ', TurnId=' +
                turnIdentifier
        );

        try {
            // Prepare the user message data for LLM interaction
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            OrchestrationService orchestrationSvc = new OrchestrationService();

            // Initialize the decision step logger - single instance for the entire turn
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(sessionId, turnIdentifier, originalUserId);

            decisionLogger.logUserInput('User Input Received (via Platform Event)', userMessage, null);

            // Instantiate LLMInteractionService with the execution user context and decision logger
            LLMInteractionService interactionService = new LLMInteractionService(
                sessionId,
                originalUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1, // Turn count (always 1 for initial LLM processing)
                currentRecordId,
                false, // Not a retry
                decisionLogger
            );

            // Execute LLM interaction (HTTP callouts are permitted in Flow-triggered async context)
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new AsyncFrameworkException('LLMInteractionService returned a null result');
            }

            // Process the LLM result using the orchestration service with the decision logger
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                sessionId,
                originalUserId,
                UserInfo.getUserId(),
                agentDefinitionId,
                turnIdentifier,
                1, // Turn count
                currentUserMessageData,
                currentRecordId,
                decisionLogger
            );

            System.debug(
                LoggingLevel.INFO,
                logPrefix + '[AsyncFrameworkRequestTriggerHandler] Initial LLM message processing completed successfully. Outcome: ' + outcome
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    '[AsyncFrameworkRequestTriggerHandler] ERROR: Initial LLM processing failed. Exception: ' +
                    e.getMessage() +
                    '\nStack Trace: ' +
                    e.getStackTraceString()
            );

            // Attempt to mark the turn as failed to maintain session state consistency
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    sessionId,
                    turnIdentifier,
                    'Initial LLM processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix +
                        '[AsyncFrameworkRequestTriggerHandler] CRITICAL: Failed to update session state after processing failure: ' +
                        failEx.getMessage()
                );
            }
        }
    }

    /**
     * Handles data change triggered agent executions.
     * Creates AgentExecution__c with trigger context and processes the data change event.
     *
     * @param payloadJson JSON payload containing trigger data, record information, and execution context.
     */
    private static void handleProcessDataChange(String payloadJson) {
        String logPrefix = '[AsyncFrameworkRequestTriggerHandler.ProcessDataChange] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing data change trigger event');

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

            Id agentDefinitionId = (Id) payload.get('agentDefinitionId');
            Id triggerRecordId = (Id) payload.get('triggerRecordId');
            String changeType = (String) payload.get('changeType'); // INSERT, UPDATE, DELETE
            Map<String, Object> recordData = (Map<String, Object>) payload.get('recordData');
            Map<String, Object> oldValues = (Map<String, Object>) payload.get('oldValues');

            // Create AgentExecution__c for this data change trigger
            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = 'Trigger',
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = 'DataChange',
                TriggerPayload__c = payloadJson,
                ExecutionStatus__c = 'Processing',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                SourceRecordId__c = triggerRecordId,
                CurrentTurnIdentifier__c = generateTurnIdentifier(),
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                User__c = UserInfo.getUserId()
            );
            insert execution;

            // Create initial execution step for the trigger event
            ExecutionStep__c triggerStep = new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'TriggerInput',
                StepRole__c = 'Trigger',
                Content__c = 'Data change trigger: ' + changeType + ' on record ' + triggerRecordId,
                ContentType__c = 'JSON',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                TurnCount__c = 1,
                StepMetadata__c = JSON.serialize(
                    new Map<String, Object>{ 'changeType' => changeType, 'recordId' => triggerRecordId, 'hasOldValues' => oldValues != null }
                )
            );
            insert triggerStep;

            System.debug(LoggingLevel.INFO, logPrefix + 'Created AgentExecution__c: ' + execution.Id + ' for data change trigger');

            // TODO: Process the data change through the unified execution engine
            // This would involve creating an ExecutionContext and routing to appropriate processors
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing data change trigger: ' + e.getMessage());
        }
    }

    /**
     * Handles batch job agent executions.
     * Processes multiple items through batch execution patterns.
     *
     * @param payloadJson JSON payload containing batch job configuration and items to process.
     */
    private static void handleProcessBatchJob(String payloadJson) {
        String logPrefix = '[AsyncFrameworkRequestTriggerHandler.ProcessBatchJob] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing batch job execution');

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

            Id agentDefinitionId = (Id) payload.get('agentDefinitionId');
            List<Object> batchItems = (List<Object>) payload.get('batchItems');
            Integer batchSize = (Integer) payload.get('batchSize');
            String batchJobName = (String) payload.get('batchJobName');

            // Create parent AgentExecution__c for the batch job
            AgentExecution__c batchExecution = new AgentExecution__c(
                ExecutionType__c = 'Batch',
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = 'BatchJob',
                TriggerPayload__c = payloadJson,
                ExecutionStatus__c = 'Processing',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                CurrentTurnIdentifier__c = generateTurnIdentifier(),
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                User__c = UserInfo.getUserId(),
                ExecutionMetadata__c = JSON.serialize(
                    new Map<String, Object>{ 'batchJobName' => batchJobName, 'totalItems' => batchItems.size(), 'batchSize' => batchSize }
                )
            );
            insert batchExecution;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Created batch AgentExecution__c: ' + batchExecution.Id + ' with ' + batchItems.size() + ' items'
            );

            // TODO: Process batch items through the unified execution engine
            // This would involve creating child executions for each batch chunk
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing batch job: ' + e.getMessage());
        }
    }

    /**
     * Handles scheduled task agent executions.
     * Processes scheduled/cron-based agent invocations.
     *
     * @param payloadJson JSON payload containing scheduled task configuration and context.
     */
    private static void handleProcessScheduledTask(String payloadJson) {
        String logPrefix = '[AsyncFrameworkRequestTriggerHandler.ProcessScheduledTask] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing scheduled task execution');

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

            Id agentDefinitionId = (Id) payload.get('agentDefinitionId');
            Id executionTriggerId = (Id) payload.get('executionTriggerId');
            String scheduleName = (String) payload.get('scheduleName');
            Datetime scheduledTime = (Datetime) payload.get('scheduledTime');

            // Create AgentExecution__c for the scheduled task
            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = 'Scheduled',
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = 'Schedule',
                TriggerPayload__c = payloadJson,
                ExecutionStatus__c = 'Processing',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                CurrentTurnIdentifier__c = generateTurnIdentifier(),
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                User__c = UserInfo.getUserId(),
                ExecutionMetadata__c = JSON.serialize(
                    new Map<String, Object>{
                        'scheduleName' => scheduleName,
                        'scheduledTime' => scheduledTime,
                        'executionTriggerId' => executionTriggerId
                    }
                )
            );
            insert execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Created scheduled AgentExecution__c: ' + execution.Id + ' for schedule: ' + scheduleName);

            // TODO: Process the scheduled task through the unified execution engine
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing scheduled task: ' + e.getMessage());
        }
    }

    /**
     * Handles email-triggered agent executions.
     * Processes inbound emails and creates appropriate agent executions.
     *
     * @param payloadJson JSON payload containing email content, headers, and routing information.
     */
    private static void handleProcessEmailTrigger(String payloadJson) {
        String logPrefix = '[AsyncFrameworkRequestTriggerHandler.ProcessEmailTrigger] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing email trigger execution');

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

            Id agentDefinitionId = (Id) payload.get('agentDefinitionId');
            String emailSubject = (String) payload.get('emailSubject');
            String emailBody = (String) payload.get('emailBody');
            String fromAddress = (String) payload.get('fromAddress');
            String toAddress = (String) payload.get('toAddress');
            List<Object> attachments = (List<Object>) payload.get('attachments');

            // Create AgentExecution__c for the email trigger
            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = 'Email',
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = 'Email',
                TriggerPayload__c = payloadJson,
                ExecutionStatus__c = 'Processing',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                CurrentTurnIdentifier__c = generateTurnIdentifier(),
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                User__c = UserInfo.getUserId(),
                ExecutionMetadata__c = JSON.serialize(
                    new Map<String, Object>{
                        'emailSubject' => emailSubject,
                        'fromAddress' => fromAddress,
                        'toAddress' => toAddress,
                        'hasAttachments' => attachments != null && !attachments.isEmpty()
                    }
                )
            );
            insert execution;

            // Create initial execution step for the email content
            ExecutionStep__c emailStep = new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'TriggerInput',
                StepRole__c = 'Trigger',
                Content__c = 'Email from ' + fromAddress + ': ' + emailSubject + '\n\n' + emailBody,
                ContentType__c = 'Email',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                TurnCount__c = 1,
                StepMetadata__c = JSON.serialize(
                    new Map<String, Object>{ 'emailSubject' => emailSubject, 'fromAddress' => fromAddress, 'toAddress' => toAddress }
                )
            );
            insert emailStep;

            System.debug(LoggingLevel.INFO, logPrefix + 'Created email AgentExecution__c: ' + execution.Id + ' from: ' + fromAddress);

            // TODO: Process the email through the unified execution engine
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing email trigger: ' + e.getMessage());
        }
    }

    /**
     * Generates a unique turn identifier for execution tracking.
     *
     * @return String unique turn identifier
     */
    private static String generateTurnIdentifier() {
        return 'turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }

    /**
     * Exception for unrecoverable errors during async framework processing.
     */
    public class AsyncFrameworkException extends Exception {
    }
}
