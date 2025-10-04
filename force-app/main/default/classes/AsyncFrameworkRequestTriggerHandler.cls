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
                } else if ('InitiateExecution'.equalsIgnoreCase(jobType)) {
                    handleInitiateExecution(payloadJson);
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestTriggerHandler] Unknown JobType received: ' +
                            jobType +
                            '. Valid types: ExecuteAction, FollowUpLLM, ProcessLLMMessage, InitiateExecution.'
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
     * Handles execution initiation for all non-conversational trigger sources.
     * This unified method replaces the individual handlers for Email, Scheduled, DataChange, Batch, and API triggers.
     * Uses deferred processing pattern to avoid transaction conflicts between DML and HTTP callouts.
     *
     * @param payloadJson JSON payload containing execution ID, trigger source, and trigger-specific data.
     */
    private static void handleInitiateExecution(String payloadJson) {
        String logPrefix = '[AsyncFrameworkRequestTriggerHandler.InitiateExecution] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing execution initiation');

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

            Id executionId = (Id) payload.get('executionId');
            String triggerSource = (String) payload.get('triggerSource');

            if (executionId == null || String.isBlank(triggerSource)) {
                throw new AsyncFrameworkException('ExecutionId and triggerSource are required for InitiateExecution');
            }

            // Remove execution metadata from payload to pass clean trigger data
            Map<String, Object> triggerData = new Map<String, Object>(payload);
            triggerData.remove('executionId');
            triggerData.remove('triggerSource');

            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueueing deferred processing for ' + triggerSource + ' execution: ' + executionId);

            // Use deferred processing to avoid transaction conflicts
            // Platform events may be processed in the same transaction as DML operations,
            // so we enqueue a queueable job to handle HTTP callouts in a separate transaction
            DeferredExecutionProcessor processor = new DeferredExecutionProcessor(executionId, triggerSource, triggerData);
            System.enqueueJob(processor);

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully enqueued ' + triggerSource + ' execution: ' + executionId);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Error processing execution initiation: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString()
            );
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
