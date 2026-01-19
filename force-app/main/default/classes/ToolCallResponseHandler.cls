/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Orchestrates the full lifecycle of tool call requests from LLM responses. Handles validation, approval, and execution paths.
 */
public class ToolCallResponseHandler implements ILLMResponseHandler {
    public class ToolProcessingException extends AIAgentException {
    }

    public class ToolCallRequest {
        public String toolCallId;
        public String toolName;
        public String toolArguments;
        public AgentCapability__c capability;
        public Boolean isAsync;
        public String hitlMode;
        public Integer executionOrder;
        public String rationale;

        public ToolCallRequest(String toolCallId, String toolName, String toolArguments, AgentCapability__c capability, Integer executionOrder) {
            this(toolCallId, toolName, toolArguments, capability, executionOrder, null);
        }

        public ToolCallRequest(
            String toolCallId,
            String toolName,
            String toolArguments,
            AgentCapability__c capability,
            Integer executionOrder,
            String rationale
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.toolArguments = toolArguments;
            this.capability = capability;
            this.isAsync = capability.RunAsynchronously__c == true;
            this.executionOrder = executionOrder;
            this.rationale = rationale;

            this.hitlMode = String.isNotBlank(capability.HITLMode__c) ? capability.HITLMode__c : null;

            if (this.isAsync && this.hitlMode == HITLGatewayService.HITL_MODE_CONFIRMATION) {
                throw new ToolProcessingException(
                    'Configuration error: Capability "' +
                        capability.CapabilityName__c +
                        '" has HITLMode=Confirmation with RunAsynchronously=true. ' +
                        'Confirmation mode requires synchronous user interaction. ' +
                        'Use HITLMode=Approval for async tools requiring human oversight.'
                );
            }

            if (this.isAsync && this.hitlMode == HITLGatewayService.HITL_MODE_APPROVAL) {
                throw new ToolProcessingException(
                    'Configuration error: Capability "' +
                        capability.CapabilityName__c +
                        '" has HITLMode=Approval with RunAsynchronously=true. ' +
                        'Approval mode requires synchronous processing. ' +
                        'Async tools cannot require human approval.'
                );
            }
        }
    }

    public class ToolExecutionResult {
        public String toolCallId;
        public String toolName;
        public ActionOutcome outcome;
        public Long processingTime;
        public Boolean isAsync;
        public Integer executionOrder;
        public Id capabilityId;

        public ToolExecutionResult(
            String toolCallId,
            String toolName,
            ActionOutcome outcome,
            Long processingTime,
            Boolean isAsync,
            Integer executionOrder,
            Id capabilityId
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.outcome = outcome;
            this.processingTime = processingTime;
            this.isAsync = isAsync;
            this.executionOrder = executionOrder;
            this.capabilityId = capabilityId;
        }
    }

    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';
        List<Map<String, String>> requestedActions = context.llmResult.providerResult.requestedActions;

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting unified tool call handling for ' + requestedActions.size() + ' tool(s).');

        IDecisionStepLogger.ILogger decisionLogger = context.decisionLogger;

        try {
            List<ToolCallRequest> toolRequests = parseAndValidateToolCalls(context, requestedActions, decisionLogger, logPrefix);

            if (toolRequests.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'No valid tool calls found after parsing');
                context.agentStateSvc.failTurn(
                    context.executionId,
                    context.turnIdentifier,
                    'No valid tool calls found in LLM response',
                    AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_FAILED;
            }

            Map<String, List<ToolCallRequest>> toolGroups = groupToolsByExecutionMode(toolRequests);
            List<ToolCallRequest> approvalTools = toolGroups.get('approval');
            List<ToolCallRequest> confirmationTools = toolGroups.get('confirmation');
            List<ToolCallRequest> syncTools = toolGroups.get('sync');
            List<ToolCallRequest> asyncTools = toolGroups.get('async');

            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Tool execution plan - Approval: ' +
                    approvalTools.size() +
                    ', Confirmation: ' +
                    confirmationTools.size() +
                    ', Sync: ' +
                    syncTools.size() +
                    ', Async: ' +
                    asyncTools.size()
            );

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

            Id savedAssistantMessageId = null;
            LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;
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

