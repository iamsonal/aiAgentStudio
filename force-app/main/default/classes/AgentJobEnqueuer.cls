/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Central service for dispatching asynchronous jobs. Routes to Platform Events (High) or Queueable (Low/null) based on agent async dispatch type.
 */
public inherited sharing class AgentJobEnqueuer {
    public class DispatchException extends AIAgentException {
    }

    private final AgentStateService agentStateSvc;
    private static Map<Id, String> agentAsyncDispatchTypeCache = new Map<Id, String>();

    public AgentJobEnqueuer() {
        this(new AgentStateService());
    }
    public AgentJobEnqueuer(AgentStateService agentStateService) {
        if (agentStateService == null) {
            throw new IllegalArgumentException('AgentStateService cannot be null.');
        }
        this.agentStateSvc = agentStateService;
    }

    /**
     * Retrieves the AsyncDispatchType__c setting for a given agent definition.
     * Uses a static cache to minimize SOQL queries within the same transaction.
     *
     * @param agentDefId The ID of the agent definition.
     * @return The AsyncDispatchType__c value ('High', 'Low', or null). Defaults to 'Low' if null or not found.
     */
    private String getAgentAsyncDispatchType(Id agentDefId) {
        if (agentDefId == null) {
            return 'Low'; // Default to Low if no agent definition is provided
        }

        // Check cache first
        if (agentAsyncDispatchTypeCache.containsKey(agentDefId)) {
            return agentAsyncDispatchTypeCache.get(agentDefId);
        }

        // Query the agent definition
        try {
            List<AIAgentDefinition__c> agents = [
                SELECT AsyncDispatchType__c
                FROM AIAgentDefinition__c
                WHERE Id = :agentDefId
                LIMIT 1
            ];

            String asyncDispatchType = 'Low'; // Default to Low
            if (!agents.isEmpty() && agents[0].AsyncDispatchType__c != null) {
                asyncDispatchType = agents[0].AsyncDispatchType__c;
            }

            // Cache the result
            agentAsyncDispatchTypeCache.put(agentDefId, asyncDispatchType);
            return asyncDispatchType;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[AgentJobEnqueuer] Failed to query agent async dispatch type setting: ' + e.getMessage() + '. Defaulting to Low.');
            return 'Low';
        }
    }

    /**
     * Enqueues a follow-up LLM operation for a given agent execution turn.
     * Dynamically routes to either Platform Events (for High dispatch type) or Queueable jobs (for Low dispatch type)
     * based on the agent's AsyncDispatchType__c setting.
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
    public void enqueueFollowUp(Id executionId, Id userId, Id agentDefId, String turnId, Integer nextTurnCount, String logPrefix, Boolean isFinalErrorTurn) {
        try {
            Boolean finalErrorFlag = (isFinalErrorTurn == true);
            String asyncDispatchType = this.getAgentAsyncDispatchType(agentDefId);

            if ('High'.equalsIgnoreCase(asyncDispatchType)) {
                // High dispatch type: Use Platform Event for maximum throughput (fire-and-forget)
                this.enqueueFollowUpViaPlatformEvent(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag, logPrefix);
            } else {
                // Low dispatch type (or null): Use Queueable for guaranteed sequential processing
                this.enqueueFollowUpViaQueueable(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag, logPrefix);
            }
        } catch (Exception e) {
            this.handleDispatchFailure(executionId, turnId, 'FollowUpLLM', e, logPrefix);
        }
    }

    /**
     * Enqueues a follow-up LLM operation via Platform Event (for High dispatch type agents).
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
            AgentExecutionId__c = executionId,
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
     * Enqueues a follow-up LLM operation via Queueable (for Low dispatch type agents).
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
        FollowUpLLMEngine queueable = new FollowUpLLMEngine(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag);

        // Get AsyncOptions if configured (for scratch/developer orgs)
        AsyncOptions asyncOptions = getAsyncOptions(logPrefix);
        Id jobId;
        if (asyncOptions != null) {
            jobId = System.enqueueJob(queueable, asyncOptions);
        } else {
            jobId = System.enqueueJob(queueable);
        }

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
     * Dynamically routes to either Platform Events (for High dispatch type) or Queueable jobs (for Low dispatch type)
     * based on the agent's AsyncDispatchType__c setting.
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
            String asyncDispatchType = this.getAgentAsyncDispatchType(agentDefId);

            if ('High'.equalsIgnoreCase(asyncDispatchType)) {
                // High dispatch type: Use Platform Event for maximum throughput (fire-and-forget)
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
                // Low dispatch type (or null): Use Queueable for guaranteed sequential processing
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
     * Enqueues an asynchronous action via Platform Event (for High dispatch type agents).
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
            AgentExecutionId__c = sessionId,
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
     * Enqueues an asynchronous action via Queueable (for Low dispatch type agents).
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
        AsyncActionEngine queueable = new AsyncActionEngine(
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

        // Get AsyncOptions if configured (for scratch/developer orgs)
        AsyncOptions asyncOptions = getAsyncOptions(logPrefix);
        Id jobId;
        if (asyncOptions != null) {
            jobId = System.enqueueJob(queueable, asyncOptions);
        } else {
            jobId = System.enqueueJob(queueable);
        }

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
     * Creates AsyncOptions for queueable job enqueueing if configured.
     * Returns null if MaxQueueableStackDepth is 0 (use Salesforce defaults).
     * This is primarily for scratch/developer orgs which have a 5-job chain limit.
     *
     * IMPORTANT: AsyncOptions can only be set on the FIRST job in a chain.
     * You cannot reset MaximumQueueableStackDepth from within a running queueable.
     * This method checks if max stack depth was already configured in the parent chain.
     *
     * @param logPrefix A logging prefix for debug output.
     * @return AsyncOptions with configured stack depth, or null to use defaults.
     */
    private AsyncOptions getAsyncOptions(String logPrefix) {
        Integer maxStackDepth = AIAgentFrameworkSettings.getMaxQueueableStackDepth();

        if (maxStackDepth == null || maxStackDepth <= 0) {
            // Use Salesforce defaults (recommended for production/sandbox)
            return null;
        }

        // Check if MaxStackDepth was already configured in parent chain
        // AsyncInfo.hasMaxStackDepth() returns true if AsyncOptions was set on a parent job
        if (AsyncInfo.hasMaxStackDepth()) {
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    '[AgentJobEnqueuer] MaxStackDepth already configured in parent chain (depth=' +
                    AsyncInfo.getMaximumQueueableStackDepth() +
                    ') - skipping AsyncOptions'
            );
            return null;
        }

        // Set AsyncOptions for the first job in the chain
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = maxStackDepth;

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AgentJobEnqueuer] Setting AsyncOptions with MaximumQueueableStackDepth=' +
                maxStackDepth +
                ' (first job in chain for scratch/developer org)'
        );

        return asyncOptions;
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

        this.agentStateSvc.failTurn(sessionId, turnId, errorDetailForState, AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, logPrefix);

        // Always re-throw to notify the calling orchestrator of the dispatch failure
        throw new DispatchException('Failed to dispatch ' + jobDescription, enqueueException);
    }

    public class AgentJobEnqueuerException extends Exception {
    }
}
