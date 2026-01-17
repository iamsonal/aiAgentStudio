/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Centralized service for composing system prompts sent to LLMs. Assembles prompts from agent configuration, context data, and temporal information.
 */
public inherited sharing class SystemPromptBuilder {
    private final ContextManagerService contextManager;
    private final ContextResolverService contextResolver;
    private static final Integer MAX_CONTEXT_CHARS = 8000;
    private static final Map<String, String> SECTION_HEADERS = new Map<String, String>{
        'primary' => '## Current Primary Context',
        'recent' => '## Recently Discussed',
        'related' => '## Related Records',
        'background' => '## Background Context'
    };
    private final IDecisionStepLogger.ILogger decisionLogger;
    private PIIMaskingService piiMaskingService;

    public SystemPromptBuilder() {
        this(new ContextManagerService(), new ContextResolverService(), null, null);
    }

    public SystemPromptBuilder(IDecisionStepLogger.ILogger decisionLogger) {
        this(new ContextManagerService(), new ContextResolverService(), decisionLogger, null);
    }

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

        String temporalContext = buildTemporalContext(conversationalUserId);
        promptParts.add('# System Context\n\n' + temporalContext);

        if (String.isNotBlank(agentConfig.IdentityPrompt__c)) {
            promptParts.add('# Identity\n\n' + agentConfig.IdentityPrompt__c);
        }

        if (String.isNotBlank(agentConfig.InstructionsPrompt__c)) {
            promptParts.add('# Instructions\n\n' + agentConfig.InstructionsPrompt__c);
        }

        if (String.isNotBlank(agentConfig.ExamplesPrompt__c)) {
            promptParts.add('# Examples\n\n' + agentConfig.ExamplesPrompt__c);
        }

        String formattedContextData = buildEnhancedContextData(executionId, agentConfig, llmConfig, currentPageRecordId, currentTurn, conversationalUserId);
        String contextSection = '';
        if (String.isNotBlank(formattedContextData)) {
            contextSection = '# Context\n\n<CONTEXT>\n' + formattedContextData + '\n</CONTEXT>';
            promptParts.add(contextSection);
        }

        if (String.isNotBlank(agentConfig.PromptFooter__c)) {
            promptParts.add('# Additional Instructions\n\n' + agentConfig.PromptFooter__c);
        }

        if (this.decisionLogger != null) {
            List<String> loggablePromptParts = new List<String>();
            for (String part : promptParts) {
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

        String summary = getConversationSummary(executionId, agentConfig, logPrefix);
        if (String.isNotBlank(summary)) {
            contextBlocks.add('<CONVERSATION_SUMMARY>\n' + summary.escapeHtml4() + '\n</CONVERSATION_SUMMARY>');
        }

        String formatStrategy = String.isNotBlank(agentConfig.ContextFormatStrategy__c) ? agentConfig.ContextFormatStrategy__c : null;

        if (String.isBlank(formatStrategy)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No ContextFormatStrategy__c configured. Skipping context resolution and formatting.');
        } else {
            try {
                ContextResolverService.ResolutionResult resolvedContext = this.contextResolver.resolve(
                    executionId,
                    agentConfig.Id,
                    conversationalUserId,
                    currentPageRecordId,
                    currentTurn
                );

                if (resolvedContext != null && !resolvedContext.recordsToLoad.isEmpty()) {
                    try {
                        ContextFormattingService formatter = new ContextFormattingService();

                        ContextFormattingService.FormattingOptions formatOptions = new ContextFormattingService.FormattingOptions();
                        if (this.piiMaskingService != null && this.piiMaskingService.getSchemaMasker() != null) {
                            formatOptions.withPIIMasking(this.piiMaskingService.getSchemaMasker(), this.piiMaskingService.getSession());
                            System.debug(LoggingLevel.DEBUG, logPrefix + 'PII schema masking enabled for context data formatting');
                        }

                        String formattedRecords = formatter.formatContext(resolvedContext.recordsToLoad, logPrefix, formatStrategy, formatOptions);

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
                        System.debug(
                            LoggingLevel.ERROR,
                            logPrefix + 'Failed to execute formatter for strategy: ' + formatStrategy + '. Error: ' + formatterEx.getMessage()
                        );
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

                if (String.isNotBlank(resolvedContext.longTermContextSummary)) {
                    contextBlocks.add('<LONG_TERM_CONTEXT>\n' + resolvedContext.longTermContextSummary + '\n</LONG_TERM_CONTEXT>');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to resolve context via ContextResolverService: ' + e.getMessage());
                contextBlocks.add(
                    '<CONTEXT_WARNING>Context resolution failed. Responses may lack full context about related records. ' +
                        'Error: ' +
                        e.getMessage() +
                        '</CONTEXT_WARNING>'
                );
            }
        }

        String structuredContextPrompt = buildStructuredContextPrompt(executionId, currentTurn, false);
        if (String.isNotBlank(structuredContextPrompt)) {
            contextBlocks.add('<CONTEXT_LEDGER_OVERVIEW>\n' + structuredContextPrompt + '\n</CONTEXT_LEDGER_OVERVIEW>');
        }

        return String.join(contextBlocks, '\n\n');
    }

    @TestVisible
    private String buildStructuredContextPrompt(Id executionId, Integer currentTurn, Boolean includeMetadata) {
        Map<String, List<ContextManagerService.ContextItem>> structuredContext = this.contextManager.getStructuredContext(executionId, currentTurn);

        if (structuredContext.isEmpty()) {
            return '';
        }

        List<String> promptSections = new List<String>();
        Integer totalChars = 0;

        String[] sectionOrder = new List<String>{ 'primary', 'recent', 'related', 'background' };

        for (String sectionKey : sectionOrder) {
            List<ContextManagerService.ContextItem> items = structuredContext.get(sectionKey);
            if (items != null && !items.isEmpty()) {
                String section = buildContextPromptSection(sectionKey, items, currentTurn, includeMetadata);

                if (totalChars + section.length() > MAX_CONTEXT_CHARS) {
                    if (sectionKey == 'primary' || sectionKey == 'recent') {
                        section = truncateContextSection(section, MAX_CONTEXT_CHARS - totalChars);
                    } else {
                        break;
                    }
                }

                promptSections.add(section);
                totalChars += section.length();
            }
        }

        return String.join(promptSections, '\n\n');
    }

    private String getConversationSummary(Id executionId, AIAgentDefinition__c agentConfig, String logPrefix) {
        if ('Summary Buffer'.equalsIgnoreCase(agentConfig.MemoryStrategy__c)) {
            try {
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

    @TestVisible
    private String formatContextItem(ContextManagerService.ContextItem item, Integer currentTurn, Boolean includeMetadata) {
        List<String> parts = new List<String>();

        parts.add('**' + item.type + ': ' + item.id + '**');

        String temporal = item.getTemporalLabel(currentTurn);
        if (temporal != 'Current Turn') {
            parts.add('*(' + temporal + ')*');
        }

        String contextExplanation = getContextTypeExplanation(item);
        if (String.isNotBlank(contextExplanation)) {
            parts.add('*' + contextExplanation + '*');
        }

        if (String.isNotBlank(item.sourceId)) {
            parts.add('*Related to: ' + item.sourceId + '*');
        }

        if (!item.childIds.isEmpty()) {
            parts.add('*Has related: ' + String.join(item.childIds, ', ') + '*');
        }

        if (includeMetadata && !item.metadata.isEmpty()) {
            List<String> metadataParts = new List<String>();
            for (String key : item.metadata.keySet()) {
                metadataParts.add(key + ': ' + item.metadata.get(key));
            }
            parts.add('*[' + String.join(metadataParts, ', ') + ']*');
        }

        return String.join(parts, ' ');
    }

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

    @TestVisible
    private String truncateContextSection(String section, Integer maxChars) {
        if (section.length() <= maxChars) {
            return section;
        }

        String truncated = section.substring(0, maxChars - 20);
        Integer lastNewline = truncated.lastIndexOf('\n');
        if (lastNewline > 0) {
            truncated = truncated.substring(0, lastNewline);
        }
        return truncated + '\n*[Context truncated...]*';
    }
}
