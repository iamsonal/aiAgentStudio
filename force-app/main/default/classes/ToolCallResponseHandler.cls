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

    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ToolCallHandler] ';

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;
        List<Map<String, String>> requestedActions = context.llmResult.providerResult.requestedActions;

        Map<String, String> firstActionRequestMap = requestedActions[0];
        AIAssistantController.ActionRequest toolRequest = this.parseToolRequestMap(firstActionRequestMap);

        AgentCapabilityBinding__c binding = AIAgentConfigService.getCapabilityBinding(context.agentDefinitionId, toolRequest.name);
        this.validateBinding(binding, toolRequest.name, logPrefix);

        Id savedUserMessageId = context.msgPersistenceSvc.saveUserMessage(
            context.sessionId,
            context.turnIdentifier,
            context.userMessageData,
            context.relatedRecordId,
            logPrefix
        );

        if (binding.RequiresHumanApproval__c == true) {
            return this.handleApprovalRequiredAction(context, savedUserMessageId, assistantData, toolRequest, binding, logPrefix);
        } else {
            Id savedAssistantMessageId = context.msgPersistenceSvc.saveAssistantMessage(
                context.sessionId,
                savedUserMessageId,
                assistantData,
                logPrefix
            );
            return this.executeActionDirectly(context, savedAssistantMessageId, toolRequest, binding, logPrefix);
        }
    }

    private String executeActionDirectly(
        OrchestrationContext context,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapabilityBinding__c binding,
        String logPrefix
    ) {
        Id actionDefId = binding.ActionDefinition__c;
        Boolean runAsync = binding.ActionDefinition__r.RunAsynchronously__c == true;
        String bindingConfigJson = binding.ActionConfiguration__c;

        if (!runAsync) {
            ActionContext actionContext = new ActionContext(
                context.sessionId,
                context.userId,
                context.relatedRecordId,
                context.agentDefinitionId,
                binding.Id,
                actionDefId
            );
            ActionResult actionResult = null;
            Long actionDuration = 0L;
            Long syncActionStart = System.currentTimeMillis();
            try {
                actionResult = context.actionExecSvc.executeSingleAction(actionDefId, bindingConfigJson, toolRequest.arguments, actionContext);
            } catch (Exception execEx) {
                actionResult = new ActionResult(
                    'Action failed internally: ' + execEx.getMessage(),
                    execEx.getStackTraceString(),
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION
                );
            } finally {
                actionDuration = System.currentTimeMillis() - syncActionStart;
            }
            String toolResultContentJson = OrchestrationService.serializeActionResult(actionResult, logPrefix);
            Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);
            String newRecordContextData = (newRecordContextId != null) ? toolResultContentJson : null;

            Id savedToolMsgId = context.msgPersistenceSvc.saveToolResultMessage(
                context.sessionId,
                savedAssistantMessageId,
                toolRequest.id,
                toolResultContentJson,
                actionResult?.internalDetails,
                actionResult?.errorCode,
                actionDuration,
                newRecordContextId,
                newRecordContextData,
                logPrefix
            );
            return this.handleSyncActionResult(context, (actionResult != null && actionResult.isSuccess), actionResult?.internalDetails, logPrefix);
        } else {
            String capabilityDevName = binding.DeveloperName__c;
            context.turnLifecycleSvc.pauseForAsyncAction(context.sessionId, context.turnIdentifier, null, capabilityDevName, logPrefix);
            context.dispatchSvc.enqueueAsyncAction(
                context.sessionId,
                context.userId,
                context.agentDefinitionId,
                savedAssistantMessageId,
                toolRequest.id,
                toolRequest.arguments,
                bindingConfigJson,
                actionDefId,
                context.relatedRecordId,
                context.turnIdentifier,
                context.currentTurnCount,
                logPrefix
            );
            return OrchestrationService.OUTCOME_QUEUED_ACTION;
        }
    }

    private String handleSyncActionResult(OrchestrationContext context, Boolean actionSucceeded, String actionFailureDetails, String logPrefix) {
        if (actionSucceeded) {
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((context.currentTurnCount + 1) > maxTurns) {
                String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') would be exceeded by follow-up LLM call.';

                context.turnLifecycleSvc.failTurn(
                    context.sessionId,
                    context.turnIdentifier,
                    limitErrorMsg,
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_FAILED;
            } else {
                context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);
                context.dispatchSvc.enqueueFollowUp(
                    context.sessionId,
                    context.userId,
                    context.agentDefinitionId,
                    context.turnIdentifier,
                    context.currentTurnCount + 1,
                    logPrefix
                );
                return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
            }
        } else {
            String failureMsg = ('Synchronous action execution failed: ' + (actionFailureDetails ?? 'No details.')).abbreviate(131072);

            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                failureMsg,
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }
    }

    private String handleApprovalRequiredAction(
        OrchestrationContext context,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapabilityBinding__c binding,
        String logPrefix
    ) {
        String confirmationPrompt = this.extractConfirmationMessage(toolRequest.arguments, toolRequest.name, logPrefix);
        if (String.isBlank(confirmationPrompt)) {
            String errMsg = 'Agent did not provide a required confirmation prompt for action "' + toolRequest.name + '".';
            context.turnLifecycleSvc.failTurn(
                context.sessionId,
                context.turnIdentifier,
                errMsg,
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        Id assistantMessageId = context.msgPersistenceSvc.saveAssistantMessageWithPendingAction(
            context.sessionId,
            savedUserMessageId,
            assistantData,
            assistantData.assistantToolCallsJson,
            logPrefix
        );

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            ChatSession__c = context.sessionId,
            OriginalAssistantMessage__c = assistantMessageId,
            LLMConfirmationMessage__c = confirmationPrompt,
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

        String toolResultContent = JSON.serialize(
            new Map<String, String>{
                'status' => 'pending_approval',
                'message' => 'The action ' +
                toolRequest.name +
                ' has been submitted for Salesforce Approval.'
            }
        );
        context.msgPersistenceSvc.saveToolResultMessage(
            context.sessionId,
            assistantMessageId,
            toolRequest.id,
            toolResultContent,
            null,
            null,
            0L,
            null,
            null,
            logPrefix
        );

        context.turnLifecycleSvc.resumeForFollowUpLlmCall(context.sessionId, context.turnIdentifier, null, logPrefix);

        context.dispatchSvc.enqueueFollowUp(
            context.sessionId,
            context.userId,
            context.agentDefinitionId,
            context.turnIdentifier,
            context.currentTurnCount + 1,
            logPrefix
        );

        return OrchestrationService.OUTCOME_QUEUED_FOLLOWUP;
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

    private void validateBinding(AgentCapabilityBinding__c binding, String capabilityName, String logPrefix) {
        if (binding == null) {
            throw new OrchestrationService.ConfigurationException('Active AgentCapabilityBinding not found for capability: "' + capabilityName + '"');
        }
        if (binding.ActionDefinition__r == null || !binding.ActionDefinition__r.IsActive__c) {
            throw new OrchestrationService.ConfigurationException(
                'The Action Definition linked to capability "' + capabilityName + '" is missing or inactive.'
            );
        }
    }

    private String extractConfirmationMessage(String argumentsJson, String capabilityDevName, String logPrefix) {
        if (String.isBlank(argumentsJson))
            return null;
        try {
            Map<String, Object> argsMap = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
            Object confirmationObj = argsMap.get(ToolDefinitionFormatter.CONFIRMATION_PARAM_NAME);
            return (confirmationObj instanceof String && String.isNotBlank((String) confirmationObj)) ? (String) confirmationObj : null;
        } catch (Exception e) {
            return null;
        }
    }
}
