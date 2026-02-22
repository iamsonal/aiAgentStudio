/**
 * @description Tests for AsyncFrameworkRequestFlowInvoker routing safeguards.
 */
@IsTest
private class AsyncFrameworkRequestFlowInvokerTest {
    private static AgentExecution__c createExecution(String turnId, String status) {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = status,
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            CurrentTurnIdentifier__c = turnId
        );
        insert execution;
        return execution;
    }

    @IsTest
    static void testProcessEvents_SkipsInvalidAndUnknownJobTypes() {
        Integer beforeCount = [SELECT COUNT() FROM AgentExecution__c];

        AsyncFrameworkRequest__e missingFields = new AsyncFrameworkRequest__e();
        AsyncFrameworkRequest__e unknownJob = new AsyncFrameworkRequest__e(JobType__c = 'Unknown', Payload__c = '{}');

        Test.startTest();
        AsyncFrameworkRequestFlowInvoker.processEvents(new List<AsyncFrameworkRequest__e>{ missingFields, unknownJob });
        Test.stopTest();

        Integer afterCount = [SELECT COUNT() FROM AgentExecution__c];
        System.assertEquals(beforeCount, afterCount, 'Invalid or unknown job types should not create executions');
    }

    @IsTest
    static void testProcessEvents_ExecuteAction_ExitsWhenNotAwaiting() {
        AgentExecution__c execution = createExecution('turn-exec-001', 'Pending');
        AgentCapability__c capability = TestFactory.newCapability().withName('exec_action').forPostChatter().build();
        capability.AIAgentDefinition__c = execution.AIAgentDefinition__c;
        insert capability;

        Map<String, Object> payload = new Map<String, Object>{
            'sessionId' => execution.Id,
            'originalUserId' => UserInfo.getUserId(),
            'agentDefId' => execution.AIAgentDefinition__c,
            'parentAsstMsgId' => null,
            'toolCallId' => 'tool-call-1',
            'llmArgsJson' => '{"param":"value"}',
            'relatedId' => null,
            'turnId' => 'turn-exec-001',
            'currentTurnCount' => 1,
            'capability' => new Map<String, Object>{
                'Id' => capability.Id,
                'CapabilityName__c' => capability.CapabilityName__c,
                'ImplementationType__c' => capability.ImplementationType__c,
                'StandardActionType__c' => capability.StandardActionType__c,
                'BackendConfiguration__c' => capability.BackendConfiguration__c,
                'Parameters__c' => capability.Parameters__c,
                'RunAsynchronously__c' => capability.RunAsynchronously__c,
                'HITLMode__c' => capability.HITLMode__c,
                'HITLNotificationPreference__c' => capability.HITLNotificationPreference__c,
                'ExposureLevel__c' => capability.ExposureLevel__c,
                'AIAgentDefinition__c' => capability.AIAgentDefinition__c
            }
        };

        AsyncFrameworkRequest__e executeAction = new AsyncFrameworkRequest__e(JobType__c = 'ExecuteAction', Payload__c = JSON.serialize(payload));

        Test.startTest();
        AsyncFrameworkRequestFlowInvoker.processEvents(new List<AsyncFrameworkRequest__e>{ executeAction });
        Test.stopTest();

        AgentExecution__c reloaded = [SELECT ProcessingStatus__c FROM AgentExecution__c WHERE Id = :execution.Id];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, reloaded.ProcessingStatus__c, 'Execution should remain unchanged when not awaiting action');
    }

    @IsTest
    static void testProcessEvents_FollowUpLLM_ExitsWhenNotAwaiting() {
        AgentExecution__c execution = createExecution('turn-follow-001', 'Pending');

        Map<String, Object> payload = new Map<String, Object>{
            'sessionId' => execution.Id,
            'userId' => UserInfo.getUserId(),
            'agentDefId' => execution.AIAgentDefinition__c,
            'turnId' => 'turn-follow-001',
            'nextTurnCount' => 2,
            'isFinalErrorTurn' => false,
            'recordId' => null
        };

        AsyncFrameworkRequest__e followUp = new AsyncFrameworkRequest__e(JobType__c = 'FollowUpLLM', Payload__c = JSON.serialize(payload));

        Test.startTest();
        AsyncFrameworkRequestFlowInvoker.processEvents(new List<AsyncFrameworkRequest__e>{ followUp });
        Test.stopTest();

        AgentExecution__c reloaded = [SELECT ProcessingStatus__c FROM AgentExecution__c WHERE Id = :execution.Id];
        System.assertEquals(AIAgentConstants.STATUS_IDLE, reloaded.ProcessingStatus__c, 'Execution should remain unchanged when not awaiting follow-up');
    }

    @IsTest
    static void testProcessEvents_ProcessLLMMessage_MissingLlmConfigFailsTurn() {
        AgentExecution__c execution = createExecution('turn-proc-001', 'Pending');

        Map<String, Object> payload = new Map<String, Object>{
            'sessionId' => execution.Id,
            'originalUserId' => UserInfo.getUserId(),
            'agentDefinitionId' => execution.AIAgentDefinition__c,
            'llmConfigurationId' => null,
            'turnIdentifier' => 'turn-proc-001',
            'userMessage' => 'Hello',
            'currentRecordId' => null,
            'logPrefix' => '[test] '
        };

        AsyncFrameworkRequest__e processMsg = new AsyncFrameworkRequest__e(JobType__c = 'ProcessLLMMessage', Payload__c = JSON.serialize(payload));

        Test.startTest();
        AsyncFrameworkRequestFlowInvoker.processEvents(new List<AsyncFrameworkRequest__e>{ processMsg });
        Test.stopTest();

        AgentExecution__c reloaded = [SELECT ExecutionStatus__c, ProcessingStatus__c FROM AgentExecution__c WHERE Id = :execution.Id];
        System.assertEquals('Failed', reloaded.ExecutionStatus__c, 'Missing LLM config should fail turn');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, reloaded.ProcessingStatus__c, 'Processing status should be Failed');
    }
}
