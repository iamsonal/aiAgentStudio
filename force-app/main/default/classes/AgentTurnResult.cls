/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
