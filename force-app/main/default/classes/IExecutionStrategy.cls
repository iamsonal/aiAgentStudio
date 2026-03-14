/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy-layer contract for agent execution semantics.
 * Concrete strategy classes own runtime flow behind this interface.
 */
public interface IExecutionStrategy {
    String getKey();
    AgentExecutionService.ExecutionResult startExecution(
        String agentDeveloperName,
        AgentExecutionService.ExecutionPayload payload,
        AIAgentDefinition__c agentDefinition
    );
    AgentExecutionService.ExecutionResult resumeExecution(Id executionId, ExecutionResumeModels.ResumeOptions options, AIAgentDefinition__c agentDefinition);
    void runAsync(Map<String, Object> payload, String logPrefix, AIAgentDefinition__c agentDefinition, String interactionChannel);
    void onChildComplete(Id executionId, Map<String, Object> asyncPayload, AIAgentDefinition__c agentDefinition);
    String buildStrategyPromptAdditions(OrchestrationContext context, AIAgentDefinition__c agentDefinition, String interactionChannel);
    String validateCompletionOutcome(
        OrchestrationContext context,
        List<ToolCallResponseHandler.ToolExecutionResult> toolResults,
        String scenario,
        AIAgentDefinition__c agentDefinition,
        String interactionChannel
    );
    Boolean canResume(Id executionId, AIAgentDefinition__c agentDefinition, String interactionChannel);
    InteractionRuntimeModels.TraitSet getTraits(String interactionChannel);
}
