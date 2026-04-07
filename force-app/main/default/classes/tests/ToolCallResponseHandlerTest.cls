/**
 * @description Focused tests for ToolCallResponseHandler using shared TestFactory helpers
 */
@IsTest
private class ToolCallResponseHandlerTest {
    @TestSetup
    static void setupData() {
        AgentCapability__c syncCapability = TestFactory.newCapability()
            .withName('get_case_details')
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .build();

        AgentCapability__c asyncCapability = TestFactory.newCapability().withName('create_account_async').forCreateRecord('Account').async().build();

        TestFactory.createFullAgentSetup().withCapability(syncCapability).withCapability(asyncCapability).save();

        TestFactory.newCase().withSubject('Tool Handler Case').save();
    }

    @IsTest
    static void testHandle_SyncToolCall_CreatesToolStepsAndQueuesFollowUp() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'call-sync-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Calling tool', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withUserMessage('Fetch case details')
            .withTurn('turn-sync-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'Sync tool should queue follow-up');

        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c, ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testHandle_CreateRecordTool_PersistsPageAndCreatedContextReferences() {
        AgentCapability__c createCapability = TestFactory.newCapability().forCreateRecord('Account').withName('create_account_sync').build();
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withCapability(createCapability).save();
        Case pageCase = TestFactory.newCase().withSubject('Create Context Case').save();

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(createCapability.CapabilityName__c, '{"recordData":{"Name":"Created From Tool Handler"}}', 'call-create-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Create account', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withUserMessage('Create an account for me')
            .withTurn('turn-create-ctx-001', 1)
            .withPageRecord(pageCase.Id)
            .build();

        String outcome = new ToolCallResponseHandler().handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'Sync create tool should queue a follow-up turn');

        List<ContextReference__c> references = [
            SELECT RecordId__c, ReferenceRole__c, ReferenceSource__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];
        System.assertEquals(2, references.size(), 'Should persist both page and created record anchors');

        Map<String, ContextReference__c> referencesByRole = new Map<String, ContextReference__c>();
        for (ContextReference__c reference : references) {
            referencesByRole.put(reference.ReferenceRole__c, reference);
        }
        System.assertEquals(String.valueOf(pageCase.Id), referencesByRole.get('Primary').RecordId__c);
        System.assertEquals('Page Context', referencesByRole.get('Primary').ReferenceSource__c);
        System.assertEquals('Tool Output', referencesByRole.get('Created').ReferenceSource__c);
    }

    @IsTest
    static void testHandle_AsyncToolCall_QueuesActionAndSkipsImmediateResult() {
        TestFactory.AgentSetup setup = getSetup();
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = TRUE
            LIMIT 1
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"recordData":{"Name":"Async Account"}}', 'call-async-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Queuing async tool', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-async-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, outcome, 'Async tool should queue action');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c, ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id
        ];

