/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Data Transfer Object (DTO) to hold the complete context for processing an LLM response.
 *              This is passed to ILLMResponseHandler implementations.
 */
public class OrchestrationContext {
    public LLMInteractionService.LLMInteractionResult llmResult { get; private set; }
    public LLMInteractionService.MessageData userMessageData { get; private set; }

    public Id sessionId { get; private set; }
    public Id originalUserId { get; private set; }
    public Id executionUserId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public String turnIdentifier { get; private set; }
    public Integer currentTurnCount { get; private set; }
    public String logPrefix { get; private set; }
    public Id currentPageRecordId { get; private set; }

    public TurnLifecycleService turnLifecycleSvc { get; private set; }
    public ActionExecutionService actionExecSvc { get; private set; }
    public AgentJobEnqueuer dispatchSvc { get; private set; }
    public ContextManagerService contextManagerSvc { get; private set; }

    public OrchestrationContext(
        LLMInteractionService.LLMInteractionResult llmResult,
        Id sessionId,
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
        Id pageRecordId
    ) {
        this.llmResult = llmResult;
        this.sessionId = sessionId;
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
        this.logPrefix = '[OrchSvc Turn:' + turnId?.left(8) + ' Cycle:' + turnCount + ' Sess:' + sessionId + '] ';
    }
}
