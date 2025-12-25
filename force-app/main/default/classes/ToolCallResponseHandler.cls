/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * ToolCallResponseHandler orchestrates the full lifecycle of tool call requests originating from LLM responses within the agent framework.
 *
 * Responsibilities:
 *   - Validates and interprets tool call requests from LLM output (single or multiple)
 *   - Determines whether tool execution requires human approval or can proceed autonomously
 *   - Manages both synchronous and asynchronous execution paths for tool actions, including queuing and follow-up
 *   - Handles parallel tool execution by grouping tools into Sync/Async/Approval buckets
 *   - Integrates with chat history, approval processes, and orchestration services to maintain robust conversation and action state
 *   - Ensures traceability and error handling throughout the tool call process, providing clear runtime diagnostics and developer insight
 *
 * Consolidated from ParallelToolCallHandler to eliminate code duplication and normalize list-based processing.
 */
public class ToolCallResponseHandler implements ILLMResponseHandler {
    public class ToolProcessingException extends AIAgentException {
    }

    /**
     * Data structure to hold information about a parsed tool call request
     */
    public class ToolCallRequest {
        public String toolCallId;
        public String toolName;
        public String toolArguments;
        public AgentCapability__c capability;
        public Boolean isAsync;
        public Boolean requiresApproval;
        public Integer executionOrder;

        /**
         * Constructs a ToolCallRequest with validation for mutually exclusive execution modes.
         *
         * @param toolCallId The unique identifier for this tool call from the LLM
         * @param toolName The name of the tool/capability
         * @param toolArguments JSON string of arguments from the LLM
         * @param capability The AgentCapability__c record defining the tool
         * @param executionOrder The order in which this tool was requested (1-based)
         * @throws ToolProcessingException if capability has invalid execution mode configuration
         */
        public ToolCallRequest(String toolCallId, String toolName, String toolArguments, AgentCapability__c capability, Integer executionOrder) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.toolArguments = toolArguments;
            this.capability = capability;
            this.isAsync = capability.RunAsynchronously__c == true;
            this.requiresApproval = capability.RequiresApproval__c == true;
            this.executionOrder = executionOrder;

