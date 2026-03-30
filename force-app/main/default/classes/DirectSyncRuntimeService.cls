/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Synchronous direct runtime for agents with 0-1 capabilities using the tool-terminating pattern.
 * Executes synchronously and returns immediately without follow-up LLM calls.
 *
 * **Key Characteristics:**
 * - **Synchronous Execution**: Completes within a single transaction
 * - **Tool-Terminating**: No follow-up LLM call after tool execution
 * - **0-1 Tools**: Supports agents with no tools or exactly one tool
 * - **Immediate Response**: Returns result directly to caller
 *
 * **Execution Flow:**
 * 1. Call LLM (no execution record yet)
 * 2. If text response: return immediately
 * 3. If tool call: execute tool, create audit trail, return tool output
 * 4. If multiple tools: ERROR (not supported in this pattern)
 *
 * **Use Cases:**
 * - Text-only responses (summarization, translation, classification)
 * - Single tool execution (create record, send email, etc.)
 *
 * This class was extracted from DirectRuntimeService to separate concerns and
 * reduce complexity in the main runtime router.
 */
public with sharing class DirectSyncRuntimeService {
    private static final String LOG_PREFIX = '[DirectSyncRuntime] ';

    private AIAgentDefinition__c agentDefinition;
    private LLMConfiguration__c llmConfig;
    private Map<String, AgentCapability__c> capabilityCache = new Map<String, AgentCapability__c>();
    private String triggerPayload;
    private String executionIdentityProfileDeveloperName;
    private String executionIdentityNamedCredential;

    public void setTriggerPayload(String value) {
        this.triggerPayload = value;
    }
    public void setExecutionIdentitySnapshot(String profileDeveloperName, String namedCredentialDeveloperName) {
        this.executionIdentityProfileDeveloperName = profileDeveloperName;
        this.executionIdentityNamedCredential = namedCredentialDeveloperName;
    }

    /**
     * @description Constructor
     * @param agentDef The agent definition
     * @param llmConfig The LLM configuration
     */
    public DirectSyncRuntimeService(AIAgentDefinition__c agentDef, LLMConfiguration__c llmConfig) {
        this.agentDefinition = agentDef;
        this.llmConfig = llmConfig;
    }

    /**
     * @description
     * Executes the tool-terminating pattern for agents with 0-1 capabilities.
     *
     * Note: Pre-existing DML detection is handled centrally by DirectRuntimeService
     * before routing to this specialized runtime.
     *
     * @param input The primary text input for the task
     * @param recordId The record context for the task (can be null)
     * @param userId The user ID
     * @param turnIdentifier The turn identifier
     * @param capabilities List of agent capabilities (passed from DirectRuntimeService)
     * @param existingExecutionId Optional execution ID to reuse (for bulk/pipeline contexts)
     * @return DirectExecutionResult containing the response or error
     */
    public DirectExecutionResult execute(
        String input,
        Id recordId,
        Id userId,
        String turnIdentifier,
        List<AgentCapability__c> capabilities,
        Id existingExecutionId
    ) {
        Long startTime = System.currentTimeMillis();
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDefinition.DeveloperName__c + ' Turn:' + turnIdentifier.left(8) + '] ';

        try {
            // --- 1. PREPARE FOR LLM CALL (NO DML) ---
            LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
            userMessageData.role = AIAgentConstants.ROLE_USER;
            userMessageData.content = input;

            // Use existing execution ID if provided, otherwise temporary ID for read-only context gathering
            Id executionIdForContext = (existingExecutionId != null) ? existingExecutionId : '000000000000AAA';

            // Buffer storyboard events before the real execution exists, then rebind later.
            IDecisionStepLogger.ILogger decisionLogger = existingExecutionId != null
                ? IDecisionStepLogger.create(executionIdForContext, turnIdentifier, userId)
                : IDecisionStepLogger.createForAgent(agentDefinition.Id, turnIdentifier, userId);

            // Get user and agent names for dynamic description
            String userName = getUserName(userId);
            String agentDisplayName = getAgentName(agentDefinition.Id); // Use actual agent name instead of developer name
            if (String.isNotBlank(input)) {
                decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ input, userName, agentDisplayName });
            }

            LLMInteractionService interactionService = new LLMInteractionService(
                executionIdForContext,
                userId,
                agentDefinition.Id,
                llmConfig.Id,
                turnIdentifier,
                1,
                recordId,
                false,
                decisionLogger
            );

            // --- 2. PERFORM LLM CALLOUT (NO DML has occurred yet) ---
            System.debug(LoggingLevel.INFO, logPrefix + 'Calling LLM via framework services...');
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(userMessageData);

            // Validate LLM result: must be successful and have either content or tool calls
            Boolean hasContent = String.isNotBlank(llmResult?.providerResult?.content);
            Boolean hasToolCalls = (llmResult?.providerResult?.requestedActions != null && !llmResult.providerResult.requestedActions.isEmpty());

            if (llmResult == null || !llmResult.isSuccess || (!hasContent && !hasToolCalls)) {
                return createFailureResult(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, llmResult?.failureReason ?? 'LLM returned an empty or failed response.');
            }

            Long processingTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'LLM call succeeded in ' + processingTime + 'ms.');

            // --- 3. CHECK FOR TOOL CALL PATTERN ---
            if (hasToolCalls) {
                // Use capabilities passed from DirectRuntimeService
                if (capabilities == null || capabilities.isEmpty()) {
                    // ERROR: 0 tools configured but LLM requested a tool
                    String requestedToolName = llmResult.providerResult.requestedActions[0].get('name');
                    System.debug(LoggingLevel.ERROR, logPrefix + 'LLM requested tool "' + requestedToolName + '" but agent has 0 capabilities configured');
                    return createFailureResult(
                        AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                        'Agent requested tool "' +
                            requestedToolName +
                            '" but no capabilities are configured for this direct agent. ' +
                            'Either add the capability to the agent definition or adjust the system prompt to prevent tool calls.'
                    );
                }

                // Single tool call - execute in tool-terminating pattern
                if (llmResult.providerResult.requestedActions.size() == 1) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Single tool call detected. Executing tool-terminating pattern.');
                    return executeSingleToolCall(
                        userId,
                        recordId,
                        input,
                        llmResult,
                        turnIdentifier,
                        processingTime,
                        decisionLogger,
                        existingExecutionId,
                        logPrefix,
                        startTime
                    );
                }

                // Multiple tool calls - not supported in tool-terminating pattern
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Multiple tool calls requested (' + llmResult.providerResult.requestedActions.size() + ') in tool-terminating pattern'
                );
                return createFailureResult(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Multiple tool calls (' +
                        llmResult.providerResult.requestedActions.size() +
                        ') are not supported in tool-terminating pattern (0-1 tools). ' +
                        'LLM should only request one tool at a time.'
                );
            } else {
                // --- 4. NO TOOL CALLS: Return LLM text response ---
                System.debug(LoggingLevel.INFO, logPrefix + 'No tool calls requested. Returning LLM text response.');

                String auditLevel = getAuditLevel();

                // Create audit trail for text response (handles existing execution ID)
                Id executionId = createAuditTrail(
                    userId,
                    recordId,
                    input,
                    llmResult,
                    turnIdentifier,
                    processingTime,
                    decisionLogger,
                    auditLevel,
                    existingExecutionId,
                    logPrefix
                );

                return createSuccessResult(llmResult.providerResult.content, executionId, llmResult.providerResult.totalTokens, processingTime);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, e.getMessage());
        }
    }

    // ===================================================================================
    // PRIVATE HELPER METHODS
    // ===================================================================================

    /**
     * Executes a single tool call in tool-terminating pattern.
     */
    private DirectExecutionResult executeSingleToolCall(
        Id userId,
        Id recordId,
        String input,
        LLMInteractionService.LLMInteractionResult llmResult,
        String turnIdentifier,
        Long processingTime,
        IDecisionStepLogger.ILogger decisionLogger,
        Id existingExecutionId,
        String logPrefix,
        Long startTime
    ) {
        // Parse tool call
        Map<String, String> toolCall = llmResult.providerResult.requestedActions[0];
        String toolCallId = toolCall.get('id');
        String toolName = toolCall.get('name');
        String toolArgs = toolCall.get('arguments');

        // Lookup capability
        AgentCapability__c capability = getCachedCapability(toolName);

        if (capability == null) {
            return createFailureResult(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Tool "' + toolName + '" is not configured for this agent.');
        }

        // Check if tool is async - not supported in sync pattern
        if (capability.RunAsynchronously__c == true) {
            return createFailureResult(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Async tool "' +
                    toolName +
                    '" is not supported in synchronous tool-terminating pattern. ' +
                    'Configure the agent with 2+ capabilities to use the iterative pattern, or make the tool synchronous.'
            );
        }

        // Execute tool synchronously (before any DML to avoid governor limits)
        ActionContext actionContext = new ActionContext(
            null, // executionId not created yet
            userId,
            userId,
            recordId,
            agentDefinition.Id,
            capability.Id,
            capability.ImplementationDetail__c,
            turnIdentifier,
            1,
            'DirectSyncRuntimeService'
        );

        Long toolStartTime = System.currentTimeMillis();
        ActionOutcome toolOutcome;

        try {
            toolOutcome = new CapabilityExecutionService().executeSingleAction(capability, toolArgs, actionContext);
        } catch (Exception toolEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Tool execution failed: ' + toolEx.getMessage());
            toolOutcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, 'Tool execution failed: ' + toolEx.getMessage());
        }

        Long toolExecutionTime = System.currentTimeMillis() - toolStartTime;
        System.debug(LoggingLevel.INFO, logPrefix + 'Tool executed in ' + toolExecutionTime + 'ms. Success: ' + toolOutcome.isSuccess);

        // Create audit trail (after all callouts, handles existing execution ID)
        String auditLevel = getAuditLevel();
        Id executionId = createAuditTrailWithTool(
            userId,
            recordId,
            input,
            llmResult,
            toolCallId,
            toolName,
            toolArgs,
            toolOutcome,
            turnIdentifier,
            processingTime,
            decisionLogger,
            auditLevel,
            existingExecutionId,
            logPrefix
        );

        // Return tool result
        if (toolOutcome.isSuccess) {
            String responseText = toolOutcome.data != null ? String.valueOf(toolOutcome.data) : 'Tool executed successfully';
            return createSuccessResult(responseText, executionId, llmResult.providerResult.totalTokens, System.currentTimeMillis() - startTime);
        } else {
            // CRITICAL: For bulk/pipeline context, ensure execution status is updated even on tool failure
            // The createAuditTrailWithTool method handles this, but we need to ensure it's called with the right context
            if (existingExecutionId != null && executionId == null) {
                // Edge case: if audit trail creation was skipped but we have existing execution, we must fail it
                System.debug(LoggingLevel.ERROR, logPrefix + 'Tool failed in bulk context - ensuring execution is marked as failed');
                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.failTurn(existingExecutionId, turnIdentifier, toolOutcome.errorMessage, toolOutcome.errorCode, logPrefix);
            }
            return createFailureResult(toolOutcome.errorCode, toolOutcome.errorMessage);
        }
    }

    /**
     * Creates audit trail for text-only responses.
     */
    private Id createAuditTrail(
        Id userId,
        Id recordId,
        String input,
        LLMInteractionService.LLMInteractionResult llmResult,
        String turnIdentifier,
        Long processingTime,
        IDecisionStepLogger.ILogger decisionLogger,
        String auditLevel,
        Id existingExecutionId,
        String logPrefix
    ) {
        Id executionId;
        Boolean shouldCreateSteps = (auditLevel != 'None');

        if (existingExecutionId != null) {
            // BULK/PIPELINE CONTEXT: Use existing execution record
            executionId = existingExecutionId;
            System.debug(LoggingLevel.INFO, logPrefix + 'Using existing execution record: ' + executionId);

            // Update decision logger with real execution ID
            decisionLogger.updateExecutionId(executionId);
        } else {
            // STANDALONE CONTEXT: Create new execution record (only if audit level allows)
            if (shouldCreateSteps) {
                AgentStateService execSvc = new AgentStateService();
                String executionLabel = 'Function - ' + Datetime.now().format('MM/dd HH:mm:ss');
                String execTriggerPayload = String.isNotBlank(this.triggerPayload) ? this.triggerPayload : 'Sync Function: ' + executionLabel;
                executionId = execSvc.createExecution(
                    RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                    agentDefinition.Id,
                    'API',
                    execTriggerPayload,
                    recordId,
                    userId,
                    null,
                    null,
                    null,
                    this.executionIdentityProfileDeveloperName,
                    this.executionIdentityNamedCredential
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'Created new execution record: ' + executionId);

                if (String.isNotBlank(turnIdentifier)) {
                    update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = turnIdentifier);
                }

                // Update decision logger with real execution ID
                decisionLogger.updateExecutionId(executionId);
            } else {
                // No audit trail and no existing execution - return null
                return null;
            }
        }

        // Create execution steps only if audit level allows
        if (shouldCreateSteps) {
            ExecutionStepService stepSvc = new ExecutionStepService();

            // User input step
            stepSvc.createUserInputStep(executionId, input, turnIdentifier, 1);

            // LLM response step
            Id responseStepId = stepSvc.createAgentResponseStep(executionId, llmResult.providerResult.content, turnIdentifier, 1);

            decisionLogger.commitSteps();

            // Complete execution - CRITICAL for bulk/pipeline chaining
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.completeTurnSuccessfully(executionId, turnIdentifier, responseStepId, logPrefix);
        } else if (existingExecutionId != null) {
            // CRITICAL: Even with no audit trail, we must complete the execution for bulk chaining
            System.debug(LoggingLevel.INFO, logPrefix + 'No audit trail (AuditLevel=None) but completing execution for bulk chaining');

            // Create minimal response step for completion
            ExecutionStepService stepSvc = new ExecutionStepService();
            Id responseStepId = stepSvc.createAgentResponseStep(executionId, llmResult.providerResult.content, turnIdentifier, 1);

            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.completeTurnSuccessfully(executionId, turnIdentifier, responseStepId, logPrefix);
        }

        if (existingExecutionId != null) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Marked existing execution as completed - trigger will handle chaining');
        }

        return executionId;
    }

    /**
     * Creates audit trail for tool execution responses.
     */
    private Id createAuditTrailWithTool(
        Id userId,
        Id recordId,
        String input,
        LLMInteractionService.LLMInteractionResult llmResult,
        String toolCallId,
        String toolName,
        String toolArgs,
        ActionOutcome toolOutcome,
        String turnIdentifier,
        Long processingTime,
        IDecisionStepLogger.ILogger decisionLogger,
        String auditLevel,
        Id existingExecutionId,
        String logPrefix
    ) {
        Id executionId;
        Boolean shouldCreateSteps = (auditLevel != 'None');

        if (existingExecutionId != null) {
            // BULK/PIPELINE CONTEXT: Use existing execution record
            executionId = existingExecutionId;
            System.debug(LoggingLevel.INFO, logPrefix + 'Using existing execution record: ' + executionId);

            // Update decision logger with real execution ID
            decisionLogger.updateExecutionId(executionId);
        } else {
            // STANDALONE CONTEXT: Create new execution record (only if audit level allows)
            if (shouldCreateSteps) {
                AgentStateService execSvc = new AgentStateService();
                String executionLabel = 'Function - ' + Datetime.now().format('MM/dd HH:mm:ss');
                String execTriggerPayload = String.isNotBlank(this.triggerPayload) ? this.triggerPayload : 'Sync Function: ' + executionLabel;
                executionId = execSvc.createExecution(
                    RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                    agentDefinition.Id,
                    'API',
                    execTriggerPayload,
                    recordId,
                    userId,
                    null,
                    null,
                    null,
                    this.executionIdentityProfileDeveloperName,
                    this.executionIdentityNamedCredential
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'Created new execution record: ' + executionId);

                if (String.isNotBlank(turnIdentifier)) {
                    update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = turnIdentifier);
                }

                // Update decision logger with real execution ID
                decisionLogger.updateExecutionId(executionId);
            } else {
                // No audit trail and no existing execution - return null
                return null;
            }
        }

        // Create execution steps only if audit level allows
        if (shouldCreateSteps) {
            ExecutionStepService stepSvc = new ExecutionStepService();

            // User input step
            stepSvc.createUserInputStep(executionId, input, turnIdentifier, 1);

            // Tool call step
            AgentCapability__c capability = getCachedCapability(toolName);
            stepSvc.createToolCallStep(
                executionId,
                toolCallId,
                toolName,
                toolArgs,
                turnIdentifier,
                1,
                null,
                null,
                null,
                null,
                null,
                capability?.Id,
                null,
                null,
                null,
                false
            );

            // Tool result step
            String toolResultJson = OrchestrationService.serializeActionOutcome(toolOutcome, logPrefix);
            stepSvc.createToolResultStep(
                executionId,
                toolCallId,
                toolName,
                toolResultJson,
                turnIdentifier,
                1,
                0L,
                false,
                capability?.Id,
                !toolOutcome.isSuccess,
                false
            );

            // Log tool result to decision logger for storyboard display
            Long toolExecutionTime = 0L; // Already captured in tool execution timing above
            decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, toolOutcome, toolExecutionTime });

            decisionLogger.commitSteps();
        }

        // Complete or fail execution based on tool outcome - CRITICAL for bulk/pipeline chaining
        AgentStateService agentStateSvc = new AgentStateService();
        if (toolOutcome.isSuccess) {
            // Create response step (minimal if no audit trail)
            ExecutionStepService stepSvc = new ExecutionStepService();
            Id responseStepId = stepSvc.createAgentResponseStep(
                executionId,
                toolOutcome.data != null ? String.valueOf(toolOutcome.data) : 'Tool executed successfully',
                turnIdentifier,
                1
            );

            agentStateSvc.completeTurnSuccessfully(executionId, turnIdentifier, responseStepId, logPrefix);

            if (existingExecutionId != null) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Marked existing execution as completed - trigger will handle chaining');
            }
        } else {
            // Tool failed - fail the execution regardless of context or audit level
            agentStateSvc.failTurn(executionId, turnIdentifier, toolOutcome.errorMessage, toolOutcome.errorCode, logPrefix);

            if (existingExecutionId != null) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Marked existing execution as failed - trigger will handle chaining');
            }
        }

        return executionId;
    }

    private AgentCapability__c getCachedCapability(String toolName) {
        if (String.isBlank(toolName)) {
            return null;
        }
        String key = toolName.toLowerCase();
        if (!capabilityCache.containsKey(key)) {
            capabilityCache.put(key, AIAgentConfigService.getCapability(agentDefinition.Id, toolName));
        }
        return capabilityCache.get(key);
    }

    private String getAuditLevel() {
        return String.isNotBlank(agentDefinition.AuditLevel__c) ? agentDefinition.AuditLevel__c : 'Standard';
    }

    /**
     * Creates a success result.
     */
    private DirectExecutionResult createSuccessResult(String response, Id executionId, Integer tokensUsed, Long processingTime) {
        DirectExecutionResult result = new DirectExecutionResult();
        result.success = true;
        result.response = response;
        result.executionId = executionId;
        result.status = 'Completed';
        result.requiresPolling = false;
        result.tokensUsed = tokensUsed;
        result.processingTimeMs = processingTime;
        return result;
    }

    /**
     * Creates a failure result.
     */
    private DirectExecutionResult createFailureResult(String errorCode, String errorMessage) {
        DirectExecutionResult result = new DirectExecutionResult();
        result.success = false;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.status = 'Failed';
        result.requiresPolling = false;
        return result;
    }

    /**
     * Helper method to get user name for dynamic descriptions
     *
     * @param userId The user ID
     * @return User name or fallback
     */
    private String getUserName(Id userId) {
        try {
            if (userId != null) {
                User user = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
                return user.Name;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not retrieve user name for ID: ' + userId + '. Error: ' + e.getMessage());
        }
        return 'User';
    }

    /**
     * Helper method to get agent name for dynamic descriptions
     *
     * @param agentDefinitionId The agent definition ID
     * @return Agent name or fallback
     */
    private String getAgentName(Id agentDefinitionId) {
        return AIAgentConfigService.getAgentName(agentDefinitionId);
    }
}
