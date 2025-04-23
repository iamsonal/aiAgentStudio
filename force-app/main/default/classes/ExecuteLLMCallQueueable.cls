/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Queueable Job: Step 2. Fetches history/context, formats payload (incl. tools from bindings),
 *              makes LLM callout using adapter. SAVES the single 'assistant' response message.
 *              Dispatches ExecuteActionsQueueable if actions are requested,
 *              otherwise updates session status to Idle and queues FinalizeTurnQueueable for success event.
 *              Relies on ChatSessionStateService for state updates and FrameworkUtils for payload formatting.
 */
public class ExecuteLLMCallQueueable implements Queueable, Database.AllowsCallouts {
    private static final String CURRENT_JOB_EXPECTED_STATUS = AIAgentConstants.STATUS_AWAITING_LLM_RESPONSE;
    private static final String NEXT_ACTION_JOB_STATUS = AIAgentConstants.STATUS_QUEUED_FOR_ACTION;
    private static final String NEXT_ACTION_EXPECTED_HINT = AIAgentConstants.NEXT_EXPECTED_EXECUTE_ACTIONS;
    private static final String SUCCESS_FINAL_STATUS = AIAgentConstants.STATUS_IDLE;
    private static final String SUCCESS_NO_NEXT_HINT = AIAgentConstants.NEXT_EXPECTED_NONE;
    private static final String FAILURE_STATUS = AIAgentConstants.STATUS_FAILED;

    private Id chatSessionId;
    private Id userId;
    private Id agentDefinitionId;
    private Id llmConfigurationId;
    private String turnIdentifier;
    private Integer currentTurnCount;

    public ExecuteLLMCallQueueable(
        Id sessId,
        Id usrId,
        Id agentDefId,
        Id llmConfigId,
        String turnId,
        Integer turnCount
    ) {
        if (
            sessId == null ||
            usrId == null ||
            agentDefId == null ||
            llmConfigId == null ||
            String.isBlank(turnId) ||
            turnCount == null ||
            turnCount < 1
        ) {
            String errorMsg =
                '[ExecuteLLMCallQueueable] Instantiation ERROR: Required arguments missing/invalid. TurnCount: ' +
                turnCount;

            throw new IllegalArgumentException(errorMsg);
        }
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.llmConfigurationId = llmConfigId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        Integer seq = 0;
        String logPrefix = '[ExecuteLLM:' + this.turnIdentifier?.left(8) + ' Cycle:' + this.currentTurnCount + '] ';

        Long fullJobStartTime = System.currentTimeMillis();
        ProviderResult llmResult = null;
        Id savedAssistantMessageId = null;
        Exception processingException = null;
        Id relatedRecordId = null;

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
            relatedRecordId = session.RelatedRecordId__c;

            if (session.CurrentTurnIdentifier__c != this.turnIdentifier) {
                return;
            }

            String currentStatus = session.ProcessingStatus__c;
            if (currentStatus == FAILURE_STATUS) {
                return;
            }
            if (currentStatus != CURRENT_JOB_EXPECTED_STATUS) {
                throw new LLMProcessingException(
                    'Session in unexpected state: ' +
                        currentStatus +
                        '. Expected ' +
                        CURRENT_JOB_EXPECTED_STATUS +
                        '. Turn: ' +
                        this.turnIdentifier
                );
            }

            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);

