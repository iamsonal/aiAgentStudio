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
 *   - Manages prompt composition, payload formatting, HTTP communication, and response parsing
 *   - Integrates with SystemPromptBuilder for prompt assembly and MemoryManager for execution history
 *   - Supports action transparency mode, injecting summarization or error instructions as needed
 *   - Handles all configuration, error, and result packaging for downstream orchestration
 *   - Provides LLM provider adapter factory (consolidated from LLMProviderFactory)
 *
 * This service is the central entry point for all LLM calls in the agent framework, ensuring consistency,
 * observability, and extensibility for all execution turns.
 */
public inherited sharing class LLMInteractionService {
    // --- STATIC CACHE FOR LLM PROVIDER ADAPTERS (Consolidated from LLMProviderFactory) ---
    @TestVisible
    private static Map<String, ILLMProviderAdapter> adapterInstanceCache = new Map<String, ILLMProviderAdapter>();

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
     * - Calls the LLM provider adapter
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
        PIIMaskingService maskingService = null;

        try {
            // 1. Load Core Configurations
            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            llmConfig = AIAgentConfigService.getLLMConfiguration(this.llmConfigurationId);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Loaded configuration: Agent=' + agentConfig.DeveloperName__c + ', LLM=' + llmConfig.DeveloperName__c + ', User=' + this.userId
            );

            // 1b. Create PII Masking Service early so it can be used for context data formatting
            // This ensures schema-based PII masking works for context data in the system prompt
            maskingService = PIIMaskingService.createForAgent(agentConfig, this.executionId);
            if (maskingService != null) {
                System.debug(LoggingLevel.DEBUG, logPrefix + 'PII masking service created. Mode: ' + maskingService.getMode());
            }

            // Create SystemPromptBuilder with decision logger and PII masking service
            SystemPromptBuilder promptBuilder = new SystemPromptBuilder(this.decisionLogger, maskingService);

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

            // --- 3. AGENT-SPECIFIC PROMPT ADDITIONS ---
            // Delegate to orchestrator for agent-type-specific prompt modifications.
            // This keeps LLMInteractionService agent-agnostic.
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
            IMemoryManager memoryManager = ContextManagerService.getMemoryManager(agentConfig.MemoryStrategy__c);
            List<Map<String, Object>> historyPayload = memoryManager.getHistoryPayload(this.executionId, agentConfig, llmConfig, logPrefix);
            if (historyPayload != null) {
                finalMessagesPayload.addAll(historyPayload);
            }

            // c. Append the current user's message for this turn.
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

            // --- 5. Format Tool Definitions ---
            // Pass agent config to enable tool reasoning if configured
            // Pass executionId to enable tool exclusion based on MaxToolRetries__c
            List<Map<String, Object>> toolsPayload = LLMFormattingService.formatToolsForApi(agentConfig.Id, agentConfig, this.executionId, logPrefix);

            // Log available tools if decision logger is available (before masking - tools don't contain PII)
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

                this.decisionLogger.logAvailableTools(
                    'Available Tools for LLM',
                    'List of tools made available to the LLM for this turn',
                    JSON.serialize(new Map<String, Object>{ 'toolCount' => toolsPayload.size(), 'toolNames' => toolNames, 'tools' => toolsPayload }),
                    null
                );
            }

            // --- 6. Apply Prompt Safety Check (BEFORE PII Masking) ---
            // Checks for jailbreak attempts and prompt injection attacks
            PromptSafetyService safetyService = PromptSafetyService.createForAgent(agentConfig, this.executionId);
            if (safetyService != null && currentTurnUserMessage != null && String.isNotBlank(currentTurnUserMessage.content)) {
                ThreatAssessment safetyResult = safetyService.checkMessage(currentTurnUserMessage.content);

                // Log safety check result if decision logger is available
                if (this.decisionLogger != null) {
                    this.decisionLogger.logLLMRequest(
                        'Prompt Safety Check',
                        'Analyzed user message for jailbreak/injection attempts. Score: ' +
                            safetyResult.overallScore +
                            ', Level: ' +
                            safetyResult.levelName +
                            ', Action: ' +
                            safetyResult.recommendedAction,
                        JSON.serialize(safetyResult.getSummary()),
                        safetyResult.processingTimeMs
                    );
                }

                // Handle blocking if needed
                if (safetyResult.shouldBlock()) {
                    System.debug(
                        LoggingLevel.WARN,
                        logPrefix +
                            'Message blocked by prompt safety service. Score: ' +
                            safetyResult.overallScore +
                            ', Indicators: ' +
                            safetyResult.getIndicatorCount()
                    );

                    // Log error if decision logger is available
                    if (this.decisionLogger != null) {
                        this.decisionLogger.logError(
                            'Message Blocked',
                            'User message blocked by prompt safety service due to detected threat',
                            AIAgentConstants.ERR_CODE_SAFETY_BLOCKED,
                            safetyResult.getSafeMessage(),
                            null,
                            safetyResult.processingTimeMs
                        );
                    }

                    return new LLMInteractionResult(safetyResult.getSafeMessage(), AIAgentConstants.ERR_CODE_SAFETY_BLOCKED, null);
                }

                // Apply sanitization if configured
                if (safetyResult.hasSanitizedContent()) {
                    currentTurnUserMessage.content = safetyResult.getSanitizedContent();
                    System.debug(LoggingLevel.INFO, logPrefix + 'Applied sanitization to user message. Original threats neutralized.');
                }

                // Handle flagging (message continues but is marked for review)
                if (safetyResult.flagged) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Message flagged for review. Score: ' + safetyResult.overallScore + ', Indicators: ' + safetyResult.getIndicatorCount()
                    );
                    // The flagged status is logged via decision logger above
                }
            }

            // --- 8. Apply PII Masking (if enabled) ---
            // IMPORTANT: Must happen BEFORE logging the LLM request to ensure no raw PII is stored in decision logs
            // Note: maskingService was created earlier (step 1b) for context data formatting, reusing it here
            if (maskingService != null) {
                finalMessagesPayload = maskingService.maskMessagePayload(finalMessagesPayload);
                System.debug(LoggingLevel.INFO, logPrefix + 'Applied PII masking to message payload. Mode: ' + maskingService.getMode());
            }

            // Log LLM request AFTER PII masking to ensure decision logs contain only masked data
            if (this.decisionLogger != null) {
                Map<String, Object> requestPayload = new Map<String, Object>{ 'messages' => finalMessagesPayload, 'tools' => toolsPayload };

                String description = 'Prepared complete LLM request payload with ' + toolsPayload.size() + ' available tools';
                if (maskingService != null) {
                    description += ' (PII masked)';
                }

                this.decisionLogger.logLLMRequest('LLM Request Prepared', description, JSON.serialize(requestPayload), null);
            }

            // --- 9. Call LLM ---
            Long callStartTime = System.currentTimeMillis();
            try {
                ILLMProviderAdapter adapter = LLMInteractionService.getLLMProviderAdapter(llmConfig);
                ProviderResult llmApiResult = adapter.sendMessage(finalMessagesPayload, toolsPayload, llmConfig, agentConfig);

                if (llmApiResult == null) {
                    throw new LLMInteractionException('LLM Adapter returned a null result.');
                }
                Long callDuration = System.currentTimeMillis() - callStartTime;
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'LLM call succeeded in ' + callDuration + 'ms. Tokens used: ' + llmApiResult.totalTokens + ', executionId=' + this.executionId
                );

                // Log LLM response if decision logger is available
                if (this.decisionLogger != null) {
                    // Extract provider name from adapter class (e.g., "OpenAIProviderAdapter" -> "OpenAI")
                    String providerName = extractProviderName(llmConfig.ProviderAdapterClass__c);

                    // Use the same duration value as ExecutionStep__c.LLMCalloutDurationMs__c
                    // This ensures consistency between ExecutionStep and AgentDecisionStep records
                    Long llmCalloutDuration = llmApiResult.llmCalloutDurationMs != null ? llmApiResult.llmCalloutDurationMs : callDuration;

                    // Use enhanced logging method with cost and token tracking
                    this.decisionLogger.logLLMResponseWithMetrics(
                        'LLM Response Received',
                        'Successfully received response from LLM',
                        JSON.serialize(llmApiResult),
                        llmCalloutDuration,
                        llmApiResult.promptTokens,
                        llmApiResult.completionTokens,
                        llmApiResult.totalTokens,
                        llmConfig.DefaultModelIdentifier__c,
                        providerName,
                        llmConfig.DefaultTemperature__c
                    );
                }

                // --- Unmask PII in response (if masking was applied) ---
                String unmaskedContent = llmApiResult.content;
                String unmaskedToolCallsJson = llmApiResult.rawToolCallsJson;
                if (maskingService != null) {
                    if (String.isNotBlank(unmaskedContent)) {
                        unmaskedContent = maskingService.unmaskText(unmaskedContent);
                    }
                    if (String.isNotBlank(unmaskedToolCallsJson)) {
                        unmaskedToolCallsJson = maskingService.unmaskText(unmaskedToolCallsJson);
                    }
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Applied PII unmasking to LLM response. Stats: ' + JSON.serialize(maskingService.getStatistics())
                    );
                }

                // Package result DTOs
                MessageData asstMsgData = new MessageData();
                asstMsgData.role = AIAgentConstants.ROLE_ASSISTANT;
                asstMsgData.content = unmaskedContent;
                asstMsgData.assistantToolCallsJson = unmaskedToolCallsJson;
                asstMsgData.tokensUsed = llmApiResult.totalTokens;
                asstMsgData.processingTimeMs = callDuration;

                // Also update the provider result with unmasked content for consistency
                llmApiResult.content = unmaskedContent;
                llmApiResult.rawToolCallsJson = unmaskedToolCallsJson;

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

    /**
     * Extract provider name from the adapter class name
     * Example: "OpenAIProviderAdapter" -> "OpenAI"
     *
     * @param adapterClassName The adapter class name
     * @return The provider name
     */
    private String extractProviderName(String adapterClassName) {
        if (String.isBlank(adapterClassName)) {
            return 'Unknown';
        }

        // Remove "ProviderAdapter" suffix if present
        String providerName = adapterClassName.replace('ProviderAdapter', '');

        // If nothing left, return the full class name
        if (String.isBlank(providerName)) {
            return adapterClassName;
        }

        return providerName;
    }

    // =========================================================================
    // LLM PROVIDER ADAPTER FACTORY (Consolidated from LLMProviderFactory)
    // =========================================================================

    /**
     * @description
     * Retrieves a cached or newly instantiated LLM provider adapter based on configuration.
     * Consolidated from LLMProviderFactory to reduce file overhead.
     *
     * - Checks the cache for an existing adapter instance by class name
     * - Dynamically instantiates the adapter if not cached, validates interface implementation
     * - Caches the instance for future use
     *
     * @param llmConfig  The LLMConfiguration__c record containing the adapter class name
     * @return ILLMProviderAdapter  Configured adapter instance ready for use
     * @throws ConfigurationException if the adapter class is missing, invalid, or does not implement the required interface
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

    /**
     * @description
     * Clears the adapter instance cache. Used for testing or to force re-instantiation.
     */
    @TestVisible
    private static void clearAdapterCache() {
        adapterInstanceCache = new Map<String, ILLMProviderAdapter>();
        System.debug(LoggingLevel.DEBUG, '[LLMInteractionService] Adapter cache cleared.');
    }

    // =========================================================================
    // ORCHESTRATOR INTEGRATION
    // =========================================================================

    /**
     * @description
     * Gets agent-specific prompt additions from the orchestrator.
     * This delegates prompt customization to the orchestrator, keeping LLMInteractionService agent-agnostic.
     *
     * @param agentConfig The agent definition
     * @param executionId The execution ID
     * @param userId The user ID
     * @param currentTurnCount The current turn count
     * @param currentTurnUserMessage The user message for this turn (null for follow-up calls)
     * @param currentPageRecordId The current page record ID
     * @param logPrefix Logging prefix
     * @return String to append to system prompt, or empty string
     */
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
            // Build a minimal OrchestrationContext for the orchestrator hook
            // Note: We don't have the full context here (no LLM result yet), but we have enough
            // for the orchestrator to make prompt decisions
            OrchestrationContext minimalContext = buildMinimalContext(
                executionId,
                userId,
                agentConfig.Id,
                currentTurnCount,
                currentTurnUserMessage,
                currentPageRecordId
            );

            // Load the orchestrator for this agent type
            IAgentOrchestrator orchestrator = loadOrchestrator(agentConfig);

            // Get prompt additions from orchestrator (polymorphic call - no instanceof check needed)
            String additions = orchestrator.buildSystemPromptAdditions(minimalContext);

            return additions != null ? additions : '';
        } catch (Exception e) {
            // Log but don't fail - prompt additions are optional
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to get orchestrator prompt additions: ' + e.getMessage());
            return '';
        }
    }

    /**
     * @description
     * Builds a minimal OrchestrationContext for use in prompt building.
     * This context doesn't have LLM results yet (we're preparing for the call).
     */
    private OrchestrationContext buildMinimalContext(
        Id executionId,
        Id userId,
        Id agentDefinitionId,
        Integer currentTurnCount,
        MessageData currentTurnUserMessage,
        Id currentPageRecordId
    ) {
        // Generate a temporary turn identifier for context
        String turnIdentifier = 'prompt_' + System.currentTimeMillis();

        return new OrchestrationContext(
            null, // llmResult - not available yet
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
     * Uses the same metadata-driven approach as AgentExecutionService.
     */
    private IAgentOrchestrator loadOrchestrator(AIAgentDefinition__c agentConfig) {
        String agentType = agentConfig.AgentType__c;

        if (String.isBlank(agentType)) {
            throw new LLMInteractionException('AgentType__c is required on agent definition');
        }

        // Query orchestrator mapping
        List<AgentOrchestratorMapping__mdt> mappings = [
            SELECT OrchestratorClassName__c
            FROM AgentOrchestratorMapping__mdt
            WHERE AgentType__c = :agentType AND IsActive__c = TRUE
            LIMIT 1
        ];

        if (mappings.isEmpty()) {
            throw new LLMInteractionException('No orchestrator mapping found for agent type: ' + agentType);
        }

        String orchestratorClassName = mappings[0].OrchestratorClassName__c;

        // Instantiate orchestrator
        Type orchestratorType = Type.forName(orchestratorClassName);
        if (orchestratorType == null) {
            throw new LLMInteractionException('Orchestrator class not found: ' + orchestratorClassName);
        }

        Object instanceObj = orchestratorType.newInstance();
        if (!(instanceObj instanceof IAgentOrchestrator)) {
            throw new LLMInteractionException('Class does not implement IAgentOrchestrator: ' + orchestratorClassName);
        }

        IAgentOrchestrator orchestrator = (IAgentOrchestrator) instanceObj;
        orchestrator.configure(agentConfig);

        return orchestrator;
    }
}
