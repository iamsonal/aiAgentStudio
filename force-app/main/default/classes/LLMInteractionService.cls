/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * LLMInteractionService orchestrates the complete LLM interaction lifecycle for a single execution turn.
 *
 * Responsibilities:
 *   - Manages prompt composition, payload formatting, HTTP communication (with retry), and response parsing
 *   - Integrates with SystemPromptBuilder for prompt assembly and MemoryManager for execution history
 *   - Supports action transparency mode, injecting summarization or error instructions as needed
 *   - Handles all configuration, error, and result packaging for downstream orchestration
 *
 * This service is the central entry point for all LLM calls in the agent framework, ensuring consistency,
 * observability, and extensibility for all execution turns.
 */
public inherited sharing class LLMInteractionService {
    /**
     * Data Transfer Object containing the complete result of an LLM interaction cycle.
     *
     * Includes success status, provider response data, message metadata, and failure details.
     */
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

    /**
     * Data Transfer Object for message metadata that hasn't been persisted to ExecutionStep__c yet.
     *
     * Contains role, content, tool calls, token usage, and processing time information.
     */
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

    private final Id executionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final String logPrefix;
    private final Id currentPageRecordId;
    private final Boolean isFinalErrorTurn;
    // Add decision logger reference
    private final AgentDecisionStepLogger decisionLogger;

    /**
     * Constructor for LLMInteractionService working exclusively with the unified AgentExecution__c model.
     *
     * @param executionId The AgentExecution__c ID
     * @param usrId The user ID
     * @param agentDefId The agent definition ID
     * @param llmConfigId The LLM configuration ID
     * @param turnId The turn identifier
     * @param turnNum The turn number
     * @param pageRecordId The current page record ID
     * @param isFinalError Whether this is a final error turn
     * @param decisionLogger The decision logger (optional)
     */
    public LLMInteractionService(
        Id executionId,
        Id usrId,
        Id agentDefId,
        Id llmConfigId,
        String turnId,
        Integer turnNum,
        Id pageRecordId,
        Boolean isFinalError,
        AgentDecisionStepLogger decisionLogger
    ) {
        if (executionId == null || usrId == null || agentDefId == null || llmConfigId == null || String.isBlank(turnId) || turnNum == null) {
            throw new IllegalArgumentException('Required arguments cannot be null for LLMInteractionService.');
        }
        this.executionId = executionId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.llmConfigurationId = llmConfigId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnNum;
        this.currentPageRecordId = pageRecordId;
        this.isFinalErrorTurn = (isFinalError == true);
        this.decisionLogger = decisionLogger;
        this.logPrefix = '[LLMIntSvc Turn:' + turnId?.left(8) + ' Cycle:' + turnNum + '] ';
    }

    /**
     * Orchestrates the process of calling the LLM for a single conversational turn.
     *
     * - Loads agent and LLM configuration
     * - Delegates prompt composition to SystemPromptBuilder
     * - Injects summarization or error instructions as needed
     * - Assembles the final message and tool payloads
     * - Calls the LLM provider adapter (with retry logic)
     * - Packages the result or error for downstream processing
     *
     * @param currentTurnUserMessage  The DTO containing the user message for the current turn. Can be null for follow-up calls.
     * @return LLMInteractionResult   The result of the LLM interaction, including success/failure, provider result, and message metadata.
     */
    public LLMInteractionResult prepareAndCallLLM(LLMInteractionService.MessageData currentTurnUserMessage) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Starting LLM interaction cycle for turn ' + this.currentTurnCount + ' (executionId=' + this.executionId + ')'
        );
        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;

        // Create SystemPromptBuilder with decision logger if available
        SystemPromptBuilder promptBuilder = (this.decisionLogger != null) ? new SystemPromptBuilder(this.decisionLogger) : new SystemPromptBuilder();

        try {
            // 1. Load Core Configurations
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Loaded configuration: Agent=' +
                    agentConfig.DeveloperName__c +
                    ', LLM=' +
                    llmConfig.DeveloperName__c +
                    ', User=' +
                    this.userId
            );

            // --- 2. DELEGATE Prompt Composition ---
            // All complex prompt assembly logic is now in one place.
            String finalSystemPrompt = promptBuilder.build(
                this.executionId,
                agentConfig,
                llmConfig,
                this.currentPageRecordId,
                this.currentTurnCount,
                this.userId
            );

            // --- 3. FINAL SUMMARY INJECTION LOGIC
            Boolean isMultiStepTurn = this.currentTurnCount > 1;
            Boolean isFinalContentCall = (currentTurnUserMessage == null);

            // Default to 'true' (action transparency enabled) if the field is null for backward compatibility.
            Boolean actionTransparencyEnabled = (agentConfig.EnableActionTransparency__c != false);
            Boolean transientMessagesDisabled = !actionTransparencyEnabled;

            if (isMultiStepTurn && isFinalContentCall && transientMessagesDisabled) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Injecting summarization instructions for multi-step turn without action transparency.');

                String summarizationInstruction =
                    '\n\n# FINAL INSTRUCTIONS\n\n' +
                    'You have just completed one or more tool actions that the user did not see. ' +
                    'Your task is to synthesize the results of all actions into a single, user-friendly summary. ' +
                    'This will be the only message the user sees for this turn. ' +
                    'Do not ask questions; provide a conclusive, final response.';

                finalSystemPrompt += summarizationInstruction;
            }

            // This logic handles the "Halt and Report" error path.
            if (this.isFinalErrorTurn) {
                String finalErrorInstruction =
                    '\n\n# CRITICAL INSTRUCTIONS\n\n' +
                    'The last tool you tried to use failed. Inform the user of this failure based on the history. ' +
                    'Then, check if you have an alternative tool and propose it as the next step. ' +
                    'Do not use any tools now; only generate a text response.';
                finalSystemPrompt += finalErrorInstruction;
                System.debug(LoggingLevel.WARN, logPrefix + 'Injecting error recovery instructions into system prompt for failed tool use.');
            }

            // 4. Assemble the Final Message Payload for the LLM
            List<Map<String, Object>> finalMessagesPayload = new List<Map<String, Object>>();

            // a. Add the single, unified system prompt as the first message.
            if (String.isNotBlank(finalSystemPrompt)) {
                finalMessagesPayload.add(new Map<String, Object>{ 'role' => AIAgentConstants.ROLE_SYSTEM, 'content' => finalSystemPrompt });
            }

            // b. Get the execution history using the appropriate Memory Manager.
            IMemoryManager memoryManager = MemoryManagerFactory.getManager(agentConfig.MemoryStrategy__c);
            List<Map<String, Object>> historyPayload = memoryManager.getHistoryPayload(this.executionId, agentConfig, llmConfig, logPrefix);
            if (historyPayload != null) {
                finalMessagesPayload.addAll(historyPayload);
            }

            // c. Append the current user's message for this turn.
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

            // --- 5. Format Tool Definitions ---
            List<Map<String, Object>> toolsPayload = ToolDefinitionFormatter.formatToolsForApi(agentConfig.Id, logPrefix);

            // Log LLM request if decision logger is available
            if (this.decisionLogger != null) {
                // Additionally log the available tools list for better diagnostic visibility
                if (!toolsPayload.isEmpty()) {
                    List<String> toolNames = new List<String>();
                    for (Map<String, Object> tool : toolsPayload) {
                        if (tool.containsKey('function')) {
                            Map<String, Object> functionDef = (Map<String, Object>) tool.get('function');
                            if (functionDef.containsKey('name')) {
                                toolNames.add((String) functionDef.get('name'));
                            }
                        }
                    }

                    this.decisionLogger.logAvailableTools(
                        'Available Tools for LLM',
                        'List of tools made available to the LLM for this turn',
                        JSON.serialize(
                            new Map<String, Object>{ 'toolCount' => toolsPayload.size(), 'toolNames' => toolNames, 'tools' => toolsPayload }
                        ),
                        null
                    );
                }

                Map<String, Object> requestPayload = new Map<String, Object>{ 'messages' => finalMessagesPayload, 'tools' => toolsPayload };

                this.decisionLogger.logLLMRequest(
                    'LLM Request Prepared',
                    'Prepared complete LLM request payload with ' + toolsPayload.size() + ' available tools',
                    JSON.serialize(requestPayload),
                    null
                );
            }

            // --- 6. Call LLM (Includes Retries) ---
            Long callStartTime = System.currentTimeMillis();
            try {
                ILLMProviderAdapter adapter = LLMProviderFactory.getAdapter(llmConfig);
                ProviderResult llmApiResult = adapter.sendMessage(finalMessagesPayload, toolsPayload, llmConfig, agentConfig);

                if (llmApiResult == null) {
                    throw new LLMInteractionException('LLM Adapter returned a null result.');
                }
                Long callDuration = System.currentTimeMillis() - callStartTime;
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix +
                        'LLM call succeeded in ' +
                        callDuration +
                        'ms. Tokens used: ' +
                        llmApiResult.totalTokens +
                        ', executionId=' +
                        this.executionId
                );

                // Log LLM response if decision logger is available
                if (this.decisionLogger != null) {
                    this.decisionLogger.logLLMResponse(
                        'LLM Response Received',
                        'Successfully received response from LLM',
                        JSON.serialize(llmApiResult),
                        callDuration
                    );
                }

                // Package result DTOs
                MessageData asstMsgData = new MessageData();
                asstMsgData.role = AIAgentConstants.ROLE_ASSISTANT;
                asstMsgData.content = llmApiResult.content;
                asstMsgData.assistantToolCallsJson = llmApiResult.rawToolCallsJson;
                asstMsgData.tokensUsed = llmApiResult.totalTokens;
                asstMsgData.processingTimeMs = callDuration;

                return new LLMInteractionResult(llmApiResult, asstMsgData);
            } catch (Exception callEx) {
                Long callDuration = System.currentTimeMillis() - callStartTime;
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix +
                        'LLM call failed after ' +
                        callDuration +
                        'ms. Error: ' +
                        callEx.getMessage() +
                        ', Type: ' +
                        callEx.getTypeName() +
                        ', executionId=' +
                        this.executionId
                );

                // Log error if decision logger is available
                if (this.decisionLogger != null) {
                    this.decisionLogger.logError(
                        'LLM Call Failed',
                        'Failed to call LLM API',
                        AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                        callEx.getMessage(),
                        callEx.getStackTraceString(),
                        callDuration
                    );
                }

                return new LLMInteractionResult('LLM Call Failed: ' + callEx.getMessage(), AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, callEx);
            }
        } catch (Exception ex) {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    'Critical error during LLM interaction preparation: ' +
                    ex.getMessage() +
                    '\n' +
                    ex.getStackTraceString() +
                    ', executionId=' +
                    this.executionId
            );

            // Log error if decision logger is available
            if (this.decisionLogger != null) {
                this.decisionLogger.logError(
                    'LLM Interaction Setup Failed',
                    'Critical error during LLM interaction preparation',
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    ex.getMessage(),
                    ex.getStackTraceString(),
                    null
                );
            }

            return new LLMInteractionResult('Interaction Setup Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
        }
    }
}
