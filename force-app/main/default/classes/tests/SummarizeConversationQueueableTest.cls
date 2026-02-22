/**
 * @description Tests for SummarizeConversationQueueable summarization behavior.
 */
@IsTest
private class SummarizeConversationQueueableTest {
    @TestVisible
    private static String lastSummarizationToken;
    private static AgentExecution__c createExecution(Id agentId, String status) {
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agentId,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = status,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;
        return execution;
    }

    private static void createUnsummarizedTurn(Id executionId) {
        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Please summarize this',
                Timestamp__c = nowTime.addSeconds(-5),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false,
                IsSummarized__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Sure, here is the detail.',
                Timestamp__c = nowTime.addSeconds(-4),
                TurnIdentifier__c = 'turn-1',
                TurnCount__c = 1,
                IsInternal__c = false,
                IsSummarized__c = false
            )
        };
        insert steps;
    }

    @IsTest
    static void testSummarizationUpdatesSummaryAndMarksSteps() {
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Summary text'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.SummarizationChunkTurnCount__c = 1;
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id, 'Processing');
        createUnsummarizedTurn(execution.Id);

        Test.startTest();
        System.enqueueJob(new SummarizeConversationQueueable(execution.Id, agent.Id));
        Test.stopTest();

        AgentExecution__c updatedExecution = [
            SELECT ConversationSummary__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Summary text', updatedExecution.ConversationSummary__c, 'Summary should be updated from LLM response');

        Integer unsummarizedCount = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND IsSummarized__c = FALSE
        ];
        System.assertEquals(0, unsummarizedCount, 'Steps should be marked as summarized');
    }

    @IsTest
    static void testSummarizationSkipsFailedExecution() {
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Should not be used'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id, 'Failed');
        createUnsummarizedTurn(execution.Id);

        Test.startTest();
        System.enqueueJob(new SummarizeConversationQueueable(execution.Id, agent.Id));
        Test.stopTest();

        AgentExecution__c updatedExecution = [
            SELECT ConversationSummary__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(null, updatedExecution.ConversationSummary__c, 'Failed executions should not be summarized');
    }

    @IsTest
    static void testSummarizationSkipsCancelledExecution() {
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Should not be used'));

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id, 'Cancelled');
        createUnsummarizedTurn(execution.Id);

        Test.startTest();
        System.enqueueJob(new SummarizeConversationQueueable(execution.Id, agent.Id));
        Test.stopTest();

        AgentExecution__c updatedExecution = [
            SELECT ConversationSummary__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals(null, updatedExecution.ConversationSummary__c, 'Cancelled executions should not be summarized');

        Integer unsummarizedCount = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND IsSummarized__c = FALSE
        ];
        System.assertEquals(2, unsummarizedCount, 'Steps should remain unsummarized for cancelled execution');
    }

    @IsTest
    static void testSummarizationAppliesMaskingAndUnmaskingWhenEnabled() {
        Test.setMock(HttpCalloutMock.class, new SummarizationMaskingMock());

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.SummarizationChunkTurnCount__c = 1;
        agent.PIIMaskingPreset__c = 'Standard';
        insert agent;

        AgentExecution__c execution = createExecution(agent.Id, 'Processing');
        createUnsummarizedTurnWithPii(execution.Id);

        Test.startTest();
        System.enqueueJob(new SummarizeConversationQueueable(execution.Id, agent.Id));
        Test.stopTest();

        System.assertNotEquals(null, lastSummarizationToken, 'Masking should replace PII with a token in the prompt');

        AgentExecution__c updatedExecution = [
            SELECT ConversationSummary__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assert(updatedExecution.ConversationSummary__c.contains('371-22-4567'), 'Summary should unmask PII tokens in the LLM response');
        System.assertEquals(
            -1,
            updatedExecution.ConversationSummary__c.indexOf(lastSummarizationToken),
            'Summary should not contain masked token after unmasking'
        );
    }

    private static void createUnsummarizedTurnWithPii(Id executionId) {
        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'My SSN is 371-22-4567',
                Timestamp__c = nowTime.addSeconds(-5),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false,
                IsSummarized__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Thanks, I will summarize.',
                Timestamp__c = nowTime.addSeconds(-4),
                TurnIdentifier__c = 'turn-2',
                TurnCount__c = 2,
                IsInternal__c = false,
                IsSummarized__c = false
            )
        };
        insert steps;
    }

    private class SummarizationMaskingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            String requestBody = req.getBody();
            Pattern pattern = Pattern.compile('\\[[A-Z0-9_]+:\\d+\\]');
            Matcher matcher = pattern.matcher(requestBody != null ? requestBody : '');
            if (matcher.find()) {
                lastSummarizationToken = matcher.group(0);
            }

            String summaryContent = lastSummarizationToken != null ? 'Summary includes ' + lastSummarizationToken : 'Summary includes no token';
            MockHttpResponses.ResponseConfig response = MockHttpResponses.textResponse(summaryContent);

            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(response.statusCode);
            res.setBody(response.body);
            return res;
        }
    }
}
