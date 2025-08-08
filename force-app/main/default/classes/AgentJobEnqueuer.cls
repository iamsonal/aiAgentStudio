/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for enqueueing asynchronous framework jobs
 *              (FollowUpLLM, ExecuteSingleAction). Now supports both Queueable and
 *              Platform Event dispatching based on framework settings.
 */
public inherited sharing class AgentJobEnqueuer {
    public class DispatchException extends AIAgentException {
    }

    private final TurnLifecycleService turnLifecycleSvc;

    /**
     * @description Default constructor for ease of use. Instantiates its own dependency.
     */
    public AgentJobEnqueuer() {
        this(new TurnLifecycleService());
    }

    /**
     * @description Main constructor for dependency injection, used for testing.
     * @param turnLifecycleService The lifecycle service for failure handling.
     */
    public AgentJobEnqueuer(TurnLifecycleService turnLifecycleService) {
        if (turnLifecycleService == null) {
            throw new IllegalArgumentException('TurnLifecycleService cannot be null.');
        }
        this.turnLifecycleSvc = turnLifecycleService;
    }

    /**
     * @description Enqueues the FollowUpLLMQueueableWrapper job.
     * @param sessionId The ID of the chat session.
     * @param userId The ID of the user.
     * @param agentDefId The ID of the agent definition.
     * @param turnId The unique identifier for the current turn.
     * @param nextTurnCount The cycle number for the next turn.
     * @param logPrefix A logging prefix.
     */
    public void enqueueFollowUp(
        Id sessionId,
        Id userId,
        Id agentDefId,
        String turnId,
        Integer nextTurnCount,
        String logPrefix,
        Boolean isFinalErrorTurn
    ) {
        try {
            Boolean finalErrorFlag = (isFinalErrorTurn == true);

            Map<String, Object> payload = new Map<String, Object>{
                'sessionId' => sessionId,
                'userId' => userId,
                'agentDefId' => agentDefId,
                'turnId' => turnId,
                'nextTurnCount' => nextTurnCount,
                'isFinalErrorTurn' => finalErrorFlag
            };
            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = sessionId,
                TurnIdentifier__c = turnId,
                JobType__c = 'FollowUpLLM',
                Payload__c = JSON.serialize(payload)
            );
            EventBus.publish(event);
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, turnId, 'FollowUpLLM event', e, logPrefix);
        }
    }

    /**
     * @description Enqueues the AsyncActionQueueableWrapper job.
     *              Now accepts the entire AgentCapability__c object for a cleaner interface.
     * @param sessionId The ID of the chat session.
     * @param originalUserId The ID of the user.
     * @param agentDefId The ID of the agent definition.
     * @param parentAsstMsgId The ID of the assistant message that requested this action.
     * @param toolCallId The unique ID for this specific tool call from the LLM.
     * @param llmArgsJson The JSON string of arguments from the LLM for the action.
     * @param capability The self-contained AgentCapability__c object defining the action to be run.
     * @param relatedId The turn-specific related record ID.
     * @param turnId The unique identifier for the current turn.
     * @param currentTurnCount The cycle number of the current turn.
     * @param logPrefix A logging prefix.
     */
    public void enqueueAsyncAction(
        Id sessionId,
        Id originalUserId,
        Id agentDefId,
        Id parentAsstMsgId,
        String toolCallId,
        String llmArgsJson,
        AgentCapability__c capability,
        Id relatedId,
        String turnId,
        Integer currentTurnCount,
        String logPrefix
    ) {
        String jobDetails = 'ExecuteSingleAction event for Capability: ' + capability.CapabilityName__c;
        try {
            Map<String, Object> payload = new Map<String, Object>{
                'sessionId' => sessionId,
                'originalUserId' => originalUserId,
                'agentDefId' => agentDefId,
                'parentAsstMsgId' => parentAsstMsgId,
                'toolCallId' => toolCallId,
                'llmArgsJson' => llmArgsJson,
                'capability' => capability,
                'relatedId' => relatedId,
                'turnId' => turnId,
                'currentTurnCount' => currentTurnCount
            };
            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = sessionId,
                TurnIdentifier__c = turnId,
                JobType__c = 'ExecuteAction',
                Payload__c = JSON.serialize(payload)
            );
            EventBus.publish(event);
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, turnId, jobDetails, e, logPrefix);
        }
    }

    private void handleDispatchFailure(Id sessionId, String turnId, String jobDescription, Exception enqueueException, String logPrefix) {
        String errorMsg = 'Failed to dispatch ' + jobDescription;
        String errorDetailForState = errorMsg + ': ' + enqueueException.getMessage();

        try {
            this.turnLifecycleSvc.failTurn(sessionId, turnId, errorDetailForState, AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, logPrefix);
        } catch (Exception finalStateEx) {
        }

        throw new DispatchException('Failed to dispatch ' + jobDescription, enqueueException);
    }

    public void enqueueGraphStep(Id sessionId, Id graphCapabilityId) {
        String logPrefix = '[AgentJobEnqueuer Sess:' + sessionId + '] ';
        String jobDescription = 'GraphStep job/event';

        try {
            Map<String, Object> payload = new Map<String, Object>{ 'sessionId' => sessionId, 'graphCapabilityId' => graphCapabilityId };
            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = sessionId,
                TurnIdentifier__c = null,
                JobType__c = 'GraphStep',
                Payload__c = JSON.serialize(payload)
            );
            EventBus.publish(event);
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, null, jobDescription, e, logPrefix);
        }
    }
}
