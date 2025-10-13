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
 *
 * In the unified agent architecture:
 *   - ProcessLLMMessage: Handles high-concurrency conversational agents (via ConversationalOrchestrator)
 *   - ExecuteAction: Handles tool/action execution (from ToolCallResponseHandler via AgentJobEnqueuer)
 *   - FollowUpLLM: Handles multi-turn LLM continuations (via AgentJobEnqueuer)
 *
 * Note: Most orchestrators (Email, Batch, Autonomous, low-concurrency Conversational) now use Queueables directly,
 * bypassing platform events for better statefulness and simpler flows.
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
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestTriggerHandler] Unknown JobType received: ' +
                            jobType +
                            '. Valid types: ExecuteAction, FollowUpLLM, ProcessLLMMessage.'
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
     * Handles the ExecuteAction job type by deserializing the payload and invoking AsyncActionEngine.
     *
     * @param payloadJson JSON payload containing action execution parameters.
     */
    private static void handleExecuteAction(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

        // Deserialize the AgentCapability__c object from the payload
        AgentCapability__c capability = (AgentCapability__c) JSON.deserialize(JSON.serialize(params.get('capability')), AgentCapability__c.class);

        AsyncActionEngine engine = new AsyncActionEngine(
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
        engine.process(null);
    }

    /**
     * Handles the FollowUpLLM job type by deserializing the payload and invoking FollowUpLLMEngine.
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

        FollowUpLLMEngine engine = new FollowUpLLMEngine(
            (Id) params.get('sessionId'),
            (Id) params.get('userId'),
            (Id) params.get('agentDefId'),
            (String) params.get('turnId'),
            (Integer) params.get('nextTurnCount'),
            isFinalError
        );
        engine.process(null);
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
     * Exception for unrecoverable errors during async framework processing.
     */
    public class AsyncFrameworkException extends Exception {
    }
}
