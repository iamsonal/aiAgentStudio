/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Orchestrates LLM interaction lifecycle for a single execution turn. Manages prompt composition, payload formatting, and response parsing.
 */
public inherited sharing class LLMInteractionService {
    private static final Integer SAFETY_CONTEXT_MAX_HISTORY = 3;
    private static final Integer SAFETY_CONTEXT_MAX_CHARS = 2000;
    @TestVisible
    private static Map<String, ILLMProviderAdapter> adapterInstanceCache = new Map<String, ILLMProviderAdapter>();

    @TestVisible
    private static Map<Id, LLMRequestCache> requestCacheByExecution = new Map<Id, LLMRequestCache>();
    @TestVisible
    private class LLMRequestCache {
        public String systemPrompt;
        public List<Map<String, Object>> toolsPayload;
        public AIAgentDefinition__c agentConfig;
        public LLMConfiguration__c llmConfig;
        public PIIMaskingService maskingService;
        public Datetime createdAt;

        public LLMRequestCache() {
            this.createdAt = Datetime.now();
        }
    }

    public static void clearRequestCache(Id executionId) {
        if (executionId != null && requestCacheByExecution.containsKey(executionId)) {
            requestCacheByExecution.remove(executionId);
            System.debug(LoggingLevel.DEBUG, '[LLMInteractionService] Cleared request cache for execution: ' + executionId);
        }
    }

    @TestVisible
    private static void clearAllRequestCaches() {
        requestCacheByExecution.clear();
    }

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
    private final IDecisionStepLogger.ILogger decisionLogger;
    private List<ExecutionStep__c> pendingSafetyAuditSteps = new List<ExecutionStep__c>();
    public LLMInteractionService(
        Id executionId,
        Id usrId,
        Id agentDefId,
        Id llmConfigId,
        String turnId,
        Integer turnNum,
        Id pageRecordId,
        Boolean isFinalError,
        IDecisionStepLogger.ILogger decisionLogger
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

    public LLMInteractionResult prepareAndCallLLM(LLMInteractionService.MessageData currentTurnUserMessage) {
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Starting LLM interaction cycle for turn ' + this.currentTurnCount + ' (executionId=' + this.executionId + ')'
        );
        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        PIIMaskingService maskingService = null;
        String finalSystemPrompt = null;
        List<Map<String, Object>> toolsPayload = null;

        try {
            Boolean useCachedContext = false;
            LLMRequestCache cachedRequest = null;

            if (TransactionContext.getInstance().isDeferredDMLMode() && requestCacheByExecution.containsKey(this.executionId)) {
                cachedRequest = requestCacheByExecution.get(this.executionId);
                // Only use cache if it's from the same transaction (within reasonable time window)
                if (cachedRequest != null && cachedRequest.systemPrompt != null) {
                    useCachedContext = true;
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Using cached request context (saved system prompt rebuild)');
                }
            }

            if (useCachedContext) {
                agentConfig = cachedRequest.agentConfig;
                llmConfig = cachedRequest.llmConfig;
                maskingService = cachedRequest.maskingService;
                finalSystemPrompt = cachedRequest.systemPrompt;
                toolsPayload = cachedRequest.toolsPayload;

                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Loaded cached config: Agent=' + agentConfig.DeveloperName__c + ', LLM=' + llmConfig.DeveloperName__c
                );
            } else {
                agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
                llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Loaded configuration: Agent=' + agentConfig.DeveloperName__c + ', LLM=' + llmConfig.DeveloperName__c + ', User=' + this.userId
                );

                maskingService = PIIMaskingService.createForAgent(agentConfig, this.executionId);
                if (maskingService != null) {
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'PII masking service created. Mode: ' + maskingService.getMode());
                }

                SystemPromptBuilder promptBuilder = new SystemPromptBuilder(this.decisionLogger, maskingService);
                finalSystemPrompt = promptBuilder.build(this.executionId, agentConfig, llmConfig, this.currentPageRecordId, this.currentTurnCount, this.userId);

                String orchestratorAdditions = getOrchestratorPromptAdditions(
                    agentConfig,
                    this.executionId,
                    this.userId,
                    this.currentTurnCount,
                    currentTurnUserMessage,
                    this.currentPageRecordId,
                    logPrefix
                );

                if (String.isNotBlank(orchestratorAdditions)) {
                    finalSystemPrompt += orchestratorAdditions;
                    System.debug(LoggingLevel.INFO, logPrefix + 'Added orchestrator-specific prompt additions');
                }

                if (this.isFinalErrorTurn) {
                    String finalErrorInstruction =
                        '\n\n# CRITICAL INSTRUCTIONS\n\n' +
                        'The last tool you tried to use failed. Inform the user of this failure based on the history. ' +
                        'Then, check if you have an alternative tool and propose it as the next step. ' +
                        'Do not use any tools now; only generate a text response.';
                    finalSystemPrompt += finalErrorInstruction;
                    System.debug(LoggingLevel.WARN, logPrefix + 'Injecting error recovery instructions into system prompt for failed tool use.');
                }

                toolsPayload = LLMFormattingService.formatToolsForApi(agentConfig.Id, agentConfig, this.executionId, logPrefix);

                if (this.decisionLogger != null && !toolsPayload.isEmpty()) {
                    List<String> toolNames = new List<String>();
                    for (Map<String, Object> tool : toolsPayload) {
                        if (tool.containsKey('function')) {
                            Map<String, Object> functionDef = (Map<String, Object>) tool.get('function');
                            if (functionDef.containsKey('name')) {
                                toolNames.add((String) functionDef.get('name'));
                            }
                        }
                    }

                    this.decisionLogger.log(IDecisionStepLogger.EventType.TOOLS_CONFIGURED, new List<Object>{ toolsPayload });
                }

                if (TransactionContext.getInstance().isDeferredDMLMode()) {
                    LLMRequestCache newCache = new LLMRequestCache();
                    newCache.systemPrompt = finalSystemPrompt;
                    newCache.toolsPayload = toolsPayload;
                    newCache.agentConfig = agentConfig;
                    newCache.llmConfig = llmConfig;
                    newCache.maskingService = maskingService;
                    requestCacheByExecution.put(this.executionId, newCache);
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'Multi-LLM optimization: Cached request context for subsequent calls');
                }
            }

            List<Map<String, Object>> finalMessagesPayload = new List<Map<String, Object>>();

            if (String.isNotBlank(finalSystemPrompt)) {
                finalMessagesPayload.add(new Map<String, Object>{ 'role' => AIAgentConstants.ROLE_SYSTEM, 'content' => finalSystemPrompt });
            }

            IMemoryManager memoryManager = ContextManagerService.getMemoryManager(agentConfig.MemoryStrategy__c);
            List<Map<String, Object>> historyPayload = memoryManager.getHistoryPayload(this.executionId, agentConfig, llmConfig, logPrefix);
            if (historyPayload != null) {
                finalMessagesPayload.addAll(historyPayload);
            }

            if (currentTurnUserMessage != null && String.isNotBlank(currentTurnUserMessage.content)) {
                LLMFormattingService.addMessageToPayload(
                    finalMessagesPayload,
                    currentTurnUserMessage.role,
                    currentTurnUserMessage.content,
                    null,
                    null,
                    logPrefix,
                    'Current User Turn'
                );
            }

            PromptSafetyService safetyService = PromptSafetyService.createForAgent(agentConfig, this.executionId);
            if (safetyService != null && currentTurnUserMessage != null && String.isNotBlank(currentTurnUserMessage.content)) {
                String originalUserMessage = currentTurnUserMessage.content;
                ThreatAssessment safetyResult = safetyService.checkMessage(originalUserMessage);

                if (this.decisionLogger != null) {
                    this.decisionLogger.log(IDecisionStepLogger.EventType.SAFETY_CHECK, new List<Object>{ safetyResult });
                }

                if (safetyService.isAuditLoggingEnabled()) {
                    logPromptSafetyAudit(safetyResult, 'current', logPrefix);
                }

                if (safetyResult.shouldBlock()) {
                    System.debug(
                        LoggingLevel.WARN,
                        logPrefix +
                            'Message blocked by prompt safety service. Score: ' +
                            safetyResult.overallScore +
                            ', Indicators: ' +
                            safetyResult.getIndicatorCount()
                    );

                    // Log as SAFETY_BLOCKED (not ERROR) - this is expected behavior, not a failure
                    if (this.decisionLogger != null) {
                        this.decisionLogger.log(IDecisionStepLogger.EventType.SAFETY_BLOCKED, new List<Object>{ safetyResult });
                    }

                    // Return a SUCCESS result with safe response instead of failure
                    // This allows ContentResponseHandler to process it as a normal content response
                    // and complete the turn gracefully instead of failing
                    String safeMessage = safetyResult.getSafeMessage();
                    ProviderResult safetyProviderResult = new ProviderResult(
                        safeMessage, // content
                        0, // promptTokens (no LLM call made)
                        0, // completionTokens
                        0, // totalTokens
                        null, // requestedActions (no tool calls)
                        null, // rawToolCallsJson
                        null, // rawAssistantMessageWithActionsJson
                        'safety-layer', // modelIdentifier
                        0 // llmCalloutDurationMs
                    );

                    MessageData safetyMessageData = new MessageData();
                    safetyMessageData.role = AIAgentConstants.ROLE_ASSISTANT;
                    safetyMessageData.content = safeMessage;

                    System.debug(LoggingLevel.INFO, logPrefix + 'Returning safe response to user: ' + safeMessage.left(100));
                    flushPendingSafetyAuditSteps(logPrefix, false);
                    return new LLMInteractionResult(safetyProviderResult, safetyMessageData);
                }

                if (safetyResult.hasSanitizedContent()) {
                    currentTurnUserMessage.content = safetyResult.getSanitizedContent();
                    System.debug(LoggingLevel.INFO, logPrefix + 'Applied sanitization to user message. Original threats neutralized.');
                }

                if (safetyResult.flagged) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Message flagged for review. Score: ' + safetyResult.overallScore + ', Indicators: ' + safetyResult.getIndicatorCount()
                    );
                }

                String safetyContext = buildPromptSafetyContext(this.executionId, originalUserMessage, logPrefix);
                if (String.isNotBlank(safetyContext)) {
                    ThreatAssessment contextResult = safetyService.checkMessage(safetyContext);

                    if (this.decisionLogger != null) {
                        this.decisionLogger.log(IDecisionStepLogger.EventType.SAFETY_CHECK, new List<Object>{ contextResult, 'context' });
                    }

                    if (safetyService.isAuditLoggingEnabled()) {
                        logPromptSafetyAudit(contextResult, 'context', logPrefix);
                    }

                    if (contextResult.shouldBlock()) {
                        System.debug(
                            LoggingLevel.WARN,
                            logPrefix +
                                'Message blocked by prompt safety context check. Score: ' +
                                contextResult.overallScore +
                                ', Indicators: ' +
                                contextResult.getIndicatorCount()
                        );

                        if (this.decisionLogger != null) {
                            this.decisionLogger.log(IDecisionStepLogger.EventType.SAFETY_BLOCKED, new List<Object>{ contextResult, 'context' });
                        }

                        String safeMessage = contextResult.getSafeMessage();
                        ProviderResult safetyProviderResult = new ProviderResult(
                            safeMessage, // content
                            0, // promptTokens (no LLM call made)
                            0, // completionTokens
                            0, // totalTokens
                            null, // requestedActions (no tool calls)
                            null, // rawToolCallsJson
                            null, // rawAssistantMessageWithActionsJson
                            'safety-layer', // modelIdentifier
                            0 // llmCalloutDurationMs
                        );

                        MessageData safetyMessageData = new MessageData();
                        safetyMessageData.role = AIAgentConstants.ROLE_ASSISTANT;
                        safetyMessageData.content = safeMessage;

                        System.debug(LoggingLevel.INFO, logPrefix + 'Returning safe response to user (context check): ' + safeMessage.left(100));
                        flushPendingSafetyAuditSteps(logPrefix, false);
                        return new LLMInteractionResult(safetyProviderResult, safetyMessageData);
                    }

                    if (contextResult.flagged) {
                        System.debug(
                            LoggingLevel.INFO,
                            logPrefix +
                                'Message flagged for review by context check. Score: ' +
                                contextResult.overallScore +
                                ', Indicators: ' +
                                contextResult.getIndicatorCount()
                        );
                    }
                }
            }

            if (maskingService != null) {
                Integer maskingOpsBefore = null;
                if (this.decisionLogger != null) {
                    Map<String, Object> preStats = maskingService.getStatistics();
                    Object preCount = preStats != null ? preStats.get('totalMaskingOperations') : null;
                    if (preCount instanceof Integer) {
                        maskingOpsBefore = (Integer) preCount;
                    }
                }

                finalMessagesPayload = maskingService.maskMessagePayload(finalMessagesPayload);
                System.debug(LoggingLevel.INFO, logPrefix + 'Applied PII masking to message payload. Mode: ' + maskingService.getMode());

                if (this.decisionLogger != null) {
                    Map<String, Object> stats = maskingService.getStatistics();
                    Integer maskingOpsAfter = null;
                    Object postCount = stats != null ? stats.get('totalMaskingOperations') : null;
                    if (postCount instanceof Integer) {
                        maskingOpsAfter = (Integer) postCount;
                    }
                    Integer appliedCount = null;
                    if (maskingOpsBefore != null && maskingOpsAfter != null) {
                        appliedCount = Math.max(0, maskingOpsAfter - maskingOpsBefore);
                    }
                    this.decisionLogger.log(IDecisionStepLogger.EventType.PII_MASKING, new List<Object>{ stats, appliedCount });
                }
            }

            if (this.decisionLogger != null) {
                Map<String, Object> requestPayload = new Map<String, Object>{ 'messages' => finalMessagesPayload, 'tools' => toolsPayload };
                this.decisionLogger.log(IDecisionStepLogger.EventType.LLM_REQUEST, new List<Object>{ requestPayload });
            }

            Long callStartTime = System.currentTimeMillis();
            try {
                ILLMProviderAdapter adapter = LLMInteractionService.getLLMProviderAdapter(llmConfig);
                ProviderResult llmApiResult = adapter.sendMessage(finalMessagesPayload, toolsPayload, llmConfig, agentConfig);

                if (llmApiResult == null) {
                    throw new LLMInteractionException('LLM Adapter returned a null result.');
                }
                Long callDuration = System.currentTimeMillis() - callStartTime;
                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call succeeded in ' + callDuration + 'ms. executionId=' + this.executionId);

                if (this.decisionLogger != null) {
                    this.decisionLogger.log(IDecisionStepLogger.EventType.LLM_RESPONSE, new List<Object>{ llmApiResult, llmConfig });
                }

                String unmaskedContent = llmApiResult.content;
                String unmaskedToolCallsJson = llmApiResult.rawToolCallsJson;
                if (maskingService != null) {
                    if (String.isNotBlank(unmaskedContent)) {
                        unmaskedContent = maskingService.unmaskText(unmaskedContent);
                    }
                    if (String.isNotBlank(unmaskedToolCallsJson)) {
                        unmaskedToolCallsJson = maskingService.unmaskText(unmaskedToolCallsJson);
                    }
                    if (llmApiResult.requestedActions != null && !llmApiResult.requestedActions.isEmpty()) {
                        for (Map<String, String> action : llmApiResult.requestedActions) {
                            if (action == null) {
                                continue;
                            }
                            String args = action.get('arguments');
                            if (String.isNotBlank(args)) {
                                action.put('arguments', maskingService.unmaskText(args));
                            }
                        }
                    }
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'Applied PII unmasking to LLM response.');
                }

                MessageData asstMsgData = new MessageData();
                asstMsgData.role = AIAgentConstants.ROLE_ASSISTANT;
                asstMsgData.content = unmaskedContent;
                asstMsgData.assistantToolCallsJson = unmaskedToolCallsJson;
                asstMsgData.tokensUsed = llmApiResult.totalTokens;
                asstMsgData.processingTimeMs = callDuration;

                llmApiResult.content = unmaskedContent;
                llmApiResult.rawToolCallsJson = unmaskedToolCallsJson;

                Boolean hasToolCalls = (llmApiResult.requestedActions != null && !llmApiResult.requestedActions.isEmpty());
                flushPendingSafetyAuditSteps(logPrefix, hasToolCalls);
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

                if (this.decisionLogger != null) {
                    this.decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ callEx });
                }

                flushPendingSafetyAuditSteps(logPrefix, false);
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
                this.decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ ex });
            }

            flushPendingSafetyAuditSteps(logPrefix, false);
            return new LLMInteractionResult('Interaction Setup Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
        }
    }

    private String extractProviderName(String adapterClassName) {
        if (String.isBlank(adapterClassName)) {
            return 'Unknown';
        }

        String providerName = adapterClassName.replace('ProviderAdapter', '');

        if (String.isBlank(providerName)) {
            return adapterClassName;
        }

        return providerName;
    }

    /**
     * @description Retrieves a cached or newly instantiated LLM provider adapter based on configuration.
     */
    public static ILLMProviderAdapter getLLMProviderAdapter(LLMConfiguration__c llmConfig) {
        if (llmConfig == null) {
            throw new LLMInteractionException('LLM Configuration cannot be null for getting adapter.');
        }
        String adapterClassName = llmConfig.ProviderAdapterClass__c;
        if (String.isBlank(adapterClassName)) {
            throw new LLMInteractionException('ProviderAdapterClass__c is not defined for LLM Configuration: ' + llmConfig.DeveloperName__c);
        }

        if (adapterInstanceCache.containsKey(adapterClassName)) {
            System.debug(LoggingLevel.DEBUG, '[LLMInteractionService] Cache hit for adapter: ' + adapterClassName);
            return adapterInstanceCache.get(adapterClassName);
        }

        try {
            Type adapterType = Type.forName(adapterClassName);
            if (adapterType == null) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[LLMInteractionService] Adapter class not found: ' + adapterClassName + ' for LLM Config ' + llmConfig.DeveloperName__c
                );
                throw new LLMInteractionException('Adapter class not found: ' + adapterClassName + ' for LLM Config ' + llmConfig.DeveloperName__c);
            }
            Object adapterObject = adapterType.newInstance();
            if (!(adapterObject instanceof ILLMProviderAdapter)) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[LLMInteractionService] Class ' + adapterClassName + ' does not implement ILLMProviderAdapter for LLM Config ' + llmConfig.DeveloperName__c
                );
                throw new LLMInteractionException(
                    'Class ' + adapterClassName + ' does not implement ILLMProviderAdapter for LLM Config ' + llmConfig.DeveloperName__c
                );
            }
            ILLMProviderAdapter adapterInstance = (ILLMProviderAdapter) adapterObject;
            adapterInstanceCache.put(adapterClassName, adapterInstance);
            System.debug(LoggingLevel.INFO, '[LLMInteractionService] Instantiated and cached adapter: ' + adapterClassName);
            return adapterInstance;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[LLMInteractionService] Error instantiating adapter ' + adapterClassName + ' for LLM ' + llmConfig.DeveloperName__c + ': ' + e.getMessage()
            );
            throw new LLMInteractionException(
                'Error instantiating adapter ' + adapterClassName + ' for LLM ' + llmConfig.DeveloperName__c + ': ' + e.getMessage(),
                e
            );
        }
    }

    @TestVisible
    private static void clearAdapterCache() {
        adapterInstanceCache = new Map<String, ILLMProviderAdapter>();
        System.debug(LoggingLevel.DEBUG, '[LLMInteractionService] Adapter cache cleared.');
    }

    private String getOrchestratorPromptAdditions(
        AIAgentDefinition__c agentConfig,
        Id executionId,
        Id userId,
        Integer currentTurnCount,
        MessageData currentTurnUserMessage,
        Id currentPageRecordId,
        String logPrefix
    ) {
        try {
            OrchestrationContext minimalContext = buildMinimalContext(
                executionId,
                userId,
                agentConfig.Id,
                currentTurnCount,
                currentTurnUserMessage,
                currentPageRecordId
            );

            IAgentOrchestrator orchestrator = loadOrchestrator(agentConfig);
            String additions = orchestrator.buildSystemPromptAdditions(minimalContext);

            return additions != null ? additions : '';
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to get orchestrator prompt additions: ' + e.getMessage());
            return '';
        }
    }

    private OrchestrationContext buildMinimalContext(
        Id executionId,
        Id userId,
        Id agentDefinitionId,
        Integer currentTurnCount,
        MessageData currentTurnUserMessage,
        Id currentPageRecordId
    ) {
        String turnIdentifier = 'prompt_' + System.currentTimeMillis();

        return new OrchestrationContext(
            null,
            executionId,
            userId,
            userId, // executionUserId
            agentDefinitionId,
            turnIdentifier,
            currentTurnCount,
            currentTurnUserMessage,
            new AgentStateService(),
            new CapabilityExecutionService(),
            new AgentJobEnqueuer(),
            new ContextManagerService(),
            currentPageRecordId,
            this.decisionLogger
        );
    }

    /**
     * @description
     * Loads the appropriate orchestrator for an agent definition.
     * Delegates to AgentExecutionService.getOrchestrator() so the transaction-level static
     * cache is used instead of issuing a per-call SOQL against AgentOrchestratorMapping__mdt.
     */
    private IAgentOrchestrator loadOrchestrator(AIAgentDefinition__c agentConfig) {
        try {
            return AgentExecutionService.getOrchestrator(agentConfig);
        } catch (AIAgentException.OrchestrationException e) {
            throw new LLMInteractionException(e.getMessage());
        }
    }

    private String buildPromptSafetyContext(Id executionId, String currentMessage, String logPrefix) {
        if (executionId == null || String.isBlank(currentMessage)) {
            return null;
        }

        try {
            ExecutionStepService executionStepService = new ExecutionStepService();
            List<ExecutionStep__c> recentInputs = executionStepService.getHistory(
                executionId,
                SAFETY_CONTEXT_MAX_HISTORY,
                'DESC',
                new List<String>{ 'UserInput' },
                false
            );

            if (recentInputs == null || recentInputs.isEmpty()) {
                return null;
            }

            List<String> messages = new List<String>();
            for (ExecutionStep__c step : recentInputs) {
                if (String.isNotBlank(step.Content__c)) {
                    messages.add(step.Content__c);
                }
            }

            if (messages.isEmpty()) {
                return null;
            }

            List<String> orderedMessages = new List<String>();
            for (Integer i = messages.size() - 1; i >= 0; i--) {
                orderedMessages.add(messages[i]);
            }
            orderedMessages.add(currentMessage);

            String combined = String.join(orderedMessages, '\n');
            if (combined.length() > SAFETY_CONTEXT_MAX_CHARS) {
                combined = combined.right(SAFETY_CONTEXT_MAX_CHARS);
            }

            return combined;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to build prompt safety context: ' + e.getMessage());
            return null;
        }
    }

    private void logPromptSafetyAudit(ThreatAssessment assessment, String scope, String logPrefix) {
        if (assessment == null || this.executionId == null) {
            return;
        }

        try {
            Map<String, Object> summary = assessment.getSummary();
            summary.put('scope', scope);
            summary.put('executionId', this.executionId);
            summary.put('turnIdentifier', this.turnIdentifier);
            summary.put('turnCount', this.currentTurnCount);

            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                ExecutionStepService executionStepService = new ExecutionStepService();
                executionStepService.createStep(
                    this.executionId,
                    'SystemEvent',
                    'System',
                    JSON.serialize(summary),
                    'JSON',
                    this.turnIdentifier,
                    this.currentTurnCount
                );
                return;
            }

            ExecutionStep__c pendingStep = new ExecutionStep__c(
                AgentExecution__c = this.executionId,
                StepType__c = 'SystemEvent',
                StepRole__c = 'System',
                Content__c = JSON.serialize(summary),
                ContentType__c = 'JSON',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = this.turnIdentifier,
                TurnCount__c = this.currentTurnCount,
                IsInternal__c = false,
                IsAsyncToolExecution__c = false
            );
            this.pendingSafetyAuditSteps.add(pendingStep);
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Queued prompt safety audit step for deferred insert.');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log prompt safety audit: ' + e.getMessage());
        }
    }

    private void flushPendingSafetyAuditSteps(String logPrefix, Boolean mayCallAgain) {
        if (this.pendingSafetyAuditSteps == null || this.pendingSafetyAuditSteps.isEmpty()) {
            return;
        }

        try {
            if (TransactionContext.getInstance().isDeferredDMLMode() || mayCallAgain == true) {
                for (ExecutionStep__c pendingStep : this.pendingSafetyAuditSteps) {
                    TransactionContext.getInstance().bufferInsert(pendingStep);
                }
                System.debug(LoggingLevel.INFO, logPrefix + 'Buffered ' + this.pendingSafetyAuditSteps.size() + ' pending prompt safety audit step(s).');
            } else {
                insert this.pendingSafetyAuditSteps;
                System.debug(LoggingLevel.INFO, logPrefix + 'Inserted ' + this.pendingSafetyAuditSteps.size() + ' pending prompt safety audit step(s).');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to flush prompt safety audit steps: ' + e.getMessage());
        } finally {
            this.pendingSafetyAuditSteps.clear();
        }
    }
}
