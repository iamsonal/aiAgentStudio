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

    private static final Integer QUEUEABLE_STACK_BUFFER = 2;
    private final AgentStateService agentStateSvc;

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
     * Delegates to AIAgentConfigService, which already queries and caches the full
     * AIAgentDefinition__c (including AsyncDispatchType__c) for the transaction.
     *
     * @param agentDefId The ID of the agent definition.
     * @return The AsyncDispatchType__c value ('High' or 'Low'). Defaults to 'Low' if blank or not found.
     */
    private String getAgentAsyncDispatchType(Id agentDefId) {
        if (agentDefId == null) {
            return 'Low';
        }
        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefId);
            return String.isNotBlank(agentDef.AsyncDispatchType__c) ? agentDef.AsyncDispatchType__c : 'Low';
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[AgentJobEnqueuer] Failed to retrieve agent async dispatch type: ' + e.getMessage() + '. Defaulting to Low.');
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
     * @param recordId         The record ID for context (can be null).
     * @throws DispatchException if event publication fails.
     */
    public void enqueueFollowUp(
        Id executionId,
        Id userId,
        Id agentDefId,
        String turnId,
        Integer nextTurnCount,
        String logPrefix,
        Boolean isFinalErrorTurn,
        Id recordId
    ) {
        try {
            Boolean finalErrorFlag = (isFinalErrorTurn == true);
            String asyncDispatchType = this.getAgentAsyncDispatchType(agentDefId);

            if ('High'.equalsIgnoreCase(asyncDispatchType)) {
                // High dispatch type: Use Platform Event for maximum throughput (fire-and-forget)
                this.enqueueFollowUpViaPlatformEvent(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag, recordId, logPrefix);
            } else {
                // Low dispatch type (or null): Use Queueable for guaranteed sequential processing
                this.enqueueFollowUpViaQueueable(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag, recordId, logPrefix);
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
        Id recordId,
        String logPrefix
    ) {
        Map<String, Object> payload = new Map<String, Object>{
            'executionId' => executionId,
            'userId' => userId,
            'agentDefId' => agentDefId,
            'turnId' => turnId,
            'nextTurnCount' => nextTurnCount,
            'isFinalErrorTurn' => finalErrorFlag,
            'recordId' => recordId
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
        Id recordId,
        String logPrefix
    ) {
        FollowUpLLMEngine queueable = new FollowUpLLMEngine(executionId, userId, agentDefId, turnId, nextTurnCount, finalErrorFlag, recordId);
        Id jobId = enqueueQueueable(queueable, logPrefix, agentDefId);

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
     * @param executionId       The ID of the execution.
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
        Id executionId,
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
                    executionId,
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
                    executionId,
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
            this.handleDispatchFailure(executionId, turnId, jobDetails, e, logPrefix);
        }
    }

    /**
     * Enqueues an asynchronous action via Platform Event (for High dispatch type agents).
     */
    private void enqueueAsyncActionViaPlatformEvent(
        Id executionId,
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
            'executionId' => executionId,
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
            AgentExecutionId__c = executionId,
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
                ', executionId=' +
                executionId +
                ', currentTurnCount=' +
                currentTurnCount
        );
    }

    /**
     * Enqueues an asynchronous action via Queueable (for Low dispatch type agents).
     */
    private void enqueueAsyncActionViaQueueable(
        Id executionId,
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
            executionId,
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
        Id jobId = enqueueQueueable(queueable, logPrefix, agentDefId);

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AgentJobEnqueuer] Successfully enqueued AsyncAction Queueable (JobId=' +
                jobId +
                ') for capability="' +
                capability.CapabilityName__c +
                '", turnId=' +
                turnId +
                ', executionId=' +
                executionId +
                ', currentTurnCount=' +
                currentTurnCount
        );
    }

    /**
     * Enqueues a queueable job and applies AsyncOptions on the first hop in the chain.
     * Root queueables always receive a stack-depth ceiling sized to the effective
     * processing-cycle policy so scratch/developer org limits do not undercut runtime behavior.
     */
    public Id enqueueQueueable(Queueable job, String logPrefix, Id agentDefId) {
        return enqueueQueueable(job, logPrefix, agentDefId, false);
    }

    public Id enqueueQueueable(Queueable job, String logPrefix, Id agentDefId, Boolean treatAsFreshRoot) {
        AsyncOptions asyncOptions = getAsyncOptions(logPrefix, agentDefId, treatAsFreshRoot);
        return asyncOptions != null ? System.enqueueJob(job, asyncOptions) : System.enqueueJob(job);
    }

    public Id enqueueQueueable(Queueable job, String logPrefix) {
        return enqueueQueueable(job, logPrefix, null);
    }

    /**
     * Creates AsyncOptions for queueable job enqueueing.
     * Automatically derives MaximumQueueableStackDepth from effective processing cycles + buffer
     * to ensure the platform limit never interferes with the business limit.
     *
     * IMPORTANT: AsyncOptions can only be set on the FIRST job in a chain.
     * You cannot reset MaximumQueueableStackDepth from within a running queueable.
     *
     * @param logPrefix A logging prefix for debug output.
     * @return AsyncOptions with configured stack depth, or null if already set in parent chain.
     */
    public AsyncOptions getAsyncOptions(String logPrefix) {
        return getAsyncOptions(logPrefix, null, false);
    }

    public AsyncOptions getAsyncOptions(String logPrefix, Id agentDefId) {
        return getAsyncOptions(logPrefix, agentDefId, false);
    }

    public AsyncOptions getAsyncOptions(String logPrefix, Id agentDefId, Boolean treatAsFreshRoot) {
        Boolean forceFreshRoot = (treatAsFreshRoot == true);
        if (Test.isRunningTest()) {
            // AsyncOptions can only be applied to the first queueable in a chain.
            // Preserve that runtime rule in tests by skipping AsyncOptions once
            // execution is already inside a queueable.
            if (System.isQueueable() && !forceFreshRoot) {
                System.debug(LoggingLevel.DEBUG, logPrefix + '[AgentJobEnqueuer] TEST MODE: already inside queueable - skipping AsyncOptions reset');
                return null;
            }
        }

        // MaximumQueueableStackDepth must only be set on the first enqueue in a
        // chain. When this helper is invoked from queueable execution, treat it as
        // a chained enqueue and skip AsyncOptions rather than probing AsyncInfo,
        // which can throw in runtime contexts such as trigger work kicked off by a
        // queueable.
        if (System.isQueueable() && !forceFreshRoot) {
            System.debug(LoggingLevel.DEBUG, logPrefix + '[AgentJobEnqueuer] Already in Queueable context - skipping AsyncOptions for chained enqueue');
            return null;
        } else if (forceFreshRoot && System.isQueueable()) {
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + '[AgentJobEnqueuer] Queueable-backed transaction treated as fresh logical root - applying AsyncOptions'
            );
        } else {
            System.debug(LoggingLevel.DEBUG, logPrefix + '[AgentJobEnqueuer] Not in Queueable context - this is the first job in chain, will set AsyncOptions');
        }

        Integer maxProcessingCycles = resolveEffectiveMaxProcessingCycles(agentDefId, logPrefix);
        Integer maxStackDepth = maxProcessingCycles + QUEUEABLE_STACK_BUFFER;

        // Set AsyncOptions for the first job in the chain
        AsyncOptions asyncOptions = new AsyncOptions();
        asyncOptions.MaximumQueueableStackDepth = maxStackDepth;

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                '[AgentJobEnqueuer] Setting AsyncOptions with MaximumQueueableStackDepth=' +
                maxStackDepth +
                ' (derived from effective MaxProcessingCycles=' +
                maxProcessingCycles +
                ' + ' +
                QUEUEABLE_STACK_BUFFER +
                ' buffer)'
        );

        return asyncOptions;
    }

    private Integer resolveEffectiveMaxProcessingCycles(Id agentDefId, String logPrefix) {
        Integer fallbackCycles = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
        if (agentDefId == null) {
            return fallbackCycles;
        }

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefId);
            return AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef);
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    '[AgentJobEnqueuer] Failed to resolve agent-specific MaxProcessingCycles for ' +
                    agentDefId +
                    '. Falling back to org default: ' +
                    e.getMessage()
            );
            return fallbackCycles;
        }
    }

    /**
     * Handles failures during event dispatch by updating session state and re-throwing a DispatchException.
     * Ensures error tracking and prevents orphaned processing states.
     *
     * @param executionId     The ID of the execution.
     * @param turnId          The unique identifier for the current turn (may be null for some jobs).
     * @param jobDescription  A human-readable description of the job/event being dispatched.
     * @param enqueueException The exception thrown during event publication.
     * @param logPrefix       A logging prefix for debug output.
     * @throws DispatchException Always thrown to notify the calling runtime of the failure.
     */
    private void handleDispatchFailure(Id executionId, String turnId, String jobDescription, Exception enqueueException, String logPrefix) {
        String errorMsg = 'Failed to dispatch ' + jobDescription;
        String errorDetailForState = errorMsg + ': ' + enqueueException.getMessage();
        System.debug(LoggingLevel.ERROR, logPrefix + '[AgentJobEnqueuer] ' + errorDetailForState);

        this.agentStateSvc.failTurn(executionId, turnId, errorDetailForState, AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, logPrefix);

        // Always re-throw to notify the calling runtime of the dispatch failure
        throw new DispatchException('Failed to dispatch ' + jobDescription, enqueueException);
    }

    public class AgentJobEnqueuerException extends Exception {
    }
}
