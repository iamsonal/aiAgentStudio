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

            if (String.isNotBlank(assistantData.content)) {
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
            actionResult = new ActionResult(
                'Action failed internally: ' + execEx.getMessage(),
                execEx.getStackTraceString(),
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION
            );
        } finally {
            actionDuration = System.currentTimeMillis() - syncActionStart;
        }

        if (actionResult == null) {
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
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

        if (actionResult == null) {
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
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
                context.originalUserId,
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
                context.originalUserId,
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
}
