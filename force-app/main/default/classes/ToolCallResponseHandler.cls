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
public inherited sharing class ToolCallResponseHandler implements ILLMResponseHandler {
    public class ToolProcessingException extends AIAgentException {
    }

    public class ToolCallRequest {
        public String toolCallId;
        public String toolName;
        public String toolArguments;
        public String rawToolArguments;
        public AgentCapability__c capability;
        public Boolean isAsync;
        public String hitlMode;
        public Integer executionOrder;
        public String rationale;
        public Decimal confidence;
        public String nextStepSuggestion;
        public Boolean requiresApproval;
        public String approvalReason;
        public Boolean hasParsedArguments;

        public ToolCallRequest(String toolCallId, String toolName, String toolArguments, AgentCapability__c capability, Integer executionOrder) {
            this(toolCallId, toolName, toolArguments, capability, executionOrder, null, null, null);
        }

        public ToolCallRequest(
            String toolCallId,
            String toolName,
            String toolArguments,
            AgentCapability__c capability,
            Integer executionOrder,
            String rationale
        ) {
            this(toolCallId, toolName, toolArguments, capability, executionOrder, rationale, null, null);
        }

        public ToolCallRequest(
            String toolCallId,
            String toolName,
            String toolArguments,
            AgentCapability__c capability,
            Integer executionOrder,
            String rationale,
            Decimal confidence
        ) {
            this(toolCallId, toolName, toolArguments, capability, executionOrder, rationale, confidence, null);
        }

        public ToolCallRequest(
            String toolCallId,
            String toolName,
            String toolArguments,
            AgentCapability__c capability,
            Integer executionOrder,
            String rationale,
            Decimal confidence,
            String nextStepSuggestion
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.toolArguments = toolArguments;
            this.capability = capability;
            this.isAsync = capability.RunAsynchronously__c == true;
            this.executionOrder = executionOrder;
            this.rationale = rationale;
            this.confidence = confidence;
            this.nextStepSuggestion = nextStepSuggestion;
            this.hasParsedArguments = false;

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

    private class ToolCallParseResult {
        public List<ToolCallRequest> validRequests = new List<ToolCallRequest>();
        public List<InvalidToolCall> invalidRequests = new List<InvalidToolCall>();
    }

    private class ParsedToolArguments {
        public String rawArguments;
        public String cleanedArguments;
        public String rationale;
        public Decimal confidence;
        public String nextStepSuggestion;
        public Boolean requiresApproval;
        public String approvalReason;
        public Boolean parsedSuccessfully;
    }

    private class InvalidToolCall {
        public String toolCallId;
        public String toolName;
        public String toolArguments;
        public String errorMessage;
        public Boolean isMalformed;

        public InvalidToolCall(String toolCallId, String toolName, String toolArguments, String errorMessage, Boolean isMalformed) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.toolArguments = toolArguments;
            this.errorMessage = errorMessage;
            this.isMalformed = isMalformed == true;
        }
    }

    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';
        List<Map<String, String>> requestedActions = context.llmResult.providerResult.requestedActions;

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting unified tool call handling for ' + requestedActions.size() + ' tool(s).');

        IDecisionStepLogger.ILogger decisionLogger = context.decisionLogger;

        try {
            ToolCallParseResult parseResult = parseAndValidateToolCalls(context, requestedActions, decisionLogger, logPrefix);

            if (parseResult.validRequests.isEmpty() && parseResult.invalidRequests.isEmpty()) {
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

            Map<String, List<ToolCallRequest>> toolGroups = groupToolsByExecutionMode(parseResult.validRequests);
            List<ToolCallRequest> approvalTools = toolGroups.get('approval');
            List<ToolCallRequest> confirmationTools = toolGroups.get('confirmation');
            List<ToolCallRequest> syncTools = toolGroups.get('sync');
            List<ToolCallRequest> asyncTools = toolGroups.get('async');
            List<ToolCallRequest> agentTools = toolGroups.get('agent');

            // Apply confidence gate: move low-confidence sync/async tools to a blocked list.
            // Agent and approval tools are never confidence-gated (they have their own control mechanisms).
            List<ToolCallRequest> blockedTools = applyConfidenceGate(syncTools, asyncTools, context, logPrefix);

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
                    asyncTools.size() +
                    ', Agent: ' +
                    agentTools.size() +
                    ', Blocked (low confidence): ' +
                    blockedTools.size()
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
            }

            if (!parseResult.validRequests.isEmpty()) {
                createToolCallExecutionSteps(context, parseResult.validRequests, decisionLogger, logPrefix);
            }

            if (!parseResult.invalidRequests.isEmpty()) {
                handleInvalidToolCalls(context, parseResult.invalidRequests, decisionLogger, logPrefix);
                return OrchestrationService.OUTCOME_FAILED;
            }

            // Handle blocked low-confidence tools: write synthetic failed tool results so the LLM
            // self-corrects on the next ReAct iteration (consistent with LangGraph ToolNode error pattern).
            // If ALL tools were blocked (nothing left to execute), fail the turn immediately — there is
            // no useful follow-up LLM call to make when the agent has no remaining actions.
            if (!blockedTools.isEmpty()) {
                Boolean allToolsBlocked =
                    syncTools.isEmpty() &&
                    asyncTools.isEmpty() &&
                    agentTools.isEmpty() &&
                    approvalTools.isEmpty() &&
                    confirmationTools.isEmpty();
                return handleLowConfidenceTools(context, blockedTools, allToolsBlocked, logPrefix, decisionLogger);
            }

            // IMPORTANT: Execute sync tools FIRST, even if there are approval tools.
            // This ensures non-HITL tools complete their execution before we pause for approval.
            // When HITL resumes, all tool results (sync + HITL) will be aggregated and sent to LLM.
            List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();
            if (!syncTools.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' sync tool(s) before handling approval tools');
                syncResults = executeSynchronousTools(context, syncTools, decisionLogger, logPrefix);
                if (syncResults == null) {
                    return OrchestrationService.OUTCOME_FAILED;
                }
                createToolResultExecutionSteps(context, syncResults, decisionLogger, logPrefix);
            }

            // Initialize async tracking ONCE with the combined count before dispatching
            // either group. Previously each group called pauseForAsyncActionWithTracking()
            // independently, overwriting the other's count.
            Integer pendingAsyncTotal = asyncTools.size() + agentTools.size();
            if (pendingAsyncTotal > 0) {
                context.agentStateSvc.pauseForAsyncActionWithTracking(
                    context.executionId,
                    context.turnIdentifier,
                    pendingAsyncTotal,
                    'Async Tools + Agent Capabilities',
                    logPrefix
                );
            }

            // Queue async tools (they'll run independently)
            if (!asyncTools.isEmpty()) {
                queueAsyncTools(context, asyncTools, decisionLogger, logPrefix);
            }

            // Queue agent capabilities as child executions (async by nature)
            if (!agentTools.isEmpty()) {
                queueAgentCapabilities(context, agentTools, decisionLogger, logPrefix);
            }

            // Now handle approval tools - pause execution until approved
            // The sync tool results are already persisted in ExecutionStep__c records
            // and will be retrieved when HITL resumes to aggregate all results for LLM
            if (!approvalTools.isEmpty()) {
                publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantData.content, logPrefix);
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

            Integer pendingAsyncCount = asyncTools.size() + agentTools.size();
            return determineNextOrchestrationStep(
                context,
                syncResults,
                pendingAsyncCount,
                savedAssistantMessageId,
                assistantData != null ? assistantData.content : null,
                logPrefix
            );
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

    private ToolCallParseResult parseAndValidateToolCalls(
        OrchestrationContext context,
        List<Map<String, String>> requestedActions,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        ToolCallParseResult parseResult = new ToolCallParseResult();
        Map<String, AgentCapability__c> capabilitiesByLowerName = new Map<String, AgentCapability__c>();

        // Bulk-load capabilities to avoid N+1 lookups
        try {
            Set<String> capabilityNames = new Set<String>();
            for (Map<String, String> action : requestedActions) {
                String toolName = action != null ? action.get('name') : null;
                if (String.isNotBlank(toolName)) {
                    capabilityNames.add(toolName);
                }
            }

            if (!capabilityNames.isEmpty()) {
                Map<String, AgentCapability__c> capabilitiesByName = AIAgentConfigService.getCapabilitiesByNames(context.agentDefinitionId, capabilityNames);
                for (String nameKey : capabilitiesByName.keySet()) {
                    if (String.isNotBlank(nameKey) && capabilitiesByName.get(nameKey) != null) {
                        capabilitiesByLowerName.put(nameKey.toLowerCase(), capabilitiesByName.get(nameKey));
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Bulk capability lookup failed; falling back to missing tool handling. ' + e.getMessage());
        }

        for (Integer i = 0; i < requestedActions.size(); i++) {
            Map<String, String> actionMap = requestedActions[i];

            // Extract primitive fields before the try block so the catch clause can report
            // them accurately rather than silently dropping the tool call.
            String toolCallId = actionMap.get('id');
            String toolName = actionMap.get('name');
            String toolArguments = actionMap.get('arguments');

            try {
                if (String.isBlank(toolCallId) || String.isBlank(toolName)) {
                    String errorMessage = 'Malformed tool call at index ' + i + ': missing id or name';
                    System.debug(LoggingLevel.WARN, logPrefix + errorMessage);
                    parseResult.invalidRequests.add(new InvalidToolCall(toolCallId, toolName, toolArguments, errorMessage, true));
                    continue;
                }

                AgentCapability__c capability = capabilitiesByLowerName.get(toolName.toLowerCase());
                if (capability == null) {
                    String errorMessage = 'Tool "' + toolName + '" is not configured for this agent.';
                    System.debug(LoggingLevel.WARN, logPrefix + errorMessage);
                    parseResult.invalidRequests.add(new InvalidToolCall(toolCallId, toolName, toolArguments, errorMessage, false));
                    continue;
                }

                ParsedToolArguments parsedArgs = parseToolArguments(toolArguments, logPrefix);

                if (String.isNotBlank(parsedArgs.rationale)) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Extracted rationale for tool ' +
                            toolName +
                            ': ' +
                            parsedArgs.rationale.left(100) +
                            (parsedArgs.rationale.length() > 100 ? '...' : '')
                    );
                }

                if (String.isNotBlank(parsedArgs.nextStepSuggestion)) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Extracted next step suggestion for tool ' + toolName + ': ' + parsedArgs.nextStepSuggestion);
                }

                ToolCallRequest toolRequest = new ToolCallRequest(
                    toolCallId,
                    toolName,
                    parsedArgs.cleanedArguments,
                    capability,
                    i + 1,
                    parsedArgs.rationale,
                    parsedArgs.confidence,
                    parsedArgs.nextStepSuggestion
                );
                toolRequest.rawToolArguments = parsedArgs.rawArguments;
                toolRequest.requiresApproval = parsedArgs.requiresApproval;
                toolRequest.approvalReason = parsedArgs.approvalReason;
                toolRequest.hasParsedArguments = parsedArgs.parsedSuccessfully;
                parseResult.validRequests.add(toolRequest);

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
                        String.isNotBlank(parsedArgs.rationale) +
                        ')'
                );
            } catch (Exception e) {
                // Surface the failure as an invalid tool call so the LLM receives explicit
                // error feedback and execution steps are created for auditing.
                // Previously this silently dropped the call with only a debug log.
                String errorMessage = 'Unexpected error parsing tool call "' + toolName + '" at index ' + i + ': ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, logPrefix + errorMessage + '\n' + e.getStackTraceString());
                parseResult.invalidRequests.add(new InvalidToolCall(toolCallId, toolName, toolArguments, errorMessage, true));
            }
        }

        if (!parseResult.validRequests.isEmpty()) {
            try {
                AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
                List<String> requestedToolNames = new List<String>();
                for (ToolCallRequest request : parseResult.validRequests) {
                    requestedToolNames.add(request.toolName);
                }

                Map<String, String> graphErrorsByTool = ToolFlowGraphService.validateRequestedTools(agentDef, context.executionId, requestedToolNames);
                if (!graphErrorsByTool.isEmpty()) {
                    List<ToolCallRequest> stillValidRequests = new List<ToolCallRequest>();
                    for (ToolCallRequest request : parseResult.validRequests) {
                        String graphError = graphErrorsByTool.get(request.toolName);
                        if (String.isNotBlank(graphError)) {
                            parseResult.invalidRequests.add(
                                new InvalidToolCall(
                                    request.toolCallId,
                                    request.toolName,
                                    String.isNotBlank(request.rawToolArguments) ? request.rawToolArguments : request.toolArguments,
                                    graphError,
                                    false
                                )
                            );
                        } else {
                            stillValidRequests.add(request);
                        }
                    }
                    parseResult.validRequests = stillValidRequests;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Flow graph runtime validation skipped: ' + e.getMessage());
            }
        }

        // Log the tool execution plan
        if (decisionLogger != null && !parseResult.validRequests.isEmpty()) {
            // Count tools by type using the already-grouped data
            Map<String, List<ToolCallRequest>> groups = groupToolsByExecutionMode(parseResult.validRequests);

            Map<String, Object> planData = new Map<String, Object>{
                'totalTools' => parseResult.validRequests.size(),
                'syncTools' => groups.get('sync').size(),
                'asyncTools' => groups.get('async').size(),
                'approvalTools' => groups.get('approval').size(),
                'confirmationTools' => groups.get('confirmation').size(),
                'agentTools' => groups.get('agent').size(),
                'tools' => new List<Map<String, Object>>()
            };

            for (ToolCallRequest req : parseResult.validRequests) {
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
        }

        return parseResult;
    }

    private ParsedToolArguments parseToolArguments(String toolArguments, String logPrefix) {
        ParsedToolArguments result = new ParsedToolArguments();
        result.rawArguments = toolArguments;
        result.cleanedArguments = toolArguments;
        result.parsedSuccessfully = false;

        if (String.isBlank(toolArguments)) {
            return result;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(toolArguments);

            if (args.containsKey('_rationale')) {
                Object rationaleValue = args.get('_rationale');
                if (rationaleValue != null) {
                    result.rationale = String.valueOf(rationaleValue);
                }
            } else if (args.containsKey('rationale')) {
                Object rationaleValue = args.get('rationale');
                if (rationaleValue != null) {
                    result.rationale = String.valueOf(rationaleValue);
                }
                System.debug(LoggingLevel.WARN, logPrefix + 'Tool arguments used legacy "rationale" key. Treating it as alias for "_rationale".');
            }

            if (args.containsKey('_confidence')) {
                Object confidenceValue = args.get('_confidence');
                if (confidenceValue != null) {
                    try {
                        Decimal confidence = Decimal.valueOf(String.valueOf(confidenceValue));
                        if (confidence >= 0 && confidence <= 100) {
                            result.confidence = confidence;
                        } else {
                            System.debug(LoggingLevel.WARN, logPrefix + 'Confidence value out of range (0-100): ' + confidence);
                        }
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, logPrefix + 'Could not parse confidence value: ' + confidenceValue);
                    }
                }
            }

            if (args.containsKey('_nextStepSuggestion')) {
                Object suggestionValue = args.get('_nextStepSuggestion');
                if (suggestionValue != null) {
                    String suggestion = String.valueOf(suggestionValue).trim();
                    if (String.isNotBlank(suggestion)) {
                        if (suggestion.length() > 255) {
                            System.debug(LoggingLevel.WARN, logPrefix + 'Next step suggestion exceeds 255 chars, truncating: ' + suggestion);
                            suggestion = suggestion.substring(0, 255);
                        }
                        result.nextStepSuggestion = suggestion;
                    }
                }
            }

            if (args.containsKey('_requiresApproval')) {
                Object requiresApproval = args.get('_requiresApproval');
                if (requiresApproval instanceof Boolean) {
                    result.requiresApproval = (Boolean) requiresApproval;
                } else if (requiresApproval instanceof String) {
                    String strValue = ((String) requiresApproval).toLowerCase();
                    result.requiresApproval = (strValue == 'true' || strValue == '1' || strValue == 'yes');
                }
            }

            if (args.containsKey('_approvalReason')) {
                Object approvalReason = args.get('_approvalReason');
                if (approvalReason != null) {
                    result.approvalReason = String.valueOf(approvalReason);
                }
            }

            args.remove('_requiresApproval');
            args.remove('_approvalReason');
            args.remove('_rationale');
            args.remove('rationale');
            args.remove('_confidence');
            args.remove('_nextStepSuggestion');

            result.cleanedArguments = JSON.serialize(args);
            result.parsedSuccessfully = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to parse tool arguments: ' + e.getMessage());
        }

        return result;
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
            'async' => new List<ToolCallRequest>(),
            'agent' => new List<ToolCallRequest>()
        };

        for (ToolCallRequest tool : toolRequests) {
            // Agent capabilities always route to the 'agent' group regardless of HITL/async settings.
            // They follow the pipeline child execution pattern, not the standard tool execution path.
            if (tool.capability != null && 'Agent'.equalsIgnoreCase(tool.capability.ImplementationType__c)) {
                groups.get('agent').add(tool);
                continue;
            }

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
     * @description Applies the agent-level confidence gate to sync and async tools.
     * Removes any tool whose confidence score falls below MinConfidenceThreshold__c (when
     * LowConfidenceAction__c = 'Block') from the execution lists and returns them as a
     * separate blocked list. Agent and approval tools are never gated here.
     *
     * @param syncTools  Mutable list of sync tools (modified in place)
     * @param asyncTools Mutable list of async tools (modified in place)
     * @param context    Orchestration context (provides agentDefinitionId for config lookup)
     * @param logPrefix  Logging prefix
     * @return List of tools that were removed due to low confidence (empty if gate is inactive)
     */
    @TestVisible
    private static List<ToolCallRequest> applyConfidenceGate(
        List<ToolCallRequest> syncTools,
        List<ToolCallRequest> asyncTools,
        OrchestrationContext context,
        String logPrefix
    ) {
        List<ToolCallRequest> blocked = new List<ToolCallRequest>();

        AIAgentDefinition__c agentConfig;
        try {
            agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + '[ConfidenceGate] Could not load agent config: ' + e.getMessage());
            return blocked;
        }

        if (!'Block'.equals(agentConfig.LowConfidenceAction__c) || agentConfig.MinConfidenceThreshold__c == null) {
            return blocked;
        }

        Decimal threshold = agentConfig.MinConfidenceThreshold__c;

        List<ToolCallRequest> filteredSync = new List<ToolCallRequest>();
        for (ToolCallRequest tool : syncTools) {
            // Treat missing _confidence as 0 — omitting the required field is treated as maximum uncertainty.
            Decimal effectiveConfidence = tool.confidence != null ? tool.confidence : 0;
            if (effectiveConfidence < threshold) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        '[ConfidenceGate] Blocking sync tool "' +
                        tool.toolName +
                        '" (confidence=' +
                        effectiveConfidence +
                        (tool.confidence == null ? ' [defaulted — _confidence not provided]' : '') +
                        ' < threshold=' +
                        threshold +
                        ')'
                );
                blocked.add(tool);
            } else {
                filteredSync.add(tool);
            }
        }
        syncTools.clear();
        syncTools.addAll(filteredSync);

        List<ToolCallRequest> filteredAsync = new List<ToolCallRequest>();
        for (ToolCallRequest tool : asyncTools) {
            Decimal effectiveConfidence = tool.confidence != null ? tool.confidence : 0;
            if (effectiveConfidence < threshold) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        '[ConfidenceGate] Blocking async tool "' +
                        tool.toolName +
                        '" (confidence=' +
                        effectiveConfidence +
                        (tool.confidence == null ? ' [defaulted — _confidence not provided]' : '') +
                        ' < threshold=' +
                        threshold +
                        ')'
                );
                blocked.add(tool);
            } else {
                filteredAsync.add(tool);
            }
        }
        asyncTools.clear();
        asyncTools.addAll(filteredAsync);

        return blocked;
    }

    /**
     * @description Handles tool calls blocked by the confidence gate.
     * Writes a ToolCall execution step (preserving the confidence score for observability) and a
     * synthetic failed ToolResult step for each blocked tool so that the LLM message sequence
     * remains valid. The LLM receives the error on the next ReAct iteration and self-corrects —
     * identical to how LangGraph's ToolNode surfaces tool errors back to the model.
     *
     * @param context       Orchestration context
     * @param blockedTools  Tools intercepted by the confidence gate
     * @param logPrefix     Logging prefix
     * @param decisionLogger Decision step logger
     * @return OUTCOME_QUEUED_FOLLOWUP — triggers a follow-up LLM call
     */
    @TestVisible
    private String handleLowConfidenceTools(
        OrchestrationContext context,
        List<ToolCallRequest> blockedTools,
        Boolean allToolsBlocked,
        String logPrefix,
        IDecisionStepLogger.ILogger decisionLogger
    ) {
        AIAgentDefinition__c agentDef;
        try {
            agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + '[ConfidenceGate] Could not load agent config for blocked tool handling: ' + e.getMessage());
            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Confidence gate error: ' + e.getMessage(),
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        ExecutionStepService executionStepService = new ExecutionStepService();

        List<String> blockedToolNames = new List<String>();
        List<Decimal> blockedScores = new List<Decimal>();

        for (ToolCallRequest tool : blockedTools) {
            // Note: the ToolCall step for this tool was already written by createToolCallExecutionSteps()
            // (which runs on all validRequests before handleLowConfidenceTools is called).
            // We only need to write the synthetic ToolResult here.

            // Write a synthetic failed ToolResult — the LLM reads this and self-corrects.
            // Intentionally omit the threshold value so it cannot be used to game the gate.
            Decimal effectiveConfidence = tool.confidence != null ? tool.confidence : 0;
            String blockedMessage = JSON.serialize(
                new Map<String, Object>{
                    'status' => 'blocked',
                    'error' => String.format(AIAgentConstants.TOOL_RESULT_CONFIDENCE_BLOCKED_TEMPLATE, new List<Object>{ tool.toolName, effectiveConfidence }),
                    'toolName' => tool.toolName,
                    'confidenceScore' => effectiveConfidence
                }
            );

            try {
                executionStepService.createToolResultStep(
                    context.executionId,
                    tool.toolCallId,
                    tool.toolName,
                    blockedMessage,
                    context.turnIdentifier,
                    context.currentTurnCount,
                    0L,
                    false,
                    tool.capability?.Id,
                    true, // isError — blocked tools must not appear as successful executions
                    false
                );
                System.debug(LoggingLevel.INFO, logPrefix + '[ConfidenceGate] Wrote synthetic blocked result for tool "' + tool.toolName + '"');
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix + '[ConfidenceGate] Failed to write synthetic ToolResult for "' + tool.toolName + '": ' + e.getMessage()
                );
            }

            blockedToolNames.add(tool.toolName);
            blockedScores.add(effectiveConfidence);
        }

        // Log a single consolidated Storyboard step for all blocked tools.
        if (decisionLogger != null) {
            decisionLogger.log(
                IDecisionStepLogger.EventType.ERROR,
                new List<Object>{ 'CONFIDENCE_GATE_BLOCKED', blockedToolNames, blockedScores, agentDef.MinConfidenceThreshold__c }
            );
        }

        // When ALL tools were blocked, behavior depends on agent type:
        // - Function agents: fail immediately — there is no user to ask for clarification.
        // - Conversational/Email agents: queue a follow-up LLM call so the LLM can read the
        //   blocked ToolResults and self-correct by asking the user / replying via email.
        if (allToolsBlocked) {
            String strategyKey = context.agentStateSvc.getExecutionType(context.executionId);
            Boolean canCommunicateWithUser = RuntimeRegistryService.getTraits(context.executionId).routesFailuresBackToUser == true;

            if (!canCommunicateWithUser) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        '[ConfidenceGate] All ' +
                        blockedTools.size() +
                        ' tool(s) blocked for strategy ' +
                        strategyKey +
                        '. Failing turn — no path to request clarification.'
                );
                context.agentStateSvc.failTurn(
                    context.executionId,
                    context.turnIdentifier,
                    'All tool calls were blocked by the confidence gate. Confidence scores were too low to proceed.',
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_FAILED;
            }

            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    '[ConfidenceGate] All ' +
                    blockedTools.size() +
                    ' tool(s) blocked for ' +
                    strategyKey +
                    ' strategy. Queuing follow-up so LLM can ask for clarification.'
            );
        }

        // Some tools passed the gate and will execute; queue a follow-up LLM call so it can
        // incorporate both the blocked results and the successful results into its next response.
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

    /**
     * Checks if LLM requested approval via _requiresApproval parameter
     * Used for ConditionalApproval HITL mode
     * @param tool The tool call request to check
     * @return true if _requiresApproval=true, false otherwise
     */
    @TestVisible
    private static Boolean checkLLMApprovalRequest(ToolCallRequest tool) {
        if (tool != null && tool.requiresApproval != null) {
            return tool.requiresApproval;
        }

        String argsSource = tool != null && String.isNotBlank(tool.rawToolArguments) ? tool.rawToolArguments : (tool != null ? tool.toolArguments : null);
        if (String.isBlank(argsSource)) {
            return false;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(argsSource);

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
            // Fail-safe: if we can't parse, require approval
            return true;
        }
    }

    /**
     * Extracts approval reason from tool arguments
     * Used for ConditionalApproval HITL mode to get LLM's reasoning
     * @param tool The tool call request
     * @return The approval reason string, or null if not present
     */
    private static String extractApprovalReason(ToolCallRequest tool) {
        if (tool != null && String.isNotBlank(tool.approvalReason)) {
            return tool.approvalReason;
        }

        String argsSource = tool != null && String.isNotBlank(tool.rawToolArguments) ? tool.rawToolArguments : (tool != null ? tool.toolArguments : null);
        if (String.isBlank(argsSource)) {
            return null;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(argsSource);

            if (args.containsKey('_approvalReason')) {
                return String.valueOf(args.get('_approvalReason'));
            }

            return null;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ToolCallResponseHandler] ' + 'Error extracting _approvalReason: ' + e.getMessage());
            return null;
        }
    }

    /**
     * @description Strips framework-internal parameters from tool arguments before execution
     * Parameters like _requiresApproval, _approvalReason, _rationale, _confidence, _nextStepSuggestion
     * are used by the framework but should not be passed to the actual tool implementation
     * @param toolArguments The original tool arguments JSON
     * @return Cleaned tool arguments JSON without internal parameters
     */
    private static String stripInternalParameters(String toolArguments) {
        if (String.isBlank(toolArguments)) {
            return toolArguments;
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(toolArguments);

            // Remove all framework-internal parameters
            args.remove('_requiresApproval');
            args.remove('_approvalReason');
            args.remove('_rationale');
            args.remove('_confidence');
            args.remove('_nextStepSuggestion');

            return JSON.serialize(args);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ToolCallResponseHandler] ' + 'Error stripping internal parameters: ' + e.getMessage());
            // If parsing fails, return original arguments (fail-safe)
            return toolArguments;
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

        if (TransactionContext.getInstance().isDeferredDMLMode()) {
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
                        toolRequest.rationale,
                        toolRequest.confidence,
                        toolRequest.nextStepSuggestion,
                        false
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
            return;
        }

        List<ExecutionStep__c> stepsToInsert = new List<ExecutionStep__c>();
        for (ToolCallRequest toolRequest : toolRequests) {
            try {
                stepsToInsert.add(
                    executionStepService.buildToolCallStep(
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
                        toolRequest.rationale,
                        toolRequest.confidence,
                        toolRequest.nextStepSuggestion,
                        false
                    )
                );

                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix +
                        'Queued execution step for tool call: ' +
                        toolRequest.toolName +
                        ' (hasRationale=' +
                        String.isNotBlank(toolRequest.rationale) +
                        ')'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to build execution step for tool ' + toolRequest.toolName + ': ' + e.getMessage());
            }
        }

        insertExecutionSteps(stepsToInsert, logPrefix);
    }

    private void handleInvalidToolCalls(
        OrchestrationContext context,
        List<InvalidToolCall> invalidRequests,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        ExecutionStepService executionStepService = new ExecutionStepService();
        List<String> failureMessages = new List<String>();
        Boolean hasMalformed = false;

        for (InvalidToolCall invalid : invalidRequests) {
            String errorMessage = invalid.errorMessage;
            failureMessages.add(errorMessage);
            hasMalformed = hasMalformed || invalid.isMalformed;

            if (String.isBlank(invalid.toolCallId) || String.isBlank(invalid.toolName)) {
                executionStepService.createErrorStep(
                    context.executionId,
                    errorMessage,
                    AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                    context.turnIdentifier,
                    context.currentTurnCount
                );
                if (decisionLogger != null) {
                    decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ errorMessage, invalid.toolCallId, invalid.toolName });
                }
                continue;
            }

            executionStepService.createToolCallStep(
                context.executionId,
                invalid.toolCallId,
                invalid.toolName,
                invalid.toolArguments,
                context.turnIdentifier,
                context.currentTurnCount,
                context.llmResult.providerResult.promptTokens,
                context.llmResult.providerResult.completionTokens,
                context.llmResult.providerResult.totalTokens,
                context.llmResult.providerResult.modelIdentifier,
                context.llmResult.providerResult.llmCalloutDurationMs,
                null, // capabilityId unknown
                null,
                null,
                null,
                false
            );

            String errorResult = JSON.serialize(
                new Map<String, Object>{
                    'success' => false,
                    'code' => AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'error' => errorMessage,
                    'retryable' => ActionOutcome.isTransient(AIAgentConstants.ERR_CODE_CONFIG_ERROR)
                }
            );

            executionStepService.createToolResultStep(
                context.executionId,
                invalid.toolCallId,
                invalid.toolName,
                errorResult,
                context.turnIdentifier,
                context.currentTurnCount,
                0L,
                false,
                null,
                true,
                false
            );

            if (decisionLogger != null) {
                decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ invalid.toolName, errorMessage });
            }
        }

        String failureMessage = 'Invalid tool call(s): ' + String.join(failureMessages, '; ');
        String errorCode = hasMalformed ? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED : AIAgentConstants.ERR_CODE_CONFIG_ERROR;

        context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, failureMessage, errorCode, logPrefix);
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
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing ' + approvalTools.size() + ' approval-required tool(s)');

        // Load agent definition once for all approval tools
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);

        // Collect all approval tool results for orchestrator
        List<ToolExecutionResult> approvalToolResults = new List<ToolExecutionResult>();

        // Process ALL approval tools (not just the first)
        for (ToolCallRequest approvalTool : approvalTools) {
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Tool "' + approvalTool.toolName + '" requires approval. Creating approval request via HITLGatewayService.'
            );

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

            // Evaluate HITL requirement through the gateway for all modes.
            // For ConditionalApproval, the LLM already signalled approval is needed via _requiresApproval,
            // so we use the dedicated evaluateConditionalApproval() path which keeps that routing decision
            // inside the gateway rather than here.
            HITLGatewayService.HITLDecision decision;
            if (hitlContext.isConditionalApproval) {
                decision = HITLGatewayService.evaluateConditionalApproval(hitlContext);
            } else {
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
                    'message' => AIAgentConstants.TOOL_RESULT_PENDING_APPROVAL,
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
                approvalTool.capability.Id,
                false,
                false
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

            // Add this tool to the results list
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
        } // End of approval tools loop

        String interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDef, context.executionId);
        IExecutionStrategy strategy = ExecutionStrategyRegistryService.resolveStrategy(agentDef, interactionChannel);
        String strategyOutcome = strategy.validateCompletionOutcome(context, approvalToolResults, 'APPROVAL_REQUIRED', agentDef, interactionChannel);

        if (strategyOutcome != null) {
            // Strategy-specific runtime handled it
            decisionLogger.commitSteps();
            return strategyOutcome;
        }

        // Default behavior for runtimes that do not provide custom approval completion handling
        // (typically direct agents): pause execution until approval is resolved
        context.agentStateSvc.updateStatus(
            context.executionId,
            'Awaiting Action',
            AIAgentConstants.STATUS_AWAITING_ACTION,
            context.turnIdentifier,
            'Awaiting human approval'
        );

        decisionLogger.commitSteps();
        return OrchestrationService.OUTCOME_QUEUED_ACTION;
    }

    // SYNCHRONOUS EXECUTION

    /**
     * Executes all synchronous tools immediately in the same transaction.
     */
    private List<ToolExecutionResult> executeSynchronousTools(
        OrchestrationContext context,
        List<ToolCallRequest> syncTools,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' synchronous tool(s)');

        // Load agent definition for flow graph locking
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        Boolean isFlowGraphEnabled = agentDef.EnableToolFlowGraph__c == true && String.isNotBlank(agentDef.ToolFlowGraph__c);

        // Execute tools
        for (ToolCallRequest toolRequest : syncTools) {
            try {
                Long startTime = System.currentTimeMillis();

                // Multi-LLM optimization: Capture Limits before tool execution
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

                // Strip framework-internal parameters before execution if we couldn't parse earlier
                String cleanedArguments = toolRequest.hasParsedArguments == true
                    ? toolRequest.toolArguments
                    : stripInternalParameters(toolRequest.toolArguments);

                // Execute the tool
                ActionOutcome outcome = context.actionExecSvc.executeSingleAction(toolRequest.capability, cleanedArguments, actionContext);

                Long processingTime = System.currentTimeMillis() - startTime;

                // Multi-LLM optimization: Check if tool performed DML/callout and update sticky flag
                // This must happen AFTER each tool execution to properly track unsafe operations
                TransactionContext.getInstance().toolPerformedDMLOrCallout();

                // Track executed tools and apply flow graph path locking on success
                if (outcome.isSuccess) {
                    TransactionContext.getInstance().trackExecutedTool(context.executionId, toolRequest.toolName);
                    if (isFlowGraphEnabled) {
                        ToolFlowGraphService.lockExclusiveSiblings(agentDef, toolRequest.toolName, context.executionId);
                    }
                }

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

                // Multi-LLM optimization: Check for DML/callout even on failure (may have happened before exception)
                TransactionContext.getInstance().toolPerformedDMLOrCallout();

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

        if (TransactionContext.getInstance().isDeferredDMLMode()) {
            for (ToolExecutionResult result : syncResults) {
                try {
                    String resultJsonForStorage = OrchestrationService.serializeActionOutcome(result.outcome, logPrefix);
                    Boolean isError = !result.outcome.isSuccess;

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
                        isError,
                        false
                    );
                } catch (Exception e) {
                    System.debug(
                        LoggingLevel.ERROR,
                        logPrefix + 'Failed to create execution step for sync tool result ' + result.toolName + ': ' + e.getMessage()
                    );
                }
            }
            return;
        }

        List<ExecutionStep__c> stepsToInsert = new List<ExecutionStep__c>();
        for (ToolExecutionResult result : syncResults) {
            try {
                String resultJsonForStorage = OrchestrationService.serializeActionOutcome(result.outcome, logPrefix);
                Boolean isError = !result.outcome.isSuccess;

                stepsToInsert.add(
                    executionStepService.buildToolResultStep(
                        context.executionId,
                        result.toolCallId,
                        result.toolName,
                        resultJsonForStorage,
                        context.turnIdentifier,
                        context.currentTurnCount,
                        result.processingTime,
                        false,
                        result.capabilityId,
                        isError,
                        false
                    )
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to build execution step for sync tool result ' + result.toolName + ': ' + e.getMessage());
            }
        }

        insertExecutionSteps(stepsToInsert, logPrefix);
    }

    /**
     * Bulk insert helper for ExecutionStep__c with partial success handling.
     */
    private void insertExecutionSteps(List<ExecutionStep__c> stepsToInsert, String logPrefix) {
        if (stepsToInsert == null || stepsToInsert.isEmpty()) {
            return;
        }

        try {
            Database.SaveResult[] results = Database.insert(stepsToInsert, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    Database.Error err = results[i].getErrors()[0];
                    System.debug(
                        LoggingLevel.ERROR,
                        logPrefix + 'Failed to insert ExecutionStep__c (index ' + i + '): ' + err.getStatusCode() + ' - ' + err.getMessage()
                    );
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Bulk insert failed for ExecutionStep__c: ' + e.getMessage());
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
        List<String> failureReasons = new List<String>();

        // Note: pauseForAsyncActionWithTracking() is called ONCE by handle() with
        // the combined async + agent count before this method is invoked.

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
                            'success' => false,
                            'code' => AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                            'error' => 'Failed to queue tool for execution: ' + e.getMessage(),
                            'retryable' => false
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
                        true, // isError - this is a failure
                        false
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

    /**
     * Queues agent capabilities as child AgentExecution__c records.
     * Each agent tool call spawns an independent child execution linked to the parent via
     * ParentExecution__c, mirroring the pipeline child execution pattern but initiated by
     * the LLM's tool call rather than a pipeline step definition.
     *
     * The toolCallId is stored in TriggerPayload__c on the child execution so that when the
     * child completes, the parent runtime can map the result back to the original tool call.
     */
    private void queueAgentCapabilities(
        OrchestrationContext context,
        List<ToolCallRequest> agentTools,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Queuing ' + agentTools.size() + ' agent capability tool(s) as child executions');

        Integer successfullyQueued = 0;
        List<String> failedTools = new List<String>();
        List<String> failureReasons = new List<String>();

        // Note: pauseForAsyncActionWithTracking() is called ONCE by handle() with
        // the combined async + agent count before this method is invoked.

        for (ToolCallRequest toolRequest : agentTools) {
            try {
                String childAgentName = toolRequest.capability.ImplementationDetail__c;
                if (String.isBlank(childAgentName)) {
                    throw new ToolProcessingException(
                        'Agent capability "' + toolRequest.toolName + '" is missing ImplementationDetail__c (child agent DeveloperName)'
                    );
                }

                AIAgentDefinition__c childAgentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(childAgentName);
                if (childAgentDef == null) {
                    throw new ToolProcessingException('Child agent definition not found: ' + childAgentName);
                }

                String baseTurn = String.isNotBlank(context.turnIdentifier)
                    ? context.turnIdentifier
                    : EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(32);
                String childTurn = baseTurn + '-agent-' + toolRequest.toolCallId;

                // Store toolCallId + originating turn contract in TriggerPayload so
                // onChildComplete() can map back to the tool call AND reject stale
                // completions from a turn that has since been superseded.
                String triggerPayload = JSON.serialize(
                    new Map<String, Object>{
                        'toolCallId' => toolRequest.toolCallId,
                        'toolName' => toolRequest.toolName,
                        'parentExecutionId' => context.executionId,
                        'parentTurnIdentifier' => context.turnIdentifier,
                        'parentTurnCount' => context.currentTurnCount
                    }
                );

                AgentStateService agentStateSvc = new AgentStateService();
                AIAgentConfigService.ResolvedExecutionIdentity childExecutionIdentity = AIAgentConfigService.resolveExecutionIdentityForAgent(childAgentDef);
                Id childExecutionId = agentStateSvc.createExecution(
                    childAgentDef.RuntimeStrategy__c,
                    childAgentDef.Id,
                    'AgentCapability',
                    triggerPayload,
                    context.currentPageRecordId,
                    context.originalUserId,
                    null,
                    context.executionId,
                    childTurn,
                    childExecutionIdentity.profileDeveloperName,
                    childExecutionIdentity.namedCredentialDeveloperName
                );

                // Build payload for the child agent worker
                AgentExecutionService.ExecutionPayload childPayload = new AgentExecutionService.ExecutionPayload();
                childPayload.userId = context.originalUserId;
                childPayload.sourceRecordId = context.currentPageRecordId;
                childPayload.turnIdentifier = childTurn;
                childPayload.triggerSource = 'AgentCapability';
                childPayload.existingExecutionId = childExecutionId;
                childPayload.userMessage = toolRequest.toolArguments;
                childPayload.executionIdentityProfileDeveloperName = childExecutionIdentity.profileDeveloperName;
                childPayload.executionIdentityNamedCredential = childExecutionIdentity.namedCredentialDeveloperName;

                new AgentJobEnqueuer().enqueueQueueable(new AgentExecutionWorker(childAgentName, childPayload), logPrefix, childAgentDef.Id, true);

                successfullyQueued++;
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        'Queued agent capability "' +
                        toolRequest.toolName +
                        '" as child execution ' +
                        childExecutionId +
                        ' (child agent: ' +
                        childAgentName +
                        ')'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to queue agent capability ' + toolRequest.toolName + ': ' + e.getMessage());
                failedTools.add(toolRequest.toolName);

                String actualErrorMessage = e.getMessage();
                if (e.getCause() != null && String.isNotBlank(e.getCause().getMessage())) {
                    actualErrorMessage = e.getCause().getMessage();
                }
                failureReasons.add(actualErrorMessage);

                // Decrement the counter for this failed queue to prevent execution hang
                try {
                    OrchestrationService.decrementAsyncToolCounter(
                        context.executionId,
                        context.turnIdentifier,
                        context.currentTurnCount,
                        toolRequest.toolCallId,
                        logPrefix + '[AgentQueueFailureRecovery] '
                    );
                } catch (Exception decrementEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to decrement counter after agent queue failure: ' + decrementEx.getMessage());
                }

                // Create a failure tool result so LLM knows this agent tool failed
                try {
                    ExecutionStepService executionStepService = new ExecutionStepService();
                    String failureResult = JSON.serialize(
                        new Map<String, Object>{
                            'success' => false,
                            'code' => AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                            'error' => 'Failed to spawn child agent execution: ' + e.getMessage(),
                            'retryable' => false
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
                        true,
                        toolRequest.capability.Id,
                        true,
                        false
                    );
                } catch (Exception stepEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create error step for failed agent queue: ' + stepEx.getMessage());
                }
            }
        }

        if (!failedTools.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    'Agent capability queuing completed with failures. Queued: ' +
                    successfullyQueued +
                    '/' +
                    agentTools.size() +
                    '. Failed: ' +
                    String.join(failedTools, ', ')
            );

            if (decisionLogger != null) {
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
        Integer pendingAsyncCount,
        Id savedAssistantMessageId,
        String assistantMessageContent,
        String logPrefix
    ) {
        // If there are async tools or agent capabilities in flight, wait for them to complete
        if (pendingAsyncCount > 0) {
            System.debug(LoggingLevel.INFO, logPrefix + pendingAsyncCount + ' async operations queued, returning QUEUED_ACTION outcome');
            publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }

        // All tools were synchronous - check for tool-terminating mode
        AgentExecution__c execution = [
            SELECT IsToolTerminatingMode__c, ExecutionStatus__c, LastFunctionResumeTimestamp__c
            FROM AgentExecution__c
            WHERE Id = :context.executionId
            LIMIT 1
        ];

        if (execution.IsToolTerminatingMode__c == true) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool-terminating mode detected. Tool result is final.');

            Boolean hasFailures = false;
            String failureMessage = null;
            String failureCode = null;
            for (ToolExecutionResult result : syncResults) {
                if (!result.outcome.isSuccess) {
                    hasFailures = true;
                    failureMessage = result.outcome.errorMessage;
                    failureCode = result.outcome.errorCode;
                    break;
                }
            }

            if (hasFailures) {
                String errorDetail = String.isNotBlank(failureMessage) ? failureMessage : 'Tool execution failed';
                String errorCode = String.isNotBlank(failureCode) ? failureCode : AIAgentConstants.ERR_CODE_ACTION_EXECUTION;
                commitContextAnchorsIfNeeded(context, syncResults, logPrefix);
                context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, errorDetail, errorCode, logPrefix);
                publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
                return OrchestrationService.OUTCOME_FAILED;
            }

            commitContextAnchorsIfNeeded(context, syncResults, logPrefix);
            context.agentStateSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, null, logPrefix);
            publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
            return OrchestrationService.OUTCOME_COMPLETED;
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

        // Pre-load successive failure counts for all failed tools in one SOQL (avoids per-tool SOQL
        // inside shouldFailFast() and the redundant countSuccessiveToolFailures() call for the failure
        // reason message — previously O(n) queries for n failing tools).
        // Pass LastFunctionResumeTimestamp__c so that pre-resume failures don't consume the
        // post-resume circuit breaker budget on resumed Function agent executions.
        Map<String, Integer> preloadedFailureCounts = new Map<String, Integer>();
        if (!failedToolNames.isEmpty()) {
            preloadedFailureCounts = OrchestrationService.loadSuccessiveFailureCounts(
                context.executionId,
                failedToolNames,
                execution.LastFunctionResumeTimestamp__c,
                logPrefix
            );
        }

        // Now check fail-fast policy without additional SOQL queries
        Boolean shouldHalt = false;
        for (ToolExecutionResult result : syncResults) {
            if (!result.outcome.isSuccess) {
                AgentCapability__c capability = failedCapabilities.get(result.toolName);
                // Pass preloaded count (-1 if not available) to avoid issuing a SOQL inside this loop
                Integer preloadedCount = preloadedFailureCounts.containsKey(result.toolName) ? preloadedFailureCounts.get(result.toolName) : -1;
                if (
                    capability != null &&
                    OrchestrationService.shouldFailFast(capability, agentDef, result.outcome, context.executionId, preloadedCount, logPrefix)
                ) {
                    shouldHalt = true;
                    // Reuse the preloaded count for the failure reason message; no extra SOQL needed.
                    String failureReason = 'Tool execution failed';
                    Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
                    Integer failureCount = preloadedCount >= 0
                        ? preloadedCount
                        : OrchestrationService.countSuccessiveToolFailures(context.executionId, capability.CapabilityName__c, logPrefix);
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
            commitContextAnchorsIfNeeded(context, syncResults, logPrefix);
            publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Enforce max turn limit (per-agent override with org-wide fallback)
        // Use the object overload to avoid a redundant SOQL — agentDef is already loaded
        Integer maxTurns = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef);
        if ((context.currentTurnCount + 1) > maxTurns) {
            String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') exceeded.';
            commitContextAnchorsIfNeeded(context, syncResults, logPrefix);
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, limitErrorMsg, AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED, logPrefix);
            publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
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

            // Invalidate cached toolsPayload so the follow-up LLM call recomputes
            // eligible tools. Tool flow graph state may have changed after execution.
            AIAgentDefinition__c agentDefForImmediate = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (agentDefForImmediate.EnableToolFlowGraph__c == true) {
                LLMInteractionService.clearRequestCache(context.executionId);
            }

            return OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP;
        }

        // Multi-LLM optimization not applicable - fall back to queueable
        // Reasons: tool performed DML/callout, max calls reached, or deferred mode not enabled
        System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization not applicable, queueing follow-up');

        commitContextAnchorsIfNeeded(context, syncResults, logPrefix);

        // Commit buffer before queueing (if in deferred mode)
        if (txnCtx.isDeferredDMLMode()) {
            TransactionContext.getInstance().commitBuffer();
            txnCtx.disableDeferredDMLMode();
        }

        // Invalidate cached toolsPayload so the follow-up LLM call recomputes eligible tools
        AIAgentDefinition__c agentDefForCache = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        if (agentDefForCache.EnableToolFlowGraph__c == true) {
            LLMInteractionService.clearRequestCache(context.executionId);
        }

        publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);

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

    private void commitContextAnchorsIfNeeded(OrchestrationContext context, List<ToolExecutionResult> syncResults, String logPrefix) {
        if (context == null || context.agentStateSvc.isContextTrackingEnabled(context.executionId) != true) {
            return;
        }

        List<ContextManagerService.ContextDeltaItem> deltaItems = context.contextManagerSvc.buildTurnContextDelta(
            context.executionId,
            context.currentPageRecordId,
            buildContextDeltaItems(syncResults, context.contextManagerSvc)
        );
        if (deltaItems.isEmpty()) {
            return;
        }

        try {
            context.contextManagerSvc.commitContextDelta(context.executionId, context.currentTurnCount, deltaItems);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit context anchors: ' + e.getMessage());
        }
    }

    private List<ContextManagerService.ContextDeltaItem> buildContextDeltaItems(
        List<ToolExecutionResult> syncResults,
        ContextManagerService contextManagerSvc
    ) {
        List<ContextManagerService.ContextDeltaItem> deltaItems = new List<ContextManagerService.ContextDeltaItem>();
        if (syncResults == null || contextManagerSvc == null) {
            return deltaItems;
        }

        for (ToolExecutionResult result : syncResults) {
            if (result == null || result.outcome == null || result.outcome.isSuccess != true || result.outcome.contextEffects == null) {
                continue;
            }
            deltaItems.addAll(contextManagerSvc.buildDeltaItemsFromContextEffects(result.outcome.contextEffects));
        }
        return deltaItems;
    }

    /**
     * Publishes a transient assistant message for UI updates after tool processing completes.
     * Must only be called when no further callouts will occur in this transaction.
     */
    private void publishTransientAssistantMessage(Id executionId, Id messageId, String messageContent, String logPrefix) {
        if (executionId == null || messageId == null || String.isBlank(messageContent)) {
            return;
        }

        try {
            TransientMessage__e event = new TransientMessage__e(
                AgentExecutionId__c = executionId,
                MessageId__c = messageId,
                MessageContent__c = messageContent
            );
            EventBus.publish(event);
            System.debug(LoggingLevel.INFO, logPrefix + 'Published TransientMessage__e for UI (post-tool execution)');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to publish TransientMessage__e for UI.');
        }
    }
}
