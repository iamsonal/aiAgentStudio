/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Test class for ParallelToolCallHandler to verify parallel tool execution functionality
 */
@IsTest
public class ParallelToolCallHandlerTest {

    @TestSetup
    static void setupTestData() {
        // Use TestFactory to create proper test data with standard capabilities
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup()
            .withStandardActions()
            .save();
    }

    @IsTest
    static void testAllSynchronousTools() {
        // Get test data from @TestSetup
        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Get sync capabilities from test setup
        List<AgentCapability__c> syncCapabilities = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE RunAsynchronously__c = false
            LIMIT 2
        ];

        System.assert(syncCapabilities.size() >= 2, 'Should have at least 2 sync capabilities for testing');

        // Create mock orchestration context using @TestSetup data
        OrchestrationContext context = createMockOrchestrationContextFromSetup(agentDef.Id, execution.Id);

        // Create mock requested actions for sync tools only
        List<Map<String, String>> requestedActions = new List<Map<String, String>>();
        requestedActions.add(new Map<String, String>{
            'id' => 'call_1',
            'name' => syncCapabilities[0].CapabilityName__c,
            'arguments' => '{"param1": "value1"}'
        });
        requestedActions.add(new Map<String, String>{
            'id' => 'call_2',
            'name' => syncCapabilities[1].CapabilityName__c,
            'arguments' => '{"param2": "value2"}'
        });

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(execution.Id, 'test-turn', UserInfo.getUserId());

        Test.startTest();
        String result = ParallelToolCallHandler.handleParallelToolCalls(context, requestedActions, decisionLogger);
        Test.stopTest();

