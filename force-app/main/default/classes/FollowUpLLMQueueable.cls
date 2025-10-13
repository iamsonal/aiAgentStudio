/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * FollowUpLLMQueueable is a thin wrapper Queueable class that enables follow-up LLM processing
 * to be executed via System.enqueueJob instead of Platform Events. This class is specifically
 * designed for agents with low concurrency settings (Concurrency__c = 'Low' or null).
 *
 * This class contains NO business logic. Its sole responsibility is to instantiate and invoke
 * the FollowUpLLMEngine class, which contains all the actual processing logic. This design
 * prevents code duplication and centralizes business logic while allowing for different
 * invocation contexts (Platform Event vs. Queueable).
 *
 * Usage:
 *   - For low-concurrency agents, enqueue this Queueable via System.enqueueJob
 *   - For high-concurrency agents, continue using AsyncFrameworkRequest__e Platform Events
 */
public class FollowUpLLMQueueable implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer nextTurnCount;
    private final Boolean isFinalErrorTurn;

    /**
     * Constructor for FollowUpLLMQueueable.
     * Parameters mirror those required by FollowUpLLMEngine for seamless delegation.
     *
     * @param executionId      The ID of the agent execution (AgentExecution__c).
     * @param userId           The ID of the user.
     * @param agentDefId       The ID of the agent definition.
     * @param turnId           The unique identifier for the current turn.
     * @param nextTurnCount    The cycle number for the next turn.
     * @param isFinalErrorTurn Whether this is the final error turn for the session.
     */
    public FollowUpLLMQueueable(Id executionId, Id userId, Id agentDefId, String turnId, Integer nextTurnCount, Boolean isFinalErrorTurn) {
        this.executionId = executionId;
        this.userId = userId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.nextTurnCount = nextTurnCount;
        this.isFinalErrorTurn = isFinalErrorTurn;
    }

    /**
     * Queueable execute method. Instantiates FollowUpLLMEngine and delegates all processing.
     * This method contains no business logic—it simply creates the engine and invokes its process() method.
     *
     * @param context The QueueableContext provided by the platform.
     */
    public void execute(QueueableContext context) {
        String jobId = context.getJobId();
        FollowUpLLMEngine engine = new FollowUpLLMEngine(
            this.executionId,
            this.userId,
            this.agentDefinitionId,
            this.turnIdentifier,
            this.nextTurnCount,
            this.isFinalErrorTurn
        );
        engine.process(jobId);
    }
}
