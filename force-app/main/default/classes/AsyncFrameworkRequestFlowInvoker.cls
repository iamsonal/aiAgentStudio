/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Flow-invocable processor for AsyncFrameworkRequest__e platform events. Routes events to appropriate handlers based on job type.
 */
public with sharing class AsyncFrameworkRequestFlowInvoker {
    @InvocableMethod(Label='Process Async Framework Request PE' Description='Called by Flow to process AsyncFrameworkRequest__e events')
    public static void processEvents(List<AsyncFrameworkRequest__e> platformEvents) {
        System.debug(
            LoggingLevel.INFO,
            '[AsyncFrameworkRequestFlowInvoker] Invoked by Flow to process ' + platformEvents.size() + ' AsyncFrameworkRequest__e event(s).'
        );

        for (AsyncFrameworkRequest__e event : platformEvents) {
            try {
                String jobType = event.JobType__c;
                String payloadJson = event.Payload__c;

                if (String.isBlank(jobType) || String.isBlank(payloadJson)) {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[AsyncFrameworkRequestFlowInvoker] Skipping event: missing JobType or Payload. Event: ' + JSON.serialize(event)
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
                        '[AsyncFrameworkRequestFlowInvoker] Unknown JobType received: ' +
                            jobType +
                            '. Valid types: ExecuteAction, FollowUpLLM, ProcessLLMMessage.'
                    );
                }
            } catch (Exception e) {
                // Isolate errors to prevent one bad event from stopping the entire batch
                System.debug(
                    LoggingLevel.ERROR,
                    '[AsyncFrameworkRequestFlowInvoker] Error processing AsyncFrameworkRequest__e event: ' +
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

        // OPTIMIZATION: Direct field mapping instead of double serialization
        // Eliminates unnecessary heap pressure from re-serializing capability object
        Map<String, Object> capabilityMap = (Map<String, Object>) params.get('capability');

        AgentCapability__c capability = new AgentCapability__c();
        capability.Id = (Id) capabilityMap.get('Id');
        capability.CapabilityName__c = (String) capabilityMap.get('CapabilityName__c');
        capability.Description__c = (String) capabilityMap.get('Description__c');
        capability.Parameters__c = (String) capabilityMap.get('Parameters__c');
        capability.ImplementationType__c = (String) capabilityMap.get('ImplementationType__c');
        capability.StandardActionType__c = (String) capabilityMap.get('StandardActionType__c');
        capability.BackendConfiguration__c = (String) capabilityMap.get('BackendConfiguration__c');
        capability.RunAsynchronously__c = (Boolean) capabilityMap.get('RunAsynchronously__c');
        capability.HITLMode__c = (String) capabilityMap.get('HITLMode__c');
        capability.HITLNotificationPreference__c = (String) capabilityMap.get('HITLNotificationPreference__c');
        capability.ExposureLevel__c = (String) capabilityMap.get('ExposureLevel__c');
        capability.AIAgentDefinition__c = (Id) capabilityMap.get('AIAgentDefinition__c');

        AsyncActionEngine engine = new AsyncActionEngine(
            (Id) params.get('executionId'),
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
            (Id) params.get('executionId'),
            (Id) params.get('userId'),
            (Id) params.get('agentDefId'),
            (String) params.get('turnId'),
            (Integer) params.get('nextTurnCount'),
            isFinalError,
            (Id) params.get('recordId')
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

        Id executionId = (Id) params.get('executionId');
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
                '[AsyncFrameworkRequestFlowInvoker] Starting initial LLM message processing via Platform Event. SessionId=' +
                executionId +
                ', TurnId=' +
                turnIdentifier
        );

        ConversationalTurnExecutionService.RunResult result = new ConversationalTurnExecutionService()
            .executeInitialTurn(
                executionId,
                originalUserId,
                UserInfo.getUserId(),
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                userMessage,
                currentRecordId,
                logPrefix
            );

        System.debug(LoggingLevel.INFO, logPrefix + '[AsyncFrameworkRequestFlowInvoker] Initial LLM message processing completed. Outcome: ' + result.outcome);
    }
}
