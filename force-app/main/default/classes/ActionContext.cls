/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contextual information passed to IAgentAction implementations during execution.
 */
public class ActionContext {
    public Id chatSessionId { get; private set; }
    public Id userId { get; private set; }
    public Id relatedRecordId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public Id agentCapabilityId { get; private set; }
    public Id actionDefinitionId { get; private set; }

    public ActionContext(Id sessId, Id usrId, Id relId, Id agentDefId, Id capabilityId, Id actionDefId) {
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.relatedRecordId = relId;
        this.agentDefinitionId = agentDefId;
        this.agentCapabilityId = capabilityId;
        this.actionDefinitionId = actionDefId;
    }
}
