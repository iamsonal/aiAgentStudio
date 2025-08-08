/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description A centralized service responsible for composing the complete system prompt
 *              sent to the LLM. It assembles the prompt from multiple fields on the
 *              AIAgentDefinition__c and uses SObjectContextFormatter for data presentation.
 */
public inherited sharing class SystemPromptBuilder {
    private final ContextResolverService contextResolver;

    public SystemPromptBuilder() {
        this(new ContextResolverService());
    }

    @TestVisible
    private SystemPromptBuilder(ContextResolverService resolver) {
        this.contextResolver = resolver;
    }

    /**
     * @description The main method to build the complete, structured system prompt for a turn.
     * @return The final, formatted system prompt string.
     */
    public String build(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        Id currentPageRecordId,
        Integer currentTurn,
        Id conversationalUserId
    ) {
        String logPrefix = '[SystemPromptBuilder Sess:' + sessionId + '] ';

        List<String> promptParts = new List<String>();

        String temporalContext = buildTemporalContext(conversationalUserId);
        promptParts.add('# System Context\n\n' + temporalContext);

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
        }
        if (String.isNotBlank(finalInstructions)) {
            promptParts.add('# Instructions\n\n' + finalInstructions);
        }

        if (String.isNotBlank(agentConfig.ExamplesPrompt__c)) {
            promptParts.add('# Examples\n\n' + agentConfig.ExamplesPrompt__c);
        }

        String formattedContextData = buildFormattedContextData(
            sessionId,
            agentConfig,
            llmConfig,
            currentPageRecordId,
            currentTurn,
            conversationalUserId
        );
        if (String.isNotBlank(formattedContextData)) {
            promptParts.add('# Context\n\n<CONTEXT>\n' + formattedContextData + '\n</CONTEXT>');
        }

        if (String.isNotBlank(agentConfig.PromptFooter__c)) {
            promptParts.add(agentConfig.PromptFooter__c);
        }

        String composedPrompt = String.join(promptParts, '\n\n');

        return composedPrompt;
    }

    /**
     * @description Helper to orchestrate dynamic context gathering and formatting.
     */
    private String buildFormattedContextData(
        Id sessionId,
        AIAgentDefinition__c agentConfig,
        LLMConfiguration__c llmConfig,
        Id currentPageRecordId,
        Integer currentTurn,
        Id conversationalUserId
    ) {
        String logPrefix = '[SystemPromptBuilder.Context] ';
        List<String> contextBlocks = new List<String>();

        String summary = getConversationSummary(sessionId, agentConfig, logPrefix);
        if (String.isNotBlank(summary)) {
            contextBlocks.add('<CONVERSATION_SUMMARY>\n' + summary.escapeHtml4() + '\n</CONVERSATION_SUMMARY>');
        }

        ContextResolverService.ResolutionResult resolvedContext = this.contextResolver.resolve(
            sessionId,
            agentConfig.Id,
            conversationalUserId,
            currentPageRecordId,
            currentTurn
        );

        if (resolvedContext.recordsToLoad != null && !resolvedContext.recordsToLoad.isEmpty()) {
            String sObjectContextBlock = SObjectContextFormatter.formatContext(
                resolvedContext.recordsToLoad,
                agentConfig.ContextFormatStrategy__c,
                logPrefix
            );

            if (String.isNotBlank(sObjectContextBlock)) {
                contextBlocks.add(sObjectContextBlock);
            }
        }

        return String.join(contextBlocks, '\n\n');
    }

    private String getConversationSummary(Id sessionId, AIAgentDefinition__c agentConfig, String logPrefix) {
        if ('Summary Buffer'.equalsIgnoreCase(agentConfig.MemoryStrategy__c)) {
            try {
                List<ChatSession__c> sessions = [SELECT ConversationSummary__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1];
                if (!sessions.isEmpty() && String.isNotBlank(sessions[0].ConversationSummary__c)) {
                    return sessions[0].ConversationSummary__c;
                }
            } catch (Exception e) {
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
}
