/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Immutable DTO that encapsulates contextual information for executing agent actions.
 * Securely transports execution context including user, execution, agent, and turn metadata.
 */
public class ActionContext {
    /**
     * The AgentExecution__c ID where this action is being executed.
     * Used to correlate actions with a specific execution instance.
     */
    public Id executionId { get; private set; }

    /**
     * The type of execution (Conversational, Batch, Scheduled, Email, Trigger, API).
     * Helps actions understand their execution context.
     */
    public String executionType { get; private set; }

    /**
     * The related record ID for additional context (may be null).
     * Typically references a business object associated with the session.
     */
    public Id relatedRecordId { get; private set; }

    /**
     * The agent definition ID representing the agent's configuration.
     */
    public Id agentDefinitionId { get; private set; }

    /**
     * The specific agent capability being executed.
     */
    public Id agentCapabilityId { get; private set; }

    /**
     * Implementation-specific details (e.g., class name, flow name).
     * Useful for debugging and dynamic dispatch.
     */
    public String implementationDetail { get; private set; }

    /**
     * Unique identifier for the current conversation turn.
     * Enables tracking and idempotency for turn-based logic.
     */
    public String turnIdentifier { get; private set; }

    /**
     * The current turn number in the conversation.
     * Increments with each user or agent message.
     */
    public Integer currentTurnCount { get; private set; }

    /**
     * The end-user who initiated the conversation.
     * Use for business logic, notifications, and @-mentions.
     */
    public Id originalUserId { get; private set; }

    /**
     * The user context under which this action executes (may be a service account).
     * Corresponds to UserInfo.getUserId().
     */
    public Id executionUserId { get; private set; }

    /**
     * Constructs an immutable ActionContext with all required execution parameters.
     * Supports the unified execution model.
     *
     * @param execId         The AgentExecution__c ID where this action is being executed.
     * @param origUserId     The original user who initiated the execution.
     * @param execUserId     The user context under which the action will execute (may be a service account).
     * @param relId          The related record ID for context (can be null).
     * @param agentDefId     The agent definition ID representing the agent's configuration.
     * @param capabilityId   The specific capability being executed.
     * @param implDetail     Implementation-specific details (class name, flow name, etc.).
     * @param turnId         Unique identifier for the current execution turn.
     * @param turnCount      The current turn number in the execution.
     * @param execType       The type of execution (Conversational, Batch, Scheduled, etc.) - optional, defaults to Conversational.
     *
     * @throws None. This constructor does not perform validation; callers are responsible for providing valid arguments.
     * @sideeffects None. All properties are set once and are immutable thereafter.
     */
    public ActionContext(
        Id execId,
        Id origUserId,
        Id execUserId,
        Id relId,
        Id agentDefId,
        Id capabilityId,
        String implDetail,
        String turnId,
        Integer turnCount,
        String execType
    ) {
        this.executionId = execId;
        this.originalUserId = origUserId;
        this.executionUserId = execUserId;
        this.relatedRecordId = relId;
        this.agentDefinitionId = agentDefId;
        this.agentCapabilityId = capabilityId;
        this.implementationDetail = implDetail;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.executionType = execType != null ? execType : 'Conversational';

        // Debug: Log construction of ActionContext for traceability
        System.debug(
            LoggingLevel.FINER,
            '[ActionContext] Constructed with executionId=' +
                String.valueOf(execId) +
                ', executionType=' +
                String.valueOf(execType) +
                ', originalUserId=' +
                String.valueOf(origUserId) +
                ', executionUserId=' +
                String.valueOf(execUserId) +
                ', relatedRecordId=' +
                String.valueOf(relId) +
                ', agentDefinitionId=' +
                String.valueOf(agentDefId) +
                ', agentCapabilityId=' +
                String.valueOf(capabilityId) +
                ', implementationDetail=' +
                String.valueOf(implDetail) +
                ', turnIdentifier=' +
                String.valueOf(turnId) +
                ', currentTurnCount=' +
                String.valueOf(turnCount)
        );
    }
}
