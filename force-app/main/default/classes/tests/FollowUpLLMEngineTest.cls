/**
 * @description Focused tests for FollowUpLLMEngine behavior
 */
@IsTest
private class FollowUpLLMEngineTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('FollowUp LLM').save();

        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('FollowUp_Agent').withType('Conversational').withLLM(llm.Id).save();

        TestFactory.newCapability().withAgent(agent.Id).forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' }).withName('followup_get_case').save();

        TestFactory.newCase().withSubject('Follow-up Case').save();
    }

    @IsTest
    static void testProcess_TextResponse_CompletesExecution() {
        AIAgentDefinition__c agent = [
            SELECT Id, LLMConfiguration__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'FollowUp_Agent%'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_FOLLOWUP)
            .withTurnIdentifier('turn-followup-text-001')
            .save();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Follow-up answer.'));

        FollowUpLLMEngine engine = new FollowUpLLMEngine(execution.Id, UserInfo.getUserId(), agent.Id, 'turn-followup-text-001', 1, false, null);

        Test.startTest();
        engine.process('job-id');
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'Execution should be Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing status should be Idle');

        Integer responseCount = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c = 'AgentResponse'
        ];
        System.assert(responseCount > 0, 'Follow-up should create an agent response step');
    }

    @IsTest
    static void testProcess_ImmediateFollowUp_CompletesAfterTool() {
        AIAgentDefinition__c agent = [
            SELECT Id
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'FollowUp_Agent%'
            LIMIT 1
        ];
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_FOLLOWUP)
            .withTurnIdentifier('turn-followup-tool-001')
            .withSourceRecord(testCase.Id)
            .save();

        MockHttpResponses mock = MockHttpResponses.conversational()
            .addResponse(MockHttpResponses.toolCallResponse('followup_get_case', '{"Id":"' + testCase.Id + '"}', 'Fetching case'))
            .addTextResponse('Case details summarized.');

        Test.setMock(HttpCalloutMock.class, mock);

        FollowUpLLMEngine engine = new FollowUpLLMEngine(execution.Id, UserInfo.getUserId(), agent.Id, 'turn-followup-tool-001', 1, false, testCase.Id);

        Test.startTest();
        engine.process('job-id');
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Completed', updated.ExecutionStatus__c, 'Execution should be Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing status should be Idle');

        Integer toolSteps = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, toolSteps, 'Tool call should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testProcess_StaleExecution_DoesNothing() {
        AIAgentDefinition__c agent = [
            SELECT Id
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'FollowUp_Agent%'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Completed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-followup-stale-001')
            .save();

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Should not run.'));

        FollowUpLLMEngine engine = new FollowUpLLMEngine(execution.Id, UserInfo.getUserId(), agent.Id, 'turn-followup-stale-001', 1, false, null);

        engine.process('job-id');

        Integer responseCount = [
            SELECT COUNT()
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND StepType__c = 'AgentResponse'
        ];
        System.assertEquals(0, responseCount, 'Stale execution should not create response steps');
    }
}
