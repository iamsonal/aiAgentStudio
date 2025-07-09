/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Strategy implementation for handling LLM responses that request a tool call.
 *              Contains the logic for validation, approval checks, and sync/async execution.
 */
public class ToolCallResponseHandler implements ILLMResponseHandler {
    public class ToolProcessingException extends AIAgentException {
    }

    /**
     * @description Main entry point. Handles the entire tool call process.
     * @param context The orchestration context containing all necessary state and services.
     * @return String An outcome constant (e.g., OrchestrationService.OUTCOME_QUEUED_ACTION).
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        Map<String, String> firstActionRequestMap = context.llmResult.providerResult.requestedActions[0];
        AIAssistantController.ActionRequest toolRequest = this.parseToolRequestMap(firstActionRequestMap);

        AgentCapability__c capability = AIAgentConfigService.getCapability(context.agentDefinitionId, toolRequest.name);
        this.validateCapability(capability, toolRequest.name, logPrefix);

        if (String.isNotBlank(capability.ExecutionPrerequisites__c)) {
            List<String> missingPrerequisites = findMissingPrerequisites(capability, context, logPrefix);

            if (!missingPrerequisites.isEmpty()) {
                return handleMissingPrerequisites(context, toolRequest, capability, missingPrerequisites);
            }
        }

        Id savedUserMessageId = ChatMessageService.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            context.currentPageRecordId,
            logPrefix
        );

        if (capability.RequiresApproval__c) {
            return this.handleApprovalRequiredAction(context, savedUserMessageId, assistantData, toolRequest, capability, logPrefix);
        } else {
            Id savedAssistantMessageId = ChatMessageService.saveAssistantMessage(
                context.sessionId,
                context.turnIdentifier,
                savedUserMessageId,
                assistantData,
                toolRequest.name,
                logPrefix
            );

            if (AIAgentFrameworkSettings.useTransientMessages() && String.isNotBlank(assistantData.content)) {
                try {
                    TransientMessage__e event = new TransientMessage__e(
                        ChatSessionId__c = context.sessionId,
                        MessageId__c = savedAssistantMessageId,
                        MessageContent__c = assistantData.content
                    );
                    EventBus.publish(event);
                } catch (Exception e) {
                }
            }

            return this.executeActionDirectly(context, savedAssistantMessageId, toolRequest, capability, logPrefix);
        }
    }

    /**
     * @description Executes the action, branching between synchronous and asynchronous paths.
     * @param context The orchestration context.
     * @param savedAssistantMessageId The ID of the saved assistant message requesting the action.
     * @param toolRequest The parsed tool request from the LLM.
     * @param capability The fully queried AgentCapability__c record.
     * @param logPrefix A logging prefix.
     * @return String An outcome constant.
     */
    private String executeActionDirectly(
        OrchestrationContext context,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix
    ) {
        Boolean runAsync = capability.RunAsynchronously__c;

        if (!runAsync) {
            return this.executeSyncActionAndContinue(context, savedAssistantMessageId, toolRequest, capability, logPrefix);
        } else {
            context.turnLifecycleSvc.pauseForAsyncAction(context.sessionId, context.turnIdentifier, null, capability.CapabilityName__c, logPrefix);

            context.dispatchSvc.enqueueAsyncAction(
                context.sessionId,
                context.userId,
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
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }
    }

    /**
     * @description Handles the specific flow for actions that require Salesforce Approval.
     *              This involves creating a HumanApprovalRequest__c record and finalizing the turn.
     */
    private String handleApprovalRequiredAction(
        OrchestrationContext context,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix
    ) {
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
            return OrchestrationService.OUTCOME_FAILED;
        }

        Id assistantMessageId = ChatMessageService.saveAssistantMessageWithPendingAction(
            context.sessionId,
            context.turnIdentifier,
            savedUserMessageId,
            assistantData,
            assistantData.assistantToolCallsJson,
            toolRequest.name,
            logPrefix
        );

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
            return OrchestrationService.OUTCOME_FAILED;
        }

        try {
            Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();

            req.setObjectId(har.Id);

            req.setComments('Submitted by AI Agent on behalf of user. Justification: ' + submissionComment);

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
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                'Failed to start approval process: ' + approvalEx.getMessage(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                logPrefix
            );

            delete har;
            return OrchestrationService.OUTCOME_FAILED;
        }

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