        // For all sync tools, should return QUEUED_FOLLOWUP (no async tools to wait for)
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, result,
                           'All sync tools should return QUEUED_FOLLOWUP outcome');
    }

    @IsTest
    static void testAllAsynchronousTools() {
        // Get test data from @TestSetup
        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Get existing capabilities and make them async for testing
        List<AgentCapability__c> existingCapabilities = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            LIMIT 2
        ];

        // Update existing capabilities to be async
        for (AgentCapability__c cap : existingCapabilities) {
            cap.RunAsynchronously__c = true;
        }
        update existingCapabilities;

        // Create mock orchestration context using @TestSetup data
        OrchestrationContext context = createMockOrchestrationContextFromSetup(agentDef.Id, execution.Id);

        // Create mock requested actions for async tools only
        List<Map<String, String>> requestedActions = new List<Map<String, String>>();
        requestedActions.add(new Map<String, String>{
            'id' => 'call_1',
            'name' => existingCapabilities[0].CapabilityName__c,
            'arguments' => '{"param1": "value1"}'
        });
        requestedActions.add(new Map<String, String>{
            'id' => 'call_2',
            'name' => existingCapabilities[1].CapabilityName__c,
            'arguments' => '{"param2": "value2"}'
        });

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(execution.Id, 'test-turn', UserInfo.getUserId());

        Test.startTest();
        String result = ParallelToolCallHandler.handleParallelToolCalls(context, requestedActions, decisionLogger);
        Test.stopTest();

        // For all async tools, should return QUEUED_ACTION (waiting for async tools to complete)
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, result,
                           'All async tools should return QUEUED_ACTION outcome');
    }

    @IsTest
    static void testMixedSyncAndAsyncTools() {
        // Get test data from @TestSetup
        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Get existing capabilities
        List<AgentCapability__c> existingCapabilities = [
            SELECT Id, CapabilityName__c, RunAsynchronously__c
            FROM AgentCapability__c
            LIMIT 2
        ];

        // Make one sync and one async
        existingCapabilities[0].RunAsynchronously__c = false;
        existingCapabilities[1].RunAsynchronously__c = true;
        update existingCapabilities;

        // Create mock orchestration context using @TestSetup data
        OrchestrationContext context = createMockOrchestrationContextFromSetup(agentDef.Id, execution.Id);

        // Create mock requested actions for mixed sync and async tools
        List<Map<String, String>> requestedActions = new List<Map<String, String>>();
        requestedActions.add(new Map<String, String>{
            'id' => 'call_1',
            'name' => existingCapabilities[0].CapabilityName__c,
            'arguments' => '{"param1": "value1"}'
        });
        requestedActions.add(new Map<String, String>{
            'id' => 'call_2',
            'name' => existingCapabilities[1].CapabilityName__c,
            'arguments' => '{"param2": "value2"}'
        });

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(execution.Id, 'test-turn', UserInfo.getUserId());

        Test.startTest();
        String result = ParallelToolCallHandler.handleParallelToolCalls(context, requestedActions, decisionLogger);
        Test.stopTest();

        // For mixed tools, should return QUEUED_ACTION (waiting for async tools to complete)
        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, result,
                           'Mixed sync/async tools should return QUEUED_ACTION outcome');
    }

    @IsTest
    static void testInvalidToolCalls() {
        // Get test data from @TestSetup
        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Create mock orchestration context using @TestSetup data
        OrchestrationContext context = createMockOrchestrationContextFromSetup(agentDef.Id, execution.Id);

        // Create mock requested actions with invalid tool names
        List<Map<String, String>> requestedActions = new List<Map<String, String>>();
        requestedActions.add(new Map<String, String>{
            'id' => 'call_1',
            'name' => 'nonExistentTool',
            'arguments' => '{"param1": "value1"}'
        });
        requestedActions.add(new Map<String, String>{
            'id' => 'call_2',
            'name' => 'anotherNonExistentTool',
            'arguments' => '{"param2": "value2"}'
        });

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(execution.Id, 'test-turn', UserInfo.getUserId());

        Test.startTest();
        String result = ParallelToolCallHandler.handleParallelToolCalls(context, requestedActions, decisionLogger);
        Test.stopTest();

        // For invalid tools, should return FAILED
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, result,
                           'Invalid tool calls should return FAILED outcome');
    }

    @IsTest
    static void testParallelResultGatherer() {
        // Get test data from @TestSetup
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        String turnIdentifier = 'test-turn-123';
        Integer currentTurnCount = 1;
        String logPrefix = '[Test] ';

        Test.startTest();

        // Test the result gatherer (should not throw exceptions)
        ParallelResultGatherer.checkAndTriggerFinalFollowUp(
            execution.Id,
            turnIdentifier,
            currentTurnCount,
            logPrefix
        );

        // Test async tool completion
        ParallelResultGatherer.onAsyncToolCompleted(
            execution.Id,
            turnIdentifier,
            currentTurnCount,
            'test-tool-call-id',
            logPrefix
        );

        Test.stopTest();

        // Verify no exceptions were thrown
        System.assert(true, 'ParallelResultGatherer methods should execute without exceptions');
    }

    @IsTest
    static void testToolCallRequestDataStructure() {
        // Get test data from @TestSetup
        AgentCapability__c capability = [SELECT Id FROM AgentCapability__c LIMIT 1];

        Test.startTest();

        // Test ToolCallRequest
        ParallelToolCallHandler.ToolCallRequest toolRequest = new ParallelToolCallHandler.ToolCallRequest(
            'test-call-id',
            'testTool',
            '{"param": "value"}',
            capability,
            false,
            1
        );

        System.assertEquals('test-call-id', toolRequest.toolCallId, 'Tool call ID should match');
        System.assertEquals('testTool', toolRequest.toolName, 'Tool name should match');
        System.assertEquals(false, toolRequest.isAsync, 'Should be synchronous');
        System.assertEquals(1, toolRequest.executionOrder, 'Execution order should match');

        // Test ToolExecutionResult
        ActionOutcome outcome = ActionOutcome.success('Test result');
        ParallelToolCallHandler.ToolExecutionResult result = new ParallelToolCallHandler.ToolExecutionResult(
            'test-call-id',
            'testTool',
            outcome,
            100L,
            false,
            1
        );

        System.assertEquals('test-call-id', result.toolCallId, 'Result tool call ID should match');
        System.assertEquals('testTool', result.toolName, 'Result tool name should match');
        System.assertEquals(true, result.outcome.isSuccess, 'Outcome should be successful');
        System.assertEquals(100L, result.processingTime, 'Processing time should match');

        Test.stopTest();
    }

    /**
     * Helper method to get test setup
     */
    private static TestFactory.AgentSetup getTestSetup() {
        return TestFactory.createFullAgentSetup().save();
    }

    /**
     * Helper method to create a mock orchestration context from @TestSetup data
     */
    private static OrchestrationContext createMockOrchestrationContextFromSetup(Id agentDefinitionId, Id executionId) {
        // Create mock provider result
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = 'Test response';
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.modelIdentifier = 'gpt-4';
        providerResult.llmCalloutDurationMs = 1000L;
        providerResult.requestedActions = new List<Map<String, String>>();

        // Create mock assistant message data
        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = 'Test response';
        assistantData.processingTimeMs = 100;

        // Create mock LLM result using the success constructor
        LLMInteractionService.LLMInteractionResult llmResult =
            new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create mock message data
        LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
        userMessageData.role = 'user';
        userMessageData.content = 'Test message';

        // Create mock services
        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        CapabilityExecutionRouter actionExecSvc = new CapabilityExecutionRouter();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);
        ContextManagerService contextManagerSvc = new ContextManagerService();

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, 'test-turn', UserInfo.getUserId());

        return new OrchestrationContext(
            llmResult,
            executionId, // executionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            agentDefinitionId, // agentDefinitionId
            'test-turn', // turnIdentifier
            1, // currentTurnCount
            userMessageData,
            turnLifecycleSvc,
            actionExecSvc,
            orchestrationDispatchSvc,
            contextManagerSvc,
            null, // currentPageRecordId
            decisionLogger
        );
    }

    /**
     * Helper method to create a mock orchestration context
     */
    private static OrchestrationContext createMockOrchestrationContext(TestFactory.AgentSetup setup) {
        // Create mock provider result
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = 'Test response';
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.modelIdentifier = 'gpt-4';
        providerResult.llmCalloutDurationMs = 1000L;
        providerResult.requestedActions = new List<Map<String, String>>();

        // Create mock assistant message data
        LLMInteractionService.MessageData assistantData = new LLMInteractionService.MessageData();
        assistantData.role = 'assistant';
        assistantData.content = 'Test response';
        assistantData.processingTimeMs = 100;

        // Create mock LLM result using the success constructor
        LLMInteractionService.LLMInteractionResult llmResult =
            new LLMInteractionService.LLMInteractionResult(providerResult, assistantData);

        // Create mock message data
        LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
        userMessageData.role = 'user';
        userMessageData.content = 'Test message';

        // Create mock services
        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        CapabilityExecutionRouter actionExecSvc = new CapabilityExecutionRouter();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);
        ContextManagerService contextManagerSvc = new ContextManagerService();

        // Create mock decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(setup.agentExecution.Id, 'test-turn', UserInfo.getUserId());

        return new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id, // executionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            setup.agentDefinition.Id, // agentDefinitionId
            'test-turn', // turnIdentifier
            1, // currentTurnCount
            userMessageData,
            turnLifecycleSvc,
            actionExecSvc,
            orchestrationDispatchSvc,
            contextManagerSvc,
            null, // currentPageRecordId
            decisionLogger
        );
    }
}
