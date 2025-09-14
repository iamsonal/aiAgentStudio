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
 *   - Validates and interprets tool call requests from LLM output.
 *   - Determines whether tool execution requires human approval or can proceed autonomously.
 *   - Manages both synchronous and asynchronous execution paths for tool actions, including queuing and follow-up.
 *   - Integrates with chat history, approval processes, and orchestration services to maintain robust conversation and action state.
 *   - Ensures traceability and error handling throughout the tool call process, providing clear runtime diagnostics and developer insight.
 *
 * This class is central to bridging LLM-driven intent with secure, auditable, and extensible tool execution in the agent orchestration framework.
 */
public class ToolCallResponseHandler implements ILLMResponseHandler {
    public class ToolProcessingException extends AIAgentException {
    }

    /**
     * Entry point for handling a tool call request from an LLM response.
     *
     * Examines the requested action, validates agent capability, and determines whether to route
     * the request through a human approval workflow or execute it directly (synchronously or asynchronously).
     *
     * @param context OrchestrationContext containing session state, LLM result, and service references.
     * @return String outcome constant indicating the next orchestration step (e.g., queued, failed, follow-up).
     * @throws ToolProcessingException if the tool request is malformed or capability is missing.
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting tool call handling for LLM response.');

        // Use the shared decision step logger from the context
        AgentDecisionStepLogger decisionLogger = context.decisionLogger;

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        // Currently, only one tool call per turn is supported. Extend here for parallel tool calls if needed.
        Map<String, String> firstActionRequestMap = context.llmResult.providerResult.requestedActions[0];
        AIAssistantController.ActionRequest toolRequest = this.parseToolRequestMap(firstActionRequestMap);

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Parsed tool request: Capability=' + toolRequest.name + ', ToolCallID=' + toolRequest.id);

        // Retrieve capability configuration for the requested tool
        AgentCapability__c capability = AIAgentConfigService.getCapability(context.agentDefinitionId, toolRequest.name);
        this.validateCapability(capability, toolRequest.name, logPrefix);

        // Log the tool execution preparation step with enhanced details
        decisionLogger.logToolExecution(
            'Tool Execution Plan',
            'Preparing to execute tool: ' + toolRequest.name,
            JSON.serialize(
                new Map<String, Object>{
                    'toolName' => toolRequest.name,
                    'toolId' => toolRequest.id,
                    'arguments' => toolRequest.arguments,
                    'capability' => capability != null
                        ? new Map<String, Object>{
                              'name' => capability.CapabilityName__c,
                              'requiresApproval' => capability.RequiresApproval__c,
                              'runAsynchronously' => capability.RunAsynchronously__c
                          }
                        : null
                }
            ),
            null,
            true, // isSuccess
            null, // errorCode
            null // errorMessage
        );

        // Persist user message to chat history for traceability
        Id savedUserMessageId = ChatMessageService.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            context.currentPageRecordId,
            logPrefix
        );

        // Route to approval workflow or direct execution based on capability settings
        if (capability.RequiresApproval__c) {
            return this.handleApprovalRequiredAction(context, savedUserMessageId, assistantData, toolRequest, capability, logPrefix, decisionLogger);
        } else {
            // Save assistant message containing the tool call request for audit and context
            Id savedAssistantMessageId = ChatMessageService.saveAssistantMessage(
                context.sessionId,
                context.turnIdentifier,
                savedUserMessageId,
                assistantData,
                toolRequest.name,
                logPrefix
            );

            if (String.isNotBlank(assistantData.content)) {
                try {
                    TransientMessage__e event = new TransientMessage__e(
                        ChatSessionId__c = context.sessionId,
                        MessageId__c = savedAssistantMessageId,
                        MessageContent__c = assistantData.content
                    );
                    EventBus.publish(event);
                    System.debug(LoggingLevel.INFO, logPrefix + 'Published TransientMessage__e for UI update (assistant content).');
                } catch (Exception e) {
                    System.debug(
                        LoggingLevel.WARN,
                        logPrefix + 'Non-critical: Failed to publish TransientMessage__e for UI. Error: ' + e.getMessage()
                    );
                }
            }

            return this.executeActionDirectly(context, savedAssistantMessageId, toolRequest, capability, logPrefix, decisionLogger);
        }
    }

    /**
     * Determines whether to execute the tool action synchronously or asynchronously based on capability configuration.
     *
     * If asynchronous, queues the action and pauses the turn; if synchronous, executes immediately and continues the conversation.
     *
     * @param context OrchestrationContext for the current turn.
     * @param savedAssistantMessageId Id of the assistant message containing the tool call.
     * @param toolRequest Parsed ActionRequest from the LLM.
     * @param capability AgentCapability__c record for the tool.
     * @param logPrefix String prefix for log output.
     * @param decisionLogger AgentDecisionStepLogger instance for logging decision steps.
     * @return String outcome constant for orchestration flow.
     */
    private String executeActionDirectly(
        OrchestrationContext context,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix,
        AgentDecisionStepLogger decisionLogger
    ) {
        Boolean runAsync = capability.RunAsynchronously__c;
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing tool action "' + toolRequest.name + '". Async=' + runAsync);

        if (!runAsync) {
            // Synchronous execution: continue conversation in same transaction
            return this.executeSyncActionAndContinue(context, savedAssistantMessageId, toolRequest, capability, logPrefix, decisionLogger);
        } else {
            // Asynchronous execution: queue and pause turn for later resumption
            context.turnLifecycleSvc.pauseForAsyncAction(context.sessionId, context.turnIdentifier, null, capability.CapabilityName__c, logPrefix);
            context.dispatchSvc.enqueueAsyncAction(
                context.sessionId,
                context.originalUserId,
                context.agentDefinitionId,
                savedAssistantMessageId,
                toolRequest.id,
                toolRequest.arguments,
                capability,
                context.currentPageRecordId,
                context.turnIdentifier,
                context.currentTurnCount,
                logPrefix
            );
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool action queued for asynchronous execution.');
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }
    }

