/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Test class for ConversationalChatController
 * Tests all @AuraEnabled methods for LWC chat component integration
 */
@IsTest
private class ConversationalChatControllerTest {
    @TestSetup
    static void makeData() {
        // Create full agent setup
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();
        insert setup.llmConfig;

        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        insert setup.agentDefinition;

        // Link capabilities to agent
        for (AgentCapability__c cap : setup.capabilities) {
            cap.AIAgentDefinition__c = setup.agentDefinition.Id;
        }
        insert setup.capabilities;

        // Link context configs to agent
        for (AgentContextConfig__c config : setup.contextConfigs) {
            config.AIAgentDefinition__c = setup.agentDefinition.Id;
        }
        insert setup.contextConfigs;

        // Create a test execution
        AgentExecution__c execution = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        execution.ProcessingStatus__c = AIAgentConstants.STATUS_IDLE;
        execution.ExecutionType__c = 'Conversational';
        insert execution;

        // Create some chat messages
        List<ExecutionStep__c> messages = TestFactory.createChatMessages(execution.Id, 3);
        insert messages;
    }

    // =============================================================================
    // sendMessage() Tests
    // =============================================================================

    @IsTest
    static void sendMessage_withoutServiceUserContext_success() {
        // Get test data
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Ensure agent doesn't require service user context
        agent.RequiresServiceUserContext__c = false;
        update agent;

        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            execution.Id,
            'Hello, can you help me?',
            null,
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'), 'Response should be successful');
        System.assertEquals(execution.Id, response.get('sessionId'), 'Should return correct session ID');
        System.assertNotEquals(null, response.get('message'), 'Should have a message');
    }

    @IsTest
    static void sendMessage_withServiceUserContext_routesViaRest() {
        // Get test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Ensure agent requires service user context
        agent.RequiresServiceUserContext__c = true;
        update agent;

        // Update execution to reference the agent
        execution.AIAgentDefinition__c = agent.Id;
        update execution;

        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            execution.Id,
            'Hello, can you help me?',
            null,
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'), 'Response should be successful via REST');
        System.assertEquals(execution.Id, response.get('sessionId'), 'Should return correct session ID');
    }

    @IsTest
    static void sendMessage_withRecordContext_success() {
        // Get test data
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        agent.RequiresServiceUserContext__c = false;
        update agent;

        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Test.startTest();
        Map<String, Object> response = ConversationalChatController.sendMessage(
            execution.Id,
            'Tell me about this account',
            execution.Id, // Using execution ID as record context
            'test-turn-' + Datetime.now().getTime()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'), 'Response should be successful');
    }

    // =============================================================================
    // createNewChatSession() Tests
    // =============================================================================

    @IsTest
    static void createNewChatSession_withAgentName_success() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);
        Test.stopTest();

        System.assertNotEquals(null, session, 'Should return session details');
        System.assertNotEquals(null, session.sessionId, 'Should have session ID');
        System.assertNotEquals(null, session.welcomeMessage, 'Should have welcome message');
        System.assertEquals(true, session.transientMessagesEnabled, 'Transient messages should be enabled');

