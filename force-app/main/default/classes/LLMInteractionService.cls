/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
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

    public class LLMInteractionException extends AIAgentException {
    }
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

    /**
     * @description Orchestrates the process of calling the LLM for one turn.
     * @param currentTurnUserMessage The DTO containing the user message for the *current* turn. Can be null for follow-up calls.
     * @return LLMInteractionResult
     */
    public LLMInteractionResult prepareAndCallLLM(LLMInteractionService.MessageData currentTurnUserMessage) {
        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        ProviderResult llmApiResult = null;

        try {
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);

            List<Map<String, Object>> finalMessagesPayload = new List<Map<String, Object>>();

            String staticContextString = ContextProviderRunner.aggregateContext(this.agentDefinitionId, this.userId, this.relatedRecordId);
            if (String.isNotBlank(staticContextString)) {
            }

            String systemPromptContent = '';
            if (String.isNotBlank(agentConfig.SystemPrompt__c)) {
                systemPromptContent = agentConfig.SystemPrompt__c;
            }
            if (String.isNotBlank(staticContextString)) {
                systemPromptContent += '\n\n--- Additional Context ---\n' + staticContextString;
            }

            if (String.isNotBlank(systemPromptContent)) {
                finalMessagesPayload.add(new Map<String, Object>{ 'role' => AIAgentConstants.ROLE_SYSTEM, 'content' => systemPromptContent });
            }

            IMemoryManager memoryManager = MemoryManagerFactory.getManager(agentConfig.MemoryStrategy__c);
            List<Map<String, Object>> historyPayload = memoryManager.getHistoryPayload(this.sessionId, agentConfig, llmConfig, logPrefix);
            if (historyPayload != null) {
                finalMessagesPayload.addAll(historyPayload);
            }

            if (currentTurnUserMessage != null && String.isNotBlank(currentTurnUserMessage.content)) {
                LlmPayloadUtils.addMessageToPayload(
                    finalMessagesPayload,
                    currentTurnUserMessage.role,
                    currentTurnUserMessage.content,
                    null,
                    null,
                    logPrefix,
                    'Current User Turn'
                );
            }

            List<Map<String, Object>> toolsPayload = ToolDefinitionFormatter.formatToolsForApi(agentConfig.Id, logPrefix);

            Long callStartTime = System.currentTimeMillis();
            try {
                ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);
                llmApiResult = adapter.sendMessage(finalMessagesPayload, toolsPayload, llmConfig, agentConfig);

                if (llmApiResult == null) {
                    throw new LLMInteractionException('LLM Adapter returned a null result.');
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
