/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contextual information passed to IAgentAction implementations and Hooks.
 *              This DTO carries all necessary state for an action's execution.
 */
public class ActionContext {
    public Id chatSessionId { get; private set; }
    public Id relatedRecordId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public Id agentCapabilityId { get; private set; }
    public String implementationDetail { get; private set; }
    public String turnIdentifier { get; private set; }
    public Integer currentTurnCount { get; private set; }

    /** @description The end-user who initiated the conversation. Use for business logic, notifications, and @-mentions. */
    public Id originalUserId { get; private set; }

    /** @description The user under whose permissions this action is executing (e.g., a service account). Corresponds to UserInfo.getUserId(). */
    public Id executionUserId { get; private set; }

    public ActionContext(
        Id sessId,
        Id origUserId,
        Id execUserId,
        Id relId,
        Id agentDefId,
        Id capabilityId,
        String implDetail,
        String turnId,
        Integer turnCount
    ) {
        this.chatSessionId = sessId;
        this.originalUserId = origUserId;
        this.executionUserId = execUserId;
        this.relatedRecordId = relId;
        this.agentDefinitionId = agentDefId;
        this.agentCapabilityId = capabilityId;
        this.implementationDetail = implDetail;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }
}