            // Defensive validation: RequiresApproval and RunAsynchronously are mutually exclusive
            // This should be caught by the trigger, but we validate here as a safeguard
            // to prevent silent failures in tool grouping logic
            if (this.isAsync && this.requiresApproval) {
                throw new ToolProcessingException(
                    'Configuration error: Capability "' +
                        capability.CapabilityName__c +
                        '" has both ' +
                        'RequiresApproval__c and RunAsynchronously__c set to true. These execution modes ' +
                        'are mutually exclusive. Please update the capability configuration.'
                );
            }
        }
    }

    /**
     * Data structure to hold the result of a tool execution
     */
    public class ToolExecutionResult {
        public String toolCallId;
        public String toolName;
        public ActionOutcome outcome;
        public Long processingTime;
        public Boolean isAsync;
        public Integer executionOrder;

        public ToolExecutionResult(String toolCallId, String toolName, ActionOutcome outcome, Long processingTime, Boolean isAsync, Integer executionOrder) {
            this.toolCallId = toolCallId;
            this.toolName = toolName;
            this.outcome = outcome;
            this.processingTime = processingTime;
            this.isAsync = isAsync;
            this.executionOrder = executionOrder;
        }
    }

    /**
     * Entry point for handling tool call requests from an LLM response.
     * Now always treats requests as a list, even for single tool calls.
     *
     * @param context OrchestrationContext containing session state, LLM result, and service references.
     * @return String outcome constant indicating the next orchestration step (e.g., queued, failed, follow-up).
     * @throws ToolProcessingException if the tool request is malformed or capability is missing.
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';
        List<Map<String, String>> requestedActions = context.llmResult.providerResult.requestedActions;

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting unified tool call handling for ' + requestedActions.size() + ' tool(s).');

        AgentDecisionStepLogger decisionLogger = context.decisionLogger;

        try {
            // Step 1: Parse and validate all tool calls
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

            // Step 2: Group tools into execution buckets (Sync, Async, Approval) in single pass
            Map<String, List<ToolCallRequest>> toolGroups = groupToolsByExecutionMode(toolRequests);
            List<ToolCallRequest> approvalTools = toolGroups.get('approval');
            List<ToolCallRequest> syncTools = toolGroups.get('sync');
            List<ToolCallRequest> asyncTools = toolGroups.get('async');

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Tool execution plan - Approval: ' + approvalTools.size() + ', Sync: ' + syncTools.size() + ', Async: ' + asyncTools.size()
            );

            // Step 3: Persist user message for traceability
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

            // Step 4: Save assistant message containing the tool call request
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

                // Publish assistant message for UI update
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

            // Step 5: Create execution step records for all tool calls
            createToolCallExecutionSteps(context, toolRequests, decisionLogger, logPrefix);

            // Step 6: Handle approval-required tools (if any exist, pause execution)
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

            // Step 7: Execute synchronous tools immediately
            List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();
            if (!syncTools.isEmpty()) {
                syncResults = executeSynchronousTools(context, syncTools, decisionLogger, logPrefix);
                createToolResultExecutionSteps(context, syncResults, decisionLogger, logPrefix);
            }

            // Step 8: Queue asynchronous tools
            if (!asyncTools.isEmpty()) {
                queueAsyncTools(context, asyncTools, decisionLogger, logPrefix);
            }

            // Step 9: Determine next orchestration step
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

    // ===================================================================================
    // PARSING AND VALIDATION
    // ===================================================================================

    /**
     * Parses and validates all tool call requests from the LLM response
     */
    private List<ToolCallRequest> parseAndValidateToolCalls(
        OrchestrationContext context,
        List<Map<String, String>> requestedActions,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        List<ToolCallRequest> toolRequests = new List<ToolCallRequest>();

        for (Integer i = 0; i < requestedActions.size(); i++) {
            Map<String, String> actionMap = requestedActions[i];

            try {
                // Parse tool call details
                String toolCallId = actionMap.get('id');
                String toolName = actionMap.get('name');
                String toolArguments = actionMap.get('arguments');

                if (String.isBlank(toolCallId) || String.isBlank(toolName)) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping malformed tool call at index ' + i + ': missing id or name');
                    continue;
                }

                // Lookup and validate capability
                AgentCapability__c capability = AIAgentConfigService.getCapability(context.agentDefinitionId, toolName);
                if (capability == null) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Skipping tool call ' + toolName + ': capability not found');
                    continue;
                }

                ToolCallRequest toolRequest = new ToolCallRequest(toolCallId, toolName, toolArguments, capability, i + 1);
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
                        ', approval=' +
                        toolRequest.requiresApproval +
                        ')'
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Error parsing tool call at index ' + i + ': ' + e.getMessage());
                continue;
            }
        }

        // Log the tool execution plan
        if (decisionLogger != null && !toolRequests.isEmpty()) {
            Map<String, Object> planData = new Map<String, Object>{
                'totalTools' => toolRequests.size(),
                'syncTools' => getSyncTools(toolRequests).size(),
                'asyncTools' => getAsyncTools(toolRequests).size(),
                'approvalTools' => getApprovalRequiredTools(toolRequests).size(),
                'tools' => new List<Map<String, Object>>()
            };

            for (ToolCallRequest req : toolRequests) {
                ((List<Map<String, Object>>) planData.get('tools'))
                    .add(
                        new Map<String, Object>{
                            'name' => req.toolName,
                            'id' => req.toolCallId,
                            'isAsync' => req.isAsync,
                            'requiresApproval' => req.requiresApproval,
                            'order' => req.executionOrder
                        }
                    );
            }

            decisionLogger.logToolExecution(
                'Tool Execution Plan',
                'LLM requested ' + toolRequests.size() + ' tool(s) for execution',
                JSON.serialize(planData),
                null,
                true,
                null,
                null
            );
        }

        return toolRequests;
    }

    // ===================================================================================
    // TOOL GROUPING
    // ===================================================================================

    /**
     * Groups tool requests by execution mode in a single pass for efficiency.
     * Returns a map with keys: 'approval', 'sync', 'async'
     */
    private Map<String, List<ToolCallRequest>> groupToolsByExecutionMode(List<ToolCallRequest> toolRequests) {
        Map<String, List<ToolCallRequest>> groups = new Map<String, List<ToolCallRequest>>{
            'approval' => new List<ToolCallRequest>(),
            'sync' => new List<ToolCallRequest>(),
            'async' => new List<ToolCallRequest>()
        };

        for (ToolCallRequest tool : toolRequests) {
            if (tool.requiresApproval) {
                groups.get('approval').add(tool);
            } else if (tool.isAsync) {
                groups.get('async').add(tool);
            } else {
                groups.get('sync').add(tool);
            }
        }

        return groups;
    }

    // Legacy methods maintained for backward compatibility with any external callers
    private List<ToolCallRequest> getApprovalRequiredTools(List<ToolCallRequest> toolRequests) {
        List<ToolCallRequest> approvalTools = new List<ToolCallRequest>();
        for (ToolCallRequest tool : toolRequests) {
            if (tool.requiresApproval) {
                approvalTools.add(tool);
            }
        }
        return approvalTools;
    }

    private List<ToolCallRequest> getSyncTools(List<ToolCallRequest> toolRequests) {
        List<ToolCallRequest> syncTools = new List<ToolCallRequest>();
        for (ToolCallRequest tool : toolRequests) {
            if (!tool.isAsync && !tool.requiresApproval) {
                syncTools.add(tool);
            }
        }
        return syncTools;
    }

    private List<ToolCallRequest> getAsyncTools(List<ToolCallRequest> toolRequests) {
        List<ToolCallRequest> asyncTools = new List<ToolCallRequest>();
        for (ToolCallRequest tool : toolRequests) {
            if (tool.isAsync && !tool.requiresApproval) {
                asyncTools.add(tool);
            }
        }
        return asyncTools;
    }

    // ===================================================================================
    // EXECUTION STEP CREATION
    // ===================================================================================

    /**
     * Creates execution step records for all tool calls
     */
    private void createToolCallExecutionSteps(
        OrchestrationContext context,
        List<ToolCallRequest> toolRequests,
        AgentDecisionStepLogger decisionLogger,
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
                    context.llmResult.providerResult.llmCalloutDurationMs
                );

                // Register tool call ID for causality tracking
                if (String.isNotBlank(toolRequest.toolCallId)) {
                    Id toolExecutionStepId = decisionLogger.getLastLoggedStepId();
                    if (toolExecutionStepId != null) {
                        decisionLogger.registerToolCall(toolRequest.toolCallId, toolExecutionStepId);
                    }
                }

                System.debug(LoggingLevel.DEBUG, logPrefix + 'Created execution step for tool call: ' + toolRequest.toolName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution step for tool ' + toolRequest.toolName + ': ' + e.getMessage());
            }
        }
    }

    // ===================================================================================
    // APPROVAL HANDLING
    // ===================================================================================

    /**
     * Handles tools that require human approval.
     * For simplicity in Phase 1: If ANY tool requires approval, treat first approval tool and pause execution.
     * Future enhancement: Could batch multiple approval requests or handle mixed scenarios.
     */
    private String handleApprovalRequiredTools(
        OrchestrationContext context,
        Id savedUserMessageId,
        Id savedAssistantMessageId,
        LLMInteractionService.MessageData assistantData,
        List<ToolCallRequest> approvalTools,
        String logPrefix,
        AgentDecisionStepLogger decisionLogger
    ) {
        // For now, handle first approval tool (could be enhanced to handle multiple)
        ToolCallRequest approvalTool = approvalTools[0];

        System.debug(LoggingLevel.INFO, logPrefix + 'Tool "' + approvalTool.toolName + '" requires approval. Submitting approval request and pausing turn.');

        // Log the approval requirement
        decisionLogger.logToolExecution(
            'Approval Required',
            'Tool execution requires human approval',
            JSON.serialize(new Map<String, Object>{ 'toolName' => approvalTool.toolName, 'reason' => 'RequiresApproval__c is true' }),
            null,
            true,
            null,
            null
        );

        // Extract confirmation message from tool arguments
        String submissionComment = this.extractSubmissionComment(approvalTool.toolArguments, approvalTool.toolName, logPrefix);
        if (String.isBlank(submissionComment)) {
            String errMsg = 'Agent did not provide a required confirmation prompt for approval-required action "' + approvalTool.toolName + '".';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, errMsg, AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, logPrefix);
            decisionLogger.logError(
                'Missing Confirmation Prompt',
                'Agent did not provide required confirmation prompt',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                errMsg,
                null,
                null
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Create approval request record
        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            AgentExecution__c = context.executionId,
            OriginalAssistantStep__c = savedAssistantMessageId,
            LLMConfirmationMessage__c = submissionComment,
            LLMToolCallId__c = approvalTool.toolCallId,
            LLMToolName__c = approvalTool.toolName,
            LLMToolArgumentsJSON__c = approvalTool.toolArguments,
            OriginalTurnIdentifier__c = context.turnIdentifier,
            OriginalTurnCount__c = context.currentTurnCount,
            ApprovalStatus__c = 'Pending'
        );

        try {
            insert har;
        } catch (Exception e) {
            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Failed to create approval request record: ' + e.getMessage(),
                AIAgentConstants.ERR_CODE_DML_ERROR,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        try {
            // Submit approval request to Salesforce approval process
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(har.Id);
            req.setComments('Submitted by AI Agent. Justification: ' + submissionComment);
            Approval.ProcessResult result = Approval.process(req);

            if (result.isSuccess()) {
                update new HumanApprovalRequest__c(Id = har.Id, RelatedApprovalProcessInstanceId__c = result.getInstanceId());
            } else {
                String submissionErrors = '';
                for (Database.Error err : result.getErrors()) {
                    submissionErrors += err.getMessage() + '; ';
                }
                throw new ToolProcessingException('Failed to submit request to approval process: ' + submissionErrors);
            }
        } catch (Exception approvalEx) {
            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'Failed to start approval process: ' + approvalEx.getMessage(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                logPrefix
            );
            delete har;
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Save pending status as tool result
        String toolResultContent = JSON.serialize(
            new Map<String, String>{
                'status' => 'pending_approval',
                'message' => 'The action ' +
                approvalTool.toolName +
                ' has been submitted for Salesforce Approval.'
            }
        );

        ExecutionStepService executionStepService = new ExecutionStepService();
        executionStepService.createToolResultStep(
            context.executionId,
            approvalTool.toolCallId,
            approvalTool.capability.CapabilityName__c,
            toolResultContent,
            context.turnIdentifier,
            context.currentTurnCount,
            0L,
            false
        );

        // Queue follow-up LLM call to inform user
        context.agentStateSvc.resumeForFollowUpLlmCall(context.executionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.executionId,
            context.originalUserId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    // ===================================================================================
    // SYNCHRONOUS EXECUTION
    // ===================================================================================

    /**
     * Executes all synchronous tools immediately in the same transaction
     */
    private List<ToolExecutionResult> executeSynchronousTools(
        OrchestrationContext context,
        List<ToolCallRequest> syncTools,
        AgentDecisionStepLogger decisionLogger,
        String logPrefix
    ) {
        List<ToolExecutionResult> syncResults = new List<ToolExecutionResult>();

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + syncTools.size() + ' synchronous tool(s)');

        for (ToolCallRequest toolRequest : syncTools) {
            try {
                Long startTime = System.currentTimeMillis();

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
                    toolRequest.executionOrder
                );

                syncResults.add(result);

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Executed sync tool ' + toolRequest.toolName + ' in ' + processingTime + 'ms (success=' + outcome.isSuccess + ')'
                );

                // Log the tool execution result
                if (decisionLogger != null) {
                    decisionLogger.logToolResult(
                        'Synchronous Tool Executed',
                        'Tool ' + toolRequest.toolName + ' executed synchronously',
                        JSON.serialize(outcome),
                        processingTime,
                        outcome.isSuccess,
                        outcome.errorCode,
                        outcome.errorMessage
                    );
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
                    toolRequest.executionOrder
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
        AgentDecisionStepLogger decisionLogger,
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
                    false
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution step for sync tool result ' + result.toolName + ': ' + e.getMessage());
            }
        }
    }

    // ===================================================================================
    // ASYNCHRONOUS EXECUTION
    // ===================================================================================

    /**
     * Queues asynchronous tools for separate transaction execution.
     * Initializes atomic tracking counter before queuing to enable race-condition-free completion detection.
     * Handles queue failures by decrementing the counter to prevent execution hangs.
     */
    private void queueAsyncTools(OrchestrationContext context, List<ToolCallRequest> asyncTools, AgentDecisionStepLogger decisionLogger, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Queuing ' + asyncTools.size() + ' asynchronous tool(s)');

        // Track successfully queued tools to handle partial failures
        Integer successfullyQueued = 0;
        List<String> failedTools = new List<String>();

        // Initialize the atomic async tool tracking counter BEFORE queuing any tools
        // This ensures the counter is set before any async tool can complete
        OrchestrationService.initializeAsyncToolTracking(context.executionId, context.turnIdentifier, asyncTools.size(), logPrefix);

        // Pause the turn for async action processing
        context.agentStateSvc.pauseForAsyncAction(context.executionId, context.turnIdentifier, null, 'Async Tools', logPrefix);

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
                        true // isError
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
                decisionLogger.logError(
                    'Async Tool Queue Partial Failure',
                    'Some async tools failed to queue',
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    'Failed to queue: ' + String.join(failedTools, ', '),
                    null,
                    null
                );
            }
        }
    }

    // ===================================================================================
    // ORCHESTRATION FLOW
    // ===================================================================================

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
                if (capability != null && OrchestrationService.shouldFailFast(capability, agentDef, result.outcome, logPrefix)) {
                    shouldHalt = true;
                    context.agentStateSvc.failTurn(
                        context.executionId,
                        context.turnIdentifier,
                        'Tool execution failed (fail-fast policy): ' + result.outcome.errorMessage,
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
        if (context.currentPageRecordId != null) {
            try {
                context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit context: ' + e.getMessage());
            }
        }

        // Enforce max turn limit
        Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
        if ((context.currentTurnCount + 1) > maxTurns) {
            String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') exceeded.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, limitErrorMsg, AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED, logPrefix);
            return OrchestrationService.OUTCOME_FAILED;
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
            false
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    /**
     * Extracts the submission comment (confirmation prompt) from the tool arguments JSON.
     */
    private String extractSubmissionComment(String argumentsJson, String capabilityName, String logPrefix) {
        if (String.isBlank(argumentsJson))
            return null;
        try {
            Map<String, Object> argsMap = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
            Object commentValue = argsMap.get(LLMFormattingService.SUBMISSION_COMMENT_PARAM_NAME);
            return (commentValue != null && commentValue instanceof String) ? (String) commentValue : null;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to parse confirmation message for ' + capabilityName + ': ' + e.getMessage());
            return null;
        }
    }
}
