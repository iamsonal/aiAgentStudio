/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Immutable DTO that encapsulates contextual information for executing agent actions.
 */
public inherited sharing class ActionContext {
    public Id executionId { get; private set; }
    public String executionType { get; private set; }
    public Id relatedRecordId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public Id agentCapabilityId { get; private set; }
    public String implementationDetail { get; private set; }
    public String turnIdentifier { get; private set; }
    public Integer currentTurnCount { get; private set; }
    public Id originalUserId { get; private set; }
    public Id executionUserId { get; private set; }
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
