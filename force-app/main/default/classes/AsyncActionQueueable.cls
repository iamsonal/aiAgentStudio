/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AsyncActionQueueable is a thin wrapper Queueable class that enables asynchronous action processing
 * to be executed via System.enqueueJob instead of Platform Events. This class is specifically
 * designed for agents with low dispatch type settings (AsyncDispatchType__c = 'Low' or null).
 *
 * This class contains NO business logic. Its sole responsibility is to instantiate and invoke
 * the AsyncActionEngine class, which contains all the actual processing logic. This design
 * prevents code duplication and centralizes business logic while allowing for different
 * invocation contexts (Platform Event vs. Queueable).
 *
 * Usage:
 *   - For low dispatch type agents, enqueue this Queueable via System.enqueueJob
 *   - For high dispatch type agents, continue using AsyncFrameworkRequest__e Platform Events
 */
public class AsyncActionQueueable implements Queueable {
    private final Id executionId;
    private final Id originalUserId;
    private final Id agentDefinitionId;
    private final Id parentAssistantMessageId;
    private final String toolCallId;
    private final String llmArgumentsJson;
    private final AgentCapability__c capability;
    private final Id relatedRecordId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;

    /**
     * Constructor for AsyncActionQueueable.
     * Parameters mirror those required by AsyncActionEngine for seamless delegation.
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
     */
    public AsyncActionQueueable(
        Id sessionId,
        Id originalUserId,
        Id agentDefId,
        Id parentAsstMsgId,
        String toolCallId,
        String llmArgsJson,
        AgentCapability__c capability,
        Id relatedId,
        String turnId,
        Integer currentTurnCount
    ) {
        this.executionId = sessionId;
        this.originalUserId = originalUserId;
        this.agentDefinitionId = agentDefId;
        this.parentAssistantMessageId = parentAsstMsgId;
        this.toolCallId = toolCallId;
        this.llmArgumentsJson = llmArgsJson;
        this.capability = capability;
        this.relatedRecordId = relatedId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = currentTurnCount;
    }

    /**
     * Queueable execute method. Instantiates AsyncActionEngine and delegates all processing.
     * This method contains no business logic—it simply creates the engine and invokes its process() method.
     *
     * @param context The QueueableContext provided by the platform.
     */
    public void execute(QueueableContext context) {
        String jobId = context.getJobId();
        AsyncActionEngine engine = new AsyncActionEngine(
            this.executionId,
            this.originalUserId,
            this.agentDefinitionId,
            this.parentAssistantMessageId,
            this.toolCallId,
            this.llmArgumentsJson,
            this.capability,
            this.relatedRecordId,
            this.turnIdentifier,
            this.currentTurnCount
        );
        engine.process(jobId);
    }
}
