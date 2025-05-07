/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for orchestrating the AI agent's actions
 *              *after* receiving a response from the LLM Interaction Service.
 *              It decides the next step (content, sync/async action, confirmation, or failure),
 *              delegates message saving to MessagePersistenceService, and state updates to TurnLifecycleService.
 *              This service DOES NOT perform callouts or direct DML itself.
 */
public inherited sharing class OrchestrationService {
    public virtual class OrchestrationException extends AIAgentException {
    }
    public class ConfigurationException extends OrchestrationException {
    }
    public class ActionProcessingException extends OrchestrationException {
    }

    public static final String OUTCOME_COMPLETED = 'COMPLETED';
    public static final String OUTCOME_FAILED = 'FAILED';
    public static final String OUTCOME_QUEUED_FOLLOWUP = 'QUEUED_FOLLOWUP';
    public static final String OUTCOME_QUEUED_ACTION = 'QUEUED_ACTION';
    public static final String OUTCOME_AWAITING_CONFIRMATION = 'AWAITING_CONFIRMATION';

    private final MessagePersistenceService msgPersistenceSvc;
    private final TurnLifecycleService turnLifecycleSvc;
    private final ActionExecutionService actionExecSvc;
    private final OrchestrationDispatchService orchestrationDispatchSvc;

    public OrchestrationService() {
        this.msgPersistenceSvc = new MessagePersistenceService();
        this.turnLifecycleSvc = new TurnLifecycleService();
        this.actionExecSvc = new ActionExecutionService();
        this.orchestrationDispatchSvc = new OrchestrationDispatchService();
    }

    @TestVisible
    private OrchestrationService(
        MessagePersistenceService mockMsgSvc,
        TurnLifecycleService mockTurnSvc,
        ActionExecutionService mockActionExecSvc,
        OrchestrationDispatchService mockDispatchSvc
    ) {
        this.msgPersistenceSvc = mockMsgSvc;
        this.turnLifecycleSvc = mockTurnSvc;
        this.actionExecSvc = mockActionExecSvc;
        this.orchestrationDispatchSvc = mockDispatchSvc;
    }

    public String processLlmResult(
        LLMInteractionService.LLMInteractionResult llmInteractionResult,
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id relatedRecordId,
        String turnIdentifier,
        Integer currentTurnCount,
        LLMInteractionService.MessageData userMessageDataForTurn
    ) {
        String logPrefix = '[OrchSvc Turn:' + turnIdentifier?.left(8) + ' Cycle:' + currentTurnCount + ' Sess:' + sessionId + '] ';

        Id savedUserMessageId = null;
        try {
            if (llmInteractionResult == null || !llmInteractionResult.isSuccess) {
                String failureReason = llmInteractionResult?.failureReason ?? 'Unknown LLM Interaction Error';
                String failureCode = llmInteractionResult?.failureCode ?? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED;

                this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, failureReason, failureCode, logPrefix);
                return OUTCOME_FAILED;
            }

            savedUserMessageId = this.msgPersistenceSvc.saveUserMessage(sessionId, turnIdentifier, userMessageDataForTurn, logPrefix);

            ProviderResult providerResult = llmInteractionResult.providerResult;
            LLMInteractionService.MessageData assistantData = llmInteractionResult.assistantMessageData;
            List<Map<String, String>> requestedActions = providerResult.requestedActions;
            Boolean needsAction = requestedActions != null && !requestedActions.isEmpty();
            Map<String, String> firstActionRequestMap = needsAction ? requestedActions[0] : null;

            if (!needsAction || firstActionRequestMap == null) {
                return this.handleContentOnlyResponseInternal(
                    sessionId,
                    turnIdentifier,
                    currentTurnCount,
                    savedUserMessageId,
                    assistantData,
                    logPrefix
                );
            } else {
                return this.handleToolCallResponseInternal(
                    sessionId,
                    userId,
                    agentDefinitionId,
                    relatedRecordId,
                    turnIdentifier,
                    currentTurnCount,
                    savedUserMessageId,
                    assistantData,
                    firstActionRequestMap,
                    logPrefix
                );
            }
        } catch (Exception ex) {
            String errorMsg = 'Critical Orchestration Logic Error: (' + ex.getTypeName() + ') ' + ex.getMessage();

            try {
                this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception finalFailEx) {
            }
            return OUTCOME_FAILED;
        }
    }

    private String handleContentOnlyResponseInternal(
        Id sessionId,
        String turnIdentifier,
        Integer currentTurnCount,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        String logPrefix
    ) {
        if (String.isBlank(assistantData?.content)) {
            this.turnLifecycleSvc.failTurn(
                sessionId,
                turnIdentifier,
                'LLM returned empty successful response.',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OUTCOME_FAILED;
        }
        Id savedAssistantMessageId = this.msgPersistenceSvc.saveAssistantMessage(sessionId, savedUserMessageId, assistantData, logPrefix);
        this.turnLifecycleSvc.completeTurnSuccessfully(sessionId, turnIdentifier, savedAssistantMessageId, logPrefix);
        return OUTCOME_COMPLETED;
    }

    private String handleToolCallResponseInternal(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id relatedRecordId,
        String turnIdentifier,
        Integer currentTurnCount,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        Map<String, String> firstActionRequestMap,
        String logPrefix
    ) {
        AIAssistantController.ActionRequest toolRequest = parseToolRequestMap(firstActionRequestMap);

        AgentCapabilityBinding__c binding = AIAgentConfigService.getCapabilityBinding(agentDefinitionId, toolRequest.name);
        validateBinding(binding, toolRequest.name, logPrefix);

        if (binding.RequiresHumanApproval__c == true) {
            return this.requestUserConfirmationInternal(
                sessionId,
                turnIdentifier,
                savedUserMessageId,
                assistantData,
                toolRequest,
                binding,
                logPrefix
            );
        } else {
            Id savedAssistantMessageId = this.msgPersistenceSvc.saveAssistantMessage(sessionId, savedUserMessageId, assistantData, logPrefix);
            return this.executeActionDirectlyInternal(
                sessionId,
                userId,
                agentDefinitionId,
                relatedRecordId,
                turnIdentifier,
                currentTurnCount,
                savedAssistantMessageId,
                toolRequest,
                binding,
                logPrefix
            );
        }
    }

    private String requestUserConfirmationInternal(
        Id sessionId,
        String turnIdentifier,
        Id savedUserMessageId,
        LLMInteractionService.MessageData assistantData,
        AIAssistantController.ActionRequest toolRequestToConfirm,
        AgentCapabilityBinding__c binding,
        String logPrefix
    ) {
        String confirmationPrompt = LlmPayloadUtils.extractConfirmationMessage(toolRequestToConfirm.arguments, toolRequestToConfirm.name, logPrefix);

        if (String.isBlank(confirmationPrompt)) {
            String errMsg = 'Agent did not provide a required confirmation prompt for action "' + toolRequestToConfirm.name + '".';

            this.msgPersistenceSvc.saveAssistantMessage(sessionId, savedUserMessageId, assistantData, logPrefix);
            this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, errMsg, AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, logPrefix);
            return OUTCOME_FAILED;
        }

        Id savedAssistantMsgIdWithPending = this.msgPersistenceSvc.saveAssistantMessageWithPendingAction(
            sessionId,
            savedUserMessageId,
            assistantData,
            assistantData.assistantToolCallsJson,
            logPrefix
        );

        this.turnLifecycleSvc.pauseForUserConfirmation(sessionId, turnIdentifier, logPrefix);

        String confirmationRequestId = UuidUtils.generateUUID();
        AgentActionConfirmationRequest__e confirmEvent = new AgentActionConfirmationRequest__e(
            ChatSessionId__c = sessionId,
            AssistantMessageId__c = String.valueOf(savedAssistantMsgIdWithPending),
            ActionName__c = toolRequestToConfirm.name,
            ConfirmationMessage__c = confirmationPrompt.abbreviate(1000),
            FullActionArgumentsJson__c = toolRequestToConfirm.arguments,
            ConfirmationRequestId__c = confirmationRequestId
        );
        EventBus.publish(confirmEvent);

        return OUTCOME_AWAITING_CONFIRMATION;
    }

    private String executeActionDirectlyInternal(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id relatedRecordId,
        String turnIdentifier,
        Integer currentTurnCount,
        Id savedAssistantMessageId,
        AIAssistantController.ActionRequest toolRequest,
        AgentCapabilityBinding__c binding,
        String logPrefix
    ) {
        Id actionDefId = binding.ActionDefinition__c;
        Boolean runAsync = binding.ActionDefinition__r.RunAsynchronously__c == true;
        String bindingConfigJson = binding.ActionConfiguration__c;

        if (!runAsync) {
            ActionContext actionContext = new ActionContext(sessionId, userId, relatedRecordId, agentDefinitionId, binding.Id, actionDefId);
            ActionResult actionResult = null;
            Long actionDuration = 0L;
            Long syncActionStart = System.currentTimeMillis();
            try {
                actionResult = this.actionExecSvc.executeSingleAction(actionDefId, bindingConfigJson, toolRequest.arguments, actionContext);
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

            Id savedToolMsgId = this.msgPersistenceSvc.saveToolResultMessage(
                sessionId,
                savedAssistantMessageId,
                toolRequest.id,
                toolResultContentJson,
                actionResult?.internalDetails,
                actionResult?.errorCode,
                actionDuration,
                logPrefix
            );
            return this.handleSyncActionResultInternal(
                sessionId,
                userId,
                agentDefinitionId,
                (actionResult != null && actionResult.isSuccess),
                actionResult?.internalDetails,
                currentTurnCount,
                turnIdentifier,
                logPrefix
            );
        } else {
            this.turnLifecycleSvc.pauseForAsyncAction(sessionId, turnIdentifier, null, logPrefix);
            this.orchestrationDispatchSvc.enqueueAsyncAction(
                sessionId,
                userId,
                agentDefinitionId,
                savedAssistantMessageId,
                toolRequest.id,
                toolRequest.arguments,
                bindingConfigJson,
                actionDefId,
                relatedRecordId,
                turnIdentifier,
                currentTurnCount,
                logPrefix
            );
            return OUTCOME_QUEUED_ACTION;
        }
    }

    private String handleSyncActionResultInternal(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Boolean actionSucceeded,
        String actionFailureDetails,
        Integer currentTurnCount,
        String turnIdentifier,
        String logPrefix
    ) {
        if (actionSucceeded) {
            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((currentTurnCount + 1) > maxTurns) {
                String limitErrorMsg = 'Maximum processing cycles (' + maxTurns + ') would be exceeded by follow-up LLM call.';

                this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, limitErrorMsg, AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED, logPrefix);
                return OUTCOME_FAILED;
            } else {
                this.turnLifecycleSvc.resumeForFollowUpLlmCall(sessionId, turnIdentifier, null, logPrefix);
                this.orchestrationDispatchSvc.enqueueFollowUp(sessionId, userId, agentDefinitionId, turnIdentifier, currentTurnCount + 1, logPrefix);
                return OUTCOME_QUEUED_FOLLOWUP;
            }
        } else {
            String failureMsg = ('Synchronous action execution failed: ' + (actionFailureDetails ?? 'No details.')).abbreviate(131072);

            this.turnLifecycleSvc.failTurn(sessionId, turnIdentifier, failureMsg, AIAgentConstants.ERR_CODE_ACTION_EXECUTION, logPrefix);
            return OUTCOME_FAILED;
        }
    }

    public String resumeApprovedSyncAction(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id relatedRecordId,
        String turnIdentifier,
        Integer currentTurnCount,
        Id originalAssistantMessageId,
        AIAssistantController.ActionRequest toolRequestToResume,
        Id actionDefId,
        Id capabilityBindingId,
        String bindingConfigJson,
        String logPrefix
    ) {
        this.turnLifecycleSvc.startTurnProcessing(sessionId, turnIdentifier, null, logPrefix);

        ActionContext actionContext = new ActionContext(sessionId, userId, relatedRecordId, agentDefinitionId, capabilityBindingId, actionDefId);
        ActionResult actionResult = null;
        Long actionDuration = 0L;
        Long syncActionStart = System.currentTimeMillis();
        try {
            actionResult = this.actionExecSvc.executeSingleAction(actionDefId, bindingConfigJson, toolRequestToResume.arguments, actionContext);
        } catch (Exception execEx) {
            actionResult = new ActionResult(
                'Approved action failed execution: ' + execEx.getMessage(),
                execEx.getStackTraceString(),
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION
            );
        } finally {
            actionDuration = System.currentTimeMillis() - syncActionStart;
        }

        String toolResultContentJson = OrchestrationService.serializeActionResult(actionResult, logPrefix);
        Id savedToolMsgId = this.msgPersistenceSvc.saveToolResultMessage(
            sessionId,
            originalAssistantMessageId,
            toolRequestToResume.id,
            toolResultContentJson,
            actionResult?.internalDetails,
            actionResult?.errorCode,
            actionDuration,
            logPrefix
        );
        clearPendingDetailsFromMessage(originalAssistantMessageId, logPrefix);
        return this.handleSyncActionResultInternal(
            sessionId,
            userId,
            agentDefinitionId,
            (actionResult != null && actionResult.isSuccess),
            actionResult?.internalDetails,
            currentTurnCount,
            turnIdentifier,
            logPrefix
        );
    }

    public String resumeApprovedAsyncAction(
        Id sessionId,
        Id userId,
        Id agentDefinitionId,
        Id relatedRecordId,
        String turnIdentifier,
        Integer currentTurnCount,
        Id originalAssistantMessageId,
        AIAssistantController.ActionRequest toolRequestToResume,
        Id actionDefId,
        Id capabilityBindingId,
        String bindingConfigJson,
        String logPrefix
    ) {
        this.turnLifecycleSvc.pauseForAsyncAction(sessionId, turnIdentifier, null, logPrefix);

        this.orchestrationDispatchSvc.enqueueAsyncAction(
            sessionId,
            userId,
            agentDefinitionId,
            originalAssistantMessageId,
            toolRequestToResume.id,
            toolRequestToResume.arguments,
            bindingConfigJson,
            actionDefId,
            relatedRecordId,
            turnIdentifier,
            currentTurnCount,
            logPrefix
        );
        clearPendingDetailsFromMessage(originalAssistantMessageId, logPrefix);
        return OUTCOME_QUEUED_ACTION;
    }

    private static void clearPendingDetailsFromMessage(Id chatMessageId, String logPrefix) {
        try {
            update new ChatMessage__c(Id = chatMessageId, PendingConfirmationActionDetails__c = null);
        } catch (Exception e) {
        }
    }

    private static AIAssistantController.ActionRequest parseToolRequestMap(Map<String, String> requestMap) {
        AIAssistantController.ActionRequest req = new AIAssistantController.ActionRequest();
        req.id = requestMap?.get('id');
        req.name = requestMap?.get('name');
        req.arguments = requestMap?.get('arguments');
        if (String.isBlank(req.id) || String.isBlank(req.name) || req.arguments == null) {
            throw new ActionProcessingException(
                'Parsed LLM tool request missing id, name, or arguments JSON. RequestMap: ' + JSON.serialize(requestMap)
            );
        }
        return req;
    }

    private static void validateBinding(AgentCapabilityBinding__c binding, String capabilityName, String logPrefix) {
        if (binding == null) {
            throw new ConfigurationException('Active AgentCapabilityBinding not found for capability: "' + capabilityName + '"');
        }
        if (binding.ActionDefinition__r == null) {
            throw new ConfigurationException(
                'Action Definition link is missing or inaccessible on the binding for capability: "' +
                    capabilityName +
                    '" (Binding ID: ' +
                    binding.Id +
                    ')'
            );
        }
        if (!binding.ActionDefinition__r.IsActive__c) {
            throw new ConfigurationException(
                'The Action Definition "' +
                    binding.ActionDefinition__r.DeveloperName__c +
                    '" linked to capability "' +
                    capabilityName +
                    '" is not active.'
            );
        }
    }

    public static String serializeActionResult(ActionResult actionResult, String logPrefix) {
        try {
            if (actionResult == null) {
                return JSON.serialize(new Map<String, Object>{ 'error' => 'Action execution did not return a result object.' });
            }
            if (actionResult.outputForLlm != null) {
                return JSON.serialize(actionResult.outputForLlm);
            } else {
                Map<String, Object> syntheticOutput = new Map<String, Object>{ 'status' => actionResult.isSuccess ? 'success' : 'failure' };
                if (!actionResult.isSuccess) {
                    syntheticOutput.put('error_code', actionResult.errorCode);
                    String llmErrorDetail = actionResult.internalDetails != null
                        ? actionResult.internalDetails.abbreviate(200)
                        : 'No details available.';
                    if (actionResult.internalDetails != null && actionResult.internalDetails.contains('Exception:')) {
                        llmErrorDetail = 'An internal error occurred executing the action.';
                    }
                    syntheticOutput.put('details', llmErrorDetail);
                } else if (actionResult.internalDetails != null) {
                    syntheticOutput.put('details', actionResult.internalDetails.abbreviate(200));
                }
                return JSON.serialize(syntheticOutput);
            }
        } catch (Exception jsonEx) {
            return JSON.serialize(
                new Map<String, Object>{
                    'error' => 'Failed to serialize action result data.',
                    'serialization_error_details' => jsonEx.getMessage(),
                    'original_action_success_status' => actionResult?.isSuccess,
                    'original_action_error_code' => actionResult?.errorCode
                }
            );
        }
    }
}
