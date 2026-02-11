/**
 * @description Tests for SummaryBufferMemoryManager behavior and job enqueue guards.
 */
@IsTest
private class SummaryBufferMemoryManagerTest {
    private static AgentExecution__c createExecution(Id agentId) {
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agentId,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
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
                Content__c = 'Old question',
                Timestamp__c = nowTime.addSeconds(-20),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false,
                IsSummarized__c = true
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Old answer',
                Timestamp__c = nowTime.addSeconds(-19),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false,
                IsSummarized__c = true
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'New question',
                Timestamp__c = nowTime.addSeconds(-10),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false,
                IsSummarized__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'New answer',
                Timestamp__c = nowTime.addSeconds(-9),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false,
                IsSummarized__c = false
            )
        };
        insert steps;
    }

    @IsTest
    static void testGetHistoryPayload_UnsummarizedOnly() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.MemoryStrategy__c = 'Summary Buffer';
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id);
        createSteps(execution.Id);

        SummaryBufferMemoryManager mgr = new SummaryBufferMemoryManager();
        List<Map<String, Object>> history = mgr.getHistoryPayload(execution.Id, agent, llm, '[test]');

        String allContent = collectContent(history);
        System.assert(!allContent.contains('Old question'), 'Summarized turns should be excluded');
        System.assert(allContent.contains('New question'), 'Unsummarized turns should be included');
    }

    @IsTest
    static void testOnTurnCompletion_EnqueuesAndDedupes() {
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Summary complete.'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.MemoryStrategy__c = 'Summary Buffer';
        agent.SummarizationTriggerTurnCount__c = 1;
        agent.SummarizationChunkTurnCount__c = 1;
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id);
        createSteps(execution.Id);

        SummaryBufferMemoryManager mgr = new SummaryBufferMemoryManager();

        Test.startTest();
        mgr.onTurnCompletion(execution.Id, agent, llm, '[test]');
        mgr.onTurnCompletion(execution.Id, agent, llm, '[test]');

        AgentExecution__c execDuring = [
            SELECT SummarizationJobId__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assert(String.isNotBlank(execDuring.SummarizationJobId__c), 'Summarization job should be queued');
        Test.stopTest();

        AgentExecution__c execAfter = [
            SELECT SummarizationJobId__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(null, execAfter.SummarizationJobId__c, 'Summarization job id should be cleared after execution');
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
