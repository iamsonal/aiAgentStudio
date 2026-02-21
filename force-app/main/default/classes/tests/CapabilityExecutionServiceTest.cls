/**
 * @description Tests for CapabilityExecutionService capability execution and handler creation
 */
@IsTest
private class CapabilityExecutionServiceTest {
    @TestSetup
    static void setupData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Account').withName('create_account_cap').save();

        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forGetRecordDetails('Account', new List<String>{ 'Id', 'Name' })
            .withName('get_account_cap')
            .save();
    }

    @IsTest
    static void testExecuteSingleAction_NullCapability_ThrowsException() {
        AgentCapability__c capability = [
            SELECT Id, AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'create_account_cap'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-cap-001')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            capability.AIAgentDefinition__c,
            capability.Id,
            null,
            'turn-cap-001',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(null, '{}', context);
        } catch (IllegalArgumentException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('required'), 'Should indicate capability is required');
        }

        System.assert(exceptionThrown, 'Should throw IllegalArgumentException for null capability');
    }

    @IsTest
    static void testExecuteSingleAction_NullContext_ThrowsException() {
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c, ImplementationDetail__c, StandardActionType__c, ImplementationType__c, AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'create_account_cap'
            LIMIT 1
        ];

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', null);
        } catch (IllegalArgumentException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('required'), 'Should indicate context is required');
        }

        System.assert(exceptionThrown, 'Should throw IllegalArgumentException for null context');
    }

    @IsTest
    static void testExecuteSingleAction_StandardAction_ExecutesSuccessfully() {
        AgentCapability__c capability = [
            SELECT
                Id,
                CapabilityName__c,
                ImplementationDetail__c,
                StandardActionType__c,
                ImplementationType__c,
                AIAgentDefinition__c,
                BackendConfiguration__c,
                Parameters__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'create_account_cap'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-cap-002')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            capability.AIAgentDefinition__c,
            capability.Id,
            null,
            'turn-cap-002',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();

        ActionOutcome outcome = service.executeSingleAction(capability, '{"Name":"Test Account"}', context);

        System.assertNotEquals(null, outcome, 'Should return an outcome');
        System.assertEquals(true, outcome.isSuccess, 'Create account should succeed');
    }

    @IsTest
    static void testExecuteSingleAction_UnsupportedType_ThrowsException() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create a capability with Apex type for this test
        AgentCapability__c capability = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).withName('test_apex_cap').build();
        capability.ImplementationType__c = 'Apex';
        capability.ImplementationDetail__c = 'NonExistentClass';
        capability.Parameters__c = '{"type":"object","properties":{}}';
        insert capability;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-cap-003')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            capability.Id,
            null,
            'turn-cap-003',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Handler class not found'), 'Should indicate handler not found');
        }

        System.assert(exceptionThrown, 'Should throw CapabilityExecutionException for non-existent handler class');
    }

    @IsTest
    static void testExecuteSingleAction_NullArguments_DefaultsToEmptyJson() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Ensure we have at least one capability with the setup
        AgentCapability__c cap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forGetRecordDetails('Account', new List<String>{ 'Id', 'Name' })
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-null-args')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            cap.Id,
            null,
            'turn-null-args',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        // This exercises the null-safe arguments parsing path
        ActionOutcome outcome = service.executeSingleAction(cap, null, context);

        System.assertNotEquals(null, outcome, 'Should return an outcome even with null arguments');
    }

    @IsTest
    static void testExecuteSingleAction_EmptyArgumentsJson_HandledGracefully() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Ensure we have at least one capability with the setup
        AgentCapability__c cap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forGetRecordDetails('Account', new List<String>{ 'Id', 'Name' })
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-empty-args')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            cap.Id,
            null,
            'turn-empty-args',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        ActionOutcome outcome = service.executeSingleAction(cap, '{}', context);

        System.assertNotEquals(null, outcome, 'Should return an outcome with empty arguments');
    }

    @IsTest
    static void testExecuteSingleAction_StandardActionMissingType_ReturnsFailure() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withName('std_missing_type')
            .save();
        capability.StandardActionType__c = null;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-std-missing')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            capability.Id,
            null,
            'turn-std-missing',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('missing required Standard Action Type'), 'Should indicate missing standard action type');
        }

        System.assert(exceptionThrown, 'Should throw exception for missing standard action type');
    }

    @IsTest
    static void testExecuteSingleAction_ApexMissingDetail_ReturnsFailure() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCustomApex('NonExistentClass')
            .withName('apex_missing_detail')
            .build();
        capability.Parameters__c = '{"type":"object","properties":{}}';
        insert capability;
        capability.ImplementationDetail__c = null;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-apex-missing')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            capability.Id,
            null,
            'turn-apex-missing',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('missing required Implementation Detail'), 'Should indicate missing implementation detail');
        }

        System.assert(exceptionThrown, 'Should throw exception for missing implementation detail');
    }

    @IsTest
    static void testExecuteSingleAction_FlowMissingDetail_ReturnsFailure() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forFlowHandler('Test_Flow')
            .withName('flow_missing_detail')
            .save();
        capability.ImplementationDetail__c = null;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-flow-missing')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            capability.Id,
            null,
            'turn-flow-missing',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('missing required Implementation Detail'), 'Should indicate missing implementation detail');
        }

        System.assert(exceptionThrown, 'Should throw exception for missing implementation detail');
    }

    @IsTest
    static void testExecuteSingleAction_StandardHandlerNotFound_ThrowsException() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        AgentCapability__c capability = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).withName('unknown_standard_action').build();
        capability.ImplementationType__c = 'Standard';
        capability.StandardActionType__c = 'NonExistentStandardAction';
        capability.Parameters__c = '{"type":"object","properties":{}}';
        insert capability;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-handler-notfound')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            capability.Id,
            null,
            'turn-handler-notfound',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(capability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('No active StandardActionHandler'), 'Should indicate handler not found');
        }

        System.assert(exceptionThrown, 'Should throw exception for unknown standard handler');
    }

    @IsTest
    static void testExecuteSingleAction_CacheInitialization_OnlyInitializedOnce() {
        // Clear cache
        CapabilityExecutionService.clearCache_TestOnly();

        AgentCapability__c capability = [
            SELECT
                Id,
                CapabilityName__c,
                ImplementationDetail__c,
                StandardActionType__c,
                ImplementationType__c,
                AIAgentDefinition__c,
                BackendConfiguration__c,
                Parameters__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'create_account_cap'
            LIMIT 1
        ];

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(capability.AIAgentDefinition__c)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-cache-init')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            capability.AIAgentDefinition__c,
            capability.Id,
            null,
            'turn-cache-init',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();

        System.assertEquals(false, CapabilityExecutionService.isCacheInitialized, 'Cache should not be initialized initially');

        service.executeSingleAction(capability, '{"Name":"Test"}', context);

        System.assertEquals(true, CapabilityExecutionService.isCacheInitialized, 'Cache should be initialized after first execution');
        System.assertNotEquals(null, CapabilityExecutionService.standardHandlerCache, 'Cache should be populated');
    }

    /**
     * @description Tests that Flow implementation type executes successfully with ActionFlowHandler.
     *              Verifies the RunFlow standard handler is found and instantiated correctly.
     */
    @IsTest
    static void testExecuteSingleAction_FlowImplementation_ExecutesSuccessfully() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create a Flow-type capability
        AgentCapability__c flowCapability = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .withName('test_flow_cap')
            .forFlowHandler('TestFlow')
            .save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-flow-exec')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            flowCapability.Id,
            'TestFlow', // implementationDetail - Flow API name
            'turn-flow-exec',
            1,
            'Function'
        );

        // Set up flow mock for ActionFlowHandler
        ActionFlowHandler.mockFlowExecution = new TestFlowExecutionMock();

        CapabilityExecutionService service = new CapabilityExecutionService();

        Test.startTest();
        ActionOutcome outcome = service.executeSingleAction(flowCapability, '{"inputParam":"testValue"}', context);
        Test.stopTest();

        System.assertNotEquals(null, outcome, 'Should return an outcome for flow execution');
        if (!outcome.isSuccess) {
            System.debug(LoggingLevel.ERROR, 'Flow execution failed: ' + outcome.errorCode + ' - ' + outcome.errorMessage);
        }
        System.assertEquals(true, outcome.isSuccess, 'Flow execution should succeed with mock. Error: ' + (outcome.isSuccess ? '' : outcome.errorMessage));
    }

    /**
     * @description Tests that a Flow capability with a blank ImplementationDetail (flow API name)
     *              throws a CapabilityExecutionException before attempting to instantiate any handler.
     */
    @IsTest
    static void testExecuteSingleAction_FlowHandlerNotFound_ThrowsException() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Use the factory builder to satisfy all validation rules, then blank ImplementationDetail__c
        // in-memory to exercise the guard in createActionHandler (DML rules only fire at DML time).
        AgentCapability__c flowCapability = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .withName('test_flow_missing_detail')
            .forFlowHandler('Placeholder_Flow')
            .save();
        flowCapability.ImplementationDetail__c = null;

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-flow-no-detail')
            .save();

        ActionContext context = new ActionContext(
            execution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            setup.agentDefinition.Id,
            flowCapability.Id,
            null,
            'turn-flow-no-detail',
            1,
            'Function'
        );

        CapabilityExecutionService service = new CapabilityExecutionService();
        Boolean exceptionThrown = false;

        try {
            service.executeSingleAction(flowCapability, '{}', context);
        } catch (CapabilityExecutionService.CapabilityExecutionException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('missing required Implementation Detail'), 'Should indicate the flow API name is missing: ' + e.getMessage());
        }

        System.assert(exceptionThrown, 'Should throw CapabilityExecutionException when Flow capability has no flow API name');
    }

    /**
     * @description Mock implementation for flow execution in tests.
     */
    private class TestFlowExecutionMock implements ActionFlowHandler.FlowExecutionMock {
        public ActionFlowHandler.MockFlowResult execute(String flowApiName, Map<String, Object> inputs) {
            // Return a successful mock result
            return new ActionFlowHandler.MockFlowResult().setSuccess(new Map<String, Object>{ 'result' => 'success' });
        }
    }
}
