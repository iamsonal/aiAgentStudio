/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Centralized service for composing system prompts sent to LLMs.
 */
public inherited sharing class SystemPromptBuilder {
    private final ContextResolverService contextResolver;
    private final IDecisionStepLogger.ILogger decisionLogger;
    private PIIMaskingService piiMaskingService;

    @TestVisible
    private static Exception mockFormatterException;

    public SystemPromptBuilder() {
        this(new ContextResolverService(), null, null);
    }

    public SystemPromptBuilder(IDecisionStepLogger.ILogger decisionLogger) {
        this(new ContextResolverService(), decisionLogger, null);
    }

    public SystemPromptBuilder(IDecisionStepLogger.ILogger decisionLogger, PIIMaskingService piiMaskingService) {
        this(new ContextResolverService(), decisionLogger, piiMaskingService);
    }

    @TestVisible
    private SystemPromptBuilder(ContextResolverService contextResolverSvc, IDecisionStepLogger.ILogger decisionLogger) {
        this(contextResolverSvc, decisionLogger, null);
    }

    @TestVisible
    private SystemPromptBuilder(ContextResolverService contextResolverSvc, IDecisionStepLogger.ILogger decisionLogger, PIIMaskingService piiMaskingService) {
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
        promptParts.add('# System Context\n\n' + buildTemporalContext(conversationalUserId));

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
            this.decisionLogger.log(IDecisionStepLogger.EventType.SYSTEM_PROMPT_BUILT, new List<Object>{ String.join(loggablePromptParts, '\n\n') });
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
        List<String> warningBlocks = new List<String>();

        String summary = getConversationSummary(executionId, agentConfig, logPrefix);
        if (String.isNotBlank(summary)) {
            contextBlocks.add('<CONVERSATION_SUMMARY>\n' + sanitizeForDelimiter(stripInjectionPatterns(summary)) + '\n</CONVERSATION_SUMMARY>');
        }

        String formatStrategy = String.isBlank(agentConfig.ContextFormatStrategy__c) ? 'JSON' : agentConfig.ContextFormatStrategy__c;

        try {
            ContextResolverService.ResolutionResult resolvedContext = this.contextResolver.resolve(
                executionId,
                agentConfig.Id,
                conversationalUserId,
                currentPageRecordId,
                currentTurn
            );

            if (resolvedContext != null) {
                for (String warningMessage : resolvedContext.warnings) {
                    warningBlocks.add('<CONTEXT_WARNING>\n' + sanitizeForDelimiter(stripInjectionPatterns(warningMessage)) + '\n</CONTEXT_WARNING>');
                }
            }

            if (resolvedContext != null && !resolvedContext.contextBlocks.isEmpty()) {
                try {
                    ContextFormattingService formatter = new ContextFormattingService();
                    List<SObject> loggableRecords = new List<SObject>();
                    List<String> formattedSections = new List<String>();

                    if (Test.isRunningTest() && mockFormatterException != null) {
                        throw mockFormatterException;
                    }

                    for (ContextResolverService.ResolvedContextBlock block : resolvedContext.contextBlocks) {
                        ContextFormattingService.ProjectionSettings projectionSettings = formatter.buildProjectionSettings(
                            block.config,
                            block.contextDefinition,
                            this.piiMaskingService
                        );
                        if (this.piiMaskingService != null) {
                            System.debug(LoggingLevel.DEBUG, logPrefix + 'PII schema masking enabled for context data formatting');
                        }

                        List<SObject> recordsForBlock = applyRecordLimit(block.records, projectionSettings.recordLimit);
                        loggableRecords.addAll(recordsForBlock);
                        if (recordsForBlock.isEmpty()) {
                            continue;
                        }

                        String formattedRecords = formatter.formatContext(recordsForBlock, logPrefix, formatStrategy, projectionSettings.formattingOptions);
                        if (String.isNotBlank(formattedRecords)) {
                            String sectionContent = String.isNotBlank(projectionSettings.sectionName)
                                ? '### ' + projectionSettings.sectionName + '\n' + formattedRecords
                                : formattedRecords;
                            formattedSections.add(sectionContent);
                        }
                    }

                    if (this.decisionLogger != null) {
                        this.decisionLogger.log(
                            IDecisionStepLogger.EventType.CONTEXT_GATHERED,
                            new List<Object>{ loggableRecords, String.join(formattedSections, '\n\n') }
                        );
                    }

                    if (!formattedSections.isEmpty()) {
                        contextBlocks.add(
                            '<RESOLVED_CONTEXT_DATA>\n' +
                                sanitizeForDelimiter(stripInjectionPatterns(String.join(formattedSections, '\n\n'))) +
                                '\n</RESOLVED_CONTEXT_DATA>'
                        );
                    }
                } catch (Exception formatterEx) {
                    System.debug(
                        LoggingLevel.ERROR,
                        logPrefix + 'Failed to execute formatter for strategy: ' + formatStrategy + '. Error: ' + formatterEx.getMessage()
                    );
                    warningBlocks.add(String.format(AIAgentConstants.PROMPT_CONTEXT_FORMAT_WARN_TEMPLATE, new List<Object>{ formatterEx.getMessage() }));
                }
            } else {
                System.debug(LoggingLevel.INFO, logPrefix + 'No records resolved from context providers.');
            }

            if (resolvedContext != null && String.isNotBlank(resolvedContext.longTermContextSummary)) {
                contextBlocks.add(
                    '<LONG_TERM_CONTEXT>\n' + sanitizeForDelimiter(stripInjectionPatterns(resolvedContext.longTermContextSummary)) + '\n</LONG_TERM_CONTEXT>'
                );
            }
        } catch (ContextResolverService.ResolutionException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Fatal context resolution failure: ' + e.getMessage());
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to resolve context via ContextResolverService: ' + e.getMessage());
            warningBlocks.add(AIAgentConstants.PROMPT_CONTEXT_LOAD_WARN);
        }

        List<String> allBlocks = new List<String>();
        allBlocks.addAll(contextBlocks);
        allBlocks.addAll(warningBlocks);
        return String.join(allBlocks, '\n\n');
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
        String userTimezone = 'UTC';
        try {
            List<User> users = [SELECT TimeZoneSidKey FROM User WHERE Id = :conversationalUserId LIMIT 1];
            if (!users.isEmpty() && String.isNotBlank(users[0].TimeZoneSidKey)) {
                userTimezone = users[0].TimeZoneSidKey;
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                '[SystemPromptBuilder] Could not load user timezone for ' + conversationalUserId + ', defaulting to UTC: ' + e.getMessage()
            );
        }

        return String.join(
            new List<String>{
                '- Current Date: ' + now.format('yyyy-MM-dd'),
                '- Current Day: ' + now.format('EEEE'),
                '- Current Time (User TZ): ' + now.format('HH:mm:ss', userTimezone),
                '- User Timezone: ' + userTimezone
            },
            '\n'
        );
    }

    /**
     * @description Neutralises XML closing-tag sequences in user-controlled content before it is
     * embedded inside an XML delimiter block.
     */
    @TestVisible
    private static String sanitizeForDelimiter(String content) {
        if (String.isBlank(content)) {
            return content;
        }
        return content.replace('</', '< /');
    }

    /**
     * @description Strips known prompt-injection payload markers from user-controlled context data.
     */
    @TestVisible
    private static String stripInjectionPatterns(String content) {
        if (String.isBlank(content)) {
            return content;
        }
        String sanitized = content;
        for (String pattern : AIAgentConstants.PROMPT_INJECTION_PATTERNS) {
            sanitized = sanitized.replace(pattern, '');
        }
        return sanitized;
    }

    @TestVisible
    private static List<SObject> applyRecordLimit(List<SObject> records, Integer recordLimit) {
        if (records == null || records.isEmpty()) {
            return new List<SObject>();
        }
        if (recordLimit == null || recordLimit <= 0 || records.size() <= recordLimit) {
            return new List<SObject>(records);
        }

        List<SObject> trimmed = new List<SObject>();
        for (Integer i = 0; i < recordLimit; i++) {
            trimmed.add(records[i]);
        }
        return trimmed;
    }
}
