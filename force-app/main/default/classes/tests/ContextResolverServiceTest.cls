/**
 * @description Tests for ContextResolverService provider orchestration.
 */
@IsTest
private class ContextResolverServiceTest {
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
                ProviderDefinition__c = 'Test Provider',
                ApplicableObjects__c = 'Account',
                Scope__c = 'Record',
                Priority__c = 1,
                FailureMode__c = 'Warn',
                FreshnessPolicy__c = 'Session',
                OverlapMode__c = 'Allow',
                ProjectionMode__c = 'Provider Default',
                IsActive__c = true
            ),
            new AgentContextConfig__c(
                AIAgentDefinition__c = agent.Id,
                AdminLabel__c = 'User Context',
                ProviderDefinition__c = 'Test Provider',
                Scope__c = 'User',
                Priority__c = 2,
                FailureMode__c = 'Warn',
                FreshnessPolicy__c = 'Current Only',
                OverlapMode__c = 'Allow',
                ProjectionMode__c = 'Provider Default',
                IsActive__c = true
            )
        };

        ContextResolverService.setTestProviderOverride('Test Provider', new TestProvider());
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
}
