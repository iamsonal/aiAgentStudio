/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
