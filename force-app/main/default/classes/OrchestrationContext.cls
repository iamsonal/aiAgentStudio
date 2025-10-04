/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * OrchestrationContext encapsulates all state, execution, and service dependencies required for a single LLM response processing turn.
 * It is passed to ILLMResponseHandler implementations to provide unified access to user input, LLM results, execution metadata,
 * and injected service dependencies. This context object enables stateless orchestration logic, simplifies dependency management,
 * and ensures that all relevant information for a turn is available in a single, immutable structure. Its scope is limited to
 * a single turn of LLM-driven orchestration, but it is designed for easy extension as orchestration requirements evolve.
 *
 * Supports the unified AgentExecution__c model for all agent workflows.
 */
public class OrchestrationContext {
    // LLM interaction results and user input
    public LLMInteractionService.LLMInteractionResult llmResult { get; private set; }
    public LLMInteractionService.MessageData userMessageData { get; private set; }

    // Execution and turn state information
    public Id executionId { get; private set; }
    public Id originalUserId { get; private set; }
    public Id executionUserId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public String turnIdentifier { get; private set; }
    public Integer currentTurnCount { get; private set; }
    public String logPrefix { get; private set; }
    public Id currentPageRecordId { get; private set; }

    // Injected service dependencies
    public TurnLifecycleService turnLifecycleSvc { get; private set; }
    public ActionExecutionService actionExecSvc { get; private set; }
    public AgentJobEnqueuer dispatchSvc { get; private set; }
    public ContextManagerService contextManagerSvc { get; private set; }

    // Shared decision step logger for the turn
    public AgentDecisionStepLogger decisionLogger { get; private set; }

    /**
     * Constructs an OrchestrationContext with all state and dependencies for a single LLM orchestration turn.
     * Supports the unified AgentExecution__c model.
     *
     * @param llmResult         The result of the LLM interaction for this turn (required)
     * @param executionId       The current AgentExecution__c ID (required)
     * @param origUserId        The original user ID who initiated the execution (required)
     * @param execUserId        The user ID under which execution is performed (required)
     * @param agentDefId        The agent definition ID for this execution (required)
     * @param turnId            Unique identifier for this turn (required)
     * @param turnCount         The current turn count in the execution (required)
     * @param userMsgData       The user message data for this turn (optional for non-conversational)
     * @param turnSvc           Service for managing turn lifecycle events (required)
     * @param actionSvc         Service for executing agent actions (required)
     * @param dispatchSvc       Service for enqueuing agent jobs (required)
     * @param contextMgrSvc     Service for managing context and memory (required)
     * @param pageRecordId      The current page record ID, if applicable (optional)
     * @param decisionLogger    Shared decision step logger for this turn (required)
     *
     * All fields are immutable after construction. The logPrefix is precomputed for consistent debug output.
     */
    public OrchestrationContext(
        LLMInteractionService.LLMInteractionResult llmResult,
        Id executionId,
        Id origUserId,
        Id execUserId,
        Id agentDefId,
        String turnId,
        Integer turnCount,
        LLMInteractionService.MessageData userMsgData,
        TurnLifecycleService turnSvc,
        ActionExecutionService actionSvc,
        AgentJobEnqueuer dispatchSvc,
        ContextManagerService contextMgrSvc,
        Id pageRecordId,
        AgentDecisionStepLogger decisionLogger
    ) {
        this.llmResult = llmResult;
        this.executionId = executionId;
        this.originalUserId = origUserId;
        this.executionUserId = execUserId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.userMessageData = userMsgData;
        this.turnLifecycleSvc = turnSvc;
        this.actionExecSvc = actionSvc;
        this.dispatchSvc = dispatchSvc;
        this.contextManagerSvc = contextMgrSvc;
        this.currentPageRecordId = pageRecordId;
        this.decisionLogger = decisionLogger;
        // Precompute a log prefix for consistent debug output throughout the turn.
        this.logPrefix = '[OrchSvc Turn:' + turnId?.left(8) + ' Cycle:' + turnCount + ' Exec:' + executionId + '] ';
    }
}
