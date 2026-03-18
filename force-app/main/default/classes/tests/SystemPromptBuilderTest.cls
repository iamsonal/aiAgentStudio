/**
 * @description Tests for SystemPromptBuilder prompt composition and context formatting.
 */
@IsTest
private class SystemPromptBuilderTest {
    private class TestProvider implements IAgentContextProvider {
        public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
            Set<Id> accountIds = new Set<Id>();
            if (anchorIds != null) {
                for (Id anchorId : anchorIds) {
                    if (anchorId != null && anchorId.getSObjectType() == Account.SObjectType) {
                        accountIds.add(anchorId);
                    }
                }
            }

            List<SObject> records = new List<SObject>();
            if (!accountIds.isEmpty()) {
                records.addAll([SELECT Id, Name FROM Account WHERE Id IN :accountIds]);
            }
            return new Map<String, List<SObject>>{ 'records' => records };
        }
    }

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
        System.assert(!prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Should omit resolved context when no bindings exist');
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

        insert new ContextReference__c(
            AgentExecution__c = execution.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ReferenceRole__c = ContextManagerService.ReferenceRole.Primary.name(),
            ReferenceSource__c = 'Page Context',
            Status__c = ContextManagerService.ReferenceStatus.Active.name(),
            LastUsedAt__c = Datetime.now(),
            UseCount__c = 1,
            Explanation__c = 'Primary page record.'
        );

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Record Context',
            ContextDefinition__c = 'Test Provider',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            OutputSectionName__c = 'Resolved Account Summary',
            IsActive__c = true
        );

        ContextResolverService.setTestProviderOverride('Test Provider', new TestProvider());
        try {
            SystemPromptBuilder builder = new SystemPromptBuilder();
            String prompt = builder.build(execution.Id, agent, llm, account.Id, 1, UserInfo.getUserId());

            System.assert(prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Resolved context should be included');
            System.assert(prompt.contains('Resolved Account Summary'), 'Configured output section should be included');
            System.assert(prompt.contains('Resolved Account'), 'Resolved record data should be formatted into prompt');
            System.assert(!prompt.contains((String) account.Id), 'Projection definition should exclude Id fields');
        } finally {
            ContextResolverService.clearTestProviderOverrides();
        }
    }

    @IsTest
    static void testBuild_ProviderWarning_AddsContextWarning() {
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

        insert new ContextReference__c(
            AgentExecution__c = execution.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ReferenceRole__c = ContextManagerService.ReferenceRole.Primary.name(),
            ReferenceSource__c = 'Page Context',
            Status__c = ContextManagerService.ReferenceStatus.Active.name(),
            LastUsedAt__c = Datetime.now(),
            UseCount__c = 1,
            Explanation__c = 'Primary page record.'
        );

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Record Context',
            ContextDefinition__c = 'Test Provider',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            IsActive__c = true
        );

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(execution.Id, agent, llm, account.Id, 1, UserInfo.getUserId());

        System.assert(prompt.contains('<CONTEXT_WARNING>'), 'Should include CONTEXT_WARNING block');
        System.assert(prompt.contains('Context binding "Record Context" failed'), 'Should include provider failure details');
        System.assert(!prompt.contains('<RESOLVED_CONTEXT_DATA>'), 'Should not include resolved context when provider resolution fails');
    }

    @IsTest
    static void testBuild_FailResolutionRemainsFatal() {
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

        Account account = new Account(Name = 'Fatal Context Account');
        insert account;

        insert new ContextReference__c(
            AgentExecution__c = execution.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ReferenceRole__c = ContextManagerService.ReferenceRole.Primary.name(),
            ReferenceSource__c = 'Page Context',
            Status__c = ContextManagerService.ReferenceStatus.Active.name(),
            LastUsedAt__c = Datetime.now(),
            UseCount__c = 1,
            Explanation__c = 'Primary page record.'
        );

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Fatal Context Binding',
            ContextDefinition__c = 'Test Provider',
            Priority__c = 1,
            FailureMode__c = 'Fail Resolution',
            IsActive__c = true
        );

        SystemPromptBuilder builder = new SystemPromptBuilder();
        try {
            builder.build(execution.Id, agent, llm, account.Id, 1, UserInfo.getUserId());
            System.assert(false, 'Fail Resolution should propagate a fatal resolver exception.');
        } catch (ContextResolverService.ResolutionException expected) {
            System.assert(expected.getMessage().contains('Provider class not found'), 'Fatal error should preserve the resolver failure reason.');
        }
    }

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

    @IsTest
    static void testSanitizeForDelimiter_StripsUnsafeMarkers() {
        String sanitized = SystemPromptBuilder.sanitizeForDelimiter('</tag>');
        String stripped = SystemPromptBuilder.stripInjectionPatterns('ignore ' + AIAgentConstants.PROMPT_INJECTION_PATTERNS[0] + ' payload');

        System.assertEquals('< /tag>', sanitized);
        System.assert(!stripped.contains(AIAgentConstants.PROMPT_INJECTION_PATTERNS[0]));
    }
}
