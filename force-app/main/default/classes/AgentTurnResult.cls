/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-04-02.
 */

/** @description Wraps the final result of a single turn processed by the AIAgentOrchestrator. */
public class AgentTurnResult {
    @AuraEnabled
    public Boolean isSuccess { get; set; }
    @AuraEnabled
    public String finalAssistantMessage { get; set; }
    @AuraEnabled
    public String errorDetails { get; set; }

    public AgentTurnResult(Boolean success, String message) {
        this.isSuccess = success;
        this.finalAssistantMessage = message;
    }
    public AgentTurnResult(Boolean success, String message, String errorInfo) {
        this.isSuccess = success;
        this.finalAssistantMessage = message;
        this.errorDetails = errorInfo;
    }

    public AgentTurnResult() {
    }
}
