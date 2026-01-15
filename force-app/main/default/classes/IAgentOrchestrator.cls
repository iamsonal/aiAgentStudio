/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Contract for agent-type-specific orchestrators. Covers agent lifecycle: initiation, async processing, resume, and customization hooks.
 */
public interface IAgentOrchestrator {
    void configure(AIAgentDefinition__c agentDefinition);
    AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);
    AgentExecutionService.ExecutionResult resume(Id executionId, BaseAgentOrchestrator.ResumeOptions options);
    void runAsync(Map<String, Object> payload, String logPrefix);
    void onChildComplete(Id executionId, Map<String, Object> asyncPayload);
    Boolean canResume(Id executionId);
    String buildSystemPromptAdditions(OrchestrationContext context);
    String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario);
    AIAgentDefinition__c getAgentDefinition();
}
