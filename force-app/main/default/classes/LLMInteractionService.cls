/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for the core LLM interaction cycle for a single turn:
 *              context gathering, payload formatting, LLM callout (with retries), and response parsing.
 *              Designed to be called synchronously by the Controller or asynchronously by FollowUpLLMQueueable.
 */
public inherited sharing class LLMInteractionService {
    /** @description DTO for returning results */
    public class LLMInteractionResult {
        public Boolean isSuccess { get; private set; }
        public ProviderResult providerResult { get; private set; }
        public MessageData assistantMessageData { get; private set; }
        public String failureReason { get; private set; }
        public String failureCode { get; private set; }
        public Exception failureException { get; private set; }

        public LLMInteractionResult(ProviderResult result, MessageData message) {
            this.isSuccess = true;
            this.providerResult = result;
            this.assistantMessageData = message;
        }

        public LLMInteractionResult(String reason, String code, Exception ex) {
            this.isSuccess = false;
            this.failureReason = reason;
            this.failureCode = code;
            this.failureException = ex;
        }
    }

    /** @description DTO for passing necessary unsaved message data */
    public class MessageData {
        public String role;
        public String content;
        public String assistantToolCallsJson;
        public Integer tokensUsed;
        public Long processingTimeMs;
    }

    /** @description Exception for this service */
    public class LLMInteractionException extends AIAgentException {
    }
    /** @description Required Arg Exception */
    public class IllegalArgumentException extends AIAgentException {
    }

    private final Id sessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Id relatedRecordId;
    private final String logPrefix;

    public LLMInteractionService(Id sessId, Id usrId, Id agentDefId, Id llmConfigId, String turnId, Integer turnNum, Id relId) {
        if (sessId == null || usrId == null || agentDefId == null || llmConfigId == null || String.isBlank(turnId) || turnNum == null) {
            throw new IllegalArgumentException('Required arguments cannot be null for LLMInteractionService.');
        }
        this.sessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.llmConfigurationId = llmConfigId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnNum;
        this.relatedRecordId = relId;
        this.logPrefix = '[LLMIntSvc Turn:' + turnId?.left(8) + ' Cycle:' + turnNum + '] ';
    }

    public LLMInteractionResult prepareAndCallLLM() {
        return this.prepareAndCallLLM(null);
    }

    /**
     * @description Orchestrates the process of calling the LLM for one turn.
     * @param currentTurnUserMessage Optional - DTO containing the user message data for the *current* turn being processed. Should only be passed for the initial call from the controller.
     * @return LLMInteractionResult containing success/failure status, ProviderResult, and unsaved Assistant Message data.
     */
    public LLMInteractionResult prepareAndCallLLM(LLMInteractionService.MessageData currentTurnUserMessage) {
        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        String contextString = null;
        List<ChatMessage__c> history = null;
        List<Map<String, Object>> messagesPayload = null;
        List<Map<String, Object>> toolsPayload = null;
        ProviderResult llmApiResult = null;
        Integer seq = 50;

        try {
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);

            contextString = ContextService.aggregateContext(this.agentDefinitionId, this.userId, this.relatedRecordId);
            if (String.isNotBlank(contextString)) {
            } else {
            }

            Integer historyLimit = AIAgentFrameworkSettings.getDefaultHistoryLimit();
            history = ChatMessageService.getHistory(this.sessionId, historyLimit, 'ASC');

            Long fmtStartTime = System.currentTimeMillis();
            try {
                messagesPayload = LlmPayloadUtils.formatMessagesForApi(history, agentConfig, contextString, logPrefix);

                if (currentTurnUserMessage != null) {
                    if (String.isNotBlank(currentTurnUserMessage.content)) {
                        LlmPayloadUtils.addMessageToPayload(
                            messagesPayload,
                            currentTurnUserMessage.role,
                            currentTurnUserMessage.content,
                            null,
                            null,
                            logPrefix,
                            'Current User Turn'
                        );
                    } else {
                    }
                }

                toolsPayload = LlmPayloadUtils.formatToolsForApi(agentConfig.Id, logPrefix);
                Long fmtDuration = System.currentTimeMillis() - fmtStartTime;
                Map<String, Object> logFmtOutput = new Map<String, Object>{
                    'messageCount' => messagesPayload?.size() ?? 0,
                    'toolCount' => toolsPayload?.size() ?? 0
                };
            } catch (Exception fmtEx) {
                Long fmtDuration = System.currentTimeMillis() - fmtStartTime;
                throw new LLMInteractionException('Failed formatting LLM payloads: ' + fmtEx.getMessage(), fmtEx);
            }

            Map<String, Object> logInput = new Map<String, Object>{ 'messages' => messagesPayload, 'tools' => toolsPayload };
            Long callStartTime = System.currentTimeMillis();
            try {
                ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);
                llmApiResult = adapter.sendMessage(messagesPayload, toolsPayload, llmConfig, agentConfig);
                if (llmApiResult == null) {
                    throw new LLMInteractionException('LLM Adapter returned null.');
                }
                Long callDuration = System.currentTimeMillis() - callStartTime;

                MessageData asstMsgData = new MessageData();
                asstMsgData.role = AIAgentConstants.ROLE_ASSISTANT;
                asstMsgData.content = llmApiResult.content;

                asstMsgData.assistantToolCallsJson = llmApiResult.rawToolCallsJson;

                asstMsgData.tokensUsed = llmApiResult.totalTokens;
                asstMsgData.processingTimeMs = callDuration;

                return new LLMInteractionResult(llmApiResult, asstMsgData);
            } catch (Exception callEx) {
                Long callDuration = System.currentTimeMillis() - callStartTime;

                return new LLMInteractionResult('LLM Call Failed: ' + callEx.getMessage(), AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, callEx);
            }
        } catch (Exception ex) {
            return new LLMInteractionResult('Interaction Setup Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
        }
    }
}