    /**
     * Handles tool actions that require human approval via Salesforce approval process.
     *
     * Persists the approval request, submits it to the approval workflow, and manages error handling and cleanup.
     * Also saves the pending status to chat history and queues a follow-up LLM call to inform the user.
     *
     * @param context OrchestrationContext for the current turn.
     * @param savedUserMessageId Id of the user message for this turn.
     * @param assistantData LLMInteractionService.MessageData for the assistant's response.
     * @param toolRequest Parsed ActionRequest from the LLM.
     * @param capability AgentCapability__c record for the tool.
     * @param logPrefix String prefix for log output.
     * @param decisionLogger AgentDecisionStepLogger instance for logging decision steps.
     * @return String outcome constant for orchestration flow.
     */
    private String handleApprovalRequiredAction(
        OrchestrationContext context,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix,
        AgentDecisionStepLogger decisionLogger
    ) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Tool action "' + toolRequest.name + '" requires Salesforce Approval. Submitting approval request and finalizing turn.'
        );

        // Log the approval requirement step with enhanced details
        decisionLogger.logToolExecution(
            'Approval Required',
            'Tool execution requires human approval',
            JSON.serialize(new Map<String, Object>{ 'toolName' => toolRequest.name, 'reason' => 'RequiresApproval__c is true for this capability' }),
            null,
            true, // isSuccess
            null, // errorCode
            null // errorMessage
        );

        String submissionComment = this.extractSubmissionComment(toolRequest.arguments, toolRequest.name, logPrefix);
        if (String.isBlank(submissionComment)) {
            String errMsg = 'Agent did not provide a required confirmation prompt for approval-required action "' + toolRequest.name + '".';
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                errMsg,
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );

            // Log the error step
            decisionLogger.logError(
                'Missing Confirmation Prompt',
                'Agent did not provide a required confirmation prompt for approval',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                errMsg,
                null,
                null
            );

            System.debug(LoggingLevel.ERROR, logPrefix + 'Missing confirmation prompt for approval-required action. Failing turn.');
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Save assistant message with pending action status for audit and context
        Id assistantMessageId = ChatMessageService.saveAssistantMessageWithPendingAction(
            context.sessionId,
            context.turnIdentifier,
            savedUserMessageId,
            assistantData,
            assistantData.assistantToolCallsJson,
            toolRequest.name,
            logPrefix
        );

        // Create approval request record for Salesforce approval process
        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = context.sessionId,
            OriginalAssistantMessage__c = assistantMessageId,
            LLMConfirmationMessage__c = submissionComment,
            LLMToolCallId__c = toolRequest.id,
            LLMToolName__c = toolRequest.name,
            LLMToolArgumentsJSON__c = toolRequest.arguments,
            OriginalTurnIdentifier__c = context.turnIdentifier,
            OriginalTurnCount__c = context.currentTurnCount,
            ApprovalStatus__c = 'Pending'
        );
        try {
            insert har;
        } catch (Exception e) {
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                'Failed to create approval request record: ' + e.getMessage(),
                AIAgentConstants.ERR_CODE_DML_ERROR,
                logPrefix
            );
            OrchestrationService.clearPendingDetailsFromMessage(assistantMessageId, logPrefix);
            System.debug(LoggingLevel.ERROR, logPrefix + 'DML error inserting HumanApprovalRequest__c: ' + e.getMessage());
            return OrchestrationService.OUTCOME_FAILED;
        }

        try {
            // Submit approval request to Salesforce approval process
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
            req.setObjectId(har.Id);
            req.setComments('Submitted by AI Agent on behalf of user. Justification: ' + submissionComment);
            Approval.ProcessResult result = Approval.process(req);
            if (result.isSuccess()) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        'HumanApprovalRequest__c ' +
                        har.Id +
                        ' successfully submitted to approval process. Instance ID: ' +
                        result.getInstanceId()
                );

                // Store process instance ID for tracking approval status
                update new HumanApprovalRequest__c(Id = har.Id, RelatedApprovalProcessInstanceId__c = result.getInstanceId());
            } else {
                String submissionErrors = '';
                for (Database.Error err : result.getErrors()) {
                    submissionErrors += err.getMessage() + '; ';
                }
                throw new ToolProcessingException('Failed to submit request to approval process: ' + submissionErrors);
            }
        } catch (Exception approvalEx) {
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                'Failed to start approval process: ' + approvalEx.getMessage(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                logPrefix
            );
            delete har; // Clean up orphaned approval request
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Approval process submission failed. Orphaned request deleted. Error: ' + approvalEx.getMessage()
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        // Save pending status as tool result for LLM context in next turn
        String toolResultContent = JSON.serialize(
            new Map<String, String>{
                'status' => 'pending_approval',
                'message' => 'The action ' +
                toolRequest.name +
                ' has been submitted for Salesforce Approval.'
            }
        );
        ChatMessageService.saveToolResultMessage(
            context.sessionId,
            context.turnIdentifier,
            assistantMessageId,
            toolRequest.id,
            toolResultContent,
            null,
            null,
            0L,
            null,
            null,
            capability.CapabilityName__c,
            logPrefix
        );

        // Queue follow-up LLM call to inform user about pending approval
        context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.sessionId,
            context.originalUserId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    /**
     * Executes a tool action synchronously and processes the result to determine the next conversation step.
     *
     * Handles both successful and failed outcomes, updating chat history and context as needed.
     * May queue a follow-up LLM call or halt the conversation based on capability configuration and result.
     *
     * @param context OrchestrationContext for the current turn.
     * @param savedAssistantMessageId Id of the assistant message containing the tool call.
     * @param toolRequest Parsed ActionRequest from the LLM.
     * @param capability AgentCapability__c record for the tool.
     * @param logPrefix String prefix for log output.
     * @param decisionLogger AgentDecisionStepLogger instance for logging decision steps.
     * @return String outcome constant for orchestration flow.
     */
    private String executeSyncActionAndContinue(
        OrchestrationContext context,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix,
        AgentDecisionStepLogger decisionLogger
    ) {
        // Use current page record as action context for tool execution
        Id actionRecordContextId = context.currentPageRecordId;
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Resolved action context record ID: ' + actionRecordContextId);

        // Build action execution context
        ActionContext actionContext = new ActionContext(
            context.sessionId,
            context.originalUserId,
            context.executionUserId,
            actionRecordContextId,
            context.agentDefinitionId,
            capability.Id,
            capability.ImplementationDetail__c,
            context.turnIdentifier,
            context.currentTurnCount
        );

        ActionResult actionResult = null;
        Long actionDuration = 0L;
        Long syncActionStart = System.currentTimeMillis();

        try {
            actionResult = context.actionExecSvc.executeSingleAction(capability, toolRequest.arguments, actionContext);
        } catch (Exception execEx) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Unhandled exception during synchronous tool execution: ' + execEx.getMessage() + '\n' + execEx.getStackTraceString()
            );
            actionResult = new ActionResult(
                'Action failed internally: ' + execEx.getMessage(),
                execEx.getStackTraceString(),
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION
            );
        } finally {
            actionDuration = System.currentTimeMillis() - syncActionStart;
        }

        // Save tool result to chat history before any follow-up processing
        String resultJsonForStorage = OrchestrationService.serializeActionResult(actionResult, logPrefix);
        Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);

        // Log the tool result step with full ActionResult details
        decisionLogger.logToolResult(
            'Tool Execution Completed',
            'Tool execution has completed',
            resultJsonForStorage,
            actionDuration,
            actionResult.isSuccess, // isSuccess
            actionResult.errorCode, // errorCode
            actionResult.internalDetails // errorMessage
        );

        ChatMessageService.saveToolResultMessage(
            context.sessionId,
            context.turnIdentifier,
            savedAssistantMessageId,
            toolRequest.id,
            resultJsonForStorage,
            actionResult?.internalDetails,
            actionResult?.errorCode,
            actionDuration,
            newRecordContextId,
            resultJsonForStorage,
            capability.CapabilityName__c,
            logPrefix
        );

        // If a new record was created, update the context ledger for future turns
        if (actionResult.isSuccess && newRecordContextId != null) {
            try {
                context.contextManagerSvc.commitTurnContext(
                    context.sessionId,
                    context.currentTurnCount,
                    context.currentPageRecordId,
                    newRecordContextId
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit new record context to ledger: ' + e.getMessage());
            }
        }

        // Determine next orchestration step based on result and capability configuration
        if (actionResult == null) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool action transitioned to async. Sync portion complete.');
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }
        if (actionResult.isSuccess || capability.HaltAndReportError__c == false) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Tool action succeeded or is configured for autonomous recovery. Continuing agent loop.');

            // Enforce maximum turn limit to prevent infinite loops
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((context.currentTurnCount + 1) > maxTurns) {
                String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') would be exceeded. The turn cannot continue.';
                System.debug(LoggingLevel.WARN, logPrefix + limitErrorMsg + ' Failing turn.');
                context.turnLifecycleSvc.failTurn(
                    context.sessionId,
                    context.turnIdentifier,
                    limitErrorMsg,
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_FAILED;
            }

            // Queue follow-up LLM call with updated tool result in conversation history
            context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
            context.dispatchSvc.enqueueFollowUp(
                context.sessionId,
                context.originalUserId,
                context.agentDefinitionId,
                context.turnIdentifier,
                context.currentTurnCount + 1,
                logPrefix,
                false
            );
            return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
        } else {
            // Action failed and is configured to halt - dispatch final error formulation call
            System.debug(LoggingLevel.WARN, logPrefix + 'Tool action failed and is configured to HALT. Dispatching final error-formulation call.');
            context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
            context.dispatchSvc.enqueueFollowUp(
                context.sessionId,
                context.originalUserId,
                context.agentDefinitionId,
                context.turnIdentifier,
                context.currentTurnCount + 1,
                logPrefix,
                true // Final error turn
            );
            return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
        }
    }

    // -------------------------------------------------------------------------
    // Helper methods for tool request processing
    // -------------------------------------------------------------------------

    /**
     * Parses a tool request map from the LLM into a strongly-typed ActionRequest.
     * Throws ToolProcessingException if required fields are missing.
     */
    private AIAssistantController.ActionRequest parseToolRequestMap(Map<String, String> requestMap) {
        AIAssistantController.ActionRequest req = new AIAssistantController.ActionRequest();
        req.id = requestMap?.get('id');
        req.name = requestMap?.get('name');
        req.arguments = requestMap?.get('arguments');
        if (String.isBlank(req.id) || String.isBlank(req.name) || req.arguments == null) {
            throw new ToolProcessingException(
                'Malformed LLM tool request: missing id, name, or arguments. RequestMap: ' + JSON.serialize(requestMap)
            );
        }
        return req;
    }

    /**
     * Validates that the given AgentCapability__c is present. Throws ConfigurationException if not found.
     */
    private void validateCapability(AgentCapability__c capability, String capabilityName, String logPrefix) {
        if (capability == null) {
            throw new OrchestrationService.ConfigurationException('Active AgentCapability not found for name: "' + capabilityName + '"');
        }
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Capability validated: ' + capabilityName);
    }

    /**
     * Extracts the submission comment (confirmation prompt) from the tool arguments JSON.
     * Returns null if not present or if parsing fails.
     */
    private String extractSubmissionComment(String argumentsJson, String capabilityName, String logPrefix) {
        if (String.isBlank(argumentsJson))
            return null;
        try {
            Map<String, Object> argsMap = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
            return ActionConfigUtils.getOptionalString(argsMap, ToolDefinitionFormatter.SUBMISSION_COMMENT_PARAM_NAME);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to parse confirmation message for ' + capabilityName + ': ' + e.getMessage());
            return null;
        }
    }
}
