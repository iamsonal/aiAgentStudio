/**
 * @description Focused tests for UnifiedAgentQueueable using shared TestFactory helpers
 */
@IsTest
private class UnifiedAgentQueueableTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        TestFactory.newAgentDefinition().withName('Queueable_Function_Agent').withType('Function').withLLM(llm.Id).withAuditLevel('Standard').save();
        TestFactory.newAgentDefinition().withName('Queueable_Convo_Agent').withType('Conversational').withLLM(llm.Id).save();
    }

    @IsTest
    static void testFunctionJobType_ExecutesWithValidPayload() {
        AIAgentDefinition__c agentDef = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Queueable_Function_Agent%'
            LIMIT 1
        ];

        Map<String, Object> payload = new Map<String, Object>{
            'agentDeveloperName' => agentDef.DeveloperName__c,
            'input' => 'Summarize the record',
            'recordId' => null,
            'userId' => UserInfo.getUserId(),
            'turnIdentifier' => 'turn-queueable-001'
        };

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Summary complete.'));

        Test.startTest();
        Id jobId = System.enqueueJob(new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_FUNCTION, payload));
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job should be enqueued');

        Integer executionCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agentDef.Id AND ExecutionType__c = 'Function'
        ];
        System.assertEquals(0, executionCount, 'When orchestrator mappings are unavailable, function job should not create executions');
    }

    @IsTest
    static void testConstructor_BlankJobType_ThrowsException() {
        Boolean threw = false;
        try {
            new UnifiedAgentQueueable('', new Map<String, Object>{ 'key' => 'value' });
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank job type should throw UnifiedQueueableException');
    }

    @IsTest
    static void testConstructor_NullPayload_ThrowsException() {
        Boolean threw = false;
        try {
            new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_FUNCTION, null);
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Null payload should throw UnifiedQueueableException');
    }

    @IsTest
    static void testConstructor_InvalidJobType_ThrowsException() {
        Boolean threw = false;
        try {
            new UnifiedAgentQueueable('InvalidType', new Map<String, Object>{ 'key' => 'value' });
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            threw = true;
            System.assert(e.getMessage().contains('Invalid job type'), 'Should identify invalid job type');
        }
        System.assertEquals(true, threw, 'Invalid job type should throw UnifiedQueueableException');
    }

    @IsTest
    static void testConversationalJobType_QueuesAndExecutes() {
        AIAgentDefinition__c agentDef = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Queueable_Convo_Agent%'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-convo-001')
            .save();

        Map<String, Object> payload = new Map<String, Object>{
            'executionId' => execution.Id,
            'userId' => UserInfo.getUserId(),
            'turnIdentifier' => 'turn-convo-001',
            'turnCount' => 1,
            'input' => 'Hello'
        };

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Hello!'));

        Test.startTest();
        Id jobId = System.enqueueJob(new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_CONVERSATIONAL, payload));
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Conversational job should be enqueued');
    }

    @IsTest
    static void testWorkflowChildJobType_MissingParentExecution_FailsChild() {
        AIAgentDefinition__c agentDef = [
            SELECT Id
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Queueable_Convo_Agent%'
            LIMIT 1
        ];

        AgentExecution__c childExecution = TestFactory.newExecution()
            .withAgent(agentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Workflow')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-queueable-wf-001')
            .save();

        Map<String, Object> payload = new Map<String, Object>{
            'childExecutionId' => childExecution.Id
            // parentExecutionId intentionally missing
        };

        Test.startTest();
        System.enqueueJob(new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_WORKFLOW_CHILD, payload));
        Test.stopTest();

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :childExecution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Missing parent execution should fail child');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, updated.ProcessingStatus__c, 'Processing status should be Idle on failure');
        System.assert(String.isNotBlank(updated.ErrorMessage__c), 'Error message should be set');
    }
}
