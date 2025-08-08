/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Handler for the AsyncFrameworkRequestTrigger. Deserializes event payloads
 *              and routes them to the correct processor logic class.
 */
public class AsyncFrameworkRequestTriggerHandler {
    public static void handleEvents(List<AsyncFrameworkRequest__e> events) {
        for (AsyncFrameworkRequest__e event : events) {
            try {
                String jobType = event.JobType__c;
                String payloadJson = event.Payload__c;

                if (String.isBlank(jobType) || String.isBlank(payloadJson)) {
                    continue;
                }

                if ('ExecuteAction'.equalsIgnoreCase(jobType)) {
                    handleExecuteAction(payloadJson);
                } else if ('FollowUpLLM'.equalsIgnoreCase(jobType)) {
                    handleFollowUpLLM(payloadJson);
                } else if ('GraphStep'.equalsIgnoreCase(jobType)) {
                    handleGraphStep(payloadJson);
                } else {
                }
            } catch (Exception e) {
            }
        }
    }

    private static void handleExecuteAction(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

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

    private static void handleFollowUpLLM(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);

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

    private static void handleGraphStep(String payloadJson) {
        Map<String, Object> params = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
        Id sessionId = (Id) params.get('sessionId');
        Id graphCapabilityId = (Id) params.get('graphCapabilityId');

        GraphExecutionService graphService = new GraphExecutionService();
        Map<String, GraphNode__c> graphNodes = graphService.queryAndMapAllNodes(graphCapabilityId);

        graphService.executeNextStepChain(sessionId, graphNodes);
    }
}
