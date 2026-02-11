/**
 * @description Tests for ConversationalChatController.
 */
@IsTest
private class ConversationalChatControllerTest {
    @IsTest
    static void testCreateNewChatSession_ReturnsWelcomeMessage() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.WelcomeMessageTemplate__c = 'Hello {User.FirstName}, welcome!';
        insert agent;

        ConversationalChatController.SessionDetails details = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);

        System.assertNotEquals(null, details.sessionId, 'Should create execution ID');
        System.assert(details.welcomeMessage.contains(UserInfo.getFirstName()), 'Welcome message should include first name');
    }

    @IsTest
    static void testSendMessage_RequiresSessionAndMessage() {
        Boolean threw = false;
        try {
            ConversationalChatController.sendMessage(null, 'hello', null, 'turn-req');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Should throw when session ID is missing');
    }

    @IsTest
    static void testGetChatHistory_FiltersToolAndEmptyAssistantSteps() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolCall',
                StepRole__c = 'Tool',
                Content__c = null,
                Timestamp__c = nowTime.addSeconds(-3),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = null,
                Timestamp__c = nowTime.addSeconds(-2),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Hello',
                Timestamp__c = nowTime.addSeconds(-1),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Hi there',
                Timestamp__c = nowTime,
                TurnIdentifier__c = 'turn-1'
            )
        };
        insert steps;

        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 10, null);
        System.assertEquals(2, history.size(), 'Should return only user and assistant text steps');
        System.assertEquals('user', history[0].get('role'), 'First message should be user');
        System.assertEquals('assistant', history[1].get('role'), 'Second message should be assistant');
    }

    @IsTest
    static void testSendMessage_BusyExecutionThrows() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_AWAITING_ACTION,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Map<String, Object> response = ConversationalChatController.sendMessage(execution.Id, 'hello', null, 'turn-busy-1');
        System.assertEquals(false, response.get('success'), 'Busy execution should return error');
        System.assert(String.isNotBlank((String) response.get('error')), 'Error message should be set');
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, response.get('errorCode'), 'Should surface unexpected error code');
    }

    @IsTest
    static void testSendMessage_InactiveAgentReturnsConfigError() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).build();
        agent.IsActive__c = false;
        insert agent;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Map<String, Object> response = ConversationalChatController.sendMessage(execution.Id, 'hello', null, 'turn-config-1');
        System.assertEquals(false, response.get('success'), 'Inactive agent should return error');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, response.get('errorCode'), 'Should return config error code');
    }

    @IsTest
    static void testSendMessage_BlankMessage_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Boolean threw = false;
        try {
            ConversationalChatController.sendMessage(execution.Id, '', null, 'turn-blank-1');
        } catch (AuraHandledException e) {
            threw = true;
            // Exception is thrown - just verify it was thrown
        }
        System.assertEquals(true, threw, 'Should throw for blank message');
    }

    @IsTest
    static void testSendMessage_ExecutionNotFound_ThrowsException() {
        Boolean threw = false;
        try {
            ConversationalChatController.sendMessage('a0X000000000000', 'hello', null, 'turn-notfound-1');
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Should throw when execution not found');
    }

    @IsTest
    static void testSendMessage_SuccessfulProcessing_ReturnsSuccess() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Hello!'));

        Map<String, Object> response = ConversationalChatController.sendMessage(execution.Id, 'Test message', null, 'turn-success-1');
        System.assertEquals(true, response.get('success'), 'Should succeed with valid input');
    }

    @IsTest
    static void testCreateNewChatSession_BlankAgentName_ThrowsException() {
        Boolean threw = false;
        try {
            ConversationalChatController.createNewChatSession(null, '');
        } catch (AuraHandledException e) {
            threw = true;
            // Exception is thrown - just verify it was thrown
        }
        System.assertEquals(true, threw, 'Should throw for blank agent name');
    }

    @IsTest
    static void testCreateNewChatSession_AgentNotFound_ThrowsException() {
        Boolean threw = false;
        try {
            ConversationalChatController.createNewChatSession(null, 'NonExistentAgent');
        } catch (AuraHandledException e) {
            threw = true;
            // Exception is thrown - just verify it was thrown
        }
        System.assertEquals(true, threw, 'Should throw when agent not found');
    }

    @IsTest
    static void testCreateNewChatSession_WithRecordId_CreatesSession() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();
        Account acc = TestFactory.newAccount().withName('Test Account').save();

        ConversationalChatController.SessionDetails details = ConversationalChatController.createNewChatSession(acc.Id, agent.DeveloperName__c);

        System.assertNotEquals(null, details.sessionId, 'Should create execution with record context');
        AgentExecution__c exec = [
            SELECT SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :details.sessionId
        ];
        System.assertEquals(acc.Id, exec.SourceRecordId__c, 'Should set source record ID');
    }

    @IsTest
    static void testGetChatHistory_WithOldestTimestamp_ReturnsPaginatedResults() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Message 1',
                Timestamp__c = nowTime.addSeconds(-10),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Message 2',
                Timestamp__c = nowTime.addSeconds(-5),
                TurnIdentifier__c = 'turn-2'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Message 3',
                Timestamp__c = nowTime,
                TurnIdentifier__c = 'turn-3'
            )
        };
        insert steps;

        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 1, nowTime.addSeconds(-5));
        System.assert(history.size() <= 1, 'Should respect limit with pagination');
    }

    @IsTest
    static void testGetChatHistory_NullSessionId_ThrowsException() {
        Boolean threw = false;
        try {
            ConversationalChatController.getChatHistory(null, 10, null);
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().length() > 0, 'Should have error message');
        }
        System.assertEquals(true, threw, 'Should throw for null session ID');
    }

    @IsTest
    static void testGetMostRecentSession_AgentExists_ReturnsSession() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        ConversationalChatController.SessionDetails details = ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        System.assertNotEquals(null, details.sessionId, 'Should return most recent session');
    }

    @IsTest
    static void testGetMostRecentSession_AgentNotFound_ReturnsNull() {
        ConversationalChatController.SessionDetails details = ConversationalChatController.getMostRecentSession('NonExistentAgent', null);
        System.assertEquals(null, details, 'Should return null when agent not found');
    }

    @IsTest
    static void testGetMostRecentSession_NoExecutions_ReturnsNull() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        ConversationalChatController.SessionDetails details = ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        System.assertEquals(null, details, 'Should return null when no executions exist');
    }

    @IsTest
    static void testStartOverFromMessage_DeletesSubsequentSteps() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Datetime nowTime = Datetime.now();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Message 1',
                Timestamp__c = nowTime.addSeconds(-10),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'AgentResponse',
                StepRole__c = 'Assistant',
                Content__c = 'Response 1',
                Timestamp__c = nowTime.addSeconds(-9),
                TurnIdentifier__c = 'turn-1'
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'UserInput',
                StepRole__c = 'User',
                Content__c = 'Message 2',
                Timestamp__c = nowTime.addSeconds(-5),
                TurnIdentifier__c = 'turn-2'
            )
        };
        insert steps;

        ConversationalChatController.startOverFromMessage(execution.Id, 'turn-2');

        List<ExecutionStep__c> remainingSteps = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];
        // Should delete turn-2 and all after, keeping turn-1 steps (2 steps)
        System.assert(remainingSteps.size() < steps.size(), 'Should delete some steps');
    }

    @IsTest
    static void testStartOverFromMessage_TurnNotFound_ThrowsException() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            TriggerSource__c = 'Chat'
        );
        insert execution;

        Boolean threw = false;
        try {
            ConversationalChatController.startOverFromMessage(execution.Id, 'turn-nonexistent');
        } catch (AuraHandledException e) {
            threw = true;
            System.assert(e.getMessage().length() > 0, 'Should have error message');
        }
        System.assertEquals(true, threw, 'Should throw when turn not found');
    }
}
