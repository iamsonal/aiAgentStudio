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
 *   - Supports multiple job types including action execution, follow-up LLM processing, and graph step execution
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
                } else if ('GraphStep'.equalsIgnoreCase(jobType)) {
                    handleGraphStep(payloadJson);
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestTriggerHandler] Unknown JobType received: ' +
                            jobType +
                            '. Valid types: ExecuteAction, FollowUpLLM, GraphStep.'
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
        processor.process('PlatformEvent');
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
        processor.process('PlatformEvent');
    }

    /**
     * Handles the GraphStep job type by deserializing the payload and invoking GraphExecutionService.
     *
     * @param payloadJson JSON payload containing graph step execution parameters.
     */
    private static void handleGraphStep(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        Id sessionId = (Id) params.get('sessionId');
        Id graphCapabilityId = (Id) params.get('graphCapabilityId');

        // Re-query graph nodes in the new transaction context and execute next step
        GraphExecutionService graphService = new GraphExecutionService();
        Map<String, GraphNode__c> graphNodes = graphService.queryAndMapAllNodes(graphCapabilityId);

        graphService.executeNextStepChain(sessionId, graphNodes);
    }
}
