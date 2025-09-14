/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@isTest
private class AgentDecisionStepLoggerTest {
    @TestSetup
    static void makeData() {
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @isTest
    static void testConstructorWithSessionIdAndTurnIdentifier() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-001';

        // Test constructor
        Test.startTest();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);
        Test.stopTest();

        // Assertions
        System.assertNotEquals(null, logger, 'Logger should be instantiated');
    }

    @isTest
    static void testConstructorWithSessionIdTurnIdentifierAndUserId() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        User testUser = [SELECT Id FROM User WHERE IsActive = TRUE LIMIT 1];

        String turnIdentifier = 'test-turn-002';

        // Test constructor
        Test.startTest();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier, testUser.Id);
        Test.stopTest();

        // Assertions
        System.assertNotEquals(null, logger, 'Logger should be instantiated');
    }

    @isTest
    static void testLogUserInput() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-003';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logUserInput method
        Test.startTest();
        logger.logUserInput('User Input', 'Hello, how are you?', 100);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('User Input', steps[0].StepType__c, 'Step type should be User Input');
        System.assertEquals('User Input', steps[0].Title__c, 'Title should match');
        System.assertEquals('User provided input to the AI agent', steps[0].Description__c, 'Description should match');
        System.assertEquals('Hello, how are you?', steps[0].ContentJson__c, 'Content should match');
        System.assertEquals(100, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogContextGathering() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-004';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logContextGathering method
        Test.startTest();
        logger.logContextGathering('Context Gathering', 'Gathered user context', '{"userId": "123"}', 200);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Context Gathering', steps[0].StepType__c, 'Step type should be Context Gathering');
        System.assertEquals('Context Gathering', steps[0].Title__c, 'Title should match');
        System.assertEquals('Gathered user context', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"userId": "123"}', steps[0].ContentJson__c, 'Content should match');
        System.assertEquals(200, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogContextGatheringWithFormatting() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-005';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logContextGatheringWithFormatting method
        Test.startTest();
        logger.logContextGatheringWithFormatting(
            'Context Gathering with Formatting',
            'Gathered and formatted user context',
            '{"userId": "123", "name": "John"}',
            'User: John (ID: 123)',
            250
        );
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, FormattedContext__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Context Gathering', steps[0].StepType__c, 'Step type should be Context Gathering');
        System.assertEquals('Context Gathering with Formatting', steps[0].Title__c, 'Title should match');
        System.assertEquals('Gathered and formatted user context', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"userId": "123", "name": "John"}', steps[0].ContentJson__c, 'Raw context should match');
        System.assertEquals('User: John (ID: 123)', steps[0].FormattedContext__c, 'Formatted context should match');
        System.assertEquals(250, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogSystemPromptConstruction() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-006';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logSystemPromptConstruction method
        Test.startTest();
        logger.logSystemPromptConstruction(
            'System Prompt Construction',
            'Constructed system prompt for agent',
            'You are a helpful AI assistant...',
            300
        );
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, FormattedContext__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('System Prompt Construction', steps[0].StepType__c, 'Step type should be System Prompt Construction');
        System.assertEquals('System Prompt Construction', steps[0].Title__c, 'Title should match');
        System.assertEquals('Constructed system prompt for agent', steps[0].Description__c, 'Description should match');
        System.assertEquals('You are a helpful AI assistant...', steps[0].FormattedContext__c, 'Prompt content should match');
        System.assertEquals(300, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogLLMRequest() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-007';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logLLMRequest method
        Test.startTest();
        logger.logLLMRequest('LLM Request', 'Sent request to LLM', '{"prompt": "Hello", "model": "gpt-3.5-turbo"}', 400);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('LLM Request', steps[0].StepType__c, 'Step type should be LLM Request');
        System.assertEquals('LLM Request', steps[0].Title__c, 'Title should match');
        System.assertEquals('Sent request to LLM', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"prompt": "Hello", "model": "gpt-3.5-turbo"}', steps[0].ContentJson__c, 'Request JSON should match');
        System.assertEquals(400, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogLLMResponse() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-008';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logLLMResponse method
        Test.startTest();
        logger.logLLMResponse('LLM Response', 'Received response from LLM', '{"response": "I am fine, thank you!"}', 500);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('LLM Response', steps[0].StepType__c, 'Step type should be LLM Response');
        System.assertEquals('LLM Response', steps[0].Title__c, 'Title should match');
        System.assertEquals('Received response from LLM', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"response": "I am fine, thank you!"}', steps[0].ContentJson__c, 'Response JSON should match');
        System.assertEquals(500, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogAvailableTools() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-009';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logAvailableTools method
        Test.startTest();
        logger.logAvailableTools(
            'Available Tools',
            'List of available tools for LLM',
            '[{"name": "calculator", "description": "Performs calculations"}]',
            150
        );
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Available Tools', steps[0].StepType__c, 'Step type should be Available Tools');
        System.assertEquals('Available Tools', steps[0].Title__c, 'Title should match');
        System.assertEquals('List of available tools for LLM', steps[0].Description__c, 'Description should match');
        System.assertEquals('[{"name": "calculator", "description": "Performs calculations"}]', steps[0].ContentJson__c, 'Tools JSON should match');
        System.assertEquals(150, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogToolExecution() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-010';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logToolExecution method (success case)
        Test.startTest();
        logger.logToolExecution('Tool Execution', 'Executed calculator tool', '{"tool": "calculator", "input": "2+2"}', 200, true, null, null);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c, IsSuccess__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Tool Execution', steps[0].StepType__c, 'Step type should be Tool Execution');
        System.assertEquals('Tool Execution', steps[0].Title__c, 'Title should match');
        System.assertEquals('Executed calculator tool', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"tool": "calculator", "input": "2+2"}', steps[0].ContentJson__c, 'Execution JSON should match');
        System.assertEquals(200, steps[0].DurationMs__c, 'Duration should match');
        System.assertEquals(true, steps[0].IsSuccess__c, 'IsSuccess should be true');
    }

    @isTest
    static void testLogToolExecutionWithError() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-011';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logToolExecution method (error case)
        Test.startTest();
        logger.logToolExecution(
            'Tool Execution Failed',
            'Failed to execute calculator tool',
            '{"tool": "calculator", "input": "invalid"}',
            250,
            false,
            'CALC_ERROR',
            'Invalid input for calculator'
        );
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c, IsSuccess__c, ErrorCode__c, ErrorMessage__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Tool Execution', steps[0].StepType__c, 'Step type should be Tool Execution');
        System.assertEquals('Tool Execution Failed', steps[0].Title__c, 'Title should match');
        System.assertEquals('Failed to execute calculator tool', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"tool": "calculator", "input": "invalid"}', steps[0].ContentJson__c, 'Execution JSON should match');
        System.assertEquals(250, steps[0].DurationMs__c, 'Duration should match');
        System.assertEquals(false, steps[0].IsSuccess__c, 'IsSuccess should be false');
        System.assertEquals('CALC_ERROR', steps[0].ErrorCode__c, 'Error code should match');
        System.assertEquals('Invalid input for calculator', steps[0].ErrorMessage__c, 'Error message should match');
    }

    @isTest
    static void testLogToolResult() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-012';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logToolResult method (success case)
        Test.startTest();
        logger.logToolResult('Tool Result', 'Result from calculator tool', '{"result": "4"}', 100, true, null, null);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c, IsSuccess__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Tool Result', steps[0].StepType__c, 'Step type should be Tool Result');
        System.assertEquals('Tool Result', steps[0].Title__c, 'Title should match');
        System.assertEquals('Result from calculator tool', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"result": "4"}', steps[0].ContentJson__c, 'Result JSON should match');
        System.assertEquals(100, steps[0].DurationMs__c, 'Duration should match');
        System.assertEquals(true, steps[0].IsSuccess__c, 'IsSuccess should be true');
    }

    @isTest
    static void testLogFinalResponse() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-013';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logFinalResponse method
        Test.startTest();
        logger.logFinalResponse('Final Response', 'Final response to user', 'I am doing well, thank you for asking!', 350);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Final Response', steps[0].StepType__c, 'Step type should be Final Response');
        System.assertEquals('Final Response', steps[0].Title__c, 'Title should match');
        System.assertEquals('Final response to user', steps[0].Description__c, 'Description should match');
        System.assertEquals('I am doing well, thank you for asking!', steps[0].ContentJson__c, 'Response content should match');
        System.assertEquals(350, steps[0].DurationMs__c, 'Duration should match');
    }

    @isTest
    static void testLogError() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-014';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test logError method
        Test.startTest();
        logger.logError('Error Occurred', 'Failed to process user input', 'INPUT_ERROR', 'Invalid input format', '{"input": "malformed json"}', 50);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, Title__c, Description__c, ContentJson__c, DurationMs__c, IsSuccess__c, ErrorCode__c, ErrorMessage__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals('Error', steps[0].StepType__c, 'Step type should be Error');
        System.assertEquals('Error Occurred', steps[0].Title__c, 'Title should match');
        System.assertEquals('Failed to process user input', steps[0].Description__c, 'Description should match');
        System.assertEquals('{"input": "malformed json"}', steps[0].ContentJson__c, 'Error details should match');
        System.assertEquals(50, steps[0].DurationMs__c, 'Duration should match');
        System.assertEquals(false, steps[0].IsSuccess__c, 'IsSuccess should be false');
        System.assertEquals('INPUT_ERROR', steps[0].ErrorCode__c, 'Error code should match');
        System.assertEquals('Invalid input format', steps[0].ErrorMessage__c, 'Error message should match');
    }

    @isTest
    static void testCommitStepsWithMultipleSteps() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-015';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Log multiple steps
        Test.startTest();
        logger.logUserInput('User Input', 'Hello', 100);
        logger.logContextGathering('Context Gathering', 'Gathered context', '{"userId": "123"}', 200);
        logger.logLLMRequest('LLM Request', 'Sent to LLM', '{"prompt": "Hello"}', 300);
        logger.commitSteps();
        Test.stopTest();

        // Verify all steps were created
        List<AgentDecisionStep__c> steps = [
            SELECT Id, StepType__c, StepOrder__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
            ORDER BY StepOrder__c ASC
        ];

        System.assertEquals(3, steps.size(), 'Three steps should be created');
        System.assertEquals('User Input', steps[0].StepType__c, 'First step should be User Input');
        System.assertEquals('Context Gathering', steps[1].StepType__c, 'Second step should be Context Gathering');
        System.assertEquals('LLM Request', steps[2].StepType__c, 'Third step should be LLM Request');

        // Verify step order is sequential
        System.assertEquals(1, steps[0].StepOrder__c, 'First step should have order 1');
        System.assertEquals(2, steps[1].StepOrder__c, 'Second step should have order 2');
        System.assertEquals(3, steps[2].StepOrder__c, 'Third step should have order 3');
    }

    @isTest
    static void testCommitStepsWithNoSteps() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        String turnIdentifier = 'test-turn-016';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier);

        // Test commitSteps with no steps logged
        Test.startTest();
        logger.commitSteps();
        Test.stopTest();

        // Verify no steps were created
        List<AgentDecisionStep__c> steps = [
            SELECT Id
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(0, steps.size(), 'No steps should be created');
    }

    @isTest
    static void testLoggerWithUserInformation() {
        ChatSession__c testSession = [SELECT Id FROM ChatSession__c LIMIT 1];

        User testUser = [SELECT Id FROM User WHERE IsActive = TRUE LIMIT 1];

        String turnIdentifier = 'test-turn-017';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(testSession.Id, turnIdentifier, testUser.Id);

        // Test logging with user information
        Test.startTest();
        logger.logUserInput('User Input', 'Hello', 100);
        logger.commitSteps();
        Test.stopTest();

        // Verify the step was created with user information
        List<AgentDecisionStep__c> steps = [
            SELECT Id, OriginalUser__c, ExecutionUser__c
            FROM AgentDecisionStep__c
            WHERE ChatSession__c = :testSession.Id AND TurnIdentifier__c = :turnIdentifier
        ];

        System.assertEquals(1, steps.size(), 'One step should be created');
        System.assertEquals(testUser.Id, steps[0].OriginalUser__c, 'OriginalUser should match');
        System.assertEquals(UserInfo.getUserId(), steps[0].ExecutionUser__c, 'ExecutionUser should match current user');
    }
}
