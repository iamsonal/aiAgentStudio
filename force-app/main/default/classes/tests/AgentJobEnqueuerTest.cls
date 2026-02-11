/**
 * @description Tests for AgentJobEnqueuer routing behavior.
 */
@IsTest
private class AgentJobEnqueuerTest {
    @IsTest
    static void testConstructor_NullStateServiceThrows() {
        Boolean threw = false;
        try {
            new AgentJobEnqueuer(null);
        } catch (IllegalArgumentException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null AgentStateService should throw');
    }

    @IsTest
    static void testEnqueueFollowUp_QueueableLowDispatch() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.AsyncDispatchType__c = 'Low';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        Integer beforeJobs = Limits.getQueueableJobs();
        AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
        enqueuer.enqueueFollowUp(execution.Id, UserInfo.getUserId(), agent.Id, 'turn-1', 2, '[test]', false, null);
        System.assert(Limits.getQueueableJobs() > beforeJobs, 'Queueable should be enqueued for Low dispatch');
    }

    @IsTest
    static void testEnqueueFollowUp_PlatformEventHighDispatch() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.AsyncDispatchType__c = 'High';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE
        );
        insert execution;

        AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
        enqueuer.enqueueFollowUp(execution.Id, UserInfo.getUserId(), agent.Id, 'turn-2', 3, '[test]', true, null);
    }

    @IsTest
    static void testEnqueueAsyncAction_QueueableLowDispatch() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.AsyncDispatchType__c = 'Low';
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_AWAITING_ACTION,
            CurrentTurnIdentifier__c = 'turn-async-1'
        );
        insert execution;

        AgentCapability__c capability = TestFactory.newCapability().withAgent(agent.Id).forPostChatter().save();

        Integer beforeJobs = Limits.getQueueableJobs();
        AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
        enqueuer.enqueueAsyncAction(
            execution.Id,
            UserInfo.getUserId(),
            agent.Id,
            null,
            'tool-call-1',
            '{"messageText":"Hello"}',
            capability,
            execution.Id,
            'turn-async-1',
            1,
            '[test]'
        );
        System.assert(Limits.getQueueableJobs() > beforeJobs, 'Async action should enqueue queueable for Low dispatch');
    }
}
