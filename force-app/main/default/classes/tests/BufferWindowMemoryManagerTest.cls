/**
 * @description Tests for BufferWindowMemoryManager history retrieval.
 */
@IsTest
private class BufferWindowMemoryManagerTest {
    private static AgentExecution__c createExecution(Id agentId) {
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agentId,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;
        return execution;
    }

    private static void createSteps(Id executionId) {
        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Hi',
                Timestamp__c = nowTime.addSeconds(-10),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Hello',
                Timestamp__c = nowTime.addSeconds(-9),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Next',
                Timestamp__c = nowTime.addSeconds(-5),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Done',
                Timestamp__c = nowTime.addSeconds(-4),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false
            )
        };
        insert steps;
    }

    @IsTest
    static void testGetHistory_Unlimited() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.HistoryTurnLimit__c = null;
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id);
        createSteps(execution.Id);

        BufferWindowMemoryManager mgr = new BufferWindowMemoryManager();
        List<Map<String, Object>> history = mgr.getHistoryPayload(execution.Id, agent, llm, '[test]');

        String allContent = collectContent(history);
        System.assert(allContent.contains('Hi'), 'Unlimited history should include earliest turn');
        System.assert(allContent.contains('Next'), 'Unlimited history should include latest turn');
    }

    @IsTest
    static void testGetHistory_ZeroLimit() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.HistoryTurnLimit__c = 0;
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id);
        createSteps(execution.Id);

        BufferWindowMemoryManager mgr = new BufferWindowMemoryManager();
        List<Map<String, Object>> history = mgr.getHistoryPayload(execution.Id, agent, llm, '[test]');

        System.assertEquals(0, history.size(), 'Zero limit should return no history');
    }

    @IsTest
    static void testGetHistory_PositiveLimit() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.HistoryTurnLimit__c = 1;
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id);
        createSteps(execution.Id);

        BufferWindowMemoryManager mgr = new BufferWindowMemoryManager();
        List<Map<String, Object>> history = mgr.getHistoryPayload(execution.Id, agent, llm, '[test]');

        String allContent = collectContent(history);
        System.assert(!allContent.contains('Hi'), 'Limited history should exclude earliest turn');
        System.assert(allContent.contains('Next'), 'Limited history should include most recent turn');
    }

    private static String collectContent(List<Map<String, Object>> history) {
        List<String> parts = new List<String>();
        for (Map<String, Object> msg : history) {
            if (msg != null && msg.containsKey('content') && msg.get('content') != null) {
                parts.add(String.valueOf(msg.get('content')));
            }
        }
        return String.join(parts, ' | ');
    }
}
