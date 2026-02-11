/**
 * @description Focused tests for ExecutionStepService using shared TestFactory helpers
 */
@IsTest
private class ExecutionStepServiceTest {
    @TestSetup
    static void setupData() {
        TestFactory.createFullAgentSetup().save();
    }

    @IsTest
    static void testCreateUserAndAgentSteps() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ExecutionStepService svc = new ExecutionStepService();

        Id userStepId = svc.createUserInputStep(execution.Id, 'Hello', 'turn-step-001', 1);
        Id agentStepId = svc.createAgentResponseStep(execution.Id, 'Hi there', 'turn-step-001', 1);

        ExecutionStep__c userStep = [
            SELECT StepType__c, StepRole__c, Content__c
            FROM ExecutionStep__c
            WHERE Id = :userStepId
        ];
        System.assertEquals('UserInput', userStep.StepType__c, 'Should create UserInput step');
        System.assertEquals('User', userStep.StepRole__c, 'UserInput step should have User role');

        ExecutionStep__c agentStep = [
            SELECT StepType__c, StepRole__c, Content__c
            FROM ExecutionStep__c
            WHERE Id = :agentStepId
        ];
        System.assertEquals('AgentResponse', agentStep.StepType__c, 'Should create AgentResponse step');
        System.assertEquals('Assistant', agentStep.StepRole__c, 'AgentResponse step should have Assistant role');
    }

    @IsTest
    static void testCreateToolResultStep_MarksAsync() {
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];

        ExecutionStepService svc = new ExecutionStepService();
        Id stepId = svc.createToolResultStep(execution.Id, 'call_tool_001', 'test_tool', '{"isSuccess":true}', 'turn-step-002', 1, 25L, true, null);

        ExecutionStep__c toolStep = [
            SELECT StepType__c, StepRole__c, IsAsyncToolExecution__c
            FROM ExecutionStep__c
            WHERE Id = :stepId
        ];
        System.assertEquals('ToolResult', toolStep.StepType__c, 'Should create ToolResult step');
        System.assertEquals('Tool', toolStep.StepRole__c, 'ToolResult step should have Tool role');
        System.assertEquals(true, toolStep.IsAsyncToolExecution__c, 'ToolResult step should be marked async');
    }

    @IsTest
    static void testDeferredDML_BuffersAndCommitsSteps() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();

        ExecutionStepService svc = new ExecutionStepService();
        svc.createAgentResponseStep(execution.Id, 'Buffered response', 'turn-buffer-steps', 1);

        List<ExecutionStep__c> beforeCommit = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-buffer-steps'
        ];
        System.assertEquals(0, beforeCommit.size(), 'Step should be buffered before commit');

        txnCtx.commitBuffer();
        txnCtx.disableDeferredDMLMode();

        List<ExecutionStep__c> afterCommit = [
            SELECT Id
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :execution.Id AND TurnIdentifier__c = 'turn-buffer-steps'
        ];
        System.assertEquals(1, afterCommit.size(), 'Buffered step should be inserted after commit');
    }

    @IsTest
    static void testGetHistory_IncludesBufferedSteps() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        TransactionContext txnCtx = TransactionContext.getInstance();
        txnCtx.enableDeferredDMLMode();

        ExecutionStepService svc = new ExecutionStepService();
        svc.createUserInputStep(execution.Id, 'Buffered input', 'turn-history-001', 1);

        List<ExecutionStep__c> history = svc.getHistory(execution.Id, null, 'ASC', null, false);

        Boolean foundBuffered = false;
        for (ExecutionStep__c step : history) {
            if (step.TurnIdentifier__c == 'turn-history-001' && step.StepType__c == 'UserInput') {
                foundBuffered = true;
                break;
            }
        }

        System.assert(foundBuffered, 'History should include buffered steps when deferred DML is enabled');

        txnCtx.disableDeferredDMLMode();
    }

    @IsTest
    static void testCreateToolCallStep_ExtractsConfidenceAndSuggestion() {
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];
        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(execution.AIAgentDefinition__c)
            .forFlowHandler('Test_Flow')
            .withName('cap_conf_' + String.valueOf(Datetime.now().getTime()))
            .save();

        String toolArgs = '{"input":"test","_confidence":87.5,"_nextStepSuggestion":"Proceed to validate"}';

        ExecutionStepService svc = new ExecutionStepService();
        Id stepId = svc.createToolCallStep(
            execution.Id,
            'call-confidence-001',
            'test_tool',
            toolArgs,
            'turn-tool-001',
            1,
            null,
            null,
            null,
            'gpt-4o-mini',
            12L,
            capability.Id
        );

        ExecutionStep__c step = [
            SELECT Confidence__c, NextStepSuggestion__c
            FROM ExecutionStep__c
            WHERE Id = :stepId
        ];
        System.assertEquals(87.5, step.Confidence__c, 'Confidence should be extracted from tool arguments');
        System.assertEquals('Proceed to validate', step.NextStepSuggestion__c, 'Next step suggestion should be extracted');
    }

    @IsTest
    static void testGetHistoryWithCompleteTurns_RespectsLimitAndInternal() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        ExecutionStepService svc = new ExecutionStepService();

        Id turn1User = svc.createUserInputStep(execution.Id, 'T1 user', 'turn-hist-1', 1);
        Id turn1Agent = svc.createAgentResponseStep(execution.Id, 'T1 agent', 'turn-hist-1', 1);
        Id turn2User = svc.createUserInputStep(execution.Id, 'T2 user', 'turn-hist-2', 2);
        Id turn2Agent = svc.createAgentResponseStep(execution.Id, 'T2 agent', 'turn-hist-2', 2);

        Id internalStepId = svc.createStep(
            execution.Id,
            'UserInput',
            'User',
            'Internal only',
            'Text',
            'turn-hist-int',
            3,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            true,
            false,
            null,
            null
        );

        Datetime baseTime = Datetime.now();
        update new List<ExecutionStep__c>{
            new ExecutionStep__c(Id = turn1User, Timestamp__c = baseTime.addMinutes(-30)),
            new ExecutionStep__c(Id = turn1Agent, Timestamp__c = baseTime.addMinutes(-29)),
            new ExecutionStep__c(Id = turn2User, Timestamp__c = baseTime.addMinutes(-20)),
            new ExecutionStep__c(Id = turn2Agent, Timestamp__c = baseTime.addMinutes(-19)),
            new ExecutionStep__c(Id = internalStepId, Timestamp__c = baseTime.addMinutes(-10))
        };

        List<ExecutionStep__c> noInternal = svc.getHistoryWithCompleteTurns(execution.Id, null, 'ASC', false);
        Boolean foundInternal = false;
        for (ExecutionStep__c step : noInternal) {
            if (step.TurnIdentifier__c == 'turn-hist-int') {
                foundInternal = true;
                break;
            }
        }
        System.assertEquals(false, foundInternal, 'Internal-only turn should be excluded when includeInternal=false');

        List<ExecutionStep__c> withInternal = svc.getHistoryWithCompleteTurns(execution.Id, null, 'ASC', true);
        Boolean includedInternal = false;
        for (ExecutionStep__c step : withInternal) {
            if (step.TurnIdentifier__c == 'turn-hist-int') {
                includedInternal = true;
                break;
            }
        }
        System.assertEquals(true, includedInternal, 'Internal-only turn should be included when includeInternal=true');

        List<ExecutionStep__c> limited = svc.getHistoryWithCompleteTurns(execution.Id, 1, 'ASC', false);
        Set<String> limitedTurns = new Set<String>();
        for (ExecutionStep__c step : limited) {
            limitedTurns.add(step.TurnIdentifier__c);
        }
        System.assertEquals(1, limitedTurns.size(), 'Turn limit should restrict to a single turn');
        System.assert(limitedTurns.contains('turn-hist-1'), 'First turn should be selected when ASC order and limit=1');
    }

    @IsTest
    static void testUnsummarizedTurnCountAndMarkSummarized() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        ExecutionStepService svc = new ExecutionStepService();
        Id turn1User = svc.createUserInputStep(execution.Id, 'U1', 'turn-sum-1', 1);
        Id turn1Agent = svc.createAgentResponseStep(execution.Id, 'A1', 'turn-sum-1', 1);
        Id turn2User = svc.createUserInputStep(execution.Id, 'U2', 'turn-sum-2', 2);
        Id turn2Agent = svc.createAgentResponseStep(execution.Id, 'A2', 'turn-sum-2', 2);

        update new List<ExecutionStep__c>{
            new ExecutionStep__c(Id = turn2User, IsSummarized__c = true),
            new ExecutionStep__c(Id = turn2Agent, IsSummarized__c = true)
        };

        Integer unsummarized = svc.getUnsummarizedTurnCount(execution.Id);
        System.assertEquals(1, unsummarized, 'Only one turn should be unsummarized');

        svc.markStepsAsSummarized(new List<Id>{ turn1User, turn1Agent });

        Integer afterMark = svc.getUnsummarizedTurnCount(execution.Id);
        System.assertEquals(0, afterMark, 'All turns should be summarized after update');
    }
}
