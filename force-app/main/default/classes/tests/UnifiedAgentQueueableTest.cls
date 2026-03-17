/**
 * @description Focused tests for UnifiedAgentQueueable using shared TestFactory helpers
 */
@IsTest
private class UnifiedAgentQueueableTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        TestFactory.newAgentDefinition().withName('Queueable_Primary_Agent').withType('Direct').withLLM(llm.Id).withAuditLevel('Standard').save();
        TestFactory.newAgentDefinition().withName('Queueable_Convo_Agent').withType('Conversational').withLLM(llm.Id).save();
    }

    @IsTest
    static void testFunctionJobType_ExecutesWithValidPayload() {
        AIAgentDefinition__c agentDef = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'Queueable_Primary_Agent%'
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
        Id jobId = System.enqueueJob(new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_SINGLE_SHOT, payload));
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Job should be enqueued');

        Integer executionCount = [
            SELECT COUNT()
            FROM AgentExecution__c
            WHERE AIAgentDefinition__c = :agentDef.Id AND ExecutionType__c = 'Direct'
        ];
        System.assertEquals(1, executionCount, 'Execution should be created for the configured function runtime');
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
            new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_SINGLE_SHOT, null);
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
            SELECT Id, DeveloperName__c, LLMConfiguration__c
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
            'originalUserId' => UserInfo.getUserId(),
            'executionUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agentDef.Id,
            'llmConfigurationId' => agentDef.LLMConfiguration__c,
            'turnIdentifier' => 'turn-convo-001',
            'userMessage' => 'Hello',
            'interactionChannel' => RuntimeRegistryService.CHANNEL_CHAT
        };

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Hello!'));

        Test.startTest();
        Id jobId = System.enqueueJob(new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_ITERATIVE, payload));
        Test.stopTest();

        System.assertNotEquals(null, jobId, 'Conversational job should be enqueued');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertNotEquals('Failed', updatedExecution.ExecutionStatus__c, 'Conversational job should not fail after enqueueing valid payload');
        System.assertEquals(null, updatedExecution.ErrorMessage__c, 'Conversational job should not leave an execution error when payload is valid');
    }

    @IsTest
    static void testInvalidJobType_ThrowsException() {
        Map<String, Object> payload = new Map<String, Object>{ 'executionId' => null };

        Test.startTest();
        try {
            new UnifiedAgentQueueable('InvalidJobType', payload);
            System.assert(false, 'Should have thrown exception for invalid job type');
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            System.assert(e.getMessage().contains('Invalid job type'), 'Error should mention invalid job type');
        }
        Test.stopTest();
    }
}
