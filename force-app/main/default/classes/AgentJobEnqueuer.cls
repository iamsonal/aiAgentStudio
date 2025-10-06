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
 * It is responsible for dynamically routing asynchronous operations based on agent concurrency settings:
 *   - For agents with Concurrency__c = 'High', uses Platform Events (AsyncFrameworkRequest__e) for maximum throughput
 *   - For agents with Concurrency__c = 'Low' or null, uses Queueable jobs for sequential processing
 *
 * The class ensures:
 *   - Consistent, testable job dispatch logic for all asynchronous agent operations
 *   - Comprehensive error handling and session state management on dispatch failures
 *   - Clear, actionable debug output for troubleshooting and operational transparency
 *   - Dynamic async mechanism selection without code duplication
 *
 * This class is designed for extensibility and maintainability, serving as the single point of orchestration
 * for all asynchronous agent job requests.
 */
public inherited sharing class AgentJobEnqueuer {
    public class DispatchException extends AIAgentException {
    }

    private final TurnLifecycleService turnLifecycleSvc;

    // Cache for agent concurrency settings to minimize SOQL queries
    private static Map<Id, String> agentConcurrencyCache = new Map<Id, String>();

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
     * Retrieves the Concurrency__c setting for a given agent definition.
     * Uses a static cache to minimize SOQL queries within the same transaction.
     *
     * @param agentDefId The ID of the agent definition.
     * @return The Concurrency__c value ('High', 'Low', or null). Defaults to 'Low' if null or not found.
     */
    private String getAgentConcurrency(Id agentDefId) {
        if (agentDefId == null) {
            return 'Low'; // Default to Low if no agent definition is provided
        }

        // Check cache first
        if (agentConcurrencyCache.containsKey(agentDefId)) {
            return agentConcurrencyCache.get(agentDefId);
        }

        // Query the agent definition
        try {
            List<AIAgentDefinition__c> agents = [
                SELECT Concurrency__c
                FROM AIAgentDefinition__c
                WHERE Id = :agentDefId
                LIMIT 1
            ];

            String concurrency = 'Low'; // Default to Low
            if (!agents.isEmpty() && agents[0].Concurrency__c != null) {
                concurrency = agents[0].Concurrency__c;
            }

            // Cache the result
            agentConcurrencyCache.put(agentDefId, concurrency);
            return concurrency;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[AgentJobEnqueuer] Failed to query agent concurrency setting: ' + e.getMessage() + '. Defaulting to Low.');
            return 'Low';
        }
    }

    /**
     * Enqueues a follow-up LLM operation for a given agent execution turn.
     * Dynamically routes to either Platform Events (for High concurrency) or Queueable jobs (for Low concurrency)
     * based on the agent's Concurrency__c setting.
     *
     * @param executionId      The ID of the agent execution (AgentExecution__c).
     * @param userId           The ID of the user.
     * @param agentDefId       The ID of the agent definition.
     * @param turnId           The unique identifier for the current turn.
     * @param nextTurnCount    The cycle number for the next turn.
     * @param logPrefix        A logging prefix for debug output.
     * @param isFinalErrorTurn Whether this is the final error turn for the session.
     * @throws DispatchException if event publication fails.
     */
    public void enqueueFollowUp(
        Id executionId,
        Id userId,
        Id agentDefId,
        String turnId,
        Integer nextTurnCount,
        String logPrefix,
        Boolean isFinalErrorTurn
    ) {
        try {
            Boolean finalErrorFlag = (isFinalErrorTurn == true);
            String concurrency = this.getAgentConcurrency(agentDefId);

            if ('High'.equalsIgnoreCase(concurrency)) {
                // High concurrency: Use Platform Event for maximum throughput
                this.enqueueFollowUpViaPlatformEvent(
                    executionId,
                    userId,
                    agentDefId,
                    turnId,
                    nextTurnCount,
                    finalErrorFlag,
                    logPrefix
                );
            } else {
                // Low concurrency (or null): Use Queueable for sequential processing
                this.enqueueFollowUpViaQueueable(
                    executionId,
                    userId,
                    agentDefId,
                    turnId,
                    nextTurnCount,
                    finalErrorFlag,
                    logPrefix
                );
            }
        } catch (Exception e) {
            this.handleDispatchFailure(executionId, turnId, 'FollowUpLLM', e, logPrefix);
        }
    }

    /**
     * Enqueues a follow-up LLM operation via Platform Event (for High concurrency agents).
     */
    private void enqueueFollowUpViaPlatformEvent(
        Id executionId,
        Id userId,
        Id agentDefId,
        String turnId,
        Integer nextTurnCount,
        Boolean finalErrorFlag,
        String logPrefix
    ) {
        Map<String, Object> payload = new Map<String, Object>{
            'sessionId' => executionId,
            'userId' => userId,
            'agentDefId' => agentDefId,
            'turnId' => turnId,
            'nextTurnCount' => nextTurnCount,
            'isFinalErrorTurn' => finalErrorFlag
        };
        AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
            SessionId__c = executionId,
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
                '[AgentJobEnqueuer] Successfully published FollowUpLLM Platform Event for turnId=' +
                turnId +
                ', executionId=' +
                executionId +
                ', nextTurnCount=' +
                nextTurnCount +
                ', isFinalErrorTurn=' +
                finalErrorFlag
        );
    }

    /**
     * Enqueues a follow-up LLM operation via Queueable (for Low concurrency agents).
     */
    private void enqueueFollowUpViaQueueable(
        Id executionId,
        Id userId,
        Id agentDefId,
        String turnId,
        Integer nextTurnCount,
        Boolean finalErrorFlag,
        String logPrefix
    ) {
        FollowUpLLMQueueable queueable = new FollowUpLLMQueueable(
            executionId,
            userId,
            agentDefId,
            turnId,
            nextTurnCount,
            finalErrorFlag
        );
        Id jobId = System.enqueueJob(queueable);
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AgentJobEnqueuer] Successfully enqueued FollowUpLLM Queueable (JobId=' +
                jobId +
                ') for turnId=' +
                turnId +
                ', executionId=' +
                executionId +
                ', nextTurnCount=' +
                nextTurnCount +
                ', isFinalErrorTurn=' +
                finalErrorFlag
        );
    }

    /**
     * Enqueues an asynchronous action execution for a given capability.
     * Dynamically routes to either Platform Events (for High concurrency) or Queueable jobs (for Low concurrency)
     * based on the agent's Concurrency__c setting.
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
        String jobDetails = 'ExecuteAction for Capability: ' + capability.CapabilityName__c;
        try {
            String concurrency = this.getAgentConcurrency(agentDefId);

            if ('High'.equalsIgnoreCase(concurrency)) {
                // High concurrency: Use Platform Event for maximum throughput
                this.enqueueAsyncActionViaPlatformEvent(
                    sessionId,
                    originalUserId,
                    agentDefId,
                    parentAsstMsgId,
                    toolCallId,
                    llmArgsJson,
                    capability,
                    relatedId,
                    turnId,
                    currentTurnCount,
                    logPrefix
                );
            } else {
                // Low concurrency (or null): Use Queueable for sequential processing
                this.enqueueAsyncActionViaQueueable(
                    sessionId,
                    originalUserId,
                    agentDefId,
                    parentAsstMsgId,
                    toolCallId,
                    llmArgsJson,
                    capability,
                    relatedId,
                    turnId,
                    currentTurnCount,
                    logPrefix
                );
            }
        } catch (Exception e) {
            this.handleDispatchFailure(sessionId, turnId, jobDetails, e, logPrefix);
        }
    }

    /**
     * Enqueues an asynchronous action via Platform Event (for High concurrency agents).
     */
    private void enqueueAsyncActionViaPlatformEvent(
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
                '[AgentJobEnqueuer] Successfully published ExecuteAction Platform Event for capability="' +
                capability.CapabilityName__c +
                '", turnId=' +
                turnId +
                ', sessionId=' +
                sessionId +
                ', currentTurnCount=' +
                currentTurnCount
        );
    }

    /**
     * Enqueues an asynchronous action via Queueable (for Low concurrency agents).
     */
    private void enqueueAsyncActionViaQueueable(
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
        AsyncActionQueueable queueable = new AsyncActionQueueable(
            sessionId,
            originalUserId,
            agentDefId,
            parentAsstMsgId,
            toolCallId,
            llmArgsJson,
            capability,
            relatedId,
            turnId,
            currentTurnCount
        );
        Id jobId = System.enqueueJob(queueable);
        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AgentJobEnqueuer] Successfully enqueued AsyncAction Queueable (JobId=' +
                jobId +
                ') for capability="' +
                capability.CapabilityName__c +
                '", turnId=' +
                turnId +
                ', sessionId=' +
                sessionId +
                ', currentTurnCount=' +
                currentTurnCount
        );
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

    public class AgentJobEnqueuerException extends Exception {
    }
}
