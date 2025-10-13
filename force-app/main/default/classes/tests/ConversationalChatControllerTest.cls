/**
 * @description Tests for ConversationalChatController using TestFactory utilities
 */
@IsTest
private class ConversationalChatControllerTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create conversation history for chat history tests
        AgentExecution__c execution = setup.agentExecution;
        TestFactory.createConversation(execution.Id, 3);
    }

    // ===================================================================================
    // SEND MESSAGE TESTS
    // ===================================================================================

    @IsTest
    static void testSendMessage_WithoutServiceUserContext_Success() {
        // Given: Agent and session
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        agent.RequiresServiceUserContext__c = false;
        update agent;

        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Sending message
        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            session.Id,
            'Hello, can you help me?',
            null,
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        // Then: Should succeed
        System.assertEquals(true, response.get('success'));
        System.assertEquals(session.Id, response.get('sessionId'));
        System.assertNotEquals(null, response.get('message'));
    }

    @IsTest
    static void testSendMessage_WithServiceUserContext_RoutesViaRest() {
        // Given: Agent requiring service user context
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        agent.RequiresServiceUserContext__c = true;
        update agent;

        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        session.AIAgentDefinition__c = agent.Id;
        update session;

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Sending message
        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            session.Id,
            'Hello',
            null,
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        // Then: Should route via REST
        System.assertEquals(true, response.get('success'));
        System.assertEquals(session.Id, response.get('sessionId'));
    }

    @IsTest
    static void testSendMessage_WithRecordContext_Success() {
        // Given: Session and record context
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.success());

        // When: Sending message with record context
        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            session.Id,
            'Tell me about this record',
            session.Id, // Using session ID as record context
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        // Then: Should succeed
        System.assertEquals(true, response.get('success'));
    }

    // ===================================================================================
    // CREATE SESSION TESTS
    // ===================================================================================

    @IsTest
    static void testCreateNewChatSession_WithAgentName_Success() {
        // Given: Agent developer name
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // When: Creating session
        Test.startTest();
        ConversationalChatController.SessionDetails session =
            ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);
        Test.stopTest();

        // Then: Session should be created
        System.assertNotEquals(null, session);
        System.assertNotEquals(null, session.sessionId);
        System.assertNotEquals(null, session.welcomeMessage);
        System.assertEquals(true, session.transientMessagesEnabled);

        // Verify execution record
        AgentExecution__c execution = [SELECT ExecutionType__c, User__c
                                       FROM AgentExecution__c
                                       WHERE Id = :session.sessionId];
        System.assertEquals('Conversational', execution.ExecutionType__c);
        System.assertEquals(UserInfo.getUserId(), execution.User__c);
    }

    @IsTest
    static void testCreateNewChatSession_WithRecordId_Success() {
        // Given: Agent and record context
        AIAgentDefinition__c agent = [SELECT DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c recordContext = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // When: Creating session with record context
        Test.startTest();
        ConversationalChatController.SessionDetails session =
            ConversationalChatController.createNewChatSession(recordContext.Id, agent.DeveloperName__c);
        Test.stopTest();

        // Then: Should have source record
        AgentExecution__c execution = [SELECT SourceRecordId__c
                                       FROM AgentExecution__c
                                       WHERE Id = :session.sessionId];
        System.assertEquals(recordContext.Id, execution.SourceRecordId__c);
    }

    @IsTest
    static void testCreateNewChatSession_InvalidAgent_ThrowsException() {
        // When/Then: Should throw exception for invalid agent
        Test.startTest();
        try {
            ConversationalChatController.createNewChatSession(null, 'NonExistentAgent');
            System.assert(false, 'Should have thrown exception');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage());
        }
        Test.stopTest();
    }

    // ===================================================================================
    // CHAT HISTORY TESTS
    // ===================================================================================

    @IsTest
    static void testGetChatHistory_ReturnsMessages() {
        // Given: Execution with messages
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // When: Getting chat history
        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(
            execution.Id,
            50,
            null
        );
        Test.stopTest();

        // Then: Should return messages
        System.assert(!history.isEmpty());
        Map<String, Object> firstMessage = history[0];
        System.assert(firstMessage.containsKey('id'));
        System.assert(firstMessage.containsKey('role'));
        System.assert(firstMessage.containsKey('content'));
        System.assert(firstMessage.containsKey('timestamp'));
    }

    @IsTest
    static void testGetChatHistory_WithLimit_RespectsLimit() {
        // Given: Execution with many messages
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ExecutionStep__c> manyMessages = TestFactory.createConversation(execution.Id, 20);

        // When: Getting limited history
        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(
            execution.Id,
            5,
            null
        );
        Test.stopTest();

        // Then: Should respect limit
        System.assert(history.size() <= 5);
    }

    @IsTest
    static void testGetChatHistory_FiltersToolRoles() {
        // Given: Execution with tool message
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        ExecutionStep__c toolMessage = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepRole__c = AIAgentConstants.ROLE_TOOL,
            Content__c = 'Tool result',
            Timestamp__c = Datetime.now(),
            ExternalId__c = UuidUtils.generateUUID(),
            StepType__c = 'ToolResult'
        );
        insert toolMessage;

        // When: Getting history
        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(
            execution.Id,
            50,
            null
        );
        Test.stopTest();

        // Then: Should filter tool messages
        for (Map<String, Object> msg : history) {
            System.assertNotEquals(AIAgentConstants.ROLE_TOOL, msg.get('role'));
        }
    }

    // ===================================================================================
    // MOST RECENT SESSION TESTS
    // ===================================================================================

    @IsTest
    static void testGetMostRecentSession_FindsExisting() {
        // Given: Agent with recent session
        AIAgentDefinition__c agent = [SELECT DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        execution.LastActivityTime__c = Datetime.now();
        update execution;

        // When: Getting most recent session
        Test.startTest();
        ConversationalChatController.SessionDetails session =
            ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        Test.stopTest();

        // Then: Should find session
        System.assertNotEquals(null, session);
        System.assertEquals(execution.Id, session.sessionId);
    }

    @IsTest
    static void testGetMostRecentSession_NoExisting_ReturnsNull() {
        // Given: Agent with no sessions
        AIAgentDefinition__c agent = [SELECT DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        delete [SELECT Id FROM AgentExecution__c];

        // When: Getting most recent session
        Test.startTest();
        ConversationalChatController.SessionDetails session =
            ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, session);
    }

    // ===================================================================================
    // START OVER TESTS
    // ===================================================================================

    @IsTest
    static void testStartOverFromMessage_DeletesMessages() {
        // Given: Execution with messages
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        List<ExecutionStep__c> messages = [
            SELECT Id, ExternalId__c, Timestamp__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
            ORDER BY Timestamp__c
        ];

        Integer originalCount = messages.size();
        System.assert(originalCount > 1);

        ExecutionStep__c middleMessage = messages[originalCount / 2];

        // When: Starting over from middle message
        Test.startTest();
        ConversationalChatController.startOverFromMessage(execution.Id, middleMessage.ExternalId__c);
        Test.stopTest();

        // Then: Should delete messages after target
        List<ExecutionStep__c> remainingMessages = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];
        System.assert(remainingMessages.size() < originalCount);
    }
}