                try {
                    TransientMessage__e event = new TransientMessage__e(
                        AgentExecutionId__c = context.executionId,
                        MessageId__c = savedAssistantMessageId,
                        MessageContent__c = assistantData.content
                    );
                    EventBus.publish(event);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to publish TransientMessage__e for UI.');
                }
            }

            createToolCallExecutionSteps(context, toolRequests, decisionLogger, logPrefix);

            // IMPORTANT: Execute sync tools FIRST, even if there are approval tools.
            // This ensures non-HITL tools complete their execution before we pause for approval.
            // When HITL resumes, all tool results (sync + HITL) will be aggregated and sent to LLM.
            List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();
            if (!syncTools.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' sync tool(s) before handling approval tools');
                syncResults = executeSynchronousTools(context, syncTools, decisionLogger, logPrefix);
                createToolResultExecutionSteps(context, syncResults, decisionLogger, logPrefix);
            }

            // Queue async tools (they'll run independently)
            if (!asyncTools.isEmpty()) {
                queueAsyncTools(context, asyncTools, decisionLogger, logPrefix);
            }

            // Now handle approval tools - pause execution until approved
            // The sync tool results are already persisted in ExecutionStep__c records
            // and will be retrieved when HITL resumes to aggregate all results for LLM
            if (!approvalTools.isEmpty()) {
                return handleApprovalRequiredTools(
                    context,
                    savedUserMessageId,
                    savedAssistantMessageId,
                    assistantData,
                    approvalTools,
                    logPrefix,
                    decisionLogger
                );
            }

            return determineNextOrchestrationStep(context, syncResults, asyncTools, logPrefix);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in tool call handling: ' + e.getMessage() + '\n' + e.getStackTraceString());
            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Tool call handling failed: ' + e.getMessage(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }
    }

    private List<ToolCallRequest> parseAndValidateToolCalls(
        OrchestrationContext context,
        List<Map<String, String>> requestedActions,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        List<ToolCallRequest> toolRequests = new List<ToolCallRequest>();

        for (Integer i = 0; i < requestedActions.size(); i++) {
            Map<String, String> actionMap = requestedActions[i];

            try {
                String toolCallId = actionMap.get('id');
                String toolName = actionMap.get('name');
                String toolArguments = actionMap.get('arguments');

                if (String.isBlank(toolCallId) || String.isBlank(toolName)) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping malformed tool call at index ' + i + ': missing id or name');
                    continue;
                }

                AgentCapability__c capability = AIAgentConfigService.getCapability(context.agentDefinitionId, toolName);
                if (capability == null) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping tool call ' + toolName + ': capability not found');
                    continue;
                }

                String extractedRationale = null;
                String cleanedArguments = toolArguments;

                Map<String, String> rationaleResult = LLMFormattingService.extractAndStripRationale(toolArguments, logPrefix);
                extractedRationale = rationaleResult.get('rationale');
                cleanedArguments = rationaleResult.get('cleanedArguments');

                if (String.isNotBlank(extractedRationale)) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Extracted rationale for tool ' +
                            toolName +
                            ': ' +
                            extractedRationale.left(100) +
                            (extractedRationale.length() > 100 ? '...' : '')
                    );
                }

                ToolCallRequest toolRequest = new ToolCallRequest(toolCallId, toolName, cleanedArguments, capability, i + 1, extractedRationale);
                toolRequests.add(toolRequest);

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        'Parsed tool ' +
                        (i + 1) +
                        ': ' +
                        toolName +
                        ' (async=' +
                        toolRequest.isAsync +
                        ', hitlMode=' +
                        toolRequest.hitlMode +
                        ', hasRationale=' +
                        String.isNotBlank(extractedRationale) +
                        ')'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error parsing tool call at index ' + i + ': ' + e.getMessage());
                continue;
            }
        }

        // Log the tool execution plan
        if (decisionLogger != null && !toolRequests.isEmpty()) {
            // Count tools by type using the already-grouped data
            Map<String, List<ToolCallRequest>> groups = groupToolsByExecutionMode(toolRequests);

            Map<String, Object> planData = new Map<String, Object>{
                'totalTools' => toolRequests.size(),
                'syncTools' => groups.get('sync').size(),
                'asyncTools' => groups.get('async').size(),
                'approvalTools' => groups.get('approval').size(),
                'confirmationTools' => groups.get('confirmation').size(),
                'tools' => new List<Map<String, Object>>()
            };

            for (ToolCallRequest req : toolRequests) {
                ((List<Map<String, Object>>) planData.get('tools'))
                    .add(
                        new Map<String, Object>{
                            'name' => req.toolName,
                            'id' => req.toolCallId,
                            'isAsync' => req.isAsync,
                            'hitlMode' => req.hitlMode,
                            'order' => req.executionOrder,
                            'hasRationale' => String.isNotBlank(req.rationale)
                        }
                    );
            }

            // Note: Tool Execution Plan step removed - not needed in storyboard
            // decisionLogger.logToolExecution(
            //     'Tool Execution Plan',
            //     'LLM requested ' + toolRequests.size() + ' tool(s) for execution',
            //     JSON.serialize(planData),
            //     null,
            //     true,
            //     null,
            //     null
            // );
        }

        return toolRequests;
    }

    // TOOL GROUPING

    /**
     * Groups tool requests by execution mode in a single pass for efficiency.
     * Returns a map with keys: 'approval', 'confirmation', 'sync', 'async'
     *
     * HITL modes are prioritized:
     * - Approval: Formal Salesforce approval process (all agent types)
     * - Confirmation: In-chat yes/no confirmation (conversational only)
     * - Sync: Synchronous execution (no HITL)
     * - Async: Asynchronous execution (no HITL)
     *
     * Note: Confirmation mode (LLM-based conversational confirmation) does NOT require system intervention.
     * The LLM handles confirmation via prompt injection. Only Approval and ConfirmationThenApproval
     * require system intervention.
     */
    private Map<String, List<ToolCallRequest>> groupToolsByExecutionMode(List<ToolCallRequest> toolRequests) {
        Map<String, List<ToolCallRequest>> groups = new Map<String, List<ToolCallRequest>>{
            'approval' => new List<ToolCallRequest>(),
            'confirmation' => new List<ToolCallRequest>(),
            'sync' => new List<ToolCallRequest>(),
            'async' => new List<ToolCallRequest>()
        };

        for (ToolCallRequest tool : toolRequests) {
            // Check for ConditionalApproval mode first - LLM decides if approval is needed
            if (tool.hitlMode == HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL) {
                Boolean requiresApproval = checkLLMApprovalRequest(tool);
                if (requiresApproval) {
                    // LLM determined approval is needed
                    groups.get('approval').add(tool);
                } else {
                    // LLM did not request approval - proceed normally
                    if (tool.isAsync) {
                        groups.get('async').add(tool);
                    } else {
                        groups.get('sync').add(tool);
                    }
                }
            }
            // Approval mode requires formal Salesforce approval process
            else if (tool.hitlMode == HITLGatewayService.HITL_MODE_APPROVAL) {
                groups.get('approval').add(tool);
            }
            // ConfirmationThenApproval mode - LLM already confirmed, now needs approval
            else if (tool.hitlMode == HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                groups.get('approval').add(tool);
            }
            // Confirmation mode - NO system intervention needed, LLM handles via prompt injection
            // These tools execute normally (sync or async based on their config)
            else if (tool.hitlMode == HITLGatewayService.HITL_MODE_CONFIRMATION) {
                // Confirmation mode tools go to sync/async based on their RunAsynchronously setting
                if (tool.isAsync) {
                    groups.get('async').add(tool);
                } else {
                    groups.get('sync').add(tool);
                }
            } else if (tool.isAsync) {
                groups.get('async').add(tool);
            } else {
                groups.get('sync').add(tool);
            }
        }

        return groups;
    }

    /**
     * Checks if LLM requested approval via _requiresApproval parameter
     * Used for ConditionalApproval HITL mode
     * @param tool The tool call request to check
     * @return true if _requiresApproval=true, false otherwise
     */
    private static Boolean checkLLMApprovalRequest(ToolCallRequest tool) {
        if (String.isBlank(tool.toolArguments)) {
            return false;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(tool.toolArguments);

            if (!args.containsKey('_requiresApproval')) {
                return false;
            }

            Object requiresApproval = args.get('_requiresApproval');

            // Handle boolean
            if (requiresApproval instanceof Boolean) {
                return (Boolean) requiresApproval;
            }

            // Handle string "true"/"false"
            if (requiresApproval instanceof String) {
                String strValue = ((String) requiresApproval).toLowerCase();
                return strValue == 'true' || strValue == '1' || strValue == 'yes';
            }

            return false;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                '[ToolCallResponseHandler] ' + 'Error parsing _requiresApproval for tool "' + tool.toolName + '": ' + e.getMessage()
            );
            // Fail-safe: if we can't parse, don't require approval
            return false;
        }
    }

    /**
     * Extracts approval reason from tool arguments
     * Used for ConditionalApproval HITL mode to get LLM's reasoning
     * @param tool The tool call request
     * @return The approval reason string, or null if not present
     */
    private static String extractApprovalReason(ToolCallRequest tool) {
        if (String.isBlank(tool.toolArguments)) {
            return null;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(tool.toolArguments);

            if (args.containsKey('_approvalReason')) {
                return String.valueOf(args.get('_approvalReason'));
            }

            return null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ToolCallResponseHandler] ' + 'Error extracting _approvalReason: ' + e.getMessage());
            return null;
        }
    }

    // EXECUTION STEP CREATION

    /**
     * Creates execution step records for all tool calls
     */
    private void createToolCallExecutionSteps(
        OrchestrationContext context,
        List<ToolCallRequest> toolRequests,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        ExecutionStepService executionStepService = new ExecutionStepService();

        for (ToolCallRequest toolRequest : toolRequests) {
            try {
                executionStepService.createToolCallStep(
                    context.executionId,
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    toolRequest.toolArguments,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    context.llmResult.providerResult.promptTokens,
                    context.llmResult.providerResult.completionTokens,
                    context.llmResult.providerResult.totalTokens,
                    context.llmResult.providerResult.modelIdentifier,
                    context.llmResult.providerResult.llmCalloutDurationMs,
                    toolRequest.capability.Id,
                    toolRequest.rationale
                );

                // Note: Tool Execution decision step logging removed
                // The LLM Response step already shows tool calls with arguments
                // Only Tool Result steps are logged to show the outcome

                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix +
                        'Created execution step for tool call: ' +
                        toolRequest.toolName +
                        ' (hasRationale=' +
                        String.isNotBlank(toolRequest.rationale) +
                        ')'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution step for tool ' + toolRequest.toolName + ': ' + e.getMessage());
            }
        }
    }

    // APPROVAL HANDLING

    /**
     * Handles tools that require human approval via Salesforce Approval Process.
     * This includes both HITLMode = 'Approval' and HITLMode = 'ConfirmationThenApproval'.
     * Uses the HITLGatewayService for centralized HITL management.
     *
     * @param context OrchestrationContext
     * @param savedUserMessageId ID of saved user message
     * @param savedAssistantMessageId ID of saved assistant message
     * @param assistantData Assistant message data
     * @param approvalTools List of tools requiring approval
     * @param logPrefix Logging prefix
     * @param decisionLogger Decision step logger
     * @return Outcome constant
     */
    private String handleApprovalRequiredTools(
        OrchestrationContext context,
        Id savedUserMessageId,
        Id savedAssistantMessageId,
        LLMInteractionService.MessageData assistantData,
        List<ToolCallRequest> approvalTools,
        String logPrefix,
        IDecisionStepLogger.ILogger decisionLogger
    ) {
        // Handle first approval tool (could be enhanced to handle multiple)
        ToolCallRequest approvalTool = approvalTools[0];

        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Tool "' + approvalTool.toolName + '" requires approval. Creating approval request via HITLGatewayService.'
        );

        // Load agent definition for HITL context
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);

        // Build HITL context
        HITLGatewayService.HITLContext hitlContext = new HITLGatewayService.HITLContext();
        hitlContext.capability = approvalTool.capability;
        hitlContext.agentDefinition = agentDef;
        hitlContext.executionId = context.executionId;
        hitlContext.requestingUserId = context.originalUserId;
        hitlContext.turnIdentifier = context.turnIdentifier;
        hitlContext.turnCount = context.currentTurnCount;
        hitlContext.toolCallId = approvalTool.toolCallId;
        hitlContext.toolArguments = approvalTool.toolArguments;
        hitlContext.sourceRecordId = context.currentPageRecordId;
        hitlContext.logPrefix = logPrefix;

        // Add conditional approval context
        hitlContext.isConditionalApproval = (approvalTool.hitlMode == HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL);
        if (hitlContext.isConditionalApproval) {
            hitlContext.llmApprovalReason = extractApprovalReason(approvalTool);
        }

        // Evaluate HITL requirement
        // For ConditionalApproval mode, LLM already decided via _requiresApproval parameter
        // So we create an Approval decision directly without calling evaluate()
        HITLGatewayService.HITLDecision decision;
        if (hitlContext.isConditionalApproval) {
            // LLM decided approval is needed - create intervention decision
            decision = HITLGatewayService.createInterventionDecision(HITLGatewayService.HITL_MODE_APPROVAL);
        } else {
            // Standard Approval or ConfirmationThenApproval - evaluate normally
            decision = HITLGatewayService.evaluate(hitlContext);
        }

        if (!decision.isValidConfiguration) {
            // Configuration error - fail the turn
            String errMsg = 'HITL configuration error: ' + decision.configurationError;
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, errMsg, AIAgentConstants.ERR_CODE_CONFIG_ERROR, logPrefix);
            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ decision, approvalTool });
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Initiate the approval workflow FIRST to get pendingActionId
        HITLGatewayService.HITLResult hitlResult = HITLGatewayService.initiateHITL(hitlContext, decision);

        if (!hitlResult.success) {
            String errMsg = 'Failed to initiate approval: ' + hitlResult.errorMessage;
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, errMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ hitlResult, approvalTool });
            return OrchestrationService.OUTCOME_FAILED;
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Approval request created: ' + hitlResult.pendingActionId);

        decisionLogger.log(IDecisionStepLogger.EventType.APPROVAL_REQUESTED, new List<Object>{ approvalTool, decision, hitlResult });

        // Create placeholder tool result immediately to maintain proper OpenAI message sequence
        String placeholderResult = JSON.serialize(
            new Map<String, Object>{
                'status' => 'pending_approval',
                'message' => 'This action is pending approval. It will be executed once approved.',
                'pendingActionId' => hitlResult.pendingActionId,
                'toolName' => approvalTool.toolName
            }
        );

        ExecutionStepService executionStepService = new ExecutionStepService();
        executionStepService.createToolResultStep(
            context.executionId,
            approvalTool.toolCallId,
            approvalTool.capability.CapabilityName__c,
            placeholderResult,
            context.turnIdentifier,
            context.currentTurnCount,
            0L,
            false,
            approvalTool.capability.Id
        );

        // Publish approval request event to UI via TransientMessage__e
        try {
            TransientMessage__e approvalEvent = new TransientMessage__e(
                AgentExecutionId__c = context.executionId,
                MessageId__c = String.valueOf(hitlResult.pendingActionId),
                MessageContent__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'ApprovalRequest',
                        'pendingActionId' => hitlResult.pendingActionId,
                        'toolName' => approvalTool.toolName,
                        'approvalPrompt' => hitlResult.confirmationPrompt
                    }
                )
            );
            EventBus.publish(approvalEvent);
            System.debug(LoggingLevel.INFO, logPrefix + 'Published approval request event to UI');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to publish approval event: ' + e.getMessage());
        }

        // Delegate agent-specific behavior to orchestrator
        // This keeps ToolCallResponseHandler agent-agnostic
        IAgentOrchestrator orchestrator = loadOrchestrator(agentDef);

        // Build tool execution result for the orchestrator
        List<ToolExecutionResult> approvalToolResults = new List<ToolExecutionResult>();
        approvalToolResults.add(
            new ToolExecutionResult(
                approvalTool.toolCallId,
                approvalTool.toolName,
                null, // No outcome yet - pending approval
                0L,
                false,
                approvalTool.executionOrder,
                approvalTool.capability.Id
            )
        );

        // Let orchestrator handle agent-specific completion behavior (polymorphic call - no instanceof check needed)
        String orchestratorOutcome = orchestrator.evaluateToolOutcome(context, approvalToolResults, 'APPROVAL_REQUIRED');

        if (orchestratorOutcome != null) {
            // Orchestrator handled it
            return orchestratorOutcome;
        }

        // Default behavior for orchestrators that don't override handleToolCompletion
        // (Function/Workflow agents): just pause execution until approval resolved
        context.agentStateSvc.updateStatus(
            context.executionId,
            'Awaiting Action',
            AIAgentConstants.STATUS_AWAITING_ACTION,
            context.turnIdentifier,
            'Awaiting human approval'
        );

        return OrchestrationService.OUTCOME_QUEUED_ACTION;
    }

    /**
     * Loads the appropriate orchestrator for an agent definition.
     */
    private IAgentOrchestrator loadOrchestrator(AIAgentDefinition__c agentDef) {
        String agentType = agentDef.AgentType__c;

        if (String.isBlank(agentType)) {
            throw new ToolProcessingException('AgentType__c is required on agent definition');
        }

        // Query orchestrator mapping
        List<AgentOrchestratorMapping__mdt> mappings = [
            SELECT OrchestratorClassName__c
            FROM AgentOrchestratorMapping__mdt
            WHERE AgentType__c = :agentType AND IsActive__c = TRUE
            LIMIT 1
        ];

        if (mappings.isEmpty()) {
            throw new ToolProcessingException('No orchestrator mapping found for agent type: ' + agentType);
        }

        String orchestratorClassName = mappings[0].OrchestratorClassName__c;

        // Instantiate orchestrator
        Type orchestratorType = Type.forName(orchestratorClassName);
        if (orchestratorType == null) {
            throw new ToolProcessingException('Orchestrator class not found: ' + orchestratorClassName);
        }

        Object instanceObj = orchestratorType.newInstance();
        if (!(instanceObj instanceof IAgentOrchestrator)) {
            throw new ToolProcessingException('Class does not implement IAgentOrchestrator: ' + orchestratorClassName);
        }

        IAgentOrchestrator orchestrator = (IAgentOrchestrator) instanceObj;
        orchestrator.configure(agentDef);

        return orchestrator;
    }

    // SYNCHRONOUS EXECUTION

    /**
     * Executes all synchronous tools immediately in the same transaction
     */
    private List<ToolExecutionResult> executeSynchronousTools(
        OrchestrationContext context,
        List<ToolCallRequest> syncTools,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' synchronous tool(s)');

        for (ToolCallRequest toolRequest : syncTools) {
            try {
                Long startTime = System.currentTimeMillis();

                // Multi-LLM optimization: Capture Limits before tool execution
                // This allows us to detect if the tool performed DML or callouts
                TransactionContext.getInstance().capturePreToolLimits();

                // Build action execution context
                ActionContext actionContext = new ActionContext(
                    context.executionId,
                    context.originalUserId,
                    context.executionUserId,
                    context.currentPageRecordId,
                    context.agentDefinitionId,
                    toolRequest.capability.Id,
                    toolRequest.capability.ImplementationDetail__c,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    'SyncTool'
                );

                // Execute the tool
                ActionOutcome outcome = context.actionExecSvc.executeSingleAction(toolRequest.capability, toolRequest.toolArguments, actionContext);

                Long processingTime = System.currentTimeMillis() - startTime;

                ToolExecutionResult result = new ToolExecutionResult(
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    outcome,
                    processingTime,
                    false,
                    toolRequest.executionOrder,
                    toolRequest.capability.Id
                );

                syncResults.add(result);

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Executed sync tool ' + toolRequest.toolName + ' in ' + processingTime + 'ms (success=' + outcome.isSuccess + ')'
                );

                if (decisionLogger != null) {
                    decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ toolRequest, outcome, processingTime });
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error executing sync tool ' + toolRequest.toolName + ': ' + e.getMessage());

                ActionOutcome failureOutcome = ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    'Synchronous tool execution failed: ' + e.getMessage()
                );

                ToolExecutionResult failureResult = new ToolExecutionResult(
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    failureOutcome,
                    0L,
                    false,
                    toolRequest.executionOrder,
                    toolRequest.capability.Id
                );

                syncResults.add(failureResult);
            }
        }

        return syncResults;
    }

    /**
     * Creates execution step records for synchronous tool results
     */
    private void createToolResultExecutionSteps(
        OrchestrationContext context,
        List<ToolExecutionResult> syncResults,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        ExecutionStepService executionStepService = new ExecutionStepService();

        for (ToolExecutionResult result : syncResults) {
            try {
                String resultJsonForStorage = OrchestrationService.serializeActionOutcome(result.outcome, logPrefix);

                executionStepService.createToolResultStep(
                    context.executionId,
                    result.toolCallId,
                    result.toolName,
                    resultJsonForStorage,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    result.processingTime,
                    false,
                    result.capabilityId,
                    !result.outcome.isSuccess // isError = !isSuccess
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution step for sync tool result ' + result.toolName + ': ' + e.getMessage());
            }
        }
    }

    // ASYNCHRONOUS EXECUTION

    /**
     * Queues asynchronous tools for separate transaction execution.
     * Initializes atomic tracking counter before queuing to enable race-condition-free completion detection.
     * Handles queue failures by decrementing the counter to prevent execution hangs.
     */
    private void queueAsyncTools(OrchestrationContext context, List<ToolCallRequest> asyncTools, IDecisionStepLogger.ILogger decisionLogger, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Queuing ' + asyncTools.size() + ' asynchronous tool(s)');

        // Track successfully queued tools to handle partial failures
        Integer successfullyQueued = 0;
        List<String> failedTools = new List<String>();
        List<String> failureReasons = new List<String>(); // Collect actual error messages

        // Initialize async tool tracking and pause for async action processing in a single DML operation
        // This reduces DML operations from 2 to 1 by batching the updates
        context.agentStateSvc.pauseForAsyncActionWithTracking(context.executionId, context.turnIdentifier, asyncTools.size(), 'Async Tools', logPrefix);

        // Queue each async tool individually
        for (ToolCallRequest toolRequest : asyncTools) {
            try {
                context.dispatchSvc.enqueueAsyncAction(
                    context.executionId,
                    context.originalUserId,
                    context.agentDefinitionId,
                    null, // savedAssistantMessageId - not needed
                    toolRequest.toolCallId,
                    toolRequest.toolArguments,
                    toolRequest.capability,
                    context.currentPageRecordId,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    logPrefix
                );

                successfullyQueued++;
                System.debug(LoggingLevel.INFO, logPrefix + 'Queued async tool: ' + toolRequest.toolName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue async tool ' + toolRequest.toolName + ': ' + e.getMessage());
                failedTools.add(toolRequest.toolName);

                // Capture the actual error message - check for root cause
                String actualErrorMessage = e.getMessage();
                if (e.getCause() != null && String.isNotBlank(e.getCause().getMessage())) {
                    actualErrorMessage = e.getCause().getMessage();
                }
                failureReasons.add(actualErrorMessage);

                // Decrement the counter for this failed queue to prevent execution hang
                // This ensures the counter accurately reflects only successfully queued tools
                try {
                    OrchestrationService.decrementAsyncToolCounter(
                        context.executionId,
                        context.turnIdentifier,
                        context.currentTurnCount,
                        toolRequest.toolCallId,
                        logPrefix + '[QueueFailureRecovery] '
                    );
                } catch (Exception decrementEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to decrement counter after queue failure: ' + decrementEx.getMessage());
                }

                // Create a failure tool result so LLM knows this tool failed to execute
                try {
                    ExecutionStepService executionStepService = new ExecutionStepService();
                    String failureResult = JSON.serialize(
                        new Map<String, Object>{
                            'isSuccess' => false,
                            'errorCode' => AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                            'messageForUser' => 'Failed to queue async tool for execution: ' + e.getMessage()
                        }
                    );
                    executionStepService.createToolResultStep(
                        context.executionId,
                        toolRequest.toolCallId,
                        toolRequest.toolName,
                        failureResult,
                        context.turnIdentifier,
                        context.currentTurnCount,
                        0L,
                        true, // isAsyncToolExecution
                        toolRequest.capability.Id,
                        true // isError - this is a failure
                    );
                } catch (Exception stepEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create error step for failed queue: ' + stepEx.getMessage());
                }
            }
        }

        // Log summary of queue operation
        if (!failedTools.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    'Async tool queuing completed with failures. Queued: ' +
                    successfullyQueued +
                    '/' +
                    asyncTools.size() +
                    '. Failed tools: ' +
                    String.join(failedTools, ', ')
            );

            if (decisionLogger != null) {
                // Create a more informative error message
                String errorDescription;
                String errorDetails;

                if (failedTools.size() == 1) {
                    // Single tool failure - be specific
                    errorDescription = 'Tool "' + failedTools[0] + '" failed to queue for execution';
                    errorDetails = 'Error: ' + failureReasons[0];
                } else {
                    // Multiple tool failures - provide summary
                    errorDescription = failedTools.size() + ' async tools failed to queue for execution';
                    List<String> toolErrorPairs = new List<String>();
                    for (Integer i = 0; i < failedTools.size(); i++) {
                        toolErrorPairs.add(failedTools[i] + ': ' + failureReasons[i]);
                    }
                    errorDetails = String.join(toolErrorPairs, '; ');
                }

                decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ failedTools, failureReasons });
            }
        }
    }

    // ORCHESTRATION FLOW

    /**
     * Determines the next orchestration step based on execution results
     */
    private String determineNextOrchestrationStep(
        OrchestrationContext context,
        List<ToolExecutionResult> syncResults,
        List<ToolCallRequest> asyncTools,
        String logPrefix
    ) {
        // If there are async tools, wait for them to complete
        if (!asyncTools.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tools queued, returning QUEUED_ACTION outcome');
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }

        // All tools were synchronous - check for tool-terminating mode
        AgentExecution__c execution = [
            SELECT IsToolTerminatingMode__c, ExecutionStatus__c
            FROM AgentExecution__c
            WHERE Id = :context.executionId
            LIMIT 1
        ];

        if (execution.IsToolTerminatingMode__c == true) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool-terminating mode detected. Tool result is final.');

            Boolean hasFailures = false;
            for (ToolExecutionResult result : syncResults) {
                if (!result.outcome.isSuccess) {
                    hasFailures = true;
                    break;
                }
            }

            AgentExecution__c completedExecution = new AgentExecution__c(
                Id = context.executionId,
                ExecutionStatus__c = hasFailures ? 'Failed' : 'Completed',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                EndTime__c = Datetime.now()
            );
            update completedExecution;

            return hasFailures ? OrchestrationService.OUTCOME_FAILED : OrchestrationService.OUTCOME_COMPLETED;
        }

        // Check fail-fast policy using bulk capability lookup to prevent N+1 SOQL queries
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);

        // Collect all failed tool names for bulk lookup
        Set<String> failedToolNames = new Set<String>();
        for (ToolExecutionResult result : syncResults) {
            if (!result.outcome.isSuccess) {
                failedToolNames.add(result.toolName);
            }
        }

        // Bulk fetch capabilities for all failed tools in a single SOQL query
        Map<String, AgentCapability__c> failedCapabilities = new Map<String, AgentCapability__c>();
        if (!failedToolNames.isEmpty()) {
            failedCapabilities = AIAgentConfigService.getCapabilitiesByNames(context.agentDefinitionId, failedToolNames);
        }

        // Now check fail-fast policy without additional SOQL queries
        Boolean shouldHalt = false;
        for (ToolExecutionResult result : syncResults) {
            if (!result.outcome.isSuccess) {
                AgentCapability__c capability = failedCapabilities.get(result.toolName);
                if (capability != null && OrchestrationService.shouldFailFast(capability, agentDef, result.outcome, context.executionId, logPrefix)) {
                    shouldHalt = true;
                    // Determine the reason for failure (fail-fast policy or max retries exceeded)
                    String failureReason = 'Tool execution failed';
                    Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
                    Integer failureCount = OrchestrationService.countSuccessiveToolFailures(context.executionId, capability.CapabilityName__c, logPrefix);
                    if (failureCount >= maxRetries) {
                        failureReason =
                            'Tool "' +
                            capability.CapabilityName__c +
                            '" exceeded maximum retry limit (' +
                            maxRetries +
                            ') after ' +
                            failureCount +
                            ' successive failures';

                        context.decisionLogger.log(
                            IDecisionStepLogger.EventType.ERROR,
                            new List<Object>{ capability, result.outcome, maxRetries, failureCount }
                        );
                    } else {
                        failureReason = 'Tool execution stopped due to error prevention policy';

                        context.decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ capability, result.outcome });
                    }
                    context.agentStateSvc.failTurn(
                        context.executionId,
                        context.turnIdentifier,
                        failureReason + ': ' + result.outcome.errorMessage,
                        result.outcome.errorCode != null ? result.outcome.errorCode : AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                        logPrefix
                    );
                    break;
                }
            }
        }

        if (shouldHalt) {
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Commit page context to ledger
        // Skip when in deferred DML mode (function/workflow agents) since:
        // 1. Context was already resolved upfront from the recordId
        // 2. The DML would prevent multi-LLM optimization
        // 3. Function agents don't need multi-turn context tracking
        if (context.currentPageRecordId != null && !TransactionContext.getInstance().isDeferredDMLMode()) {
            try {
                context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit context: ' + e.getMessage());
            }
        }

        // Enforce max turn limit (per-agent override with org-wide fallback)
        // Reuse agentDef from line 996 (already loaded for fail-fast policy check)
        Integer maxTurns = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef.DeveloperName__c);
        if ((context.currentTurnCount + 1) > maxTurns) {
            String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') exceeded.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, limitErrorMsg, AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED, logPrefix);
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Multi-LLM Optimization: Check if we can call LLM again in the same transaction
        // This optimization reduces queueable usage by making multiple LLM calls per transaction
        // when the intervening tool executions don't perform DML or callouts.
        //
        // Conditions for immediate follow-up:
        // 1. Deferred DML mode is enabled (set by entry point)
        // 2. The sync tool(s) did not perform DML or callouts (detected via Limits class)
        // 3. We haven't reached the max LLM calls per transaction limit
        //
        // If any condition fails, we fall back to the normal queueable-based follow-up.
        TransactionContext txnCtx = TransactionContext.getInstance();

        if (txnCtx.canContinueWithImmediateFollowUp()) {
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Multi-LLM optimization: Conditions met for immediate follow-up. ' +
                    'LLM call count: ' +
                    txnCtx.getLLMCallCount() +
                    ', Max: ' +
                    AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction()
            );

            // Return IMMEDIATE_FOLLOWUP to signal the entry point to call LLM again
            // The entry point will handle the actual LLM call in its loop
            return OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP;
        }

        // Multi-LLM optimization not applicable - fall back to queueable
        // Reasons: tool performed DML/callout, max calls reached, or deferred mode not enabled
        System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization not applicable, queueing follow-up');

        // Commit buffer before queueing (if in deferred mode)
        if (txnCtx.isDeferredDMLMode()) {
            TransactionContext.getInstance().commitBuffer();
            txnCtx.disableDeferredDMLMode();
        }

        // Queue follow-up LLM call
        context.agentStateSvc.resumeForFollowUpLlmCall(context.executionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.executionId,
            context.originalUserId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false,
            context.currentPageRecordId
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }
}
