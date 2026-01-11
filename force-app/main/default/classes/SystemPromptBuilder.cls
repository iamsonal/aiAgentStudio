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
 * The builder integrates sophisticated context management via ContextResolverService and ContextManagerService:
 * - ContextResolverService orchestrates gathering full SObject data from IAgentContextProvider implementations in a bulk-safe manner
 * - ContextManagerService (the "Ledger") tracks which records are relevant and provides intelligent prioritization
 * Together, these services provide complete context coverage with structured organization optimized for LLM consumption.
 *
 * Responsibilities:
 *   - Compose system prompts from static, dynamic, and temporal sources
 *   - Orchestrate context resolution via ContextResolverService to fetch actual record data from providers
 *   - Format resolved SObject data using ContextFormattingService
 *   - Integrate conversation summaries and structured context ledger overview via ContextManagerService
 *   - Provide intelligent context prioritization and truncation within token limits
 *   - Support hierarchical context organization (primary, recent, related, background)
 *   - Offer context summaries and highlighting for diagnostics and UI
 *   - Provide clear debug output for prompt composition and troubleshooting
 */
public inherited sharing class SystemPromptBuilder {
    private final ContextManagerService contextManager;
    private final ContextResolverService contextResolver;

    // --- CONSTANTS ---
    private static final Integer MAX_CONTEXT_CHARS = 8000; // Leave room for other prompt content
    private static final Map<String, String> SECTION_HEADERS = new Map<String, String>{
        'primary' => '## Current Primary Context',
        'recent' => '## Recently Discussed',
        'related' => '## Related Records',
        'background' => '## Background Context'
    };

    // Add decision logger reference
    private final IDecisionStepLogger.ILogger decisionLogger;

    // PII Masking support for context data
    private PIIMaskingService piiMaskingService;

    public SystemPromptBuilder() {
        this(new ContextManagerService(), new ContextResolverService(), null, null);
    }

    // Constructor that accepts a decision logger
    public SystemPromptBuilder(IDecisionStepLogger.ILogger decisionLogger) {
        this(new ContextManagerService(), new ContextResolverService(), decisionLogger, null);
    }

    // Constructor that accepts both decision logger and PII masking service
    public SystemPromptBuilder(IDecisionStepLogger.ILogger decisionLogger, PIIMaskingService piiMaskingService) {
        this(new ContextManagerService(), new ContextResolverService(), decisionLogger, piiMaskingService);
    }

    @TestVisible
    private SystemPromptBuilder(ContextManagerService contextService, ContextResolverService contextResolverSvc, IDecisionStepLogger.ILogger decisionLogger) {
        this(contextService, contextResolverSvc, decisionLogger, null);
    }

    @TestVisible
    private SystemPromptBuilder(
        ContextManagerService contextService,
        ContextResolverService contextResolverSvc,
        IDecisionStepLogger.ILogger decisionLogger,
        PIIMaskingService piiMaskingService
    ) {
        this.contextManager = contextService;
        this.contextResolver = contextResolverSvc;
        this.decisionLogger = decisionLogger;
        this.piiMaskingService = piiMaskingService;
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

        if (String.isNotBlank(agentConfig.InstructionsPrompt__c)) {
            promptParts.add('# Instructions\n\n' + agentConfig.InstructionsPrompt__c);
        }

        if (String.isNotBlank(agentConfig.ExamplesPrompt__c)) {
            promptParts.add('# Examples\n\n' + agentConfig.ExamplesPrompt__c);
        }

        // Add dynamic context data using enhanced context management
        String formattedContextData = buildEnhancedContextData(executionId, agentConfig, llmConfig, currentPageRecordId, currentTurn, conversationalUserId);
        String contextSection = '';
        if (String.isNotBlank(formattedContextData)) {
            // Wrap formatted context data in XML block for clear delineation
            contextSection = '# Context\n\n<CONTEXT>\n' + formattedContextData + '\n</CONTEXT>';
            promptParts.add(contextSection);
        }

        // Add optional prompt footer
        if (String.isNotBlank(agentConfig.PromptFooter__c)) {
            promptParts.add('# Additional Instructions\n\n' + agentConfig.PromptFooter__c);
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
     * Builds enhanced context data using ContextResolverService and ContextManagerService for sophisticated context management.
     * Integrates conversation summaries, full SObject data from context providers, and structured context ledger for optimal prompt composition.
     *
     * @param executionId           The execution ID for context resolution.
     * @param agentConfig           Agent configuration containing context settings.
     * @param llmConfig             LLM configuration for the session.
     * @param currentPageRecordId   Optional record ID for page context.
     * @param currentTurn           The current conversation turn number.
     * @param conversationalUserId  The user ID for context resolution.
     * @return                      Formatted context data string ready for prompt inclusion.
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

        // Check if context format strategy is configured before attempting context resolution
        // Without a formatter, we cannot use the resolved SObject records, so skip the expensive resolution
        String formatStrategy = String.isNotBlank(agentConfig.ContextFormatStrategy__c) ? agentConfig.ContextFormatStrategy__c : null;

        if (String.isBlank(formatStrategy)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No ContextFormatStrategy__c configured. Skipping context resolution and formatting.');
        } else {
            // RESTORED INTEGRATION: Use ContextResolverService to gather actual SObject data from context providers
            // This orchestrates the retrieval of full record data based on the context ledger (IDs tracked by ContextManagerService)
            try {
                ContextResolverService.ResolutionResult resolvedContext = this.contextResolver.resolve(
                    executionId,
                    agentConfig.Id,
                    conversationalUserId,
                    currentPageRecordId,
                    currentTurn
                );

                // Format the resolved SObject records using the configured formatting strategy
                if (resolvedContext != null && !resolvedContext.recordsToLoad.isEmpty()) {
                    try {
                        ContextFormattingService formatter = new ContextFormattingService();

                        // Configure formatting options with PII masking if available
                        ContextFormattingService.FormattingOptions formatOptions = new ContextFormattingService.FormattingOptions();
                        if (this.piiMaskingService != null && this.piiMaskingService.getSchemaMasker() != null) {
                            formatOptions.withPIIMasking(this.piiMaskingService.getSchemaMasker(), this.piiMaskingService.getSession());
                            System.debug(LoggingLevel.DEBUG, logPrefix + 'PII schema masking enabled for context data formatting');
                        }

                        String formattedRecords = formatter.formatContext(resolvedContext.recordsToLoad, logPrefix, formatStrategy, formatOptions);

                        // Log context gathering with formatting if decision logger is available
                        if (this.decisionLogger != null) {
                            this.decisionLogger.logContextGatheringWithFormatting(
                                'Context Data Gathered',
                                'Context data resolved and formatted for LLM',
                                JSON.serialize(resolvedContext.recordsToLoad),
                                formattedRecords,
                                null
                            );
                        }

                        if (String.isNotBlank(formattedRecords)) {
                            contextBlocks.add('<RESOLVED_CONTEXT_DATA>\n' + formattedRecords + '\n</RESOLVED_CONTEXT_DATA>');
                            System.debug(
                                LoggingLevel.INFO,
                                logPrefix +
                                    'Added ' +
                                    resolvedContext.recordsToLoad.size() +
                                    ' resolved records to context using ' +
                                    formatStrategy +
                                    ' format.'
                            );
                        }
                    } catch (Exception formatterEx) {
                        // If formatter execution fails, log the error and add warning to context
                        System.debug(
                            LoggingLevel.ERROR,
                            logPrefix + 'Failed to execute formatter for strategy: ' + formatStrategy + '. Error: ' + formatterEx.getMessage()
                        );
                        // Add warning to context so LLM is aware of partial context
                        contextBlocks.add(
                            '<CONTEXT_WARNING>Context formatting failed for ' +
                                resolvedContext.recordsToLoad.size() +
                                ' records. Responses may lack full record details. Error: ' +
                                formatterEx.getMessage() +
                                '</CONTEXT_WARNING>'
                        );
                    }
                } else {
                    System.debug(LoggingLevel.INFO, logPrefix + 'No records resolved from context providers.');
                }

                // Include long-term context summary if available (currently not populated, but leaving for future use)
                if (String.isNotBlank(resolvedContext.longTermContextSummary)) {
                    contextBlocks.add('<LONG_TERM_CONTEXT>\n' + resolvedContext.longTermContextSummary + '\n</LONG_TERM_CONTEXT>');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to resolve context via ContextResolverService: ' + e.getMessage());
                // Add warning to context so LLM is aware that context resolution failed
                // This prevents silent failures where LLM responds without knowing context is missing
                contextBlocks.add(
                    '<CONTEXT_WARNING>Context resolution failed. Responses may lack full context about related records. ' +
                        'Error: ' +
                        e.getMessage() +
                        '</CONTEXT_WARNING>'
                );
            }
        }

        // Build structured context ledger overview using ContextManagerService
        // This provides a high-level map of what's in context, complementing the detailed record data above
        String structuredContextPrompt = buildStructuredContextPrompt(executionId, currentTurn, false);
        if (String.isNotBlank(structuredContextPrompt)) {
            contextBlocks.add('<CONTEXT_LEDGER_OVERVIEW>\n' + structuredContextPrompt + '\n</CONTEXT_LEDGER_OVERVIEW>');
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

    /**
     * Retrieves the conversation summary for the execution if using the Summary Buffer memory strategy.
     *
     * @param executionId  The execution ID.
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
    private String buildContextPromptSection(String sectionKey, List<ContextManagerService.ContextItem> items, Integer currentTurn, Boolean includeMetadata) {
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
}
