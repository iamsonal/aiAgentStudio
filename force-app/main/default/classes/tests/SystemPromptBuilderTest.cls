/**
 * @description Tests for SystemPromptBuilder prompt composition, context item formatting,
 *              context type explanations, and formatter exception handling.
 */
@IsTest
private class SystemPromptBuilderTest {
    // ========== Helper ==========

    private static ContextManagerService.ContextItem buildItem(Id recordId, ContextManagerService.ContextType ctxType, Integer turnAdded, Id sourceId) {
        return new ContextManagerService.ContextItem(recordId, ctxType, turnAdded, sourceId);
    }

    // ========== build() - Full Prompt Composition ==========

    @IsTest
    static void testBuild_ComposesSectionsAndSummary() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.IdentityPrompt__c = 'You are a helper.';
        agent.InstructionsPrompt__c = 'Follow instructions.';
        agent.ExamplesPrompt__c = 'Example: do X.';
        agent.PromptFooter__c = 'Footer note.';
        agent.MemoryStrategy__c = 'Summary Buffer';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ConversationSummary__c = 'Prior summary'
        );
        insert execution;

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(execution.Id, agent, llm, null, 1, UserInfo.getUserId());

        System.assert(prompt.contains('# System Context'), 'Should include system context');
        System.assert(prompt.contains('# Identity'), 'Should include identity section');
        System.assert(prompt.contains('# Instructions'), 'Should include instructions section');
        System.assert(prompt.contains('# Examples'), 'Should include examples section');
        System.assert(prompt.contains('# Additional Instructions'), 'Should include footer section');
        System.assert(prompt.contains('<CONVERSATION_SUMMARY>'), 'Should include conversation summary block');
        System.assert(prompt.contains('Prior summary'), 'Should include conversation summary');
        System.assert(prompt.contains('Current Date:'), 'Should include temporal context');
        System.assert(!prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Should skip resolved context when strategy is blank');
    }

    @IsTest
    static void testBuild_IncludesResolvedContextData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.ContextFormatStrategy__c = 'JSON';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        Account account = new Account(Name = 'Resolved Account');
        insert account;

        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(account.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        insert item.toRecord(execution.Id);

        AgentContextConfig__c recordConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            ContextLabel__c = 'Record Context',
            ImplementationName__c = 'ContextResolverTestProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 1
        );
        insert recordConfig;

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(execution.Id, agent, llm, account.Id, 1, UserInfo.getUserId());

        System.assert(prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Resolved context should be included');
        System.assert(prompt.contains('Resolved Account'), 'Resolved record data should be formatted into prompt');
    }

    // ========== CONTEXT_WARNING - Formatter Exception ==========

    @IsTest
    static void testBuild_FormatterException_AddsContextWarning() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.ContextFormatStrategy__c = 'JSON';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        Account account = new Account(Name = 'Context Account');
        insert account;

        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(account.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        insert item.toRecord(execution.Id);

        AgentContextConfig__c recordConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            ContextLabel__c = 'Record Context',
            ImplementationName__c = 'ContextResolverTestProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 1
        );
        insert recordConfig;

        // Inject mock formatter exception
        SystemPromptBuilder.mockFormatterException = new AIAgentException('Schema masker exploded');

        try {
            SystemPromptBuilder builder = new SystemPromptBuilder();
            String prompt = builder.build(execution.Id, agent, llm, account.Id, 1, UserInfo.getUserId());

            System.assert(prompt.contains('<CONTEXT_WARNING>'), 'Should include CONTEXT_WARNING block');
            System.assert(prompt.contains('Context formatting failed'), 'Should describe the formatting failure');
            System.assert(prompt.contains('Schema masker exploded'), 'Should include the exception message');
            System.assert(prompt.contains('Responses may lack full record details'), 'Should warn about incomplete data');
            System.assert(!prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Should not have resolved context when formatter fails');
        } finally {
            SystemPromptBuilder.mockFormatterException = null;
        }
    }

    // ========== formatContextItem ==========

    @IsTest
    static void testFormatContextItem_CurrentTurn_NoTemporalLabel() {
        Account acc = new Account(Name = 'Test');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, false);

        System.assert(result.contains('**Account: ' + acc.Id + '**'), 'Should include type and id');
        System.assert(!result.contains('Current Turn'), 'Current Turn temporal label should be suppressed');
        System.assert(result.contains('User is currently viewing this record'), 'Should include IMPLICIT_PRIMARY explanation');
    }

    @IsTest
    static void testFormatContextItem_PreviousTurn_IncludesTemporalLabel() {
        Account acc = new Account(Name = 'Old Account');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.ACTION_GENERATED, 1, null);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 3, false);

        System.assert(result.contains('*(2 turns ago)*'), 'Should include temporal label for non-current turn');
        System.assert(result.contains('Created by you in a previous turn'), 'Should include ACTION_GENERATED explanation');
    }

    @IsTest
    static void testFormatContextItem_WithSourceId_IncludesRelatedTo() {
        Account acc = new Account(Name = 'Child Account');
        insert acc;
        Account parent = new Account(Name = 'Parent Account');
        insert parent;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.RELATED_RECORD, 1, parent.Id);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, false);

        System.assert(result.contains('*Related to: ' + parent.Id + '*'), 'Should include sourceId');
        System.assert(result.contains('Related to other context records'), 'Should include RELATED_RECORD explanation');
    }

    @IsTest
    static void testFormatContextItem_WithChildIds_IncludesHasRelated() {
        Account acc = new Account(Name = 'Parent');
        insert acc;
        Contact con1 = new Contact(LastName = 'Child1', AccountId = acc.Id);
        Contact con2 = new Contact(LastName = 'Child2', AccountId = acc.Id);
        insert new List<Contact>{ con1, con2 };

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        item.childIds = new List<String>{ String.valueOf(con1.Id), String.valueOf(con2.Id) };

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, false);

        System.assert(result.contains('*Has related:'), 'Should include child IDs section');
        System.assert(result.contains(String.valueOf(con1.Id)), 'Should contain first child ID');
        System.assert(result.contains(String.valueOf(con2.Id)), 'Should contain second child ID');
    }

    @IsTest
    static void testFormatContextItem_WithMetadata_IncludeMetadataTrue() {
        Account acc = new Account(Name = 'Meta Account');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.SEARCH_RESULT, 1, null);
        item.metadata = new Map<String, Object>{ 'score' => 95, 'source' => 'SOSL' };

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, true);

        System.assert(result.contains('Found via search'), 'Should include SEARCH_RESULT explanation');
        System.assert(result.contains('score: 95'), 'Should include metadata when includeMetadata=true');
        System.assert(result.contains('source: SOSL'), 'Should include metadata key-value pairs');
    }

    @IsTest
    static void testFormatContextItem_WithMetadata_IncludeMetadataFalse_NoMetadataShown() {
        Account acc = new Account(Name = 'No Meta');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.SEARCH_RESULT, 1, null);
        item.metadata = new Map<String, Object>{ 'score' => 80 };

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, false);

        System.assert(!result.contains('score: 80'), 'Should not include metadata when includeMetadata=false');
    }

    @IsTest
    static void testFormatContextItem_UserMentioned() {
        Account acc = new Account(Name = 'Mentioned');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.USER_MENTIONED, 2, null);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 5, false);

        System.assert(result.contains('Explicitly mentioned by user'), 'Should include USER_MENTIONED explanation');
        System.assert(result.contains('*(3 turns ago)*'), 'Should include temporal label');
    }

    @IsTest
    static void testFormatContextItem_Pinned() {
        Account acc = new Account(Name = 'Pinned Rec');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.PINNED, 1, null);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.formatContextItem(item, 1, false);

        System.assert(result.contains('Pinned by user for reference'), 'Should include PINNED explanation');
    }

    // ========== getContextTypeExplanation ==========

    @IsTest
    static void testGetContextTypeExplanation_AllTypes() {
        Account acc = new Account(Name = 'Type Test');
        insert acc;

        SystemPromptBuilder builder = new SystemPromptBuilder();

        // Each named type should return a non-null explanation
        ContextManagerService.ContextItem implicitPrimary = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        System.assertEquals('User is currently viewing this record', builder.getContextTypeExplanation(implicitPrimary));

        ContextManagerService.ContextItem actionGenerated = buildItem(acc.Id, ContextManagerService.ContextType.ACTION_GENERATED, 1, null);
        System.assertEquals('Created by you in a previous turn', builder.getContextTypeExplanation(actionGenerated));

        ContextManagerService.ContextItem userMentioned = buildItem(acc.Id, ContextManagerService.ContextType.USER_MENTIONED, 1, null);
        System.assertEquals('Explicitly mentioned by user', builder.getContextTypeExplanation(userMentioned));

        ContextManagerService.ContextItem searchResult = buildItem(acc.Id, ContextManagerService.ContextType.SEARCH_RESULT, 1, null);
        System.assertEquals('Found via search', builder.getContextTypeExplanation(searchResult));

        ContextManagerService.ContextItem pinned = buildItem(acc.Id, ContextManagerService.ContextType.PINNED, 1, null);
        System.assertEquals('Pinned by user for reference', builder.getContextTypeExplanation(pinned));

        ContextManagerService.ContextItem relatedRecord = buildItem(acc.Id, ContextManagerService.ContextType.RELATED_RECORD, 1, null);
        System.assertEquals('Related to other context records', builder.getContextTypeExplanation(relatedRecord));
    }

    @IsTest
    static void testGetContextTypeExplanation_ElseBranch_ReturnsNull() {
        Account acc = new Account(Name = 'Else Test');
        insert acc;

        SystemPromptBuilder builder = new SystemPromptBuilder();

        // Types not in the switch should return null
        ContextManagerService.ContextItem implicitSecondary = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_SECONDARY, 1, null);
        System.assertEquals(null, builder.getContextTypeExplanation(implicitSecondary), 'IMPLICIT_SECONDARY should return null');

        ContextManagerService.ContextItem background = buildItem(acc.Id, ContextManagerService.ContextType.BACKGROUND_CONTEXT, 1, null);
        System.assertEquals(null, builder.getContextTypeExplanation(background), 'BACKGROUND_CONTEXT should return null');
    }

    // ========== buildContextPromptSection ==========

    @IsTest
    static void testBuildContextPromptSection_FormatsHeaderAndItems() {
        Account acc1 = new Account(Name = 'Acc1');
        Account acc2 = new Account(Name = 'Acc2');
        insert new List<Account>{ acc1, acc2 };

        ContextManagerService.ContextItem item1 = buildItem(acc1.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        ContextManagerService.ContextItem item2 = buildItem(acc2.Id, ContextManagerService.ContextType.USER_MENTIONED, 1, null);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String section = builder.buildContextPromptSection('primary', new List<ContextManagerService.ContextItem>{ item1, item2 }, 1, false);

        System.assert(section.contains('## Current Primary Context'), 'Should include section header');
        System.assert(section.contains(String.valueOf(acc1.Id)), 'Should include first item');
        System.assert(section.contains(String.valueOf(acc2.Id)), 'Should include second item');
    }

    @IsTest
    static void testBuildContextPromptSection_AllSectionKeys() {
        Account acc = new Account(Name = 'Section Test');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        List<ContextManagerService.ContextItem> items = new List<ContextManagerService.ContextItem>{ item };

        SystemPromptBuilder builder = new SystemPromptBuilder();

        String primary = builder.buildContextPromptSection('primary', items, 1, false);
        System.assert(primary.contains('## Current Primary Context'));

        String recent = builder.buildContextPromptSection('recent', items, 1, false);
        System.assert(recent.contains('## Recently Discussed'));

        String related = builder.buildContextPromptSection('related', items, 1, false);
        System.assert(related.contains('## Related Records'));

        String background = builder.buildContextPromptSection('background', items, 1, false);
        System.assert(background.contains('## Background Context'));
    }

    // ========== buildStructuredContextPrompt ==========

    @IsTest
    static void testBuildStructuredContextPrompt_EmptyLedger_ReturnsEmpty() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.buildStructuredContextPrompt(execution.Id, 1, false);

        System.assertEquals('', result, 'Empty ledger should return empty string');
    }

    @IsTest
    static void testBuildStructuredContextPrompt_WithLedgerItems_ReturnsSections() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        Account acc = new Account(Name = 'Ledger Account');
        insert acc;

        ContextManagerService.ContextItem item = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        insert item.toRecord(execution.Id);

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String result = builder.buildStructuredContextPrompt(execution.Id, 1, true);

        System.assert(String.isNotBlank(result), 'Should return non-empty structured context');
        System.assert(result.contains(String.valueOf(acc.Id)), 'Should include the ledger item record ID');
    }

    // ========== Temporal labels through formatContextItem ==========

    @IsTest
    static void testFormatContextItem_TemporalLabels_VariousTurnGaps() {
        Account acc = new Account(Name = 'Temporal');
        insert acc;

        SystemPromptBuilder builder = new SystemPromptBuilder();

        // Last Turn (1 turn ago)
        ContextManagerService.ContextItem item1 = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        String result1 = builder.formatContextItem(item1, 2, false);
        System.assert(result1.contains('*(Last Turn)*'), 'turnsSince=1 should show Last Turn');

        // 3 turns ago
        ContextManagerService.ContextItem item3 = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        String result3 = builder.formatContextItem(item3, 4, false);
        System.assert(result3.contains('*(3 turns ago)*'), 'turnsSince=3 should show X turns ago');

        // Recently (5 turns ago)
        ContextManagerService.ContextItem item5 = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        String result5 = builder.formatContextItem(item5, 6, false);
        System.assert(result5.contains('*(Recently)*'), 'turnsSince=5 should show Recently');

        // Earlier in conversation (> 10 turns ago)
        ContextManagerService.ContextItem item15 = buildItem(acc.Id, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null);
        String result15 = builder.formatContextItem(item15, 12, false);
        System.assert(result15.contains('*(Earlier in conversation)*'), 'turnsSince > 10 should show Earlier in conversation');
    }

    // ========== Build with no optional sections ==========

    @IsTest
    static void testBuild_MinimalAgent_OnlySystemContext() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(execution.Id, agent, llm, null, 1, UserInfo.getUserId());

        System.assert(prompt.contains('# System Context'), 'Should always include system context');
        System.assert(!prompt.contains('# Identity'), 'Should not include identity when blank');
        System.assert(!prompt.contains('# Instructions'), 'Should not include instructions when blank');
        System.assert(!prompt.contains('# Examples'), 'Should not include examples when blank');
        System.assert(!prompt.contains('# Additional Instructions'), 'Should not include footer when blank');
    }
}