        context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.sessionId,
            context.userId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    /**
     * @description Executes a synchronous action, processes its result, and determines the next step for the conversation.
     */
    private String executeSyncActionAndContinue(
        OrchestrationContext context,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        String logPrefix
    ) {
        Id actionRecordContextId = context.currentPageRecordId;

        ActionContext actionContext = new ActionContext(
            context.sessionId,
            context.userId,
            actionRecordContextId,
            context.agentDefinitionId,
            capability.Id,
            capability.PreExecutionHook__c,
            capability.PostExecutionHook__c,
            capability.ImplementationDetail__c
        );

        ActionResult actionResult = null;
        Long actionDuration = 0L;
        Long syncActionStart = System.currentTimeMillis();

        try {
            actionResult = context.actionExecSvc.executeSingleAction(capability, toolRequest.arguments, actionContext);
        } catch (Exception execEx) {
            actionResult = new ActionResult(
                'Action failed internally: ' + execEx.getMessage(),
                execEx.getStackTraceString(),
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION
            );
        } finally {
            actionDuration = System.currentTimeMillis() - syncActionStart;
        }

        String resultJsonForStorage = OrchestrationService.serializeActionResult(actionResult, logPrefix);
        Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);

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

        if (actionResult.isSuccess && newRecordContextId != null) {
            try {
                context.contextManagerSvc.commitTurnContext(
                    context.sessionId,
                    context.currentTurnCount,
                    context.currentPageRecordId,
                    newRecordContextId
                );
            } catch (Exception e) {
            }
        }

        if (actionResult.isSuccess || capability.HaltAndReportError__c == false) {
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((context.currentTurnCount + 1) > maxTurns) {
                String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') would be exceeded. The turn cannot continue.';

                context.turnLifecycleSvc.failTurn(
                    context.sessionId,
                    context.turnIdentifier,
                    limitErrorMsg,
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_FAILED;
            }

            context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);

            context.dispatchSvc.enqueueFollowUp(
                context.sessionId,
                context.userId,
                context.agentDefinitionId,
                context.turnIdentifier,
                context.currentTurnCount + 1,
                logPrefix,
                false
            );
            return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
        } else {
            context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);

