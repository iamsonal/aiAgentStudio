/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SystemPromptBuilder is a centralized service for composing comprehensive system prompts sent to LLMs.
 * It assembles prompts from agent configuration fields, dynamic context data, and temporal information.
 * The builder integrates sophisticated context management with traditional SObject formatting, providing
 * intelligent prioritization, truncation, and structured context organization optimized for LLM consumption.
 *
 * Responsibilities:
 *   - Compose system prompts from static, dynamic, and temporal sources
 *   - Integrate conversation summaries and structured context ledger data
 *   - Provide intelligent context prioritization and truncation within token limits
 *   - Support hierarchical context organization (primary, recent, related, background)
 *   - Offer context summaries and highlighting for diagnostics and UI
 *   - Maintain backward compatibility with traditional context resolution
 *   - Provide clear debug output for prompt composition and troubleshooting
 */
public inherited sharing class SystemPromptBuilder {
    private final ContextResolverService contextResolver;
    private final ContextManagerService contextManager;

    // --- CONSTANTS ---
    private static final Integer MAX_CONTEXT_CHARS = 8000; // Leave room for other prompt content
    private static final Map<String, String> SECTION_HEADERS = new Map<String, String>{
        'primary' => '## Current Primary Context',
        'recent' => '## Recently Discussed',
        'related' => '## Related Records',
        'background' => '## Background Context'
    };

    // Add decision logger reference
    private final AgentDecisionStepLogger decisionLogger;

    public SystemPromptBuilder() {
        this(new ContextResolverService(), new ContextManagerService(), null);
    }

    // New constructor that accepts a decision logger
    public SystemPromptBuilder(AgentDecisionStepLogger decisionLogger) {
        this(new ContextResolverService(), new ContextManagerService(), decisionLogger);
    }

    @TestVisible
    private SystemPromptBuilder(ContextResolverService resolver, ContextManagerService contextService, AgentDecisionStepLogger decisionLogger) {
        this.contextResolver = resolver;
        this.contextManager = contextService;
        this.decisionLogger = decisionLogger;
    }

    /**
     * Builds the complete, structured system prompt for an AI conversation turn.
     * Combines identity, instructions, examples, dynamic context, and temporal data into a cohesive prompt optimized for LLM consumption.
     * Uses the unified AgentExecution__c and ExecutionStep__c data models exclusively.
     *
     * @param executionId           The execution ID (AgentExecution__c) for context resolution.
     * @param agentConfig           Agent configuration containing prompt components.
     * @param llmConfig             LLM configuration for the session.
     * @param currentPageRecordId   Optional record ID for page context.
     * @param currentTurn           The current conversation turn number.
     * @param conversationalUserId  The user ID for temporal context.
     * @return                      Complete formatted system prompt string.
     */
    public String build(
        Id executionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        Id currentPageRecordId,
        Integer currentTurn,
        Id conversationalUserId
    ) {
        String logPrefix = '[SystemPromptBuilder Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Composing system prompt for Agent: ' + agentConfig.DeveloperName__c);

        List<String> promptParts = new List<String>();

        // Add temporal context with current date/time information
        String temporalContext = buildTemporalContext(conversationalUserId);
        promptParts.add('# System Context\n\n' + temporalContext);

        // Add static prompt sections from agent configuration
        if (String.isNotBlank(agentConfig.IdentityPrompt__c)) {
            promptParts.add('# Identity\n\n' + agentConfig.IdentityPrompt__c);
        }

        String finalInstructions = agentConfig.InstructionsPrompt__c;
        if (agentConfig.EnableReasoningMode__c) {
            String reasoningInstruction =
                '# CRITICAL BEHAVIOR RULE: REASONING MODE\n\n' +
                'When you decide to use a tool, you MUST first generate a user-facing `content` message. ' +
                'This message should concisely explain the action you are about to take (your "reasoning"). ' +
                'Immediately following the `content`, you must include the `tool_calls` payload for the action. ' +
                'Your response must contain BOTH `content` and `tool_calls` whenever you use a tool.';
            finalInstructions = String.isBlank(finalInstructions) ? reasoningInstruction.trim() : finalInstructions + reasoningInstruction;
            System.debug(LoggingLevel.INFO, logPrefix + 'Reasoning Mode enabled. Injecting reasoning instructions.');
        }

        if (String.isNotBlank(finalInstructions)) {
            promptParts.add('# Instructions\n\n' + finalInstructions);
        }

        if (String.isNotBlank(agentConfig.ExamplesPrompt__c)) {
            promptParts.add('# Examples\n\n' + agentConfig.ExamplesPrompt__c);
        }

        // Add dynamic context data using enhanced context management
        String formattedContextData = buildEnhancedContextData(
            executionId,
            agentConfig,
            llmConfig,
            currentPageRecordId,
            currentTurn,
            conversationalUserId
        );
        String contextSection = '';
        if (String.isNotBlank(formattedContextData)) {
            // Wrap formatted context data in XML block for clear delineation
            contextSection = '# Context\n\n<CONTEXT>\n' + formattedContextData + '\n</CONTEXT>';
            promptParts.add(contextSection);
        }

        // Add optional prompt footer
        if (String.isNotBlank(agentConfig.PromptFooter__c)) {
            promptParts.add(agentConfig.PromptFooter__c);
        }

        // Log system prompt construction if decision logger is available
        // This should be done after all prompt components are added
        // Exclude context data from logging
        if (this.decisionLogger != null) {
            // Create a version of prompt parts without sensitive context data for logging
            List<String> loggablePromptParts = new List<String>();
            for (String part : promptParts) {
                // Skip the context section to avoid logging sensitive data
                if (part != contextSection) {
                    loggablePromptParts.add(part);
                }
            }

            String systemPromptComponents = String.join(loggablePromptParts, '\n\n');

            this.decisionLogger.logSystemPromptConstruction(
                'System Prompt Constructed',
                'Built complete system prompt for LLM interaction',
                systemPromptComponents,
                null
            );
        }

        String composedPrompt = String.join(promptParts, '\n\n');
        System.debug(LoggingLevel.INFO, logPrefix + 'System prompt composition complete. Prompt length: ' + composedPrompt.length());
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Composed Prompt:\n' + composedPrompt);

        return composedPrompt;
    }

    /**
     * Enhanced context data building that combines traditional context resolution with sophisticated context management.
     * Integrates conversation summaries, SObject context data, and structured context ledger for optimal prompt composition.
     *
     * @param sessionId             The chat session ID for context resolution.
     * @param agentConfig           Agent configuration containing context settings.
     * @param llmConfig             LLM configuration for the session.
     * @param currentPageRecordId   Optional record ID for page context.
     * @param currentTurn           The current conversation turn number.
     * @param conversationalUserId  The user ID for context resolution.
     * @return                      Enhanced formatted context data string ready for prompt inclusion.
     */
    private String buildEnhancedContextData(
        Id executionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        Id currentPageRecordId,
        Integer currentTurn,
        Id conversationalUserId
    ) {
        String logPrefix = '[SystemPromptBuilder.EnhancedContext] ';
        List<String> contextBlocks = new List<String>();

        // Include conversation summary for summary buffer strategy
        String summary = getConversationSummary(executionId, agentConfig, logPrefix);
        if (String.isNotBlank(summary)) {
            contextBlocks.add('<CONVERSATION_SUMMARY>\n' + summary.escapeHtml4() + '\n</CONVERSATION_SUMMARY>');
        }

        // Build structured context prompt using ContextManagerService
        String structuredContextPrompt = buildStructuredContextPrompt(executionId, currentTurn, false);
        if (String.isNotBlank(structuredContextPrompt)) {
            contextBlocks.add(structuredContextPrompt);
        }

        // Fallback to traditional context resolution if structured context is empty
        if (String.isBlank(structuredContextPrompt)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No structured context available, falling back to traditional resolution');
            String traditionalContext = buildTraditionalContextData(
                executionId,
                agentConfig,
                llmConfig,
                currentPageRecordId,
                currentTurn,
                conversationalUserId,
                logPrefix
            );
            if (String.isNotBlank(traditionalContext)) {
                contextBlocks.add(traditionalContext);
            }
        }

        return String.join(contextBlocks, '\n\n');
    }

    /**
     * Builds structured context prompt using ContextManagerService with intelligent prioritization and truncation.
     * Organizes context into hierarchical sections (primary, recent, related, background) optimized for LLM consumption.
     *
     * @param sessionId   The chat session identifier.
     * @param currentTurn The current conversation turn.
     * @param includeMetadata Whether to include technical metadata for each context item.
     * @return            Structured context prompt string, or empty if no context available.
     */
    @TestVisible
    private String buildStructuredContextPrompt(Id executionId, Integer currentTurn, Boolean includeMetadata) {
        Map<String, List<ContextManagerService.ContextItem>> structuredContext = this.contextManager.getStructuredContext(executionId, currentTurn);

        if (structuredContext.isEmpty()) {
            return '';
        }

        List<String> promptSections = new List<String>();
        Integer totalChars = 0;

        // Build sections in priority order
        String[] sectionOrder = new List<String>{ 'primary', 'recent', 'related', 'background' };

        for (String sectionKey : sectionOrder) {
            List<ContextManagerService.ContextItem> items = structuredContext.get(sectionKey);
            if (items != null && !items.isEmpty()) {
                String section = buildContextPromptSection(sectionKey, items, currentTurn, includeMetadata);

                // Check if adding this section would exceed limit
                if (totalChars + section.length() > MAX_CONTEXT_CHARS) {
                    if (sectionKey == 'primary' || sectionKey == 'recent') {
                        // Critical sections - truncate items instead of skipping
                        section = truncateContextSection(section, MAX_CONTEXT_CHARS - totalChars);
                    } else {
                        // Less critical sections - skip if no room
                        break;
                    }
                }

                promptSections.add(section);
                totalChars += section.length();
            }
        }

        return String.join(promptSections, '\n\n');
    }

    private String buildTraditionalContextData(
        Id executionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        Id currentPageRecordId,
        Integer currentTurn,
        Id conversationalUserId,
        String logPrefix
    ) {
        // Resolve and format SObject context data
        ContextResolverService.ResolutionResult resolvedContext = this.contextResolver.resolve(
            executionId,
            agentConfig.Id,
            conversationalUserId,
            currentPageRecordId,
            currentTurn
        );

        // Log context gathering if decision logger is available
        if (this.decisionLogger != null && resolvedContext.recordsToLoad != null && !resolvedContext.recordsToLoad.isEmpty()) {
            // Get context provider information
            List<AgentContextConfig__c> contextConfigs = new List<AgentContextConfig__c>();
            try {
                contextConfigs = [
                    SELECT Id, Name, ContextLabel__c, ImplementationName__c, ApplicableSObjectTypes__c, ExecutionOrder__c
                    FROM AgentContextConfig__c
                    WHERE AIAgentDefinition__c = :agentConfig.Id AND IsActive__c = TRUE
                    ORDER BY ExecutionOrder__c ASC
                ];
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not retrieve context configs for logging: ' + e.getMessage());
            }

            // Get memory manager information
            String memoryManagerClassName = agentConfig.MemoryStrategy__c;

            // Count context providers
            Integer contextProviderCount = contextConfigs.size();

            // Get history limit if using buffer strategy
            String historyLimitInfo = '';
            if (agentConfig.MemoryStrategy__c == 'Buffer Window') {
                if (agentConfig.HistoryTurnLimit__c != null) {
                    historyLimitInfo = 'Loading up to ' + agentConfig.HistoryTurnLimit__c + ' turns';
                } else {
                    historyLimitInfo = 'Loading all conversation history';
                }
            } else if (agentConfig.MemoryStrategy__c == 'Summary Buffer') {
                historyLimitInfo = 'Loading conversation history with summarization';
            } else {
                historyLimitInfo = 'Loading conversation history';
            }

            // Create detailed context description
            List<String> contextDetails = new List<String>();
            contextDetails.add('Gathered and formatted context records for LLM interaction');

            // Add formatting strategy
            if (String.isNotBlank(agentConfig.ContextFormatStrategy__c)) {
                contextDetails.add('Formatting Strategy: ' + agentConfig.ContextFormatStrategy__c);
            }

            // Add memory manager class name
            if (String.isNotBlank(memoryManagerClassName)) {
                contextDetails.add('Memory Manager: ' + memoryManagerClassName);
            }

            // Add history limit info
            if (String.isNotBlank(historyLimitInfo)) {
                contextDetails.add(historyLimitInfo);
            }

            // Add context provider count
            if (contextProviderCount > 0) {
                contextDetails.add('Invoking ' + contextProviderCount + ' context providers');
            }

            // Add context provider details
            for (AgentContextConfig__c config : contextConfigs) {
                if (String.isNotBlank(config.ContextLabel__c) && String.isNotBlank(config.ImplementationName__c)) {
                    String sObjectInfo = String.isBlank(config.ApplicableSObjectTypes__c) ? '' : ' for ' + config.ApplicableSObjectTypes__c;
                    contextDetails.add('- ' + config.ContextLabel__c + ': ' + config.ImplementationName__c + sObjectInfo);
                }
            }

            // Create raw context data for debugging
            Map<String, Object> rawContextInfo = new Map<String, Object>{
                'recordCount' => resolvedContext.recordsToLoad.size(),
                'records' => resolvedContext.recordsToLoad,
                'contextProviders' => contextConfigs,
                'memoryManager' => memoryManagerClassName,
                'historyInfo' => historyLimitInfo
            };

            // Format SObject data using configured strategy for the formatted context
            String formattedContext = '';
            if (resolvedContext.recordsToLoad != null && !resolvedContext.recordsToLoad.isEmpty()) {
                formattedContext = ContextFormatterFactory.createFormatter(agentConfig.ContextFormatStrategy__c)
                    .formatContext(resolvedContext.recordsToLoad, logPrefix);
            }

            // Create context info that includes both raw and formatted data
            Map<String, Object> contextInfo = new Map<String, Object>{
                'recordCount' => resolvedContext.recordsToLoad.size(),
                'rawContext' => rawContextInfo,
                'formattedContext' => formattedContext,
                'formatStrategy' => agentConfig.ContextFormatStrategy__c
            };

            // Use the new method that supports separate raw and formatted context storage
            this.decisionLogger.logContextGatheringWithFormatting(
                'Context Gathered',
                String.join(contextDetails, '\n'),
                JSON.serialize(contextInfo),
                formattedContext,
                null
            );
        }

        if (resolvedContext.recordsToLoad != null && !resolvedContext.recordsToLoad.isEmpty()) {
            // Format SObject data using configured strategy
            String sObjectContextBlock = ContextFormatterFactory.createFormatter(agentConfig.ContextFormatStrategy__c)
                .formatContext(resolvedContext.recordsToLoad, logPrefix);

            return sObjectContextBlock;
        }

        return '';
    }

    /**
     * Retrieves the conversation summary for the execution if using the Summary Buffer memory strategy.
     *
     * @param executionId  The execution ID (ChatSession__c or AgentExecution__c).
     * @param agentConfig  Agent configuration.
     * @param logPrefix    Logging prefix for debug messages.
     * @return             The conversation summary string, or null if not found or not applicable.
     */
    private String getConversationSummary(Id executionId, AIAgentDefinition__c agentConfig, String logPrefix) {
        if ('Summary Buffer'.equalsIgnoreCase(agentConfig.MemoryStrategy__c)) {
            try {
                // Query AgentExecution__c for conversation summary
                List<AgentExecution__c> executions = [SELECT ConversationSummary__c FROM AgentExecution__c WHERE Id = :executionId LIMIT 1];
                if (!executions.isEmpty() && String.isNotBlank(executions[0].ConversationSummary__c)) {
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'Adding conversation summary to system prompt.');
                    return executions[0].ConversationSummary__c;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve conversation summary: ' + e.getMessage());
            }
        }
        return null;
    }

    /**
     * Builds a temporal context string with current date, day, time, and user timezone.
     *
     * @param conversationalUserId   The user ID for timezone context.
     * @return                      Temporal context string for prompt inclusion.
     */
    private String buildTemporalContext(Id conversationalUserId) {
        Datetime now = Datetime.now();
        User u = [SELECT TimeZoneSidKey FROM User WHERE Id = :conversationalUserId];

        List<String> contextLines = new List<String>{
            '- Current Date: ' + now.format('yyyy-MM-dd'),
            '- Current Day: ' + now.format('EEEE'),
            '- Current Time (User TZ): ' + now.format('HH:mm:ss', u.TimeZoneSidKey),
            '- User Timezone: ' + u.TimeZoneSidKey
        };

        return String.join(contextLines, '\n');
    }

    // --- ENHANCED CONTEXT MANAGEMENT METHODS ---

    /**
     * Constructs a single context prompt section with header and formatted context items.
     *
     * @param sectionKey      The section identifier (e.g., 'primary', 'recent').
     * @param items           List of context items to include in this section.
     * @param currentTurn     The current conversation turn for temporal labeling.
     * @param includeMetadata Whether to include technical metadata for each item.
     * @return                A string representing the formatted section.
     */
    @TestVisible
    private String buildContextPromptSection(
        String sectionKey,
        List<ContextManagerService.ContextItem> items,
        Integer currentTurn,
        Boolean includeMetadata
    ) {
        List<String> sectionLines = new List<String>();
        sectionLines.add(SECTION_HEADERS.get(sectionKey));

        for (ContextManagerService.ContextItem item : items) {
            String itemLine = formatContextItem(item, currentTurn, includeMetadata);
            if (String.isNotBlank(itemLine)) {
                sectionLines.add(itemLine);
            }
        }

        return String.join(sectionLines, '\n');
    }

    /**
     * Formats a single context item for inclusion in a prompt section.
     * Adds temporal labels, relationship information, and optional metadata for LLM consumption.
     *
     * @param item            The context item to format.
     * @param currentTurn     The current conversation turn.
     * @param includeMetadata Whether to include technical metadata.
     * @return                A formatted string for the context item, or blank if not displayable.
     */
    @TestVisible
    private String formatContextItem(ContextManagerService.ContextItem item, Integer currentTurn, Boolean includeMetadata) {
        List<String> parts = new List<String>();

        // Basic record info
        parts.add('**' + item.type + ': ' + item.id + '**');

        // Temporal context
        String temporal = item.getTemporalLabel(currentTurn);
        if (temporal != 'Current Turn') {
            parts.add('*(' + temporal + ')*');
        }

        // Context type explanation
        String contextExplanation = getContextTypeExplanation(item);
        if (String.isNotBlank(contextExplanation)) {
            parts.add('*' + contextExplanation + '*');
        }

        // Relationship info
        if (String.isNotBlank(item.sourceId)) {
            parts.add('*Related to: ' + item.sourceId + '*');
        }

        if (!item.childIds.isEmpty()) {
            parts.add('*Has related: ' + String.join(item.childIds, ', ') + '*');
        }

        // Metadata if requested
        if (includeMetadata && !item.metadata.isEmpty()) {
            List<String> metadataParts = new List<String>();
            for (String key : item.metadata.keySet()) {
                metadataParts.add(key + ': ' + item.metadata.get(key));
            }
            parts.add('*[' + String.join(metadataParts, ', ') + ']*');
        }

        return String.join(parts, ' ');
    }

    /**
     * Returns a user-friendly explanation for the context type of a given item.
     *
     * @param item The context item whose type is to be explained.
     * @return     A string explanation, or null if not applicable.
     */
    @TestVisible
    private String getContextTypeExplanation(ContextManagerService.ContextItem item) {
        switch on item.contextType {
            when IMPLICIT_PRIMARY {
                return 'User is currently viewing this record';
            }
            when ACTION_GENERATED {
                return 'Created by you in a previous turn';
            }
            when USER_MENTIONED {
                return 'Explicitly mentioned by user';
            }
            when SEARCH_RESULT {
                return 'Found via search';
            }
            when PINNED {
                return 'Pinned by user for reference';
            }
            when RELATED_RECORD {
                return 'Related to other context records';
            }
            when else {
                return null;
            }
        }
    }

    /**
     * Truncates a context section to fit within a character limit, preserving structure and adding an indicator if truncated.
     * Attempts to avoid cutting off mid-item by truncating at the last newline within the limit.
     *
     * @param section The section string to truncate.
     * @param maxChars The maximum allowed length for the section.
     * @return         The truncated section, with an ellipsis if truncation occurred.
     */
    @TestVisible
    private String truncateContextSection(String section, Integer maxChars) {
        if (section.length() <= maxChars) {
            return section;
        }

        // Leave room for ellipsis and try to avoid cutting off mid-item
        String truncated = section.substring(0, maxChars - 20);
        Integer lastNewline = truncated.lastIndexOf('\n');
        if (lastNewline > 0) {
            truncated = truncated.substring(0, lastNewline);
        }
        return truncated + '\n*[Context truncated...]*';
    }

    // --- PUBLIC UTILITY METHODS ---

    /**
     * Produces a concise, high-level summary of the current context ledger for diagnostics and quick reference.
     * The summary includes the primary context (if present) and a count of each context type.
     *
     * @param sessionId   The chat session identifier.
     * @param currentTurn The current conversation turn.
     * @return            A brief summary string with key context statistics, or a message if no context is available.
     */
    public String buildContextSummary(Id sessionId, Integer currentTurn) {
        List<ContextManagerService.ContextItem> items = this.contextManager.getContextLedger(sessionId, currentTurn);

        if (items.isEmpty()) {
            return 'No context available.';
        }

        Map<String, Integer> typeCounts = new Map<String, Integer>();
        ContextManagerService.ContextItem primaryItem = null;

        for (ContextManagerService.ContextItem item : items) {
            String typeKey = item.type;
            typeCounts.put(typeKey, typeCounts.containsKey(typeKey) ? typeCounts.get(typeKey) + 1 : 1);

            if (item.contextType == ContextManagerService.ContextType.IMPLICIT_PRIMARY) {
                primaryItem = item;
            }
        }

        List<String> summaryParts = new List<String>();

        if (primaryItem != null) {
            summaryParts.add('Primary: ' + primaryItem.type + ' (' + primaryItem.id + ')');
        }

        List<String> typeStrings = new List<String>();
        for (String type : typeCounts.keySet()) {
            typeStrings.add(typeCounts.get(type) + ' ' + type + (typeCounts.get(type) > 1 ? 's' : ''));
        }

        summaryParts.add('Context: ' + String.join(typeStrings, ', '));

        return String.join(summaryParts, ' | ');
    }

    /**
     * Returns a list of high-priority context items for UI highlighting.
     * This includes the current primary context, agent-created records, and pinned items, filtered by a high relevance threshold.
     *
     * @param sessionId   The chat session identifier.
     * @param currentTurn The current conversation turn.
     * @return            List of ContextItem objects deemed most relevant for user attention.
     */
    public List<ContextManagerService.ContextItem> getHighlightedContext(Id sessionId, Integer currentTurn) {
        return this.contextManager.getFilteredContext(
            sessionId,
            currentTurn,
            new Set<ContextManagerService.ContextType>{
                ContextManagerService.ContextType.IMPLICIT_PRIMARY,
                ContextManagerService.ContextType.ACTION_GENERATED,
                ContextManagerService.ContextType.PINNED
            },
            100.0 // High relevance threshold
        );
    }
}
