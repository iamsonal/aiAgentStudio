@IsTest
private class InteractionSessionPolicyServiceTest {
    @IsTest
    static void testResolveReusableExecutionId_ReturnsLastExecutionWhenSessionStillActive() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('SessionPolicyTestLLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('SessionPolicyAgent').withType('Conversational').withLLM(llm.Id).save();
        Case sourceCase = TestFactory.newCase().withSubject('Session Policy Case').save();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Completed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(sourceCase.Id)
            .withTurnIdentifier('turn-policy-001')
            .save();

        InteractionRuntimeModels.InteractionSessionContext sessionContext = new InteractionRuntimeModels.InteractionSessionContext();
        sessionContext.lastExecutionId = execution.Id;

        ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService.ResolvedRoute();
        route.inactivityTtlHours = 24;

        Id resolvedExecutionId = new InteractionSessionPolicyService().resolveReusableExecutionId(sessionContext, sourceCase.Id, route, '[test] ');
        System.assertEquals(execution.Id, resolvedExecutionId, 'Session policy should reuse the last execution when TTL has not expired');
    }

    @IsTest
    static void testResolveReusableExecutionId_ReturnsNullWhenPriorExecutionFailed() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('SessionPolicyTestLLM2').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('SessionPolicyAgent2').withType('Conversational').withLLM(llm.Id).save();
        Case sourceCase = TestFactory.newCase().withSubject('Session Policy Failed Case').save();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(sourceCase.Id)
            .withTurnIdentifier('turn-policy-002')
            .save();

        InteractionRuntimeModels.InteractionSessionContext sessionContext = new InteractionRuntimeModels.InteractionSessionContext();
        sessionContext.lastExecutionId = execution.Id;

        Id resolvedExecutionId = new InteractionSessionPolicyService().resolveReusableExecutionId(sessionContext, sourceCase.Id, null, '[test] ');
        System.assertEquals(null, resolvedExecutionId, 'Failed prior execution should start a new conversation cycle');
    }
}