            context.dispatchSvc.enqueueFollowUp(
                context.sessionId,
                context.userId,
                context.agentDefinitionId,
                context.turnIdentifier,
                context.currentTurnCount + 1,
                logPrefix,
                true
            );
            return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
        }
    }

    private AIAssistantController.ActionRequest parseToolRequestMap(Map<String, String> requestMap) {
        AIAssistantController.ActionRequest req = new AIAssistantController.ActionRequest();
        req.id = requestMap?.get('id');
        req.name = requestMap?.get('name');
        req.arguments = requestMap?.get('arguments');
        if (String.isBlank(req.id) || String.isBlank(req.name) || req.arguments == null) {
            throw new ToolProcessingException(
                'Parsed LLM tool request missing id, name, or arguments JSON. RequestMap: ' + JSON.serialize(requestMap)
            );
        }
        return req;
    }

    private void validateCapability(AgentCapability__c capability, String capabilityName, String logPrefix) {
        if (capability == null) {
            throw new OrchestrationService.ConfigurationException('Active AgentCapability not found for name: "' + capabilityName + '"');
        }
    }

    private String extractSubmissionComment(String argumentsJson, String capabilityName, String logPrefix) {
        if (String.isBlank(argumentsJson))
            return null;
        try {
            Map<String, Object> argsMap = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
            Object confirmationObj = argsMap.get(ToolDefinitionFormatter.SUBMISSION_COMMENT_PARAM_NAME);
            return (confirmationObj instanceof String && String.isNotBlank((String) confirmationObj)) ? (String) confirmationObj : null;
        } catch (Exception e) {
            return null;
        }
    }

    /**
     * @description (NEW and COMPLETE) Handles the case where prerequisites are missing by generating a synthetic
     *              error response to guide the LLM. This is the implementation for the "Error Feedback Loop".
     * @param context The orchestration context.
     * @param toolRequest The original tool request from the LLM.
     * @param capability The capability that was attempted.
     * @param missingTools The list of prerequisite capability names that are missing.
     * @return The final outcome for the orchestrator (OUTCOME_QUEUED_FOLLOWUP).
     */
    private String handleMissingPrerequisites(
        OrchestrationContext context,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapability__c capability,
        List<String> missingTools
    ) {
        String logPrefix = context.logPrefix + '[PrereqHandler] ';

        String missingToolsString = '\'' + String.join(missingTools, '\', \'') + '\'';
        String errorMessageForLlm =
            'Action \'' +
            capability.CapabilityName__c +
            '\' cannot be used yet. ' +
            'The following prerequisite tool(s) must be successfully used first: ' +
            missingToolsString +
            '. ' +
            'Please use the required tool(s) to proceed.';

        Map<String, Object> errorPayload = new Map<String, Object>{
            'status' => 'ERROR',
            'error' => new Map<String, Object>{ 'code' => 'PREREQUISITE_NOT_MET', 'message' => errorMessageForLlm }
        };

        ActionResult prerequisiteFailureResult = new ActionResult(
            errorPayload,
            'Prerequisites not met. Missing: ' + missingToolsString,
            'PREREQUISITE_NOT_MET'
        );

        Id savedUserMessageId = ChatMessageService.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            context.currentPageRecordId,
            logPrefix
        );
        Id savedAssistantMessageId = ChatMessageService.saveAssistantMessage(
            context.sessionId,
            context.turnIdentifier,
            savedUserMessageId,
            context.llmResult.assistantMessageData,
            toolRequest.name,
            logPrefix
        );

        String resultJsonForStorage = OrchestrationService.serializeActionResult(prerequisiteFailureResult, logPrefix);
        ChatMessageService.saveToolResultMessage(
            context.sessionId,
            context.turnIdentifier,
            savedAssistantMessageId,
            toolRequest.id,
            resultJsonForStorage,
            prerequisiteFailureResult.internalDetails,
            prerequisiteFailureResult.errorCode,
            0L,
            null,
            null,
            capability.CapabilityName__c,
            logPrefix
        );

        context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
        context.dispatchSvc.enqueueFollowUp(
            context.sessionId,
            context.userId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix,
            false
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
    }

    /**
     * @description (REWRITTEN) Checks for missing prerequisites based on the capability's configured validation scope.
     * @param capability The capability being checked for prerequisites.
     * @param context The full orchestration context, providing sessionId and turnIdentifier.
     * @param logPrefix A logging prefix.
     * @return A list of capability names that are required but have not been successfully run.
     */
    private List<String> findMissingPrerequisites(AgentCapability__c capability, OrchestrationContext context, String logPrefix) {
        String prerequisitesString = capability.ExecutionPrerequisites__c;
        String validationScope = capability.PrerequisiteValidation__c;

        List<String> requiredTools = new List<String>();
        for (String toolName : prerequisitesString.split('\\|')) {
            if (String.isNotBlank(toolName.trim())) {
                requiredTools.add(toolName.trim());
            }
        }
        if (requiredTools.isEmpty()) {
            return new List<String>();
        }

        Set<String> fulfilledTools = new Set<String>();

        if ('Entire Session'.equalsIgnoreCase(validationScope)) {
            try {
                for (ChatMessage__c msg : [
                    SELECT CapabilityName__c
                    FROM ChatMessage__c
                    WHERE ChatSession__c = :context.sessionId AND Role__c = 'tool' AND IsSuccess__c = TRUE AND CapabilityName__c != NULL
                ]) {
                    fulfilledTools.add(msg.CapabilityName__c);
                }
            } catch (Exception e) {
                return requiredTools;
            }
        } else {
            try {
                List<ChatMessage__c> toolResultMessages = [
                    SELECT Content__c, ToolCallId__c, ParentMessage__r.AssistantToolCalls__c
                    FROM ChatMessage__c
                    WHERE TurnIdentifier__c = :context.turnIdentifier AND Role__c = 'tool' AND IsSuccess__c = TRUE
                ];

                for (ChatMessage__c msg : toolResultMessages) {
                    String toolName = getToolNameForResultMessage(msg, logPrefix);
                    if (String.isNotBlank(toolName)) {
                        fulfilledTools.add(toolName);
                    }
                }
            } catch (Exception e) {
                return requiredTools;
            }
        }

        List<String> missingTools = new List<String>();
        for (String required : requiredTools) {
            if (!fulfilledTools.contains(required)) {
                missingTools.add(required);
            }
        }

        if (!missingTools.isEmpty()) {
        }

        return missingTools;
    }

    /**
     * @description (NEW HELPER) Determines the capability name that generated a specific tool result message.
     */
    private String getToolNameForResultMessage(ChatMessage__c toolResultMessage, String logPrefix) {
        if (
            toolResultMessage.ParentMessage__r == null ||
            String.isBlank(toolResultMessage.ParentMessage__r.AssistantToolCalls__c) ||
            String.isBlank(toolResultMessage.ToolCallId__c)
        ) {
            return null;
        }

        try {
            List<Object> toolCalls = (List<Object>) JSON.deserializeUntyped(toolResultMessage.ParentMessage__r.AssistantToolCalls__c);
            for (Object callObj : toolCalls) {
                Map<String, Object> callMap = (Map<String, Object>) callObj;
                if (toolResultMessage.ToolCallId__c.equals(callMap.get('id'))) {
                    Map<String, Object> functionMap = (Map<String, Object>) callMap.get('function');
                    return (String) functionMap.get('name');
                }
            }
        } catch (Exception e) {
        }

        return null;
    }

    /**
     * @description Inspects the JSON content of a tool result to determine if it was successful.
     */
    private Boolean wasToolExecutionSuccessful(String resultContentJson, String logPrefix) {
        if (String.isBlank(resultContentJson)) {
            return false;
        }

        try {
            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(resultContentJson);

            Object statusValue = payload.get('status');
            return (statusValue instanceof String && 'SUCCESS'.equalsIgnoreCase((String) statusValue));
        } catch (Exception e) {
            return false;
        }
    }
}
