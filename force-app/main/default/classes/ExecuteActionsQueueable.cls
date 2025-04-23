/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Queueable Job: Step 3a. Executes actions requested by the LLM.
 *              Looks up AgentCapabilityBinding based on LLM function name, instantiates handler via ActionRegistry,
 *              passes backend config from binding and LLM args to the action.
 *              SAVES tool results as ChatMessage records.
 *              Dispatches next PrepareLLMCall step (via Queueable or Event).
 *              Relies on ChatSessionStateService for status updates. Centralizes error handling.
 */
public class ExecuteActionsQueueable implements Queueable {
    private static final String CURRENT_JOB_EXPECTED_STATUS = AIAgentConstants.STATUS_QUEUED_FOR_ACTION;
    private static final String EXECUTING_STATUS = AIAgentConstants.STATUS_EXECUTING_ACTIONS;
    private static final String NEXT_PREP_JOB_STATUS = AIAgentConstants.STATUS_AWAITING_ACTION_RESULT_LLM;
    private static final String NEXT_PREP_EXPECTED_HINT = AIAgentConstants.NEXT_EXPECTED_PREPARE_LLM;
    private static final String FAILURE_STATUS = AIAgentConstants.STATUS_FAILED;
    private static final String ROLE_TOOL = AIAgentConstants.ROLE_TOOL;

    private Id chatSessionId;
    private Id userId;
    private Id agentDefinitionId;
    private Id parentAssistantMessageId;
    private String turnIdentifier;
    private Integer currentTurnCount;

    @TestVisible
    public class ActionRequest {
        @AuraEnabled
        public String id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String arguments;
    }

    public ExecuteActionsQueueable(
        Id sessId,
        Id usrId,
        Id agentDefId,
        String turnId,
        Id parentMsgId,
        Integer turnCount
    ) {
        if (
            sessId == null ||
            usrId == null ||
            agentDefId == null ||
            String.isBlank(turnId) ||
            parentMsgId == null ||
            turnCount == null ||
            turnCount < 1
        ) {
            String errorMsg =
                '[ExecuteActionsQueueable] Instantiation ERROR: Required arguments missing/invalid. TurnCount: ' +
                turnCount +
                ', ParentMsgId: ' +
                parentMsgId;

            throw new IllegalArgumentException(errorMsg);
        }
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.parentAssistantMessageId = parentMsgId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        Integer seq = 0;
        String logPrefix = '[ExecuteActions:' + this.turnIdentifier?.left(8) + ' Cycle:' + this.currentTurnCount + '] ';

        Long fullJobStartTime = System.currentTimeMillis();
        Id relatedRecordId = null;
        List<ActionRequest> actionsToExecute = new List<ActionRequest>();
        Map<String, AgentCapabilityBinding__c> capabilityNameToBindingMap = new Map<String, AgentCapabilityBinding__c>();
        List<ChatMessage__c> messagesToInsert = new List<ChatMessage__c>();
        Exception processingException = null;

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, RelatedRecordId__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (sessions.isEmpty()) {
                return;
            }
            ChatSession__c session = sessions[0];
            if (session.CurrentTurnIdentifier__c != this.turnIdentifier) {
                return;
            }
            relatedRecordId = session.RelatedRecordId__c;
            String currentStatus = session.ProcessingStatus__c;
            if (currentStatus == FAILURE_STATUS) {
                return;
            }
            if (currentStatus != CURRENT_JOB_EXPECTED_STATUS) {
                throw new ActionExecutionException(
                    'Session in unexpected state: ' +
                        currentStatus +
                        '. Expected ' +
                        CURRENT_JOB_EXPECTED_STATUS +
                        '. Turn: ' +
                        this.turnIdentifier
                );
            }

            try {
                ChatMessage__c assistantMsg = [
                    SELECT Id, AssistantToolCalls__c
                    FROM ChatMessage__c
                    WHERE Id = :this.parentAssistantMessageId
                    LIMIT 1
                ];
                if (assistantMsg == null || String.isBlank(assistantMsg.AssistantToolCalls__c)) {
                    throw new ActionExecutionException(
                        'Parent assistant message (' +
                            this.parentAssistantMessageId +
                            ') not found or AssistantToolCalls field is blank.'
                    );
                }

                actionsToExecute = parseToolCalls(
                    (List<Object>) JSON.deserializeUntyped(assistantMsg.AssistantToolCalls__c)
                );
                if (actionsToExecute.isEmpty()) {
                    throw new ActionExecutionException(
                        'No valid ActionRequests parsed from tool_calls on Msg: ' + this.parentAssistantMessageId
                    );
                }

                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_ACTION_PARSE,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Parsed ' + actionsToExecute.size() + ' actions from Assistant Tool Calls.',
                    assistantMsg.AssistantToolCalls__c,
                    actionsToExecute,
                    null,
                    null,
                    0L,
                    this.parentAssistantMessageId,
                    null,
                    null,
                    null,
                    null
                );

                Set<String> requestedCapabilityNames = new Set<String>();
                for (ActionRequest req : actionsToExecute) {
                    if (String.isNotBlank(req.name)) {
                        requestedCapabilityNames.add(req.name);
                    } else {
                        throw new ActionExecutionException(
                            'Found action request with missing capability name (LLM function name).'
                        );
                    }
                }

                for (AgentCapabilityBinding__c binding : [
                    SELECT Id, DeveloperName__c, ActionDefinition__c, ActionConfiguration__c
                    FROM AgentCapabilityBinding__c
                    WHERE
                        AIAgentDefinition__c = :this.agentDefinitionId
                        AND DeveloperName__c IN :requestedCapabilityNames
                        AND IsActive__c = TRUE
                        AND ActionDefinition__r.IsActive__c = TRUE
                ]) {
                    capabilityNameToBindingMap.put(binding.DeveloperName__c.toLowerCase(), binding);
                }

                for (ActionRequest req : actionsToExecute) {
                    if (!capabilityNameToBindingMap.containsKey(req.name.toLowerCase())) {
                        throw new ActionExecutionException(
                            'Configuration Error: Action capability "' +
                                req.name +
                                '" requested by LLM not found or not active/bound for this agent.'
                        );
                    }
                }

                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_ACTION_PARSE,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Validated ' + capabilityNameToBindingMap.size() + ' bindings required by LLM.',
                    requestedCapabilityNames,
                    capabilityNameToBindingMap.values(),
                    null,
                    null,
                    0L,
                    null,
                    null,
                    null,
                    null,
                    null
                );

