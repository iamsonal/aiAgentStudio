/**
 * @description Tests for ContextResolverService under the simplified context definition model.
 */
@IsTest
private class ContextResolverServiceTest {
    private static Integer globalInvocationAnchorCount;

    private class TestProvider implements IAgentContextProvider {
        public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
            List<SObject> records = new List<SObject>();
            Set<Id> accountIds = new Set<Id>();
            Set<Id> userIds = new Set<Id>();

            if (anchorIds != null) {
                for (Id anchorId : anchorIds) {
                    if (anchorId == null) {
                        continue;
                    }
                    if (anchorId.getSObjectType() == Account.SObjectType) {
                        accountIds.add(anchorId);
                    } else if (anchorId.getSObjectType() == User.SObjectType) {
                        userIds.add(anchorId);
                    }
                }
            }

            if (!accountIds.isEmpty()) {
                records.addAll([SELECT Id, Name FROM Account WHERE Id IN :accountIds]);
            }
            if (!userIds.isEmpty()) {
                records.addAll([SELECT Id, Name FROM User WHERE Id IN :userIds]);
            }

            return new Map<String, List<SObject>>{ 'records' => records };
        }
    }

    private class GlobalProvider implements IAgentContextProvider {
        public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
            globalInvocationAnchorCount = anchorIds == null ? -1 : anchorIds.size();
            return new Map<String, List<SObject>>{ 'records' => [SELECT Id, Name FROM User WHERE Id = :UserInfo.getUserId()] };
        }
    }

    @IsTest
    static void testResolve_LoadsRecordAndUserContext() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = 'Processing',
            TriggerSource__c = 'Chat'
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

        insert new List<AgentContextConfig__c>{
            new AgentContextConfig__c(
                AIAgentDefinition__c = agent.Id,
                AdminLabel__c = 'Record Context',
                ContextDefinition__c = 'Test Provider',
                Priority__c = 1,
                FailureMode__c = 'Warn',
                IsActive__c = true
            ),
            new AgentContextConfig__c(
                AIAgentDefinition__c = agent.Id,
                AdminLabel__c = 'User Context',
                ContextDefinition__c = 'User Details Provider',
                Priority__c = 2,
                FailureMode__c = 'Warn',
                IsActive__c = true
            )
        };

        ContextResolverService.setTestProviderOverride('Test Provider', new TestProvider());
        ContextResolverService.setTestProviderOverride('User Details Provider', new TestProvider());
        try {
            ContextResolverService resolver = new ContextResolverService();
            ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agent.Id, UserInfo.getUserId(), null, 1);

            Set<Id> loadedIds = new Set<Id>();
            for (SObject record : result.recordsToLoad) {
                loadedIds.add((Id) record.get('Id'));
            }

            System.assertEquals(2, result.contextBlocks.size(), 'Should create one block per applicable binding');
            System.assert(loadedIds.contains(account.Id), 'Should load account context from stored references');
            System.assert(loadedIds.contains(UserInfo.getUserId()), 'Should load user context');
        } finally {
            ContextResolverService.clearTestProviderOverrides();
        }
    }

    @IsTest
    static void testResolve_MissingProviderWarnsAndSkipsBinding() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Warning Context Agent').withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = 'Processing',
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Account account = new Account(Name = 'Warning Context Account');
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
            AdminLabel__c = 'Warn On Missing Provider',
            ContextDefinition__c = 'Test Provider',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            IsActive__c = true
        );

        ContextResolverService resolver = new ContextResolverService();
        ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agent.Id, UserInfo.getUserId(), null, 1);

        System.assertEquals(0, result.contextBlocks.size(), 'Missing providers should skip the binding when configured to warn.');
        System.assertEquals(1, result.warnings.size(), 'Warn bindings should surface a warning.');
        System.assert(result.warnings[0].contains('Provider class not found'), 'Warning should explain the missing provider class.');
    }

    @IsTest
    static void testResolve_BlankScopeUsesProviderDefaultScope() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Provider Default Scope Agent').withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = 'Processing',
            TriggerSource__c = 'Chat'
        );
        insert execution;

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Default User Context',
            ContextDefinition__c = 'User Details Provider',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            IsActive__c = true
        );

        ContextResolverService.setTestProviderOverride('User Details Provider', new TestProvider());
        try {
            ContextResolverService resolver = new ContextResolverService();
            ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agent.Id, UserInfo.getUserId(), null, 1);

            System.assertEquals(1, result.recordsToLoad.size(), 'Blank binding scope should inherit the provider default scope.');
            System.assertEquals(UserInfo.getUserId(), (Id) result.recordsToLoad[0].get('Id'));
        } finally {
            ContextResolverService.clearTestProviderOverrides();
        }
    }

    @IsTest
    static void testResolve_GlobalScopeInvokesProviderWithoutAnchors() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Global Scope Agent').withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = 'Processing',
            TriggerSource__c = 'Chat'
        );
        insert execution;

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Global Context',
            ContextDefinition__c = 'Global Test Provider',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            IsActive__c = true
        );

        globalInvocationAnchorCount = null;
        ContextResolverService.setTestProviderOverride('Global Test Provider', new GlobalProvider());
        try {
            ContextResolverService resolver = new ContextResolverService();
            ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agent.Id, UserInfo.getUserId(), null, 1);

            System.assertEquals(0, globalInvocationAnchorCount, 'Global scope should intentionally invoke the provider with no anchors.');
            System.assertEquals(1, result.recordsToLoad.size(), 'Global provider output should still be accepted.');
        } finally {
            ContextResolverService.clearTestProviderOverrides();
        }
    }

    @IsTest
    static void testResolve_UsesAgentDefaultChannelBeforeExecutionExists() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
            .withName('Direct Channel Context Agent')
            .withLLM(llm.Id)
            .withType('Direct')
            .save();

        insert new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            AdminLabel__c = 'Direct Only Context',
            ContextDefinition__c = 'User Details Provider',
            ApplicableChannels__c = 'Direct',
            Priority__c = 1,
            FailureMode__c = 'Warn',
            IsActive__c = true
        );

        ContextResolverService.setTestProviderOverride('User Details Provider', new TestProvider());
        try {
            ContextResolverService resolver = new ContextResolverService();
            ContextResolverService.ResolutionResult result = resolver.resolve(null, agent.Id, UserInfo.getUserId(), null, 1);

            System.assertEquals(1, result.contextBlocks.size(), 'Direct-only binding should apply on the initial turn for direct agents.');
            System.assertEquals(1, result.recordsToLoad.size(), 'Direct-only binding should still resolve provider output before an execution row exists.');
            System.assertEquals(0, result.warnings.size(), 'A matching direct channel should not produce a warning.');
            System.assertEquals(UserInfo.getUserId(), (Id) result.recordsToLoad[0].get('Id'));
        } finally {
            ContextResolverService.clearTestProviderOverrides();
        }
    }
}
