/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Encapsulates all state, execution, and service dependencies required for a single LLM response processing turn.
 */
public inherited sharing class OrchestrationContext {
    public LLMInteractionService.LLMInteractionResult llmResult { get; private set; }
    public LLMInteractionService.MessageData userMessageData { get; private set; }
    public Id executionId { get; private set; }
    public Id originalUserId { get; private set; }
    public Id executionUserId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public String turnIdentifier { get; private set; }
    public Integer currentTurnCount { get; private set; }
    public String logPrefix { get; private set; }
    public Id currentPageRecordId { get; private set; }
    public AgentStateService agentStateSvc { get; private set; }
    public CapabilityExecutionService actionExecSvc { get; private set; }
    public AgentJobEnqueuer dispatchSvc { get; private set; }
    public ContextManagerService contextManagerSvc { get; private set; }
    public IDecisionStepLogger.ILogger decisionLogger { get; private set; }
    public OrchestrationContext(
        LLMInteractionService.LLMInteractionResult llmResult,
        Id executionId,
        Id origUserId,
        Id execUserId,
        Id agentDefId,
        String turnId,
        Integer turnCount,
        LLMInteractionService.MessageData userMsgData,
        AgentStateService stateSvc,
        CapabilityExecutionService actionSvc,
        AgentJobEnqueuer dispatchSvc,
        ContextManagerService contextMgrSvc,
        Id pageRecordId,
        IDecisionStepLogger.ILogger decisionLogger
    ) {
        this.llmResult = llmResult;
        this.executionId = executionId;
        this.originalUserId = origUserId;
        this.executionUserId = execUserId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.userMessageData = userMsgData;
        this.agentStateSvc = stateSvc;
        this.actionExecSvc = actionSvc;
        this.dispatchSvc = dispatchSvc;
        this.contextManagerSvc = contextMgrSvc;
        this.currentPageRecordId = pageRecordId;
        this.decisionLogger = decisionLogger;
        this.logPrefix = '[OrchSvc Turn:' + turnId?.left(8) + ' Cycle:' + turnCount + ' Exec:' + executionId + '] ';
    }
}
