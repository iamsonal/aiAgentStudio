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
        public Boolean isDependencyValidationFailure;

        public ToolExecutionResult(
            String toolCallId,
            String toolName,
            ActionOutcome outcome,
            Long processingTime,
            Boolean isAsync,
            Integer executionOrder,
            Id capabilityId
        ) {
            this(toolCallId, toolName, outcome, processingTime, isAsync, executionOrder, capabilityId, false);
        }

        public ToolExecutionResult(
            String toolCallId,
            String toolName,
            ActionOutcome outcome,
            Long processingTime,
            Boolean isAsync,
            Integer executionOrder,
            Id capabilityId,
            Boolean isDependencyValidationFailure
        ) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.outcome = outcome;
            this.processingTime = processingTime;
            this.isAsync = isAsync;
            this.executionOrder = executionOrder;
            this.capabilityId = capabilityId;
            this.isDependencyValidationFailure = isDependencyValidationFailure != null ? isDependencyValidationFailure : false;
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
            }

            if (!parseResult.validRequests.isEmpty()) {
                createToolCallExecutionSteps(context, parseResult.validRequests, decisionLogger, logPrefix);
            }

            if (!parseResult.invalidRequests.isEmpty()) {
                handleInvalidToolCalls(context, parseResult.invalidRequests, decisionLogger, logPrefix);
                return OrchestrationService.OUTCOME_FAILED;
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

            // Queue async tools (they'll run independently)
            if (!asyncTools.isEmpty()) {
                queueAsyncTools(context, asyncTools, decisionLogger, logPrefix);
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

            return determineNextOrchestrationStep(
                context,
                syncResults,
                asyncTools,
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
                        toolRequest.nextStepSuggestion
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
                null // capabilityId unknown
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
                true
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

        // Delegate agent-specific behavior to orchestrator
        // This keeps ToolCallResponseHandler agent-agnostic
        IAgentOrchestrator orchestrator = loadOrchestrator(agentDef);

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
     * Delegates to AgentExecutionService.getOrchestrator() so the transaction-level static
     * cache is used instead of issuing a per-call SOQL against AgentOrchestratorMapping__mdt.
     */
    private IAgentOrchestrator loadOrchestrator(AIAgentDefinition__c agentDef) {
        try {
            return AgentExecutionService.getOrchestrator(agentDef);
        } catch (AIAgentException.OrchestrationException e) {
            throw new ToolProcessingException(e.getMessage());
        }
    }

    // SYNCHRONOUS EXECUTION

    /**
     * Result of pre-flight validation and reordering for tool dependencies.
     */
    private class PreflightValidationResult {
        public Boolean hasBlockedTools = false;
        public List<ToolExecutionResult> blockedResults = new List<ToolExecutionResult>();
        public List<ToolCallRequest> reorderedTools = new List<ToolCallRequest>();
        public Boolean wasReordered = false;
    }

    /**
     * Executes all synchronous tools immediately in the same transaction.
     * Uses PRE-FLIGHT validation: validates ALL tools BEFORE executing ANY.
     * This ensures no DML occurs if validation fails, keeping the transaction clean
     * for the follow-up LLM call to be queued.
     */
    private List<ToolExecutionResult> executeSynchronousTools(
        OrchestrationContext context,
        List<ToolCallRequest> syncTools,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' synchronous tool(s)');

        // Load agent definition for dependency validation
        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        Boolean isDependencyValidationEnabled = agentDef.EnableDependencyValidation__c == true;
        String dependencyGraph = agentDef.ToolDependencyGraph__c;

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Dependency validation enabled: ' + isDependencyValidationEnabled);

        // Determine dependency scope based on agent type:
        // - Conversational/Email: Turn-scoped (dependencies reset each conversation turn)
        // - Function/Workflow: Execution-scoped (dependencies persist across entire execution)
        Boolean turnScoped = isTurnScopedDependencies(agentDef.AgentType__c);
        System.debug(
            LoggingLevel.DEBUG,
            logPrefix + 'Dependency scope: ' + (turnScoped ? 'turn-scoped' : 'execution-wide') + ' for agent type: ' + agentDef.AgentType__c
        );

        // Track executed tools for dependency validation
        Set<String> executedTools = getExecutedToolsForExecution(context.executionId, context.turnIdentifier, turnScoped);

        // PRE-FLIGHT VALIDATION & REORDERING
        if (isDependencyValidationEnabled && String.isNotBlank(dependencyGraph)) {
            PreflightValidationResult preflightResult = performPreflightValidation(syncTools, executedTools, dependencyGraph, decisionLogger, logPrefix);

            // Use the reordered/filtered tools for execution
            syncTools = preflightResult.reorderedTools;

            // Add blocked results to return list (if any)
            if (preflightResult.hasBlockedTools) {
                syncResults.addAll(preflightResult.blockedResults);

                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Pre-flight validation blocked ' +
                        preflightResult.blockedResults.size() +
                        ' tool(s). Executing ' +
                        syncTools.size() +
                        ' allowed tool(s).'
                );

                // CIRCUIT BREAKER: Check if max dependency violations exceeded
                Integer existingViolations = countDependencyViolations(context.executionId);
                Integer newViolations = preflightResult.blockedResults.size();
                Integer totalViolations = existingViolations + newViolations;
                Integer maxViolations = AIAgentFrameworkSettings.getMaxDependencyViolations();

                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix +
                        'Dependency violations: existing=' +
                        existingViolations +
                        ', new=' +
                        newViolations +
                        ', total=' +
                        totalViolations +
                        ', max=' +
                        maxViolations
                );

                if (totalViolations >= maxViolations) {
                    System.debug(
                        LoggingLevel.ERROR,
                        logPrefix +
                            'CIRCUIT BREAKER: Max dependency violations (' +
                            maxViolations +
                            ') exceeded. Total violations: ' +
                            totalViolations +
                            '. Failing execution immediately.'
                    );

                    // Create an error step for auditing (not a tool result - just for logs)
                    try {
                        String errorMessage =
                            'Circuit breaker triggered: Maximum dependency violations (' +
                            totalViolations +
                            '/' +
                            maxViolations +
                            ') exceeded. ' +
                            'The LLM repeatedly violated dependency rules. This may indicate:\n' +
                            '1) Dependency graph is incorrectly configured\n' +
                            '2) Agent instructions are unclear\n' +
                            '3) LLM does not understand the error guidance\n\n' +
                            'ACTION: Review the dependency graph and agent instructions, then resume execution. ' +
                            'On resume, the execution will continue with only the successfully executed tools.';

                        ExecutionStepService stepService = new ExecutionStepService();
                        stepService.createErrorStep(
                            context.executionId,
                            errorMessage,
                            AIAgentConstants.ERR_CODE_DEPENDENCY_VALIDATION,
                            context.turnIdentifier,
                            context.currentTurnCount
                        );
                    } catch (Exception e) {
                        System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create circuit breaker error step: ' + e.getMessage());
                    }

                    // Fail execution immediately - DO NOT queue follow-up
                    // This prevents the invalid tool_call_id error with OpenAI
                    String failureMessage =
                        'Circuit breaker: Maximum dependency violations (' +
                        totalViolations +
                        '/' +
                        maxViolations +
                        ') exceeded. Review dependency graph and resume to retry.';

                    AgentStateService stateService = new AgentStateService();
                    stateService.failTurn(
                        context.executionId,
                        context.turnIdentifier,
                        failureMessage,
                        AIAgentConstants.ERR_CODE_DEPENDENCY_VALIDATION,
                        logPrefix
                    );

                    // Return null - execution stops here, no follow-up LLM call
                    return null;
                }

                // If ALL tools blocked, return immediately - no DML has occurred
                if (syncTools.isEmpty()) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'All tools blocked. Returning errors without executing any tools.');
                    return syncResults;
                }
            }

            // Log reordering if it occurred
            if (preflightResult.wasReordered && !preflightResult.hasBlockedTools) {
                List<String> toolNames = new List<String>();
                for (ToolCallRequest t : syncTools) {
                    toolNames.add(t.toolName);
                }
                System.debug(LoggingLevel.INFO, logPrefix + 'Tools reordered based on dependencies: ' + String.join(toolNames, ' -> '));
            }
        }

        // Track which dependencies have successfully executed (for success state tracking)
        Set<String> satisfiedDependencies = new Set<String>(executedTools);

        // Execute tools with SUCCESS STATE TRACKING
        for (ToolCallRequest toolRequest : syncTools) {
            // Re-validate dependencies before execution if enabled
            // This catches cases where a dependency in the batch failed
            if (isDependencyValidationEnabled && String.isNotBlank(dependencyGraph)) {
                ToolDependencyValidator.ValidationResult validationResult = ToolDependencyValidator.validate(
                    toolRequest.toolName,
                    satisfiedDependencies,
                    dependencyGraph
                );

                if (!validationResult.allowed) {
                    // Dependency failed at runtime - block this tool
                    System.debug(LoggingLevel.WARN, logPrefix + 'Tool "' + toolRequest.toolName + '" blocked at execution time - dependency not satisfied');

                    ActionOutcome blockedOutcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_DEPENDENCY_VALIDATION, validationResult.guidanceForLLM);

                    ToolExecutionResult blockedResult = new ToolExecutionResult(
                        toolRequest.toolCallId,
                        toolRequest.toolName,
                        blockedOutcome,
                        0L,
                        false,
                        toolRequest.executionOrder,
                        toolRequest.capability.Id,
                        true // isDependencyValidationFailure
                    );

                    syncResults.add(blockedResult);

                    if (decisionLogger != null) {
                        decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ toolRequest, blockedOutcome, 0L });
                    }

                    continue; // Skip execution
                }
            }

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

                // Only add to satisfied dependencies if SUCCESSFUL
                if (outcome.isSuccess) {
                    satisfiedDependencies.add(toolRequest.toolName);
                    trackExecutedTool(context.executionId, toolRequest.toolName);
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
     * Validates ALL tools in the batch BEFORE executing any.
     * Attempts to intelligently reorder tools based on dependency graph.
     * Only blocks tools whose dependencies are completely missing from the batch.
     */
    private PreflightValidationResult performPreflightValidation(
        List<ToolCallRequest> tools,
        Set<String> executedTools,
        String dependencyGraph,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        PreflightValidationResult result = new PreflightValidationResult();

        // Parse dependency graph
        ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph(dependencyGraph);

        // Build set of tool names in current batch (for dependency validation)
        Set<String> toolsInBatch = new Set<String>();
        for (ToolCallRequest tool : tools) {
            if (!toolsInBatch.contains(tool.toolName)) {
                toolsInBatch.add(tool.toolName);
            }
        }

        Set<String> executedOrInBatch = new Set<String>(executedTools);
        executedOrInBatch.addAll(toolsInBatch);

        List<ToolCallRequest> allowedRequests = new List<ToolCallRequest>();
        for (ToolCallRequest toolRequest : tools) {
            ToolDependencyValidator.DependencyRequirements reqs = graph.getDependenciesFor(toolRequest.toolName);

            List<String> missingAllOf = new List<String>();
            for (String dep : reqs.allOf) {
                if (!executedOrInBatch.contains(dep)) {
                    missingAllOf.add(dep);
                }
            }

            List<String> missingAnyOfGroups = new List<String>();
            if (!reqs.anyOf.isEmpty()) {
                Boolean anyMet = false;
                for (String dep : reqs.anyOf) {
                    if (executedOrInBatch.contains(dep)) {
                        anyMet = true;
                        break;
                    }
                }
                if (!anyMet) {
                    missingAnyOfGroups.add('[Any of: ' + String.join(reqs.anyOf, ', ') + ']');
                }
            }

            if (missingAllOf.isEmpty() && missingAnyOfGroups.isEmpty()) {
                allowedRequests.add(toolRequest);
            } else {
                result.hasBlockedTools = true;
                ToolDependencyValidator.ValidationResult validationResult = ToolDependencyValidator.createBlockedResult(
                    toolRequest.toolName,
                    missingAllOf,
                    missingAnyOfGroups,
                    executedTools
                );

                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Pre-flight: Tool "' +
                        toolRequest.toolName +
                        '" blocked. Missing dependencies: ' +
                        String.join(validationResult.missingDependencies, ', ')
                );

                ActionOutcome blockedOutcome = ActionOutcome.failure(AIAgentConstants.ERR_CODE_DEPENDENCY_VALIDATION, validationResult.guidanceForLLM);

                ToolExecutionResult blockedResult = new ToolExecutionResult(
                    toolRequest.toolCallId,
                    toolRequest.toolName,
                    blockedOutcome,
                    0L,
                    false,
                    toolRequest.executionOrder,
                    toolRequest.capability.Id,
                    true // isDependencyValidationFailure
                );

                result.blockedResults.add(blockedResult);

                if (decisionLogger != null) {
                    decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ toolRequest, blockedOutcome, 0L });
                }
            }
        }

        result.reorderedTools = orderToolsByDependencies(allowedRequests, executedTools, graph, logPrefix);
        result.wasReordered = !isOriginalOrder(allowedRequests, result.reorderedTools);

        if (result.wasReordered) {
            List<String> toolNames = new List<String>();
            for (ToolCallRequest t : result.reorderedTools) {
                toolNames.add(t.toolName);
            }
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Pre-flight: Reordered ' + result.reorderedTools.size() + ' tool(s) based on dependencies. Order: ' + String.join(toolNames, ' -> ')
            );
        }

        return result;
    }

    /**
     * Orders tools based on dependency readiness while preserving original ordering where possible.
     */
    private List<ToolCallRequest> orderToolsByDependencies(
        List<ToolCallRequest> tools,
        Set<String> executedTools,
        ToolDependencyValidator.DependencyGraph graph,
        String logPrefix
    ) {
        List<ToolCallRequest> remaining = new List<ToolCallRequest>();
        remaining.addAll(tools);

        List<ToolCallRequest> ordered = new List<ToolCallRequest>();
        Set<String> satisfied = new Set<String>(executedTools);
        Boolean progress = true;

        while (!remaining.isEmpty() && progress) {
            progress = false;
            for (Integer i = 0; i < remaining.size(); i++) {
                ToolCallRequest candidate = remaining[i];
                ToolDependencyValidator.DependencyRequirements reqs = graph.getDependenciesFor(candidate.toolName);
                if (areDependenciesSatisfied(reqs, satisfied)) {
                    ordered.add(candidate);
                    satisfied.add(candidate.toolName);
                    remaining.remove(i);
                    i--;
                    progress = true;
                }
            }
        }

        if (!remaining.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                'Pre-flight: Unable to fully satisfy dependency ordering (possible cycle or missing prerequisites). Executing remaining tools in original order.'
            );
            ordered.addAll(remaining);
        }

        Integer newOrder = 0;
        for (ToolCallRequest tool : ordered) {
            tool.executionOrder = newOrder++;
        }

        return ordered;
    }

    /**
     * Checks if the sorted order matches the original order.
     */
    private Boolean isOriginalOrder(List<ToolCallRequest> original, List<ToolCallRequest> reordered) {
        if (original.size() != reordered.size()) {
            return false;
        }

        for (Integer i = 0; i < original.size(); i++) {
            if (original[i].toolCallId != reordered[i].toolCallId) {
                return false;
            }
        }

        return true;
    }

    private Boolean areDependenciesSatisfied(ToolDependencyValidator.DependencyRequirements reqs, Set<String> satisfied) {
        for (String dep : reqs.allOf) {
            if (!satisfied.contains(dep)) {
                return false;
            }
        }

        if (!reqs.anyOf.isEmpty()) {
            Boolean anyMet = false;
            for (String dep : reqs.anyOf) {
                if (satisfied.contains(dep)) {
                    anyMet = true;
                    break;
                }
            }
            if (!anyMet) {
                return false;
            }
        }

        return true;
    }

    /**
     * Gets the set of tools already executed in this execution session.
     * Retrieves from ExecutionStep__c records.
     *
     * @param executionId The execution ID
     * @param turnIdentifier The current turn identifier (used for turn-scoped queries)
     * @param turnScopedOnly If true, only return tools from the current turn (Conversational/Email agents).
     *                       If false, return tools from all turns (Function/Workflow agents).
     * @return Set of tool names that have been successfully executed
     */
    private Set<String> getExecutedToolsForExecution(Id executionId, String turnIdentifier, Boolean turnScopedOnly) {
        Set<String> executed = new Set<String>();

        if (executionId == null) {
            return executed;
        }

        // Query successful tool result steps for this execution
        // CRITICAL: Include tools regardless of IsError__c, but exclude dependency validation failures
        // Dependency failures are NOT real executions - they're blocked attempts
        List<ExecutionStep__c> toolSteps;

        // For turn-scoped agents (Conversational/Email), only consider tools from current turn
        // For execution-scoped agents (Function/Workflow), consider all tools across turns
        if (turnScopedOnly && String.isNotBlank(turnIdentifier)) {
            toolSteps = [
                SELECT ToolName__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND StepType__c = 'ToolResult'
                    AND IsError__c = FALSE
                    AND IsDependencyValidationFailure__c = FALSE
                    AND ToolName__c != NULL
                    AND TurnIdentifier__c = :turnIdentifier
            ];
        } else {
            toolSteps = [
                SELECT ToolName__c
                FROM ExecutionStep__c
                WHERE
                    AgentExecution__c = :executionId
                    AND StepType__c = 'ToolResult'
                    AND IsError__c = FALSE
                    AND IsDependencyValidationFailure__c = FALSE
                    AND ToolName__c != NULL
            ];
        }

        for (ExecutionStep__c step : toolSteps) {
            executed.add(step.ToolName__c);
        }

        // Also include any tools tracked in this transaction
        Set<String> transactionTools = TransactionContext.getInstance().getExecutedTools(executionId);
        if (transactionTools != null) {
            executed.addAll(transactionTools);
        }

        return executed;
    }

    /**
     * Determines if the given agent type should use turn-scoped dependency tracking.
     * - Conversational & Email agents: Turn-scoped (dependencies reset each turn)
     * - Function & Workflow agents: Execution-scoped (dependencies persist across turns)
     */
    private Boolean isTurnScopedDependencies(String agentType) {
        if (String.isBlank(agentType)) {
            return false; // Default to execution-wide for unknown types
        }

        String agentTypeLower = agentType.toLowerCase();
        // Conversational and Email agents have multi-turn conversations where each turn is independent
        // Function and Workflow agents have sequential/dependent tool execution across the execution
        return agentTypeLower == 'conversational' || agentTypeLower == 'email';
    }

    /**
     * Tracks a tool as executed in this transaction.
     * Used for same-transaction dependency validation before steps are persisted.
     */
    private void trackExecutedTool(Id executionId, String toolName) {
        TransactionContext.getInstance().trackExecutedTool(executionId, toolName);
    }

    /**
     * Counts the number of dependency validation failures for an execution.
     * Used by the circuit breaker to prevent infinite loops when LLM repeatedly violates dependencies.
     */
    private Integer countDependencyViolations(Id executionId) {
        if (executionId == null) {
            return 0;
        }

        // Count from persisted ExecutionStep__c records
        Integer count = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId AND StepType__c = 'ToolResult' AND IsDependencyValidationFailure__c = TRUE
        ];

        // Include buffered steps in deferred DML mode
        for (ExecutionStep__c step : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
            if (step.StepType__c == 'ToolResult' && step.IsDependencyValidationFailure__c == true) {
                count++;
            }
        }

        return count;
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

                    // For dependency validation failures, IsError__c should be false
                    // These are not real execution errors - they're blocked attempts
                    Boolean isError = !result.outcome.isSuccess && !result.isDependencyValidationFailure;

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
                        isError, // isError = real failure only, not dependency blocks
                        false, // isResumed
                        result.isDependencyValidationFailure // Pass the dependency validation failure flag
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

                // For dependency validation failures, IsError__c should be false
                // These are not real execution errors - they're blocked attempts
                Boolean isError = !result.outcome.isSuccess && !result.isDependencyValidationFailure;

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
                        isError, // isError = real failure only, not dependency blocks
                        false, // isResumed
                        result.isDependencyValidationFailure
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
        Id savedAssistantMessageId,
        String assistantMessageContent,
        String logPrefix
    ) {
        // If there are async tools, wait for them to complete
        if (!asyncTools.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tools queued, returning QUEUED_ACTION outcome');
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
                if (!result.outcome.isSuccess && !result.isDependencyValidationFailure) {
                    hasFailures = true;
                    failureMessage = result.outcome.errorMessage;
                    failureCode = result.outcome.errorCode;
                    break;
                }
            }

            if (hasFailures) {
                String errorDetail = String.isNotBlank(failureMessage) ? failureMessage : 'Tool execution failed';
                String errorCode = String.isNotBlank(failureCode) ? failureCode : AIAgentConstants.ERR_CODE_ACTION_EXECUTION;
                context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, errorDetail, errorCode, logPrefix);
                publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
                return OrchestrationService.OUTCOME_FAILED;
            }

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
            // CRITICAL: Skip dependency validation failures - they're not real execution errors
            // Dependency failures are guardrails that guide the LLM, not errors that should halt execution
            if (result.isDependencyValidationFailure) {
                continue;
            }

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
            publishTransientAssistantMessage(context.executionId, savedAssistantMessageId, assistantMessageContent, logPrefix);
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Enforce max turn limit (per-agent override with org-wide fallback)
        // Use the object overload to avoid a redundant SOQL — agentDef is already loaded
        Integer maxTurns = AIAgentFrameworkSettings.getMaxProcessingCycles(agentDef);
        if ((context.currentTurnCount + 1) > maxTurns) {
            String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') exceeded.';
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

            // Return IMMEDIATE_FOLLOWUP to signal the entry point to call LLM again
            // The entry point will handle the actual LLM call in its loop
            return OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP;
        }

        // Multi-LLM optimization not applicable - fall back to queueable
        // Reasons: tool performed DML/callout, max calls reached, or deferred mode not enabled
        System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization not applicable, queueing follow-up');

        // Commit page context to ledger (Conversational agents only)
        // Skip for Function/Workflow agents since:
        // 1. Context was already resolved upfront from the recordId
        // 2. Function agents don't need multi-turn context tracking
        // 3. Reduces unnecessary DML for stateless execution patterns
        if (context.currentPageRecordId != null && context.agentStateSvc.isContextTrackingEnabled(context.executionId)) {
            try {
                context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit context: ' + e.getMessage());
            }
        }

        // Commit buffer before queueing (if in deferred mode)
        if (txnCtx.isDeferredDMLMode()) {
            TransactionContext.getInstance().commitBuffer();
            txnCtx.disableDeferredDMLMode();
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
