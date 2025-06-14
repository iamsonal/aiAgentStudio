/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for encapsulating the enqueueing of asynchronous
 *              framework jobs (FollowUpLLM, ExecuteSingleAction). Includes error handling.
 *              This service is now instantiated.
 */
public inherited sharing class OrchestrationDispatchService {
    public class DispatchException extends AIAgentException {
    }

    private final TurnLifecycleService turnLifecycleSvc;

    /**
     * @description Default constructor for ease of use.
     */
    public OrchestrationDispatchService() {
        this(new TurnLifecycleService());
    }

    /**
     * @description Main constructor for dependency injection.
     * @param turnLifecycleService The lifecycle service for failure handling.
     */
    public OrchestrationDispatchService(TurnLifecycleService turnLifecycleService) {
        if (turnLifecycleService == null) {
            throw new IllegalArgumentException('TurnLifecycleService cannot be null.');
        }
        this.turnLifecycleSvc = turnLifecycleService;
    }

    /**
     * @description Enqueues the FollowUpLLMQueueable job.
     */
    public void enqueueFollowUp(Id sessionId, Id userId, Id agentDefId, String turnId, Integer nextTurnCount, String logPrefix) {
        FollowUpLLMQueueable nextJob = new FollowUpLLMQueueable(sessionId, userId, agentDefId, turnId, nextTurnCount);
        String jobDetails = 'FollowUpLLM job Cycle: ' + nextTurnCount;
        try {
            Id jobId = System.enqueueJob(nextJob);
        } catch (Exception e) {
            this.handleEnqueueFailure(sessionId, turnId, jobDetails, e, logPrefix);
            throw new DispatchException('Failed to enqueue ' + jobDetails, e);
        }
    }

    /**
     * @description Enqueues the ExecuteSingleActionQueueable job.
     */
    public void enqueueAsyncAction(
        Id sessionId,
        Id userId,
        Id agentDefId,
        Id parentAsstMsgId,
        String toolCallId,
        String llmArgsJson,
        String bindingCfg,
        Id actionDefId,
        Id relatedId,
        String turnId,
        Integer currentTurnCount,
        String logPrefix
    ) {
        ExecuteSingleActionQueueable asyncJob = new ExecuteSingleActionQueueable(
            sessionId,
            userId,
            agentDefId,
            parentAsstMsgId,
            toolCallId,
            llmArgsJson,
            bindingCfg,
            actionDefId,
            relatedId,
            turnId,
            currentTurnCount
        );
        String jobDetails = 'ExecuteSingleAction job ActionDef: ' + actionDefId;
        try {
            Id jobId = System.enqueueJob(asyncJob);
        } catch (Exception e) {
            this.handleEnqueueFailure(sessionId, turnId, jobDetails, e, logPrefix);
            throw new DispatchException('Failed to enqueue ' + jobDetails, e);
        }
    }

    /**
     * @description Centralized handling for enqueue failures. Now an instance method.
     *              Uses the injected TurnLifecycleService to fail the turn.
     */
    private void handleEnqueueFailure(Id sessionId, String turnId, String jobDescription, Exception enqueueException, String logPrefix) {
        String errorMsg = 'Failed to enqueue ' + jobDescription;
        String errorDetailForState = errorMsg + ': ' + enqueueException.getMessage();

        try {
            this.turnLifecycleSvc.failTurn(
                sessionId,
                turnId,
                errorDetailForState,
                AIAgentConstants.ERR_CODE_SYSTEM_LIMIT /*or a new QUEUE_FAILURE code?*/,
                logPrefix
            );
        } catch (Exception finalStateEx) {
        }
    }
}