        // Verify execution was created
        AgentExecution__c execution = [SELECT Id, ExecutionType__c, User__c FROM AgentExecution__c WHERE Id = :session.sessionId];
        System.assertEquals('Conversational', execution.ExecutionType__c, 'Should be conversational type');
        System.assertEquals(UserInfo.getUserId(), execution.User__c, 'Should be for current user');
    }

    @IsTest
    static void createNewChatSession_withRecordId_success() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c recordContext = [SELECT Id FROM AgentExecution__c LIMIT 1];

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.createNewChatSession(
            recordContext.Id,
            agent.DeveloperName__c
        );
        Test.stopTest();

        System.assertNotEquals(null, session, 'Should return session details');
        System.assertNotEquals(null, session.sessionId, 'Should have session ID');

        // Verify execution has source record
        AgentExecution__c execution = [SELECT Id, SourceRecordId__c FROM AgentExecution__c WHERE Id = :session.sessionId];
        System.assertEquals(recordContext.Id, execution.SourceRecordId__c, 'Should have source record context');
    }

    @IsTest
    static void createNewChatSession_welcomeMessageTemplate_processesCorrectly() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // Update welcome message template
        agent.WelcomeMessageTemplate__c = 'Hello {User.FirstName}, I am {User.Name}!';
        update agent;

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);
        Test.stopTest();

        System.assert(session.welcomeMessage.contains(UserInfo.getFirstName()), 'Should contain user first name');
        System.assert(session.welcomeMessage.contains(UserInfo.getName()), 'Should contain user full name');
    }

    @IsTest
    static void createNewChatSession_invalidAgentName_throwsException() {
        Test.startTest();
        try {
            ConversationalChatController.createNewChatSession(null, 'NonExistentAgent');
            System.assert(false, 'Should have thrown exception');
        } catch (AuraHandledException e) {
            System.assertNotEquals(null, e.getMessage(), 'Should have error message');
        }
        Test.stopTest();
    }

    // =============================================================================
    // getChatHistory() Tests
    // =============================================================================

    @IsTest
    static void getChatHistory_returnsMessages() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 50, null);
        Test.stopTest();

        System.assert(!history.isEmpty(), 'Should return messages');

        // Verify message structure
        Map<String, Object> firstMessage = history[0];
        System.assert(firstMessage.containsKey('id'), 'Should have id');
        System.assert(firstMessage.containsKey('role'), 'Should have role');
        System.assert(firstMessage.containsKey('content'), 'Should have content');
        System.assert(firstMessage.containsKey('timestamp'), 'Should have timestamp');
    }

    @IsTest
    static void getChatHistory_withLimit_returnsLimitedResults() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Create many messages
        List<ExecutionStep__c> manyMessages = TestFactory.createChatMessages(execution.Id, 20);
        insert manyMessages;

        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 5, null);
        Test.stopTest();

        System.assert(history.size() <= 5, 'Should respect limit');
    }

    @IsTest
    static void getChatHistory_withOlderThanTimestamp_filtersCorrectly() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Get a timestamp in the middle
        List<ExecutionStep__c> allSteps = [
            SELECT Id, Timestamp__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
            ORDER BY Timestamp__c DESC
        ];

        if (!allSteps.isEmpty()) {
            Datetime midTimestamp = allSteps[0].Timestamp__c;

            Test.startTest();
            List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 50, midTimestamp);
            Test.stopTest();

            // All returned messages should be older than midTimestamp
            for (Map<String, Object> msg : history) {
                Datetime msgTimestamp = (Datetime) msg.get('timestamp');
                System.assert(msgTimestamp < midTimestamp, 'Should only return older messages');
            }
        }
    }

    @IsTest
    static void getChatHistory_filtersToolRoles() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Add a tool message
        ExecutionStep__c toolMessage = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepRole__c = AIAgentConstants.ROLE_TOOL,
            Content__c = 'Tool result',
            Timestamp__c = Datetime.now(),
            ExternalId__c = UuidUtils.generateUUID(),
            StepType__c = 'ToolResult'
        );
        insert toolMessage;

        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 50, null);
        Test.stopTest();

        // Verify no tool messages are returned
        for (Map<String, Object> msg : history) {
            System.assertNotEquals(AIAgentConstants.ROLE_TOOL, msg.get('role'), 'Should filter out tool messages');
        }
    }

    @IsTest
    static void getChatHistory_filtersInternalSteps() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Add an internal message
        ExecutionStep__c internalMessage = new ExecutionStep__c(
            AgentExecution__c = execution.Id,
            StepRole__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'Internal processing',
            Timestamp__c = Datetime.now(),
            ExternalId__c = UuidUtils.generateUUID(),
            StepType__c = 'AgentResponse',
            IsInternal__c = true
        );
        insert internalMessage;

        Test.startTest();
        List<Map<String, Object>> history = ConversationalChatController.getChatHistory(execution.Id, 50, null);
        Test.stopTest();

        // Verify no internal messages are returned
        for (Map<String, Object> msg : history) {
            System.assertNotEquals('Internal processing', msg.get('content'), 'Should filter out internal messages');
        }
    }

    @IsTest
    static void getMostRecentSession_findsExistingSession() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Update execution to have recent activity
        execution.LastActivityTime__c = Datetime.now();
        update execution;

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        Test.stopTest();

        System.assertNotEquals(null, session, 'Should find existing session');
        System.assertEquals(execution.Id, session.sessionId, 'Should return correct session ID');
        System.assertNotEquals(null, session.welcomeMessage, 'Should have welcome message');
    }

    @IsTest
    static void getMostRecentSession_noExistingSession_returnsNull() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // Delete existing executions
        delete [SELECT Id FROM AgentExecution__c];

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        Test.stopTest();

        System.assertEquals(null, session, 'Should return null when no session exists');
    }

    @IsTest
    static void getMostRecentSession_invalidAgentName_returnsNull() {
        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.getMostRecentSession('NonExistentAgent', null);
        Test.stopTest();

        System.assertEquals(null, session, 'Should return null for invalid agent');
    }

    @IsTest
    static void getMostRecentSession_processesWelcomeTemplate() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // Update welcome message template
        agent.WelcomeMessageTemplate__c = 'Welcome back {User.FirstName}!';
        update agent;

        Test.startTest();
        ConversationalChatController.SessionDetails session = ConversationalChatController.getMostRecentSession(agent.DeveloperName__c, null);
        Test.stopTest();

        if (session != null) {
            System.assert(session.welcomeMessage.contains(UserInfo.getFirstName()), 'Should process welcome template');
        }
    }

    // =============================================================================
    // startOverFromMessage() Tests
    // =============================================================================

    @IsTest
    static void startOverFromMessage_deletesMessagesFromPoint() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Get messages
        List<ExecutionStep__c> messages = [
            SELECT Id, ExternalId__c, Timestamp__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
            ORDER BY Timestamp__c
        ];

        Integer originalCount = messages.size();
        System.assert(originalCount > 1, 'Should have multiple messages');

        // Get the middle message's external ID
        ExecutionStep__c middleMessage = messages[originalCount / 2];
        String externalId = middleMessage.ExternalId__c;
        Datetime middleTimestamp = middleMessage.Timestamp__c;

        Test.startTest();
        ConversationalChatController.startOverFromMessage(execution.Id, externalId);
        Test.stopTest();

        // Verify messages were deleted
        List<ExecutionStep__c> remainingMessages = [
            SELECT Id, Timestamp__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id
        ];

        System.assert(remainingMessages.size() < originalCount, 'Should have deleted messages');

        // Verify all remaining messages are before the target timestamp
        for (ExecutionStep__c msg : remainingMessages) {
            System.assert(msg.Timestamp__c < middleTimestamp, 'Should only keep messages before target');
        }
    }

    @IsTest
    static void sendMessage_success_toolCallCapability() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        agent.Concurrency__c = 'High';
        update agent;
        ConversationalChatController.SessionDetails sessionDetails = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        // No need to configure anything - the mock will intelligently respond based on request content
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = ConversationalChatController.sendMessage(
            sessionDetails.sessionId,
            'Find sales records for test query',
            null,
            UuidUtils.generateUUID()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        // For tool calls, the initial response should be "Processing..." or "Processing" since it's async
        System.assert(String.valueOf(response.get('message')).contains('Processing'), 'Should indicate processing');

        AgentExecution__c finalExecution = [SELECT ProcessingStatus__c FROM AgentExecution__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(
            AIAgentConstants.STATUS_AWAITING_FOLLOWUP,
            finalExecution.ProcessingStatus__c,
            'Should be awaiting followup after the tool execution. Actual: ' + finalExecution.ProcessingStatus__c
        );
    }

    @IsTest
    static void sendMessage_success_toolCallCapability_runAsynchronously() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        agent.Concurrency__c = 'High';
        update agent;

        // Find and update the capability to run asynchronously
        AgentCapability__c capability = [
            SELECT Id, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agent.Id AND CapabilityName__c = 'find_sales_records'
            LIMIT 1
        ];
        capability.RunAsynchronously__c = true;
        update capability;

        ConversationalChatController.SessionDetails sessionDetails = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = ConversationalChatController.sendMessage(
            sessionDetails.sessionId,
            'Find sales records for async test query',
            null,
            UuidUtils.generateUUID()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        System.assert(String.valueOf(response.get('message')).contains('Processing'), 'Should indicate processing');

        AgentExecution__c finalExecution = [SELECT ProcessingStatus__c FROM AgentExecution__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(
            AIAgentConstants.STATUS_AWAITING_ACTION,
            finalExecution.ProcessingStatus__c,
            'Should be awaiting the async action to be picked up. Actual: ' + finalExecution.ProcessingStatus__c
        );
    }

    @IsTest
    static void sendMessage_success_toolCallCapability_requiresApproval() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];
        agent.Concurrency__c = 'High';
        update agent;

        // Find and update the capability to require approval
        AgentCapability__c capability = [
            SELECT Id, RequiresApproval__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agent.Id AND CapabilityName__c = 'find_sales_records'
            LIMIT 1
        ];
        capability.RequiresApproval__c = true;
        update capability;

        ConversationalChatController.SessionDetails sessionDetails = ConversationalChatController.createNewChatSession(null, agent.DeveloperName__c);

        MockHttpResponses.reset();
        Test.setMock(HttpCalloutMock.class, new MockHttpResponses());

        Map<String, Object> response;
        Test.startTest();
        response = ConversationalChatController.sendMessage(
            sessionDetails.sessionId,
            'Find sales records for approval test query',
            null,
            UuidUtils.generateUUID()
        );
        Test.stopTest();

        System.assertEquals(true, response.get('success'));
        // For approval-required tool calls, the initial response should indicate processing
        System.assert(String.valueOf(response.get('message')).contains('Processing'), 'Should indicate processing');

        AgentExecution__c finalExecution = [SELECT ProcessingStatus__c FROM AgentExecution__c WHERE Id = :sessionDetails.sessionId];
        System.assertEquals(
            AIAgentConstants.STATUS_AWAITING_FOLLOWUP,
            finalExecution.ProcessingStatus__c,
            'Should be awaiting followup after submitting for approval. Actual: ' + finalExecution.ProcessingStatus__c
        );

        List<HumanApprovalRequest__c> approvalRequests = [
            SELECT Id, ApprovalStatus__c
            FROM HumanApprovalRequest__c
            WHERE AgentExecution__c = :sessionDetails.sessionId
        ];

        System.assertEquals(1, approvalRequests.size(), 'Should have created one approval request');
        System.assertEquals('Pending', approvalRequests[0].ApprovalStatus__c, 'Approval request should be Pending');
    }
}
