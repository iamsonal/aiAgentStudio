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
    public Id userId { get; private set; }
    public Id relatedRecordId { get; private set; }
    public Id agentDefinitionId { get; private set; }
    public Id agentCapabilityId { get; private set; }
    public String preHookClassName { get; private set; }
    public String postHookClassName { get; private set; }
    public String implementationDetail { get; private set; }

    /**
     * @description Constructor requires all context pieces, including optional hooks.
     */
    public ActionContext(Id sessId, Id usrId, Id relId, Id agentDefId, Id capabilityId, String preHook, String postHook, String implDetail) {
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.relatedRecordId = relId;
        this.agentDefinitionId = agentDefId;
        this.agentCapabilityId = capabilityId;
        this.preHookClassName = preHook;
        this.postHookClassName = postHook;
        this.implementationDetail = implDetail;
    }
}
