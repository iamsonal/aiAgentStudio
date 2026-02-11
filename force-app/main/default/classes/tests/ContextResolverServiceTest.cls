/**
 * @description Tests for ContextResolverService provider orchestration.
 */
@IsTest
private class ContextResolverServiceTest {
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
        AgentContextConfig__c userConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            ContextLabel__c = 'User Context',
            ImplementationName__c = 'ContextResolverTestProvider',
            RequiresRecordContext__c = false,
            IsActive__c = true,
            ExecutionOrder__c = 2
        );
        insert new List<AgentContextConfig__c>{ recordConfig, userConfig };

        ContextResolverService resolver = new ContextResolverService();
        ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agent.Id, UserInfo.getUserId(), null, 1);

        Set<Id> loadedIds = new Set<Id>();
        for (SObject record : result.recordsToLoad) {
            loadedIds.add(record.Id);
        }

        System.assert(loadedIds.contains(account.Id), 'Should load account context');
        System.assert(loadedIds.contains(UserInfo.getUserId()), 'Should load user context');
    }
}