            String injectedContextString = null;
            ContextService contextService = new ContextService();
            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_CONTEXT_GATHERING,
                OrchestrationLogger.STATUS_INIT,
                'Gathering context.',
                new Map<String, Object>{ 'agentDefId' => this.agentDefinitionId, 'relatedRecordId' => relatedRecordId },
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                this.llmConfigurationId,
                null
            );
            Long ctxStartTime = System.currentTimeMillis();
            try {
                Map<String, List<SObject>> structuredContext = contextService.gatherContext(
                    this.agentDefinitionId,
                    relatedRecordId
                );
                if (structuredContext != null && !structuredContext.isEmpty()) {
                    injectedContextString = contextService.formatContextForLLM(structuredContext, relatedRecordId);
                } else {
                }
                Long ctxDuration = System.currentTimeMillis() - ctxStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_CONTEXT_GATHERING,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Context gathered. Length: ' + injectedContextString?.length(),
                    null,
                    injectedContextString,
                    null,
                    null,
                    ctxDuration,
                    null,
                    null,
                    null,
                    this.llmConfigurationId,
                    null
                );
            } catch (Exception ctxEx) {
                Long ctxDuration = System.currentTimeMillis() - ctxStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_CONTEXT_GATHERING,
                    OrchestrationLogger.STATUS_FAILURE,
                    'Failed gathering context.',
                    null,
                    null,
                    ctxEx.getMessage(),
                    ctxEx.getTypeName(),
                    ctxDuration,
                    null,
                    null,
                    null,
                    this.llmConfigurationId,
                    null
                );
            }

            Integer historyLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();

            List<ChatMessage__c> fullHistoryAsc = ChatMessageService.getHistory(
                this.chatSessionId,
                historyLimit,
                'ASC'
            );

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_LLM_PREP,
                OrchestrationLogger.STATUS_INIT,
                'Preparing messages payload.',
                fullHistoryAsc,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                this.llmConfigurationId,
                null
            );
            Long payloadStartTime = System.currentTimeMillis();
            List<Map<String, Object>> messagesPayloadForCall;
            try {
                messagesPayloadForCall = FrameworkUtils.formatLlmApiPayload(
                    fullHistoryAsc,
                    agentConfig,
                    injectedContextString,
                    logPrefix
                );
                if (messagesPayloadForCall.isEmpty()) {
                }
                Long payloadDuration = System.currentTimeMillis() - payloadStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_PREP,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Messages payload formatted. Count: ' + messagesPayloadForCall.size(),
                    null,
                    messagesPayloadForCall,
                    null,
                    null,
                    payloadDuration,
                    null,
                    null,
                    null,
                    this.llmConfigurationId,
                    null
                );
            } catch (Exception formatEx) {
                Long payloadDuration = System.currentTimeMillis() - payloadStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_PREP,
                    OrchestrationLogger.STATUS_FAILURE,
                    'Failed formatting message payload.',
                    null,
                    null,
                    formatEx.getMessage(),
                    formatEx.getTypeName(),
                    payloadDuration,
                    null,
                    null,
                    null,
                    this.llmConfigurationId,
                    null
                );
                throw new LLMProcessingException(
                    'Critical error formatting LLM message payload: ' + formatEx.getMessage(),
                    formatEx
                );
            }

            List<Map<String, Object>> toolsForLLMPayload = new List<Map<String, Object>>();

            List<AgentCapabilityBinding__c> capabilities = [
                SELECT Id, DeveloperName__c, Description__c, InputSchema__c
                FROM AgentCapabilityBinding__c
                WHERE
                    AIAgentDefinition__c = :this.agentDefinitionId
                    AND IsActive__c = TRUE
                    AND ActionDefinition__r.IsActive__c = TRUE
                ORDER BY ExecutionOrder__c ASC NULLS LAST, Name ASC
            ];

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_LLM_PREP,
                OrchestrationLogger.STATUS_INIT,
                'Preparing tools payload.',
                capabilities,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                this.llmConfigurationId,
                null
            );
            payloadStartTime = System.currentTimeMillis();

            if (capabilities.isEmpty()) {
            } else {
                for (AgentCapabilityBinding__c binding : capabilities) {
                    String capabilityDevName = binding.DeveloperName__c;
                    String capabilityDesc = binding.Description__c;
                    String capabilityInputSchemaJson = binding.InputSchema__c;

                    if (String.isBlank(capabilityDevName)) {
                        continue;
                    }
                    if (String.isBlank(capabilityDesc)) {
                        continue;
                    }

                    if (String.isBlank(capabilityInputSchemaJson)) {
                        capabilityInputSchemaJson = '{"type":"object", "properties":{}}';
                    }

                    try {
                        Map<String, Object> paramSchema = parseInputSchemaJson(
                            capabilityInputSchemaJson,
                            capabilityDevName,
                            logPrefix
                        );
                        if (paramSchema == null) {
                            continue;
                        }

                        Map<String, Object> functionDef = new Map<String, Object>{
                            'name' => capabilityDevName,
                            'description' => capabilityDesc,
                            'parameters' => paramSchema
                        };
                        toolsForLLMPayload.add(
                            new Map<String, Object>{ 'type' => 'function', 'function' => functionDef }
                        );
                    } catch (Exception schemaEx) {
                        continue;
                    }
                }

                Long payloadDuration = System.currentTimeMillis() - payloadStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_PREP,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Tools payload prepared. Count: ' + toolsForLLMPayload.size(),
                    null,
                    toolsForLLMPayload,
                    null,
                    null,
                    payloadDuration,
                    null,
                    null,
                    null,
                    this.llmConfigurationId,
                    null
                );
            }

            ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);

            Map<String, Object> callPayloadLog = new Map<String, Object>{
                'messages' => messagesPayloadForCall,
                'tools' => toolsForLLMPayload
            };
            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_LLM_CALL,
                OrchestrationLogger.STATUS_INIT,
                'Attempting LLM call.',
                callPayloadLog,
                null,
                null,
                null,
                0L,
                null,
                null,
                null,
                llmConfig.Id,
                null
            );

            Long calloutStartTime = System.currentTimeMillis();
            try {
                llmResult = adapter.sendMessage(messagesPayloadForCall, toolsForLLMPayload, llmConfig, agentConfig);
                if (llmResult == null) {
                    throw new LLMProcessingException('LLM adapter returned null ProviderResult.');
                }
                Long calloutDuration = System.currentTimeMillis() - calloutStartTime;

                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'LLM Call successful. Tokens: ' +
                        formatTokenInfo(llmResult) +
                        '. Action Req: ' +
                        (llmResult.requestedActions != null && !llmResult.requestedActions.isEmpty()),
                    null,
                    llmResult,
                    null,
                    null,
                    calloutDuration,
                    null,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
            } catch (Exception llmEx) {
                Long calloutDuration = System.currentTimeMillis() - calloutStartTime;
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_FAILURE,
                    'LLM Call failed.',
                    null,
                    null,
                    llmEx.getMessage(),
                    llmEx.getTypeName(),
                    calloutDuration,
                    null,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
                throw new LLMProcessingException('LLM call failed: ' + llmEx.getMessage(), llmEx);
            }

            String finalContent = llmResult.content;
            String toolCallsJson = llmResult.rawToolCallsJson;
            Boolean requiresAction = llmResult.requestedActions != null && !llmResult.requestedActions.isEmpty();

            ChatMessage__c assistantSObject = new ChatMessage__c(
                ChatSession__c = this.chatSessionId,
                Role__c = 'assistant',
                Content__c = finalContent,
                Timestamp__c = Datetime.now(),
                ExternalId__c = FrameworkUtils.generateUUID(),
                TokensUsed__c = llmResult.totalTokens,
                ProcessingTimeMillis__c = System.currentTimeMillis() - calloutStartTime,
                AssistantToolCalls__c = toolCallsJson,
                ToolCallId__c = null,
                ParentMessage__c = null
            );

            try {
                Database.SaveResult srMsg = ChatMessageService.saveMessages(
                    new List<ChatMessage__c>{ assistantSObject }
                )[0];
                if (!srMsg.isSuccess()) {
                    throw new LLMProcessingException(
                        'Failed saving assistant message: ' + srMsg.getErrors()[0].getMessage()
                    );
                }
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Assistant message saved successfully.',
                    null,
                    assistantSObject,
                    null,
                    null,
                    null,
                    srMsg.getId(),
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
                savedAssistantMessageId = srMsg.getId();
            } catch (Exception saveEx) {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_FAILURE,
                    'Failed saving assistant message.',
                    assistantSObject,
                    null,
                    saveEx.getMessage(),
                    saveEx.getTypeName(),
                    null,
                    null,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
                throw new LLMProcessingException('Exception saving assistant message', saveEx);
            }

            if (requiresAction) {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_DISPATCH,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Actions required. Dispatching ExecuteActions job.',
                    new Map<String, Object>{ 'jobClass' => 'ExecuteActionsQueueable' },
                    null,
                    null,
                    null,
                    0L,
                    savedAssistantMessageId,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );

                ChatSessionStateService.updateStatus(
                    this.chatSessionId,
                    NEXT_ACTION_JOB_STATUS,
                    NEXT_ACTION_EXPECTED_HINT,
                    null,
                    null,
                    this.turnIdentifier
                );
                ExecuteActionsQueueable actionsJob = new ExecuteActionsQueueable(
                    this.chatSessionId,
                    this.userId,
                    this.agentDefinitionId,
                    this.turnIdentifier,
                    savedAssistantMessageId,
                    this.currentTurnCount
                );
                Id nextJobId = System.enqueueJob(actionsJob);

                try {
                    ChatSessionStateService.updateStatus(
                        this.chatSessionId,
                        NEXT_ACTION_JOB_STATUS,
                        NEXT_ACTION_EXPECTED_HINT,
                        nextJobId,
                        null,
                        this.turnIdentifier
                    );
                } catch (Exception e) {
                }
            } else if (!String.isBlank(finalContent)) {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_DISPATCH,
                    OrchestrationLogger.STATUS_SUCCESS,
                    'Final response received. Dispatching FinalizeTurn job.',
                    new Map<String, Object>{ 'jobClass' => 'FinalizeTurnQueueable', 'finalSuccess' => true },
                    null,
                    null,
                    null,
                    0L,
                    savedAssistantMessageId,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
                ChatSessionStateService.updateFinalStatus(this.chatSessionId, true, null, this.turnIdentifier);
                FinalizeTurnQueueable finalizeJob = new FinalizeTurnQueueable(
                    this.chatSessionId,
                    true,
                    savedAssistantMessageId,
                    null,
                    this.turnIdentifier
                );
                Id finalizeJobId = System.enqueueJob(finalizeJob);
            } else {
                OrchestrationLogger.logStep(
                    this.chatSessionId,
                    this.turnIdentifier,
                    seq++,
                    OrchestrationLogger.TYPE_LLM_RESPONSE,
                    OrchestrationLogger.STATUS_FAILURE,
                    'LLM response empty (no content or actions).',
                    null,
                    llmResult,
                    'LLM response was empty (no text content or action requests).',
                    'EMPTY_RESPONSE',
                    0L,
                    savedAssistantMessageId,
                    null,
                    null,
                    llmConfig.Id,
                    null
                );
                throw new LLMProcessingException('LLM response was empty (no text content or action requests).');
            }
        } catch (Exception ex) {
            processingException = ex;

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                999,
                OrchestrationLogger.TYPE_LLM_CALL,
                OrchestrationLogger.STATUS_FAILURE,
                'Top-level exception caught during LLM call execution.',
                null,
                null,
                ex.getMessage(),
                ex.getTypeName(),
                null,
                null,
                null,
                null,
                llmConfigurationId,
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
            String finalOutcome = (processingException == null) ? 'Success / Dispatched Next' : 'Failure';
        }
    }

    /**
     * Parses the InputSchema__c JSON from an AgentCapabilityBinding__c.
     * Returns a default empty schema if JSON is blank.
     * Returns null if JSON is invalid.
     */
    private Map<String, Object> parseInputSchemaJson(String schemaJson, String capabilityDevName, String logPrefix) {
        Map<String, Object> paramSchema = null;
        try {
            if (String.isNotBlank(schemaJson)) {
                Object parsedSchemaObj = JSON.deserializeUntyped(schemaJson);
                if (parsedSchemaObj instanceof Map<String, Object>) {
                    paramSchema = (Map<String, Object>) parsedSchemaObj;

                    if (
                        !paramSchema.containsKey('type') ||
                        !'object'.equalsIgnoreCase(String.valueOf(paramSchema.get('type')))
                    ) {
                    }
                } else {
                    return null;
                }
            } else {
                paramSchema = new Map<String, Object>{ 'type' => 'object', 'properties' => new Map<String, Object>() };
            }
        } catch (Exception schemaEx) {
            return null;
        }
        return paramSchema;
    }

    private String formatTokenInfo(ProviderResult result) {
        if (result == null)
            return '(Token Usage N/A)';
        String pTokens = (result.promptTokens != null) ? String.valueOf(result.promptTokens) : 'N/A';
        String cTokens = (result.completionTokens != null) ? String.valueOf(result.completionTokens) : 'N/A';
        String tTokens = (result.totalTokens != null) ? String.valueOf(result.totalTokens) : 'N/A';
        return 'Prompt=' + pTokens + ' | Completion=' + cTokens + ' | Total=' + tTokens;
    }

    public class LLMProcessingException extends AIAgentException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }
}
