/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy contract for one-turn or minimal-orchestration executions.
 */
public inherited sharing class SingleShotExecutionStrategy extends BaseExecutionStrategy {
    public String getKey() {
        return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot);
    }

    public InteractionRuntimeModels.TraitSet getTraits(String interactionChannel) {
        return new ExecutionStrategyRegistryService.SingleShotStrategyDescriptor().getTraits(interactionChannel);
    }

    public AgentExecutionService.ExecutionResult startExecution(
        String agentDeveloperName,
        AgentExecutionService.ExecutionPayload payload,
        AIAgentDefinition__c agentDefinition
    ) {
        SingleShotRuntimeService runtime = new SingleShotRuntimeService();
        runtime.configure(agentDefinition);
        AgentExecutionService.ExecutionResult result = runtime.start(agentDeveloperName, payload);
        ensureSessionAnchor(payload, agentDefinition, result);
        return result;
    }

    public AgentExecutionService.ExecutionResult resumeExecution(
        Id executionId,
        ExecutionResumeModels.ResumeOptions options,
        AIAgentDefinition__c agentDefinition
    ) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        return runtime.resume(executionId, options);
    }

    public void runAsync(Map<String, Object> payload, String logPrefix, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        runtime.runAsync(payload, logPrefix);
    }

    public void onChildComplete(Id executionId, Map<String, Object> asyncPayload, AIAgentDefinition__c agentDefinition) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        runtime.onChildComplete(executionId, asyncPayload);
    }

    public String buildStrategyPromptAdditions(OrchestrationContext context, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        return runtime.buildSystemPromptAdditions(context);
    }

    public String validateCompletionOutcome(
        OrchestrationContext context,
        List<ToolCallResponseHandler.ToolExecutionResult> toolResults,
        String scenario,
        AIAgentDefinition__c agentDefinition,
        String interactionChannel
    ) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        return runtime.evaluateToolOutcome(context, toolResults, scenario);
    }

    public Boolean canResume(Id executionId, AIAgentDefinition__c agentDefinition, String interactionChannel) {
        SingleShotRuntimeService runtime = buildRuntime(agentDefinition);
        return runtime.canResume(executionId);
    }

    private SingleShotRuntimeService buildRuntime(AIAgentDefinition__c agentDefinition) {
        SingleShotRuntimeService runtime = new SingleShotRuntimeService();
        runtime.configure(agentDefinition);
        return runtime;
    }

    private void ensureSessionAnchor(
        AgentExecutionService.ExecutionPayload payload,
        AIAgentDefinition__c agentDefinition,
        AgentExecutionService.ExecutionResult result
    ) {
        if (result == null || result.success != true || result.executionId == null) {
            return;
        }

        String interactionChannel = String.isNotBlank(payload != null ? payload.interactionChannel : null)
            ? payload.interactionChannel
            : RuntimeRegistryService.CHANNEL_API;

        if (!RuntimeRegistryService.CHANNEL_API.equalsIgnoreCase(interactionChannel)) {
            return;
        }

        Boolean hasExplicitSessionContract =
            (payload != null && payload.interactionSessionId != null) || (payload != null && String.isNotBlank(payload.conversationKey));
        if (!hasExplicitSessionContract) {
            return;
        }

        Map<String, Object> metadata = new Map<String, Object>{
            'existingExecutionId' => String.valueOf(result.executionId),
            'interactionSessionId' => payload != null && payload.interactionSessionId != null ? String.valueOf(payload.interactionSessionId) : null,
            'userId' => payload != null && payload.userId != null ? String.valueOf(payload.userId) : null,
            'turnIdentifier' => payload != null ? payload.turnIdentifier : null,
            'batchId' => payload != null ? payload.batchId : null,
            'triggerSource' => payload != null ? payload.triggerSource : null,
            'conversationKey' => payload != null ? payload.conversationKey : null
        };

        InteractionRuntimeModels.IInteractionChannel adapter = new ApiInteractionChannel();
        InboundInteractionPipelineService.ResolvedInbound resolved = new InboundInteractionPipelineService()
            .resolve(
                agentDefinition,
                adapter,
                interactionChannel,
                payload != null ? payload.sourceRecordId : null,
                payload != null ? payload.userMessage : null,
                metadata,
                '[SingleShotExecutionStrategy] '
            );
        InteractionRuntimeModels.InteractionSessionContext sessionContext = resolved.sessionContext;

        if (sessionContext != null && sessionContext.sessionId != null) {
            update new AgentExecution__c(
                Id = result.executionId,
                InteractionChannel__c = interactionChannel,
                InteractionSession__c = sessionContext.sessionId,
                SessionStartedAt__c = Datetime.now()
            );
            new InteractionSessionService().stampExecution(sessionContext.sessionId, result.executionId);
            if (payload != null) {
                payload.interactionSessionId = sessionContext.sessionId;
            }
        }
    }
}