                ChatSessionStateService.updateStatus(
                    this.chatSessionId,
                    EXECUTING_STATUS,
                    AIAgentConstants.NEXT_EXPECTED_NONE,
                    context.getJobId(),
                    null,
                    this.turnIdentifier
                );
            } catch (Exception prepareEx) {
                throw new ActionExecutionException(
                    'Failure during action preparation: ' + prepareEx.getMessage(),
                    prepareEx
                );
            }

            for (ActionRequest request : actionsToExecute) {
                ActionResult executionResult = null;
                String resultJsonForStorage = null;
                Long startTime = System.currentTimeMillis();
                Long duration = 0L;
                String actionLogStatus = 'UNKNOWN';

                AgentCapabilityBinding__c currentBinding = capabilityNameToBindingMap.get(request.name.toLowerCase());
                if (currentBinding == null) {
                    throw new ActionExecutionException(
                        'Internal Error: Binding not found in cache for capability: ' + request.name
                    );
                }
                Id actionDefinitionId = currentBinding.ActionDefinition__c;
                String implementationConfigJson = currentBinding.ActionConfiguration__c;

                try {
                    IAgentAction actionHandler = ActionRegistry.createActionHandler(actionDefinitionId);

                    ActionContext actionContext = new ActionContext(
                        this.chatSessionId,
                        this.userId,
                        relatedRecordId,
                        this.agentDefinitionId,
                        currentBinding.Id,
                        actionDefinitionId
                    );

                    executionResult = actionHandler.execute(implementationConfigJson, request.arguments, actionContext);
                    duration = System.currentTimeMillis() - startTime;

                    if (executionResult == null) {
                        executionResult = FrameworkUtils.createErrorResult(
                            'Action handler for "' + request.name + '" returned a null ActionResult.',
                            'ACTION_HANDLER_NULL_RESULT'
                        );
                        actionLogStatus = 'FAILURE';
                    } else {
                        actionLogStatus = executionResult.getIsSuccess() ? 'SUCCESS' : 'FAILURE';
                        OrchestrationLogger.logStep(
                            this.chatSessionId,
                            this.turnIdentifier,
                            seq++,
                            OrchestrationLogger.TYPE_ACTION_RESULT,
                            actionLogStatus.equals('SUCCESS')
                                ? OrchestrationLogger.STATUS_SUCCESS
                                : OrchestrationLogger.STATUS_FAILURE,
                            'Action execution completed. Status: ' + actionLogStatus,
                            null,
                            executionResult.getOutputForLlm(),
                            executionResult.isFailure() ? executionResult.getInternalDetails() : null,
                            executionResult.getErrorCode(),
                            duration,
                            null,
                            currentBinding.Id,
                            actionDefinitionId,
                            null,
                            request.id
                        );
                        Object outputForLlm = executionResult.getOutputForLlm();

                        if (!executionResult.getIsSuccess()) {
                        }
                    }

                    resultJsonForStorage = JSON.serialize(executionResult.getOutputForLlm());
                } catch (Exception ex) {
                    duration = System.currentTimeMillis() - startTime;
                    actionLogStatus = 'EXCEPTION';
                    String exceptionMsg =
                        ex.getMessage() + (ex.getCause() != null ? ' Cause: ' + ex.getCause().getMessage() : '');

                    executionResult = FrameworkUtils.createErrorResult(
                        'Action execution failed critically: ' + exceptionMsg,
                        'ACTION_EXCEPTION'
                    );
                    OrchestrationLogger.logStep(
                        this.chatSessionId,
                        this.turnIdentifier,
                        seq++,
                        OrchestrationLogger.TYPE_ACTION_RESULT,
                        OrchestrationLogger.STATUS_FAILURE,
                        'Exception during action execution.',
                        request.arguments,
                        null,
                        exceptionMsg,
                        ex.getTypeName(),
                        duration,
                        null,
                        currentBinding?.Id,
                        actionDefinitionId,
                        null,
                        request.id
                    );
                    resultJsonForStorage = JSON.serialize(executionResult.getOutputForLlm());
                } finally {
                    ChatMessage__c toolResultMessage = new ChatMessage__c(
                        ChatSession__c = this.chatSessionId,
                        Role__c = ROLE_TOOL,
                        ToolCallId__c = request.id,
                        Content__c = resultJsonForStorage ??
                            '{"isSuccess":false, "error":"Internal error: Result could not be determined or serialized."}',
                        Timestamp__c = Datetime.now(),
                        ExternalId__c = FrameworkUtils.generateUUID(),
                        ParentMessage__c = this.parentAssistantMessageId,
                        ProcessingTimeMillis__c = duration,
                        TokensUsed__c = null
                    );
                    messagesToInsert.add(toolResultMessage);
                }
            }

            try {
                List<Database.SaveResult> srList = ChatMessageService.saveMessages(messagesToInsert);

                Integer failureCount = 0;
                String firstDmlError = '';
                for (Integer i = 0; i < srList.size(); i++) {
                    if (!srList[i].isSuccess()) {
                        failureCount++;
                        if (String.isBlank(firstDmlError))
                            firstDmlError = srList[i].getErrors()[0].getMessage();
                    }
                }
                if (failureCount > 0) {
                    throw new ActionExecutionException(
                        'Failed to save ' + failureCount + ' tool result message(s). First Error: ' + firstDmlError
                    );
                }
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_TOOL_SAVE,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Saved ' + messagesToInsert.size() + ' tool result messages.',
                    null,
                    messagesToInsert,
                    null,
                    null,
                    null,
                    this.parentAssistantMessageId,
                    null,
                    null,
                    null,
                    null
                );
            } catch (Exception dmlEx) {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_TOOL_SAVE,
                    OrchestrationLogger.STATUS_FAILURE,
                    'Failed saving tool result messages.',
                    messagesToInsert,
                    null,
                    dmlEx.getMessage(),
                    dmlEx.getTypeName(),
                    null,
                    this.parentAssistantMessageId,
                    null,
                    null,
                    null,
                    null
                );
                throw new ActionExecutionException(
                    'Critical DML error saving tool result messages: ' + dmlEx.getMessage(),
                    dmlEx
                );
            }

            AIAgentFrameworkSettings__c settings = AIAgentFrameworkSettings.getInstance();
            Boolean decoupleWithEvents = settings?.MitigateChainingLimitsViaEvent__c == true;
            Integer nextTurnCount = this.currentTurnCount + 1;

            try {
                ChatSessionStateService.updateStatus(
                    this.chatSessionId,
                    NEXT_PREP_JOB_STATUS,
                    NEXT_PREP_EXPECTED_HINT,
                    null,
                    null,
                    this.turnIdentifier
                );
            } catch (Exception statusEx) {
                throw new ActionExecutionException(
                    'Failed setting session status before dispatch: ' + statusEx.getMessage(),
                    statusEx
                );
            }

            try {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_DISPATCH,
                    OrchestrationLogger.STATUS_INIT,
                    'Dispatching next step for Cycle ' +
                        nextTurnCount +
                        '. Method: ' +
                        (decoupleWithEvents ? 'Event' : 'Queueable'),
                    new Map<String, Object>{ 'nextTurn' => nextTurnCount },
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null,
                    null
                );
                if (decoupleWithEvents) {
                    Id llmConfigIdToPublish = null;
                    try {
                        AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
                        llmConfigIdToPublish = agentDef?.LLMConfiguration__c;
                    } catch (Exception configEx) {
                        throw new ActionExecutionException(
                            'Could not retrieve LLMConfigurationId needed for Platform Event dispatch: ' +
                            configEx.getMessage(),
                            configEx
                        );
                    }
                    if (llmConfigIdToPublish == null) {
                        throw new ActionExecutionException(
                            'LLMConfigurationId is unexpectedly null. Cannot publish Platform Event.'
                        );
                    }

                    AgentOrchestrationStep__e event = new AgentOrchestrationStep__e(
                        ChatSessionId__c = this.chatSessionId,
                        TurnIdentifier__c = this.turnIdentifier,
                        CurrentTurnCount__c = nextTurnCount,
                        UserId__c = this.userId,
                        AgentDefinitionId__c = this.agentDefinitionId,
                        LLMConfigurationId__c = llmConfigIdToPublish,
                        NextStepType__c = AIAgentConstants.EVENT_STEP_PREPARE_LLM_WITH_RESULTS
                    );
                    Database.SaveResult sr = EventBus.publish(event);
                    if (!sr.isSuccess()) {
                        throw new ActionExecutionException(
                            'Failed to publish Platform Event: ' + sr.getErrors()[0].getMessage()
                        );
                    }
                } else {
                    PrepareLLMCallQueueable nextPrepJob = new PrepareLLMCallQueueable(
                        this.chatSessionId,
                        this.userId,
                        this.agentDefinitionId,
                        this.turnIdentifier,
                        nextTurnCount
                    );
                    Id nextJobId = System.enqueueJob(nextPrepJob);

                    try {
                        ChatSessionStateService.updateStatus(
                            this.chatSessionId,
                            NEXT_PREP_JOB_STATUS,
                            NEXT_PREP_EXPECTED_HINT,
                            nextJobId,
                            null,
                            this.turnIdentifier
                        );
                    } catch (Exception jobDmlEx) {
                    }
                }
            } catch (Exception dispatchEx) {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_DISPATCH,
                    OrchestrationLogger.STATUS_FAILURE,
                    'Failed dispatching next step.',
                    null,
                    null,
                    dispatchEx.getMessage(),
                    dispatchEx.getTypeName(),
                    null,
                    null,
                    null,
                    null,
                    null,
                    null
                );
                throw new ActionExecutionException(
                    'Failed dispatching next step after actions: ' + dispatchEx.getMessage(),
                    dispatchEx
                );
            }
        } catch (Exception ex) {
            processingException = ex;

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                999,
                OrchestrationLogger.TYPE_ACTION_START,
                OrchestrationLogger.STATUS_FAILURE,
                'Top-level exception during Action Execution.',
                null,
                null,
                ex.getMessage(),
                ex.getTypeName(),
                null,
                this.parentAssistantMessageId,
                null,
                null,
                null,
                null
            );
        } finally {
            OrchestrationLogger.commitLogs();
            if (processingException != null) {
                String errorMsg = processingException.getMessage();

                String abbreviatedError = errorMsg.abbreviate(131072);
                try {
                    ChatSessionStateService.updateFinalStatus(
                        this.chatSessionId,
                        false,
                        abbreviatedError,
                        this.turnIdentifier
                    );
                } catch (Exception serviceEx) {
                }

                FinalizeTurnQueueable finalizeJob = new FinalizeTurnQueueable(
                    this.chatSessionId,
                    false,
                    null,
                    errorMsg,
                    this.turnIdentifier
                );
                try {
                    Id finalizeJobId = System.enqueueJob(finalizeJob);
                } catch (Exception finalizeQueueEx) {
                }
            }

            Long duration = System.currentTimeMillis() - fullJobStartTime;
            String finalOutcome = (processingException == null) ? 'Dispatched Next Step' : 'Failure';
        }
    }

    private List<ActionRequest> parseToolCalls(List<Object> toolCallsList) {
        List<ActionRequest> parsedRequests = new List<ActionRequest>();
        if (toolCallsList == null)
            return parsedRequests;

        for (Object callObj : toolCallsList) {
            if (callObj instanceof Map<String, Object>) {
                Map<String, Object> callMap = (Map<String, Object>) callObj;
                ActionRequest req = new ActionRequest();
                req.id = String.valueOf(callMap.get('id'));

                if (
                    'function'.equalsIgnoreCase(String.valueOf(callMap.get('type'))) &&
                    callMap.get('function') instanceof Map<String, Object>
                ) {
                    Map<String, Object> functionMap = (Map<String, Object>) callMap.get('function');
                    req.name = String.valueOf(functionMap.get('name'));
                    Object argsObj = functionMap.get('arguments');
                    req.arguments = (argsObj == null) ? '{}' : String.valueOf(argsObj);

                    if (String.isNotBlank(req.id) && String.isNotBlank(req.name)) {
                        parsedRequests.add(req);
                    } else {
                    }
                } else {
                }
            } else {
            }
        }
        return parsedRequests;
    }

    public class ActionExecutionException extends AIAgentException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }
}