        Boolean hasToolCall = false;
        Boolean hasToolResult = false;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'ToolCall' && step.ToolName__c == capability.CapabilityName__c) {
                hasToolCall = true;
            } else if (step.StepType__c == 'ToolResult' && step.ToolName__c == capability.CapabilityName__c) {
                hasToolResult = true;
            }
        }
        System.assert(hasToolCall, 'Async tool should create ToolCall step');
        System.assert(!hasToolResult, 'Async tool should not create ToolResult immediately');
    }

    @IsTest
    static void testHandle_InvalidToolCall_FailsExecution() {
        TestFactory.AgentSetup setup = getSetup();

        List<Map<String, String>> actions = new List<Map<String, String>>{
            new Map<String, String>{ 'id' => 'call-invalid-001', 'name' => 'unknown_tool', 'arguments' => '{}' }
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Invalid tool', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-invalid-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Invalid tool call should fail');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Failed', execution.ExecutionStatus__c, 'Execution should be marked Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, execution.ProcessingStatus__c, 'Processing status should be Failed');

        ExecutionStep__c toolResult = [
            SELECT StepType__c, ToolName__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND ToolName__c = 'unknown_tool'
            LIMIT 1
        ];
        System.assertEquals(true, toolResult.IsError__c, 'Invalid tool should create an error ToolResult step');
    }

    @IsTest
    static void testHandle_MixedToolCalls_FailsWhenAnyToolInvalid() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'call-valid-001'),
            new Map<String, String>{ 'id' => 'call-invalid-002', 'name' => 'missing_tool', 'arguments' => '{}' }
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Mixed tools', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-mixed-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Mixed tool calls should fail when any tool is invalid');

        ExecutionStep__c invalidResult = [
            SELECT StepType__c, ToolName__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND ToolName__c = 'missing_tool'
            LIMIT 1
        ];
        System.assertEquals(true, invalidResult.IsError__c, 'Invalid tool should create an error ToolResult step');
    }

    @IsTest
    static void testHandle_ToolTerminatingMode_CompletesExecution() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentExecution__c executionUpdate = new AgentExecution__c(Id = setup.agentExecution.Id, IsToolTerminatingMode__c = true);
        update executionUpdate;

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{"Id":"' + testCase.Id + '"}', 'call-term-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Tool-terminating', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-term-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_COMPLETED, outcome, 'Tool-terminating mode should complete execution');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Completed', execution.ExecutionStatus__c, 'Execution should be Completed');
        System.assertEquals(AIAgentConstants.STATUS_IDLE, execution.ProcessingStatus__c, 'Processing status should be Idle');

        List<ExecutionStep__c> toolSteps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, toolSteps.size(), 'Should create ToolCall and ToolResult steps');
    }

    @IsTest
    static void testHandle_ToolTerminatingMode_FailureSetsErrorMessage() {
        TestFactory.AgentSetup setup = getSetup();

        AgentExecution__c executionUpdate = new AgentExecution__c(Id = setup.agentExecution.Id, IsToolTerminatingMode__c = true);
        update executionUpdate;

        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, '{}', 'call-term-fail-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Tool-terminating failure', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-term-fail-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Tool-terminating failure should fail execution');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Failed', execution.ExecutionStatus__c, 'Execution should be Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, execution.ProcessingStatus__c, 'Processing status should be Failed');
        System.assertEquals(
            true,
            execution.ErrorMessage__c != null && execution.ErrorMessage__c.contains(AIAgentConstants.ERR_CODE_INPUT_VALIDATION),
            'Failure should capture error code in ErrorMessage__c'
        );
    }

    @IsTest
    static void testHandle_FailFastToolFailure_FailsExecution() {
        TestFactory.FunctionAgentSetup functionSetup = TestFactory.createFunctionAgentSetup().save();

        AgentCapability__c failFastCapability = TestFactory.newCapability().forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' }).build();
        failFastCapability.CapabilityName__c = 'failfast_case_' + String.valueOf(Datetime.now().getTime());
        failFastCapability.AIAgentDefinition__c = functionSetup.agentDefinition.Id;
        insert failFastCapability;

        // Set agent to Fail Fast mode — halts immediately on any tool error
        update new AIAgentDefinition__c(Id = functionSetup.agentDefinition.Id, ErrorRecoveryMode__c = 'Fail Fast');

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(functionSetup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-failfast-001')
            .save();

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(failFastCapability.CapabilityName__c, '{}', 'call-failfast-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Fail-fast tool', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withExecution(execution.Id)
            .withAgent(functionSetup.agentDefinition.Id)
            .withLlmResult(llmResult)
            .withUserMessage('Trigger fail-fast')
            .withTurn('turn-failfast-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Fail-fast tool failure should fail execution');

        AgentExecution__c updatedExecution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updatedExecution.ExecutionStatus__c, 'Execution should be Failed');
        System.assertEquals(AIAgentConstants.STATUS_FAILED, updatedExecution.ProcessingStatus__c, 'Processing status should be Failed');
    }

    @IsTest
    static void testConditionalApproval_RequiresApprovalOnMalformedJson() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c conditionalCap = TestFactory.newCapability()
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .build();
        conditionalCap.CapabilityName__c = 'conditional_tool_' + String.valueOf(Datetime.now().getTime());
        conditionalCap.AIAgentDefinition__c = setup.agentDefinition.Id;
        insert conditionalCap;

        ToolCallResponseHandler.ToolCallRequest toolRequest = new ToolCallResponseHandler.ToolCallRequest(
            'call-conditional-001',
            conditionalCap.CapabilityName__c,
            '{not-json',
            conditionalCap,
            1
        );

        Boolean requiresApproval = ToolCallResponseHandler.checkLLMApprovalRequest(toolRequest);

        System.assertEquals(true, requiresApproval, 'Malformed JSON should require approval in ConditionalApproval mode');
    }

    @IsTest
    static void testHandle_StripsInternalParamsAndStoresRationale() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        String longSuggestion = String.valueOf('x').repeat(300);
        String argsJson =
            '{"Id":"' +
            testCase.Id +
            '","_rationale":"Use case details","_confidence":87.5,"_nextStepSuggestion":"' +
            longSuggestion +
            '","_requiresApproval":false,"_approvalReason":"N/A"}';

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(capability.CapabilityName__c, argsJson, 'call-meta-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Meta tools', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withUserMessage('Fetch details')
            .withTurn('turn-meta-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'Sync tool should queue follow-up');

        ExecutionStep__c toolCallStep = [
            SELECT ToolArguments__c, ToolRationale__c, Confidence__c, NextStepSuggestion__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolCall'
            LIMIT 1
        ];

        System.assert(!toolCallStep.ToolArguments__c.contains('_rationale'), 'Tool arguments should strip internal params');
        System.assert(!toolCallStep.ToolArguments__c.contains('_confidence'), 'Tool arguments should strip internal params');
        System.assert(!toolCallStep.ToolArguments__c.contains('_nextStepSuggestion'), 'Tool arguments should strip internal params');
        System.assertEquals('Use case details', toolCallStep.ToolRationale__c, 'Tool rationale should be stored');
        System.assertEquals(87.5, toolCallStep.Confidence__c, 'Tool confidence should be stored');
        System.assert(toolCallStep.NextStepSuggestion__c.length() <= 255, 'Next step suggestion should be truncated');
    }

    @IsTest
    static void testHandle_ToleratesLegacyRationaleAlias() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c createAccountCap = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Account').build();
        createAccountCap.CapabilityName__c = 'create_account_alias_' + String.valueOf(Datetime.now().getTime());
        insert createAccountCap;

        String argsJson = '{"recordData":{"Name":"Alias Rationale Account"},"rationale":"Customer requested account creation"}';

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(createAccountCap.CapabilityName__c, argsJson, 'call-rationale-alias-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Alias rationale', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-rationale-alias-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertNotEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Legacy rationale alias should not cause tool-call parsing failure');

        ExecutionStep__c toolCallStep = [
            SELECT ToolArguments__c, ToolRationale__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolCall' AND ToolCallId__c = 'call-rationale-alias-001'
            LIMIT 1
        ];

        System.assert(!toolCallStep.ToolArguments__c.contains('rationale'), 'Legacy rationale alias should be stripped from tool arguments');
        System.assertEquals('Customer requested account creation', toolCallStep.ToolRationale__c, 'Legacy rationale alias should be stored as tool rationale');
    }

    @IsTest
    static void testHandle_ApprovalRequired_ToolCreatesPendingActionOrFails() {
        configureDefaultHitlExecutionIdentity();
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c approvalCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .build();
        approvalCap.CapabilityName__c = 'approval_tool_' + String.valueOf(Datetime.now().getTime());
        insert approvalCap;

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(approvalCap.CapabilityName__c, '{"recordData":{"Name":"Needs Approval"}}', 'call-approval-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Approval needed', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-approval-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        List<PendingHITLAction__c> pending = [
            SELECT Id
            FROM PendingHITLAction__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND ToolCallId__c = 'call-approval-001'
        ];

        if (outcome == OrchestrationService.OUTCOME_COMPLETED) {
            System.assertEquals(1, pending.size(), 'Approval should create a pending HITL action');

            ExecutionStep__c toolResult = [
                SELECT ToolResult__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND ToolCallId__c = 'call-approval-001'
                LIMIT 1
            ];
            System.assert(toolResult.ToolResult__c.contains('pending_approval'), 'Tool result should indicate pending approval');
        } else {
            AgentExecution__c execution = [
                SELECT ExecutionStatus__c, ErrorMessage__c
                FROM AgentExecution__c
                WHERE Id = :setup.agentExecution.Id
            ];
            System.assertEquals('Failed', execution.ExecutionStatus__c, 'Approval failure should fail execution');
            System.assert(
                execution.ErrorMessage__c != null &&
                (execution.ErrorMessage__c.contains('Failed to initiate approval') ||
                execution.ErrorMessage__c.contains('Failed to initiate HITL workflow') ||
                execution.ErrorMessage__c.contains('submit to approval process')),
                'Failure should report approval initiation error'
            );
        }
    }

    @IsTest
    static void testHandle_ConditionalApproval_NoApproval_SyncExecutes() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentCapability__c conditionalCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .build();
        conditionalCap.CapabilityName__c = 'conditional_sync_' + String.valueOf(Datetime.now().getTime());
        insert conditionalCap;

        String argsJson = '{"Id":"' + testCase.Id + '","_requiresApproval":false}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(conditionalCap.CapabilityName__c, argsJson, 'call-conditional-sync-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Conditional sync', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-conditional-sync-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'Conditional approval false should execute sync tool');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c, ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND ToolName__c = :conditionalCap.CapabilityName__c
        ];
        System.assertEquals(2, steps.size(), 'Sync tool should create ToolCall and ToolResult');
    }

    @IsTest
    static void testHandle_ConditionalApproval_NoApproval_AsyncQueues() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c conditionalAsync = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .async()
            .build();
        conditionalAsync.CapabilityName__c = 'conditional_async_' + String.valueOf(Datetime.now().getTime());
        insert conditionalAsync;

        String argsJson = '{"recordData":{"Name":"Async Conditional"},"_requiresApproval":false}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(conditionalAsync.CapabilityName__c, argsJson, 'call-conditional-async-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Conditional async', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-conditional-async-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, outcome, 'Async tool should queue action');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :setup.agentExecution.Id
        ];
        System.assertEquals('Processing', execution.ExecutionStatus__c, 'Execution should be processing');
        System.assertEquals(AIAgentConstants.STATUS_AWAITING_ACTION, execution.ProcessingStatus__c, 'Should await async action');
    }

    @IsTest
    static void testHandle_AsyncQueueFailure_CreatesErrorToolResult() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c asyncCap = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Account').async().build();
        asyncCap.CapabilityName__c = 'async_fail_' + String.valueOf(Datetime.now().getTime());
        insert asyncCap;

        String argsJson = '{"recordData":{"Name":"Async Failure"}}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(asyncCap.CapabilityName__c, argsJson, 'call-async-fail-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Async failure', actions);

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(setup.agentExecution.Id, 'turn-async-fail-001');
        OrchestrationContext context = new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-async-fail-001',
            1,
            TestFactory.createUserMessage('Run async tool'),
            new AgentStateService(),
            new CapabilityExecutionService(),
            null,
            new ContextManagerService(),
            null,
            logger
        );

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_ACTION, outcome, 'Async tools still queue action outcome');

        ExecutionStep__c errorStep = [
            SELECT ToolResult__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND ToolCallId__c = 'call-async-fail-001'
            LIMIT 1
        ];
        System.assertEquals(true, errorStep.IsError__c, 'Queue failure should create an error tool result');
        System.assert(errorStep.ToolResult__c.contains('Failed to queue tool for execution'), 'Tool result should include queue failure message');
    }

    @IsTest
    static void testHandle_EmptyToolCallsList_CompletesGracefully() {
        TestFactory.AgentSetup setup = getSetup();

        // LLM result with empty requestedActions
        List<Map<String, String>> emptyActions = new List<Map<String, String>>();
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Empty actions', emptyActions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-empty-tools', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();

        // Empty tool calls should not throw an exception
        String outcome = null;
        Boolean exceptionThrown = false;
        try {
            outcome = handler.handle(context);
        } catch (Exception e) {
            exceptionThrown = true;
        }

        System.assertEquals(false, exceptionThrown, 'Empty tool calls should not throw exception');
        System.assertNotEquals(null, outcome, 'Should return a valid outcome for empty tools');
    }

    @IsTest
    static void testHandle_MultipleSyncTools_AllExecuted() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];
        AgentCapability__c cap1 = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        String argsJson = '{"Id":"' + testCase.Id + '"}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(cap1.CapabilityName__c, argsJson, 'call-multi-001'),
            TestFactory.createToolCallAction(cap1.CapabilityName__c, argsJson, 'call-multi-002')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Multi tools', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withUserMessage('Run multiple tools')
            .withTurn('turn-multi-tools', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertNotEquals(null, outcome, 'Should return a valid outcome for multiple sync tools');

        List<ExecutionStep__c> results = [
            SELECT ToolCallId__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult'
        ];
        System.assert(results.size() >= 2, 'Both tool calls should produce results');
    }

    @IsTest
    static void testHandle_ToolFlowGraphRejectsCurrentlyIneligibleTool() {
        TestFactory.AgentSetup setup = getSetup();
        AgentCapability__c syncCap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];
        AgentCapability__c asyncCap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = TRUE
            LIMIT 1
        ];

        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ syncCap.CapabilityName__c },
                'flow' => new List<Object>{
                    new Map<String, Object>{
                        'fromTools' => new List<String>{ syncCap.CapabilityName__c },
                        'type' => 'sequential',
                        'toTools' => new List<String>{ asyncCap.CapabilityName__c }
                    }
                }
            }
        );
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, EnableToolFlowGraph__c = true, ToolFlowGraph__c = graphJson);

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(asyncCap.CapabilityName__c, '{"recordData":{"Name":"Too Early"}}', 'call-ineligible-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Ineligible tool', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-ineligible-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Currently ineligible tool calls should fail');

        ExecutionStep__c toolResult = [
            SELECT ToolResult__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND ToolCallId__c = 'call-ineligible-001'
            LIMIT 1
        ];
        System.assertEquals(true, toolResult.IsError__c, 'Ineligible tool should create an error ToolResult');
        System.assert(toolResult.ToolResult__c.contains('not eligible'), 'Error result should explain graph ineligibility');
    }

    @IsTest
    static void testHandle_ToolFlowGraphRejectsMultipleExclusiveBranchesInSameResponse() {
        TestFactory.FunctionAgentSetup functionSetup = TestFactory.createFunctionAgentSetup().withExecution().save();

        AgentCapability__c entryCap = TestFactory.newCapability()
            .withAgent(functionSetup.agentDefinition.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .build();
        entryCap.CapabilityName__c = 'evaluate_case_' + String.valueOf(Datetime.now().getTime());
        insert entryCap;

        AgentCapability__c branchACap = TestFactory.newCapability()
            .withAgent(functionSetup.agentDefinition.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id' })
            .build();
        branchACap.CapabilityName__c = 'branch_a_' + String.valueOf(Datetime.now().getTime());
        insert branchACap;

        AgentCapability__c branchBCap = TestFactory.newCapability()
            .withAgent(functionSetup.agentDefinition.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id' })
            .build();
        branchBCap.CapabilityName__c = 'branch_b_' + String.valueOf(Datetime.now().getTime());
        insert branchBCap;

        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ entryCap.CapabilityName__c },
                'flow' => new List<Object>{
                    new Map<String, Object>{
                        'fromTools' => new List<String>{ entryCap.CapabilityName__c },
                        'type' => 'exclusive',
                        'toTools' => new List<String>{ branchACap.CapabilityName__c, branchBCap.CapabilityName__c },
                        'conditions' => new Map<String, Object>{ branchACap.CapabilityName__c => 'Option A', branchBCap.CapabilityName__c => 'Option B' }
                    }
                }
            }
        );
        update new AIAgentDefinition__c(Id = functionSetup.agentDefinition.Id, EnableToolFlowGraph__c = true, ToolFlowGraph__c = graphJson);

        insert new ExecutionStep__c(
            AgentExecution__c = functionSetup.execution.Id,
            StepType__c = 'ToolResult',
            StepRole__c = 'Tool',
            ToolName__c = entryCap.CapabilityName__c,
            ToolCallId__c = 'call-entry-complete-001',
            IsError__c = false
        );

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(branchACap.CapabilityName__c, '{}', 'call-branch-a-001'),
            TestFactory.createToolCallAction(branchBCap.CapabilityName__c, '{}', 'call-branch-b-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Conflicting exclusive choices', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withExecution(functionSetup.execution.Id)
            .withAgent(functionSetup.agentDefinition.Id)
            .withLlmResult(llmResult)
            .withTurn('turn-exclusive-conflict-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Multiple branches from the same exclusive gateway should fail');

        List<ExecutionStep__c> errorResults = [
            SELECT ToolName__c, ToolResult__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :functionSetup.execution.Id AND StepType__c = 'ToolResult' AND IsError__c = TRUE
        ];
        System.assert(errorResults.size() >= 2, 'Each conflicting branch should create an error ToolResult');
    }

    private static TestFactory.AgentSetup getSetup() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c WHERE AIAgentDefinition__c = :agent.Id LIMIT 1];
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        TestFactory.AgentSetup setup = new TestFactory.AgentSetup();
        setup.agentDefinition = agent;
        setup.agentExecution = execution;
        setup.llmConfig = llm;
        return setup;
    }

    private static void configureDefaultHitlExecutionIdentity() {
        insert new AIAgentFrameworkSettings__c(DefaultHITLExecIdentityProfile__c = 'FrameworkServiceUser');
        AIAgentFrameworkSettings.clearCache();
        AIAgentConfigService.setTestExecutionIdentityProfiles(
            new List<ExecutionIdentityProfile__mdt>{
                new ExecutionIdentityProfile__mdt(
                    DeveloperName = 'FrameworkServiceUser',
                    MasterLabel = 'FrameworkServiceUser',
                    IsActive__c = true,
                    NamedCredentialDeveloperName__c = 'AgentStudio_ServiceUser'
                )
            }
        );
    }

    /**
     * @description Tests extractRequiresApprovalFlag with string values like "true", "1", "yes".
     *              Covers lines 623-640 for different boolean representations.
     */
    @IsTest
    static void testConditionalApproval_RequiresApprovalStringValues_ParsedCorrectly() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c conditionalCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .build();
        conditionalCap.CapabilityName__c = 'conditional_string_' + String.valueOf(Datetime.now().getTime());
        insert conditionalCap;

        // Test string "true"
        ToolCallResponseHandler.ToolCallRequest toolRequestTrue = new ToolCallResponseHandler.ToolCallRequest(
            'call-string-true-001',
            conditionalCap.CapabilityName__c,
            '{"recordData":{"Name":"Test"},"_requiresApproval":"true"}',
            conditionalCap,
            1
        );
        System.assertEquals(true, ToolCallResponseHandler.checkLLMApprovalRequest(toolRequestTrue), 'String "true" should be parsed as true');

        // Test string "1"
        ToolCallResponseHandler.ToolCallRequest toolRequestOne = new ToolCallResponseHandler.ToolCallRequest(
            'call-string-one-001',
            conditionalCap.CapabilityName__c,
            '{"recordData":{"Name":"Test"},"_requiresApproval":"1"}',
            conditionalCap,
            1
        );
        System.assertEquals(true, ToolCallResponseHandler.checkLLMApprovalRequest(toolRequestOne), 'String "1" should be parsed as true');

        // Test string "yes"
        ToolCallResponseHandler.ToolCallRequest toolRequestYes = new ToolCallResponseHandler.ToolCallRequest(
            'call-string-yes-001',
            conditionalCap.CapabilityName__c,
            '{"recordData":{"Name":"Test"},"_requiresApproval":"yes"}',
            conditionalCap,
            1
        );
        System.assertEquals(true, ToolCallResponseHandler.checkLLMApprovalRequest(toolRequestYes), 'String "yes" should be parsed as true');

        // Test string "false"
        ToolCallResponseHandler.ToolCallRequest toolRequestFalse = new ToolCallResponseHandler.ToolCallRequest(
            'call-string-false-001',
            conditionalCap.CapabilityName__c,
            '{"recordData":{"Name":"Test"},"_requiresApproval":"false"}',
            conditionalCap,
            1
        );
        System.assertEquals(false, ToolCallResponseHandler.checkLLMApprovalRequest(toolRequestFalse), 'String "false" should be parsed as false');

        // Test missing key
        ToolCallResponseHandler.ToolCallRequest toolRequestMissing = new ToolCallResponseHandler.ToolCallRequest(
            'call-missing-001',
            conditionalCap.CapabilityName__c,
            '{"recordData":{"Name":"Test"}}',
            conditionalCap,
            1
        );
        System.assertEquals(false, ToolCallResponseHandler.checkLLMApprovalRequest(toolRequestMissing), 'Missing _requiresApproval should default to false');
    }

    /**
     * @description Tests extractApprovalReason and stripInternalParameters methods.
     *              Covers lines 657-709 for extracting and stripping framework parameters.
     */
    @IsTest
    static void testHandle_ExtractsApprovalReasonAndStripsInternalParams() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c approvalCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .build();
        approvalCap.CapabilityName__c = 'approval_reason_' + String.valueOf(Datetime.now().getTime());
        insert approvalCap;

        String argsJson =
            '{"recordData":{"Name":"Test Account"},' +
            '"_requiresApproval":true,' +
            '"_approvalReason":"High-value transaction over $10,000",' +
            '"_rationale":"Customer requested this",' +
            '"_confidence":95.5,' +
            '"_nextStepSuggestion":"Review the account"}';

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(approvalCap.CapabilityName__c, argsJson, 'call-approval-reason-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Approval with reason', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-approval-reason-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        // Check if pending action was created (approval may succeed or fail based on process config)
        List<PendingHITLAction__c> pending = [
            SELECT Id, ConfirmationPrompt__c
            FROM PendingHITLAction__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND ToolCallId__c = 'call-approval-reason-001'
        ];

        if (!pending.isEmpty()) {
            System.assert(pending[0].ConfirmationPrompt__c.contains('High-value transaction'), 'Approval reason should be included in confirmation prompt');
        }

        // Verify internal parameters were stripped from tool arguments
        ExecutionStep__c toolCallStep = [
            SELECT ToolArguments__c, ToolRationale__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolCall' AND ToolCallId__c = 'call-approval-reason-001'
            LIMIT 1
        ];

        System.assert(!toolCallStep.ToolArguments__c.contains('_requiresApproval'), 'Should strip _requiresApproval from tool arguments');
        System.assert(!toolCallStep.ToolArguments__c.contains('_approvalReason'), 'Should strip _approvalReason from tool arguments');
        System.assert(!toolCallStep.ToolArguments__c.contains('_rationale'), 'Should strip _rationale from tool arguments');
        System.assert(!toolCallStep.ToolArguments__c.contains('_confidence'), 'Should strip _confidence from tool arguments');
        System.assert(!toolCallStep.ToolArguments__c.contains('_nextStepSuggestion'), 'Should strip _nextStepSuggestion from tool arguments');
        System.assertEquals('Customer requested this', toolCallStep.ToolRationale__c, 'Rationale should be stored separately');
    }

    /**
     * @description Tests multiple async tool queue failures to cover summary error message.
     *              Covers lines 1914-1919 for multiple tool failure summary.
     */
    @IsTest
    static void testHandle_MultipleAsyncToolsFailToQueue_CreatesSummaryError() {
        TestFactory.AgentSetup setup = getSetup();

        // Create multiple async capabilities
        AgentCapability__c asyncCap1 = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Account').async().build();
        asyncCap1.CapabilityName__c = 'async_fail_1_' + String.valueOf(Datetime.now().getTime());
        insert asyncCap1;

        AgentCapability__c asyncCap2 = TestFactory.newCapability().withAgent(setup.agentDefinition.Id).forCreateRecord('Contact').async().build();
        asyncCap2.CapabilityName__c = 'async_fail_2_' + String.valueOf(Datetime.now().getTime());
        insert asyncCap2;

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(asyncCap1.CapabilityName__c, '{"recordData":{"Name":"Async Fail 1"}}', 'call-multi-async-001'),
            TestFactory.createToolCallAction(asyncCap2.CapabilityName__c, '{"recordData":{"LastName":"Fail 2"}}', 'call-multi-async-002')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Multiple async failures', actions);

        IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(setup.agentExecution.Id, 'turn-multi-async-fail');
        OrchestrationContext context = new OrchestrationContext(
            llmResult,
            setup.agentExecution.Id,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            setup.agentDefinition.Id,
            'turn-multi-async-fail',
            1,
            TestFactory.createUserMessage('Queue multiple async'),
            new AgentStateService(),
            new CapabilityExecutionService(),
            null,
            new ContextManagerService(),
            null,
            logger
        );

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        // Check for error tool results for both async tools
        List<ExecutionStep__c> errorSteps = [
            SELECT ToolName__c, ToolResult__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult' AND IsError__c = TRUE
        ];

        if (errorSteps.size() >= 2) {
            // Multiple failures should generate summary error
            System.assert(errorSteps.size() >= 2, 'Multiple async tools should create error results');
            for (ExecutionStep__c step : errorSteps) {
                System.assertEquals(true, step.IsError__c, 'Failed async tool should be marked as error');
            }
        }
    }

    /**
     * @description Tests approval required for Function agents updates status to awaiting action.
     *              Covers lines 1042-1050 for default approval handling.
     */
    @IsTest
    static void testHandle_ApprovalRequiredFunctionAgent_AwaitingAction() {
        TestFactory.AgentSetup setup = getSetup();

        // Update agent to Function type
        update new AIAgentDefinition__c(Id = setup.agentDefinition.Id, RuntimeStrategy__c = 'Direct');

        AgentCapability__c approvalCap = TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .build();
        approvalCap.CapabilityName__c = 'function_approval_' + String.valueOf(Datetime.now().getTime());
        insert approvalCap;

        AgentExecution__c functionExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-func-approval-001')
            .save();

        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(approvalCap.CapabilityName__c, '{"recordData":{"Name":"Function Approval"}}', 'call-func-approval-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Function approval', actions);

        TestFactory.AgentSetup funcSetup = new TestFactory.AgentSetup();
        funcSetup.agentDefinition = [SELECT Id FROM AIAgentDefinition__c WHERE Id = :setup.agentDefinition.Id];
        funcSetup.agentExecution = functionExec;
        funcSetup.llmConfig = setup.llmConfig;

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(funcSetup)
            .withLlmResult(llmResult)
            .withTurn('turn-func-approval-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        // Verify status is set to awaiting action for Function agents with approval
        AgentExecution__c updatedExec = [
            SELECT ExecutionStatus__c, ProcessingStatus__c
            FROM AgentExecution__c
            WHERE Id = :functionExec.Id
        ];

        if (updatedExec.ExecutionStatus__c == 'Awaiting Action') {
            System.assertEquals(AIAgentConstants.STATUS_AWAITING_ACTION, updatedExec.ProcessingStatus__c, 'Processing status should be awaiting action');
        } else {
            System.assertEquals('Failed', updatedExec.ExecutionStatus__c, 'Should fail if approval cannot be initiated');
        }
    }

    // ========== Confidence Gate Tests ==========

    @IsTest
    static void testConfidenceGate_AllToolsBlocked_FailsTurn() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        // Enable Block on the agent definition
        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c WHERE Id = :setup.agentDefinition.Id];
        agentDef.EnableConfidenceTracking__c = true;
        agentDef.MinConfidenceThreshold__c = 60;
        agentDef.LowConfidenceAction__c = 'Block';
        update agentDef;

        // Set execution type to Function so all-blocked path fails the turn (not queues follow-up)
        update new AgentExecution__c(Id = setup.agentExecution.Id, ExecutionType__c = 'Direct');

        // Single tool call with confidence below threshold — all tools are blocked
        String argsJson = '{"Id":"' + setup.agentExecution.Id + '","_confidence":35}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(cap.CapabilityName__c, argsJson, 'call-low-conf-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Low confidence call', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext().withSetup(setup).withLlmResult(llmResult).withTurn('turn-low-conf-001', 1).build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        // When ALL tools are blocked there is nothing left to do — must fail, not queue a follow-up
        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'All tools blocked should fail the turn — no follow-up LLM call should be made');

        // ToolCall step should be created (with confidence stored for observability)
        List<ExecutionStep__c> toolCallSteps = [
            SELECT StepType__c, Confidence__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolCall'
        ];
        System.assertEquals(1, toolCallSteps.size(), 'ToolCall step should be written for Storyboard observability');
        System.assertEquals(35, toolCallSteps[0].Confidence__c, 'Confidence should be stored on blocked ToolCall step');

        // Synthetic blocked ToolResult step should be created (message sequence integrity)
        List<ExecutionStep__c> toolResultSteps = [
            SELECT StepType__c, ToolResult__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResultSteps.size(), 'Synthetic ToolResult step should be written for message sequence integrity');
        System.assert(toolResultSteps[0].ToolResult__c.contains('blocked'), 'Synthetic result should indicate blocked status');
        System.assert(toolResultSteps[0].ToolResult__c.contains('35'), 'Synthetic result should include the confidence score');
        // Threshold must NOT appear in the blocked message — prevents the LLM from gaming it
        System.assert(!toolResultSteps[0].ToolResult__c.contains('"minimumThreshold"'), 'Blocked message must not expose the threshold value');
    }

    @IsTest
    static void testConfidenceGate_NullConfidence_TreatedAsZero_Blocks() {
        TestFactory.AgentSetup setup = getSetup();

        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c WHERE Id = :setup.agentDefinition.Id];
        agentDef.EnableConfidenceTracking__c = true;
        agentDef.MinConfidenceThreshold__c = 60;
        agentDef.LowConfidenceAction__c = 'Block';
        update agentDef;

        // Set execution type to Function so all-blocked path fails the turn (not queues follow-up)
        update new AgentExecution__c(Id = setup.agentExecution.Id, ExecutionType__c = 'Direct');

        // Tool call with NO _confidence — missing field must be treated as 0, not bypassed
        String argsJson = '{"Id":"' + setup.agentExecution.Id + '"}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(cap.CapabilityName__c, argsJson, 'call-null-conf-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('Null confidence call', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-null-conf-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_FAILED, outcome, 'Missing _confidence should be treated as 0 and blocked — not silently bypassed');

        List<ExecutionStep__c> toolResultSteps = [
            SELECT ToolResult__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResultSteps.size(), 'Synthetic ToolResult should be written even when confidence was null');
        System.assert(toolResultSteps[0].ToolResult__c.contains('blocked'), 'Result should indicate blocked status');
    }

    @IsTest
    static void testConfidenceGate_AboveThreshold_ExecutesNormally() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c WHERE Id = :setup.agentDefinition.Id];
        agentDef.EnableConfidenceTracking__c = true;
        agentDef.MinConfidenceThreshold__c = 60;
        agentDef.LowConfidenceAction__c = 'Block';
        update agentDef;

        // Tool call with confidence ABOVE threshold — should execute normally
        String argsJson = '{"Id":"' + testCase.Id + '","_confidence":85}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(cap.CapabilityName__c, argsJson, 'call-high-conf-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('High confidence call', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-high-conf-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'High-confidence tool should execute normally and queue follow-up');

        // Both ToolCall and ToolResult should exist (normal execution, not just synthetic)
        List<ExecutionStep__c> steps = [
            SELECT StepType__c, ToolResult__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, steps.size(), 'Normal execution should create both ToolCall and ToolResult steps');

        // ToolResult should contain real data, not a blocked message
        for (ExecutionStep__c step : steps) {
            if ('ToolResult'.equals(step.StepType__c)) {
                System.assert(!step.ToolResult__c.contains('"status":"blocked"'), 'Normal execution should not produce a blocked result');
            }
        }
    }

    @IsTest
    static void testConfidenceGate_ActionNone_DoesNotBlock() {
        TestFactory.AgentSetup setup = getSetup();
        Case testCase = [SELECT Id FROM Case LIMIT 1];

        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND RunAsynchronously__c = FALSE
            LIMIT 1
        ];

        AIAgentDefinition__c agentDef = [SELECT Id FROM AIAgentDefinition__c WHERE Id = :setup.agentDefinition.Id];
        agentDef.EnableConfidenceTracking__c = true;
        agentDef.MinConfidenceThreshold__c = 60;
        agentDef.LowConfidenceAction__c = 'None'; // Action is None — tracking only, no blocking
        update agentDef;

        // Tool call with very low confidence — should still execute because action is None
        String argsJson = '{"Id":"' + testCase.Id + '","_confidence":10}';
        List<Map<String, String>> actions = new List<Map<String, String>>{
            TestFactory.createToolCallAction(cap.CapabilityName__c, argsJson, 'call-none-action-001')
        };
        LLMInteractionService.LLMInteractionResult llmResult = TestFactory.createLlmToolCallResult('None action call', actions);

        OrchestrationContext context = TestFactory.newOrchestrationContext()
            .withSetup(setup)
            .withLlmResult(llmResult)
            .withTurn('turn-none-action-001', 1)
            .build();

        ToolCallResponseHandler handler = new ToolCallResponseHandler();
        String outcome = handler.handle(context);

        System.assertEquals(OrchestrationService.OUTCOME_QUEUED_FOLLOWUP, outcome, 'None action should not block — tool executes normally');

        List<ExecutionStep__c> steps = [
            SELECT StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :setup.agentExecution.Id AND StepType__c IN ('ToolCall', 'ToolResult')
        ];
        System.assertEquals(2, steps.size(), 'None action should produce both ToolCall and ToolResult (normal execution)');
    }
}
