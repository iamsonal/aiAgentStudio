/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AgentJobEnqueuer is the central service for dispatching asynchronous jobs within the AI Agent Framework.
 * It is responsible for reliably publishing platform events that trigger follow-up LLM interactions,
 * action executions, and graph processing steps. The class ensures:
 *   - Consistent, testable job dispatch logic for all asynchronous agent operations
 *   - Comprehensive error handling and session state management on dispatch failures
 *   - Clear, actionable debug output for troubleshooting and operational transparency
 *
 * This class is designed for extensibility and maintainability, serving as the single point of orchestration
 * for all asynchronous agent job requests.
 */
public inherited sharing class AgentJobEnqueuer {
    public class DispatchException extends AIAgentException {
    }

    private final TurnLifecycleService turnLifecycleSvc;

    /**
     * Default constructor. Instantiates its own TurnLifecycleService dependency.
     * Use this in production code where dependency injection is not required.
     */
    public AgentJobEnqueuer() {
        this(new TurnLifecycleService());
    }

    /**
     * Main constructor for dependency injection (primarily for testing).
     *
     * @param turnLifecycleService The TurnLifecycleService instance to use for session state management.
     * @throws IllegalArgumentException if turnLifecycleService is null.
     */
    public AgentJobEnqueuer(TurnLifecycleService turnLifecycleService) {
        if (turnLifecycleService == null) {
            throw new IllegalArgumentException('TurnLifecycleService cannot be null.');
        }
        this.turnLifecycleSvc = turnLifecycleService;
    }

    /**
     * Publishes a platform event to enqueue a follow-up LLM operation for a given session turn.
     *
     * @param sessionId        The ID of the chat session.
     * @param userId           The ID of the user.
     * @param agentDefId       The ID of the agent definition.
     * @param turnId           The unique identifier for the current turn.
     * @param nextTurnCount    The cycle number for the next turn.
     * @param logPrefix        A logging prefix for debug output.
     * @param isFinalErrorTurn Whether this is the final error turn for the session.
     * @throws DispatchException if event publication fails.
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
            Database.SaveResult sr = EventBus.publish(event);
            if (!sr.isSuccess()) {
                String errMsg = logPrefix + '[AgentJobEnqueuer] EventBus.publish failed for FollowUpLLM: ' + JSON.serialize(sr.getErrors());
                System.debug(LoggingLevel.ERROR, errMsg);
                throw new AgentJobEnqueuerException('Failed to publish FollowUpLLM event: ' + errMsg);
            }
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    '[AgentJobEnqueuer] Successfully published FollowUpLLM event for turnId=' +
                    turnId +
                    ', sessionId=' +
                    sessionId +
                    ', nextTurnCount=' +
                    nextTurnCount +
                    ', isFinalErrorTurn=' +
                    finalErrorFlag
            );
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, turnId, 'FollowUpLLM event', e, logPrefix);
        }
    }

    /**
     * Publishes a platform event to enqueue an asynchronous action execution for a given capability.
     *
     * @param sessionId         The ID of the chat session.
     * @param originalUserId    The ID of the user.
     * @param agentDefId        The ID of the agent definition.
     * @param parentAsstMsgId   The ID of the assistant message that requested this action.
     * @param toolCallId        The unique ID for this specific tool call from the LLM.
     * @param llmArgsJson       The JSON string of arguments from the LLM for the action.
     * @param capability        The AgentCapability__c object defining the action to be run.
     * @param relatedId         The turn-specific related record ID.
     * @param turnId            The unique identifier for the current turn.
     * @param currentTurnCount  The cycle number of the current turn.
     * @param logPrefix         A logging prefix for debug output.
     * @throws DispatchException if event publication fails.
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
            Database.SaveResult sr = EventBus.publish(event);
            if (!sr.isSuccess()) {
                String errMsg = logPrefix + '[AgentJobEnqueuer] EventBus.publish failed for ExecuteAction: ' + JSON.serialize(sr.getErrors());
                System.debug(LoggingLevel.ERROR, errMsg);
                throw new AgentJobEnqueuerException('Failed to publish ExecuteAction event: ' + errMsg);
            }
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    '[AgentJobEnqueuer] Successfully published ExecuteAction event for capability="' +
                    capability.CapabilityName__c +
                    '", turnId=' +
                    turnId +
                    ', sessionId=' +
                    sessionId +
                    ', currentTurnCount=' +
                    currentTurnCount
            );
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, turnId, jobDetails, e, logPrefix);
        }
    }

    /**
     * Handles failures during event dispatch by updating session state and re-throwing a DispatchException.
     * Ensures error tracking and prevents orphaned processing states.
     *
     * @param sessionId       The ID of the chat session.
     * @param turnId          The unique identifier for the current turn (may be null for some jobs).
     * @param jobDescription  A human-readable description of the job/event being dispatched.
     * @param enqueueException The exception thrown during event publication.
     * @param logPrefix       A logging prefix for debug output.
     * @throws DispatchException Always thrown to notify the orchestrator of the failure.
     */
    private void handleDispatchFailure(Id sessionId, String turnId, String jobDescription, Exception enqueueException, String logPrefix) {
        String errorMsg = 'Failed to dispatch ' + jobDescription;
        String errorDetailForState = errorMsg + ': ' + enqueueException.getMessage();
        System.debug(LoggingLevel.ERROR, logPrefix + '[AgentJobEnqueuer] ' + errorDetailForState);

        // Attempt to mark the turn as failed to prevent orphaned processing states
        try {
            this.turnLifecycleSvc.failTurn(sessionId, turnId, errorDetailForState, AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, logPrefix);
        } catch (Exception finalStateEx) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    '[AgentJobEnqueuer] CRITICAL: Failed to update session status after dispatch failure for "' +
                    jobDescription +
                    '". Session may be left in an inconsistent state. Error: ' +
                    finalStateEx.getMessage()
            );
        }
        // Always re-throw to notify the calling orchestrator of the dispatch failure
        throw new DispatchException('Failed to dispatch ' + jobDescription, enqueueException);
    }

    /**
     * Publishes a platform event to enqueue a graph processing step for a given capability.
     *
     * @param sessionId        The ID of the chat session.
     * @param graphCapabilityId The ID of the capability representing the graph step.
     * @throws DispatchException if event publication fails.
     */
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
            Database.SaveResult sr = EventBus.publish(event);
            if (!sr.isSuccess()) {
                String errMsg = logPrefix + '[AgentJobEnqueuer] EventBus.publish failed for GraphStep: ' + JSON.serialize(sr.getErrors());
                System.debug(LoggingLevel.ERROR, errMsg);
                throw new AgentJobEnqueuerException('Failed to publish GraphStep event: ' + errMsg);
            }
            System.debug(
                LoggingLevel.INFO,
                logPrefix + '[AgentJobEnqueuer] Published GraphStep event for capabilityId=' + graphCapabilityId + ', sessionId=' + sessionId
            );
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, null, jobDescription, e, logPrefix);
        }
    }

    public class AgentJobEnqueuerException extends Exception {
    }
}
