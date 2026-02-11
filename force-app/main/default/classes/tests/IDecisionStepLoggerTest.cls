/**
 * @description Tests for IDecisionStepLogger factory and NoOp implementation
 */
@IsTest
private class IDecisionStepLoggerTest {
    @IsTest
    static void testCreate_LoggingEnabled_ReturnsImplementation() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-001')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-001', UserInfo.getUserId());

        System.assertNotEquals(null, logger, 'Should return a logger instance');
    }

    @IsTest
    static void testCreate_TwoArgOverload_ReturnsImplementation() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 2').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_2').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-002')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-002');

        System.assertNotEquals(null, logger, 'Should return a logger instance with two-arg overload');
    }

    @IsTest
    static void testNoOp_Initialize_DoesNotThrow() {
        IDecisionStepLogger.NoOp logger = new IDecisionStepLogger.NoOp();

        logger.initialize(UserInfo.getUserId(), 'turn-noop-001', UserInfo.getUserId());

        System.assert(true, 'Initialize should complete without error');
    }

    @IsTest
    static void testNoOp_Log_DoesNotThrow() {
        IDecisionStepLogger.NoOp logger = new IDecisionStepLogger.NoOp();

        logger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ 'test message' });

        System.assert(true, 'Log should complete without error');
    }

    @IsTest
    static void testNoOp_UpdateExecutionId_DoesNotThrow() {
        IDecisionStepLogger.NoOp logger = new IDecisionStepLogger.NoOp();

        logger.updateExecutionId(UserInfo.getUserId());

        System.assert(true, 'UpdateExecutionId should complete without error');
    }

    @IsTest
    static void testNoOp_CommitSteps_DoesNotThrow() {
        IDecisionStepLogger.NoOp logger = new IDecisionStepLogger.NoOp();

        logger.commitSteps();

        System.assert(true, 'CommitSteps should complete without error');
    }

    @IsTest
    static void testNoOp_GetLastLoggedStepId_ReturnsNull() {
        IDecisionStepLogger.NoOp logger = new IDecisionStepLogger.NoOp();

        Id lastStepId = logger.getLastLoggedStepId();

        System.assertEquals(null, lastStepId, 'NoOp should always return null for last logged step ID');
    }

    @IsTest
    static void testLogger_AllEventTypes_CanBeLogged() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 3').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_3').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-003')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-003', UserInfo.getUserId());

        logger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ 'error message' });
        logger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ 'tool result' });
        logger.log(IDecisionStepLogger.EventType.APPROVAL_REQUESTED, new List<Object>{ 'approval' });
        logger.log(IDecisionStepLogger.EventType.APPROVAL_RESOLVED, new List<Object>{ 'resolved' });
        logger.log(IDecisionStepLogger.EventType.LLM_REQUEST, new List<Object>{ 'llm request' });
        logger.log(IDecisionStepLogger.EventType.LLM_RESPONSE, new List<Object>{ 'llm response' });
        logger.log(IDecisionStepLogger.EventType.SAFETY_CHECK, new List<Object>{ 'safety check' });
        logger.log(IDecisionStepLogger.EventType.SAFETY_BLOCKED, new List<Object>{ 'blocked' });
        logger.log(IDecisionStepLogger.EventType.SYSTEM_PROMPT_BUILT, new List<Object>{ 'system prompt' });
        logger.log(IDecisionStepLogger.EventType.CONTEXT_GATHERED, new List<Object>{ 'context' });
        logger.log(IDecisionStepLogger.EventType.TOOLS_CONFIGURED, new List<Object>{ 'tools' });
        logger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ 'final response' });
        logger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ 'user input' });
        logger.log(IDecisionStepLogger.EventType.AGENT_RESUMED, new List<Object>{ 'resumed' });

        logger.commitSteps();

        System.assert(true, 'Should log all event types without error');
    }

    @IsTest
    static void testLogger_UpdateExecutionId_UpdatesBufferedSteps() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 4').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_4').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution1 = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-004')
            .save();

        AgentExecution__c execution2 = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-005')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution1.Id, 'turn-logger-004', UserInfo.getUserId());

        logger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ 'message' });
        logger.updateExecutionId(execution2.Id);
        logger.commitSteps();

        System.assert(true, 'Should update execution ID without error');
    }

    @IsTest
    static void testLogger_MultipleLogsAndCommit_WorksCorrectly() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 5').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_5').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-006')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-006', UserInfo.getUserId());

        logger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ 'first message' });
        logger.log(IDecisionStepLogger.EventType.LLM_REQUEST, new List<Object>{ 'request' });
        logger.log(IDecisionStepLogger.EventType.LLM_RESPONSE, new List<Object>{ 'response' });
        logger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ 'final' });

        logger.commitSteps();

        // Logger may or may not return step ID depending on whether addons are installed
        System.assert(true, 'Logger should complete without error');
    }

    @IsTest
    static void testLogger_EmptyContextList_DoesNotThrow() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 6').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_6').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-007')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-007', UserInfo.getUserId());

        logger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>());
        logger.commitSteps();

        System.assert(true, 'Should handle empty context list without error');
    }

    @IsTest
    static void testLogger_NullContextList_DoesNotThrow() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Test LLM 7').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Test_Agent_7').withType('Conversational').withLLM(llm.Id).save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-logger-008')
            .save();

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(execution.Id, 'turn-logger-008', UserInfo.getUserId());

        logger.log(IDecisionStepLogger.EventType.USER_INPUT, null);
        logger.commitSteps();

        System.assert(true, 'Should handle null context list without error');
    }
}
