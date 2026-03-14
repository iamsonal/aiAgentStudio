/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy contract for iterative LLM/tool loops across chat, email,
 * and future conversational transports.
 */
public inherited sharing class IterativeExecutionStrategy extends BaseExecutionStrategy {
    public String getKey() {
        return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative);
    }

    public InteractionRuntimeModels.TraitSet getTraits(String interactionChannel) {
        return new ExecutionStrategyRegistryService.IterativeStrategyDescriptor().getTraits(interactionChannel);
    }

    public AgentExecutionService.ExecutionResult startExecution(
        String agentDeveloperName,
        AgentExecutionService.ExecutionPayload payload,
        AIAgentDefinition__c agentDefinition
    ) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, payload != null ? payload.interactionChannel : null);
        return runtime.start(agentDeveloperName, payload);
    }

    public AgentExecutionService.ExecutionResult resumeExecution(
        Id executionId,
        ExecutionResumeModels.ResumeOptions options,
        AIAgentDefinition__c agentDefinition
    ) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, RuntimeRegistryService.getInteractionChannel(agentDefinition, executionId));
        return runtime.resume(executionId, options);
    }

    public void runAsync(Map<String, Object> payload, String logPrefix, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, interactionChannel);
        runtime.runAsync(payload, logPrefix);
    }

    public void onChildComplete(Id executionId, Map<String, Object> asyncPayload, AIAgentDefinition__c agentDefinition) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, RuntimeRegistryService.getInteractionChannel(agentDefinition, executionId));
        runtime.onChildComplete(executionId, asyncPayload);
    }

    public String buildStrategyPromptAdditions(OrchestrationContext context, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, interactionChannel);
        return runtime.buildSystemPromptAdditions(context);
    }

    public String validateCompletionOutcome(
        OrchestrationContext context,
        List<ToolCallResponseHandler.ToolExecutionResult> toolResults,
        String scenario,
        AIAgentDefinition__c agentDefinition,
        String interactionChannel
    ) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, interactionChannel);
        return runtime.evaluateToolOutcome(context, toolResults, scenario);
    }

    public Boolean canResume(Id executionId, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        IAgentRuntime runtime = buildRuntime(agentDefinition, interactionChannel);
        return runtime.canResume(executionId);
    }

    private IAgentRuntime buildRuntime(AIAgentDefinition__c agentDefinition, String interactionChannel) {
        String resolvedChannel = String.isNotBlank(interactionChannel)
            ? interactionChannel
            : RuntimeRegistryService.getInteractionChannel(agentDefinition, null);
        return InteractionChannelRegistryService.resolveIterativeRuntime(agentDefinition, resolvedChannel);
    }
}
