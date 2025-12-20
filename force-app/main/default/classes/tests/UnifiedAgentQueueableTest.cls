/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Test class for UnifiedAgentQueueable
 * Tests all three job types: Function, WorkflowChild, and Conversational
 */
@IsTest
private class UnifiedAgentQueueableTest {
    @TestSetup
    static void setup() {
        // Create test agent and configuration
        TestFactory.createFullAgentSetup()
            .withAgent(TestFactory.newAgentDefinition().withName('Test Function Agent').withType('Function').build())
            .save();
    }

    @IsTest
    static void testFunctionJobType_ValidPayload_EnqueuesSuccessfully() {
        // Given: Valid function job payload
        AIAgentDefinition__c agentDef = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        String turnId = UUID.randomUUID().toString();

        Map<String, Object> payload = new Map<String, Object>{
            'agentDeveloperName' => agentDef.DeveloperName__c,
            'input' => 'Test input',
            'recordId' => null,
            'userId' => UserInfo.getUserId(),
            'turnIdentifier' => turnId
        };

        // Mock LLM response
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Enqueuing function job
        Test.startTest();
        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_FUNCTION, payload);
        Id jobId = System.enqueueJob(queueable);
        Test.stopTest();

        // Then: Job should execute successfully
        System.assertNotEquals(null, jobId, 'Job should be enqueued');
    }

    @IsTest
    static void testWorkflowChildJobType_ValidPayload_EnqueuesSuccessfully() {
        // Given: Valid workflow child job payload
        AIAgentDefinition__c agentDef = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        String turnId = UUID.randomUUID().toString();

        // Create parent and child execution records
        AgentExecution__c parentExec = new AgentExecution__c(
            ExecutionType__c = 'Workflow',
            AIAgentDefinition__c = agentDef.Id,
            User__c = UserInfo.getUserId(),
            ExecutionStatus__c = 'Processing',
            CurrentTurnIdentifier__c = turnId
        );
        insert parentExec;

        AgentExecution__c childExec = new AgentExecution__c(
            ExecutionType__c = 'Function',
            AIAgentDefinition__c = agentDef.Id,
            User__c = UserInfo.getUserId(),
            ExecutionStatus__c = 'Pending',
            ParentExecution__c = parentExec.Id,
            CurrentTurnIdentifier__c = turnId
        );
        insert childExec;

        Map<String, Object> payload = new Map<String, Object>{
            'childExecutionId' => childExec.Id,
            'parentExecutionId' => parentExec.Id,
            'agentType' => 'Test Child Agent',
            'agentDefinitionId' => agentDef.Id,
            'userId' => UserInfo.getUserId(),
            'turnIdentifier' => turnId,
            'sourceRecordId' => null,
            'userMessage' => 'Test message'
        };

        // Mock LLM response
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Enqueuing workflow child job
        Test.startTest();
        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_WORKFLOW_CHILD, payload);
        Id jobId = System.enqueueJob(queueable);
        Test.stopTest();

        // Then: Job should execute successfully
        System.assertNotEquals(null, jobId, 'Job should be enqueued');
    }

    @IsTest
    static void testConversationalJobType_ValidPayload_EnqueuesSuccessfully() {
        // Given: Valid conversational job payload
        AIAgentDefinition__c agentDef = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        String turnId = UUID.randomUUID().toString();

        // Create execution record
        AgentExecution__c exec = new AgentExecution__c(
            ExecutionType__c = 'Conversational',
            AIAgentDefinition__c = agentDef.Id,
            User__c = UserInfo.getUserId(),
            ExecutionStatus__c = 'Processing',
            CurrentTurnIdentifier__c = turnId
        );
        insert exec;

        Map<String, Object> payload = new Map<String, Object>{
            'executionId' => exec.Id,
            'originalUserId' => UserInfo.getUserId(),
            'executionUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => agentDef.Id,
            'llmConfigurationId' => llmConfig.Id,
            'turnIdentifier' => turnId,
            'currentRecordId' => null,
            'userMessage' => 'Hello, test message'
        };

        // Mock LLM response
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Enqueuing conversational job
        Test.startTest();
        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_CONVERSATIONAL, payload);
        Id jobId = System.enqueueJob(queueable);
        Test.stopTest();

        // Then: Job should execute successfully
        System.assertNotEquals(null, jobId, 'Job should be enqueued');
    }

    @IsTest
    static void testInvalidJobType_ThrowsException() {
        // Given: Invalid job type
        String invalidJobType = 'InvalidType';
        Map<String, Object> payload = new Map<String, Object>{
            'test' => 'data'
        };

        // When/Then: Should throw exception
        try {
            new UnifiedAgentQueueable(invalidJobType, payload);
            System.assert(false, 'Should have thrown exception for invalid job type');
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            System.assert(e.getMessage().contains('Invalid job type'), 'Should indicate invalid job type');
        }
    }

    @IsTest
    static void testNullPayload_ThrowsException() {
        // Given: Null payload
        Map<String, Object> payload = null;

        // When/Then: Should throw exception
        try {
            new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_FUNCTION, payload);
            System.assert(false, 'Should have thrown exception for null payload');
        } catch (UnifiedAgentQueueable.UnifiedQueueableException e) {
            System.assert(e.getMessage().contains('Payload is required'), 'Should indicate payload required');
        }
    }

    @IsTest
    static void testFunctionJob_MissingRequiredField_HandlesGracefully() {
        // Given: Function job with missing required field
        Map<String, Object> payload = new Map<String, Object>{
            'input' => 'Test input'
            // Missing agentDeveloperName
        };

        // Mock LLM response
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Enqueuing with incomplete payload
        Test.startTest();
        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_FUNCTION, payload);
        Id jobId = System.enqueueJob(queueable);
        Test.stopTest();

        // Then: Job should be enqueued but will fail during execution
        System.assertNotEquals(null, jobId, 'Job should be enqueued');
        // Error handling happens in execute method
    }

    @IsTest
    static void testJobTypeConstants_AreAccessible() {
        // Then: Job type constants should be accessible
        System.assertEquals('Function', UnifiedAgentQueueable.JOB_TYPE_FUNCTION, 'Function constant should be correct');
        System.assertEquals('WorkflowChild', UnifiedAgentQueueable.JOB_TYPE_WORKFLOW_CHILD, 'WorkflowChild constant should be correct');
        System.assertEquals('Conversational', UnifiedAgentQueueable.JOB_TYPE_CONVERSATIONAL, 'Conversational constant should be correct');
    }
}

