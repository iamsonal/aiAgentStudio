/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared runtime contract for strategy-owned execution runtimes.
 */
public interface IAgentRuntime {
    void configure(AIAgentDefinition__c agentDefinition);
    AIAgentDefinition__c getAgentDefinition();
    AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);
    AgentExecutionService.ExecutionResult resume(Id executionId, ExecutionResumeModels.ResumeOptions options);
    Boolean canResume(Id executionId);
    void runAsync(Map<String, Object> payload, String logPrefix);
    void onChildComplete(Id executionId, Map<String, Object> asyncPayload);
    String buildSystemPromptAdditions(OrchestrationContext context);
    String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario);
}
