/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Processes LLM responses that contain only textual content (no tool calls). Orchestrates message persistence.
 */
public inherited sharing class ContentResponseHandler implements ILLMResponseHandler {
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ContentHandler] ';
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Handling text-only LLM response for session: ' + context.executionId + ', turn: ' + context.turnIdentifier
        );

        // Use the shared decision step logger from the context
        IDecisionStepLogger.ILogger decisionLogger = context.decisionLogger;

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        // Validate LLM response content before proceeding
        if (String.isBlank(assistantData?.content)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Validation failed: LLM response content is empty.');

            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ assistantData });

            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'LLM returned empty successful response.',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Apply agent-specific content validation (e.g., Function agent strict recovery validation)
        String agentValidationResult = applyAgentSpecificContentValidation(context, assistantData.content, logPrefix);
        if (agentValidationResult != null) {
            // Agent-specific validation failed - the orchestrator has already handled the failure
            return agentValidationResult;
        }

        // Persist the user message as the parent of the assistant's reply using ExecutionStep__c
        Id savedUserMessageId = null;
        if (context.userMessageData != null && String.isNotBlank(context.userMessageData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedUserMessageId = executionStepService.createUserInputStep(
                context.executionId,
                context.userMessageData.content,
                context.turnIdentifier,
                context.currentTurnCount
            );
        }

        // Save assistant message with token usage data using ExecutionStep__c
        Id savedAssistantMessageId = null;
        if (String.isNotBlank(assistantData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedAssistantMessageId = executionStepService.createAgentResponseStepWithTokens(
                context.executionId,
                assistantData.content,
                context.turnIdentifier,
                context.currentTurnCount,
                context.llmResult.providerResult.promptTokens,
                context.llmResult.providerResult.completionTokens,
                context.llmResult.providerResult.totalTokens,
                context.llmResult.providerResult.modelIdentifier,
                context.llmResult.providerResult.llmCalloutDurationMs
            );
        }

        // Commit the turn context to the ledger (Conversational agents only)
        // Skip for Function/Workflow agents which don't need multi-turn context tracking
        if (context.agentStateSvc.isContextTrackingEnabled(context.executionId)) {
            try {
                context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Context ledger update failed: ' + e.getMessage());
            }
        }

        // Invoke memory management completion hook if configured
        try {
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (String.isNotBlank(agentConfig.MemoryStrategy__c)) {
                LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentConfig.LLMConfiguration__c);
                IMemoryManager memoryManager = ContextManagerService.getMemoryManager(agentConfig.MemoryStrategy__c);
                // Note: Memory manager will need to be updated to handle both execution models
                memoryManager.onTurnCompletion(context.executionId, agentConfig, llmConfig, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Memory management completion hook failed: ' + e.getMessage());
        }

        // Complete the turn successfully
        context.agentStateSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }

    /**
     * @description
     * Applies agent-specific content validation by delegating to the orchestrator.
     * This allows each orchestrator to implement its own validation rules without
     * polluting the generic ContentResponseHandler with agent-specific logic.
     *
     * @param context The orchestration context
     * @param contentResponse The content response from the LLM
     * @param logPrefix Logging prefix
     * @return String outcome from orchestrator validation, or null if no validation needed
     */
    private String applyAgentSpecificContentValidation(OrchestrationContext context, String contentResponse, String logPrefix) {
        try {
            // Load the orchestrator for this agent
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            IAgentOrchestrator orchestrator = loadOrchestrator(agentDef);

            // Use evaluateToolOutcome with a special scenario for content responses (polymorphic call - no instanceof check needed)
            // Pass an empty list since this is a content-only response (no tools)
            List<ToolCallResponseHandler.ToolExecutionResult> emptyToolResults = new List<ToolCallResponseHandler.ToolExecutionResult>();

            return orchestrator.evaluateToolOutcome(context, emptyToolResults, 'CONTENT_ONLY_RESPONSE');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in agent-specific content validation: ' + e.getMessage());
            // Fail open - don't block execution if validation itself fails
            return null;
        }
    }

    /**
     * @description
     * Loads the appropriate orchestrator for an agent definition.
     * This is a simplified version that only handles the orchestrator types we need.
     */
    private IAgentOrchestrator loadOrchestrator(AIAgentDefinition__c agentDef) {
        String agentType = agentDef.AgentType__c;

        if (String.isBlank(agentType)) {
            throw new IllegalArgumentException('AgentType__c is required on agent definition');
        }

        // Query orchestrator mapping
        List<AgentOrchestratorMapping__mdt> mappings = [
            SELECT OrchestratorClassName__c
            FROM AgentOrchestratorMapping__mdt
            WHERE AgentType__c = :agentType AND IsActive__c = TRUE
            LIMIT 1
        ];

        if (mappings.isEmpty()) {
            throw new IllegalArgumentException('No orchestrator mapping found for agent type: ' + agentType);
        }

        String orchestratorClassName = mappings[0].OrchestratorClassName__c;

        // Instantiate orchestrator
        Type orchestratorType = Type.forName(orchestratorClassName);
        if (orchestratorType == null) {
            throw new IllegalArgumentException('Orchestrator class not found: ' + orchestratorClassName);
        }

        Object instanceObj = orchestratorType.newInstance();
        if (!(instanceObj instanceof IAgentOrchestrator)) {
            throw new IllegalArgumentException('Class does not implement IAgentOrchestrator: ' + orchestratorClassName);
        }

        IAgentOrchestrator orchestrator = (IAgentOrchestrator) instanceObj;
        orchestrator.configure(agentDef);

        return orchestrator;
    }
}
