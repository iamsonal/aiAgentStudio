/**
 * @description Focused tests for DirectRuntimeService routing and deferral behavior
 */
@IsTest
private class DirectRuntimeServiceTest {
    private static TestFactory.FunctionAgentSetup createAgentCapabilityFunctionSetup(String agentNamePrefix) {
        LLMConfiguration__c sharedLlm = TestFactory.newLLMConfiguration().withName(agentNamePrefix + ' LLM').save();
        AIAgentDefinition__c childAgent = TestFactory.newAgentDefinition().withName(agentNamePrefix + '_Child').withType('Direct').withLLM(sharedLlm.Id).save();

        AgentCapability__c agentCap = TestFactory.newCapability().forChildAgent(childAgent.DeveloperName__c).build();

        return TestFactory.createFunctionAgentSetup().withLlm(sharedLlm).withCapability(agentCap).withExecution().save();
    }

    @IsTest
    static void testExecute_DefersWhenPriorDml() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Func LLM DML').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
            .withName('Func_Dml_Agent')
            .withType('Direct')
            .withLLM(llm.Id)
            .withAuditLevel('Standard')
            .save();
        Case testCase = TestFactory.newCase().withSubject('Function DML Case').save();

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Deferred response'));

        Test.startTest();
        // Create DML in this transaction to force deferral
        insert new Account(Name = 'PreDml Account');
        DirectExecutionResult result = orchestrator.execute('Summarize case', testCase.Id, UserInfo.getUserId(), 'turn-func-dml-001', null);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Deferred execution should return success');
        System.assertEquals('Processing', result.status, 'Deferred execution should return Processing status');
        System.assertEquals(true, result.requiresPolling, 'Deferred execution should require polling');
        System.assertNotEquals(null, result.executionId, 'Deferred execution should create an execution record');

        AgentExecution__c execution = [
            SELECT ExecutionStatus__c, IsToolTerminatingMode__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
        ];
        System.assertEquals(true, execution.IsToolTerminatingMode__c, 'Tool-terminating mode should be set for <=1 capability');
        System.assertEquals('turn-func-dml-001', execution.CurrentTurnIdentifier__c, 'Turn identifier should be stored');
    }

    @IsTest
    static void testExecute_MultipleTools_RoutesToAsyncTextResponse() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Func LLM Async').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
            .withName('Func_Async_Agent')
            .withType('Direct')
            .withLLM(llm.Id)
            .withAuditLevel('Standard')
            .save();

        TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Account').save();
        TestFactory.newCapability().withAgent(agent.Id).forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' }).save();

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Quick summary.'));
        Case testCase = TestFactory.newCase().withSubject('Function Async Case').save();

        Test.startTest();
        DirectExecutionResult result = orchestrator.execute('Summarize case', testCase.Id, UserInfo.getUserId(), 'turn-func-async-001', null);
        Test.stopTest();

        System.assertEquals(true, result.success, 'Async text-only response should succeed');
        System.assertEquals('Completed', result.status, 'Text-only response should complete');
        System.assertEquals(false, result.requiresPolling, 'Text-only response should not require polling');
        System.assertEquals(null, result.executionId, 'Text-only response should not create execution');
    }

    @IsTest
    static void testStart_MultiRecord_DispatchesDlq() {
        AIAgentFrameworkSettings__c settings = new AIAgentFrameworkSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), BulkConcurrencyLimit__c = 2);
        upsert settings;
        AIAgentFrameworkSettings.clearCache();

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Func LLM DLQ').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Func_DLQ_Agent').withType('Direct').withLLM(llm.Id).save();

        List<Account> accounts = TestFactory.createAccounts(2).save();

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.userMessage = 'Summarize records';
        payload.sourceRecordIds = new List<Id>{ accounts[0].Id, accounts[1].Id };

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        AgentExecutionService.ExecutionResult result = orchestrator.start(agent.DeveloperName__c, payload);

        System.assertEquals(true, result.success, 'DLQ dispatch should succeed');
        System.assertEquals('Processing', result.status, 'DLQ dispatch should return Processing status');

        List<AgentExecution__c> executions = [
            SELECT BatchId__c, ExecutionStatus__c
            FROM AgentExecution__c
            WHERE BatchId__c != NULL AND AIAgentDefinition__c = :agent.Id
        ];
        System.assertEquals(2, executions.size(), 'Should create one execution per source record');
    }

    /**
     * @description Verifies that in Autonomous mode, determineResumePoint() defaults to LLM_CONTINUE
     *              when a failed tool exists. The LLM should receive the full history (including
     *              correctionGuidance) rather than blindly retrying the tool.
     */
    @IsTest
    static void testDetermineResumePoint_AutonomousMode_DefaultsToLLMContinue() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Resume Strategy LLM Autonomous').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Resume_Strategy_Autonomous_Agent').withType('Direct').withLLM(llm.Id).save();
        // Autonomous is the default — explicitly confirm it is set
        System.assertEquals(
            'Autonomous',
            [SELECT ErrorRecoveryMode__c FROM AIAgentDefinition__c WHERE Id = :agent.Id].ErrorRecoveryMode__c,
            'Agent should default to Autonomous mode'
        );

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withName('resume_test_tool')
            .save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            ExecutionType__c = 'Direct',
            ExecutionStatus__c = 'Failed',
            ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
            CurrentTurnIdentifier__c = 'turn-resume-auto-001',
            User__c = UserInfo.getUserId()
        );
        insert execution;

        // Seed a failed tool result step — this is what findLastFailedTool() uses
        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolCall',
                StepRole__c = 'Tool',
                ToolName__c = 'resume_test_tool',
                ToolCallId__c = 'call-resume-001',
                ToolArguments__c = '{}',
                TurnCount__c = 1
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = 'resume_test_tool',
                ToolCallId__c = 'call-resume-001',
                IsError__c = true,
                ToolResult__c = '{"isSuccess":false}',
                TurnCount__c = 1
            )
        };

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        // LLM_CONTINUE will make a callout — mock it with a text response to keep test in control
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Resume analysis complete.'));

        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, null);
        Test.stopTest();

        // In Autonomous mode, the orchestrator should route to LLM_CONTINUE (not RETRY_FAILED_TOOL).
        // The execution should not be in Failed state — it should have been handed off to the LLM.
        AgentExecution__c updated = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :execution.Id];
        System.assertNotEquals('Failed', updated.ExecutionStatus__c, 'Autonomous mode resume should not immediately fail — it should route to LLM_CONTINUE');
    }

    /**
     * @description Verifies that in Fail Fast mode, determineResumePoint() defaults to RETRY_FAILED_TOOL
     *              when a failed tool exists. The human-initiated resume explicitly overrides the hard stop.
     */
    @IsTest
    static void testDetermineResumePoint_FailFastMode_DefaultsToRetryFailedTool() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Resume Strategy LLM FailFast').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Resume_Strategy_FailFast_Agent').withType('Direct').withLLM(llm.Id).save();
        update new AIAgentDefinition__c(Id = agent.Id, ErrorRecoveryMode__c = 'Fail Fast');

        AgentCapability__c capability = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forGetRecordDetails('Case', new List<String>{ 'Id', 'Subject' })
            .withName('ff_resume_test_tool')
            .save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            ExecutionType__c = 'Direct',
            ExecutionStatus__c = 'Failed',
            ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
            CurrentTurnIdentifier__c = 'turn-resume-ff-001',
            User__c = UserInfo.getUserId()
        );
        insert execution;

        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolCall',
                StepRole__c = 'Tool',
                ToolName__c = 'ff_resume_test_tool',
                ToolCallId__c = 'call-ff-resume-001',
                ToolArguments__c = '{}',
                TurnCount__c = 1
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = 'ff_resume_test_tool',
                ToolCallId__c = 'call-ff-resume-001',
                IsError__c = true,
                ToolResult__c = '{"isSuccess":false}',
                TurnCount__c = 1
            )
        };

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        // RETRY_FAILED_TOOL will execute the capability synchronously. The GetRecordDetails action
        // will succeed (real data), so we end up queuing a follow-up LLM call — mock it.
        Case testCase = TestFactory.newCase().withSubject('FF Resume Test Case').save();
        update new AgentExecution__c(Id = execution.Id, SourceRecordId__c = testCase.Id);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Follow-up response.'));

        Test.startTest();
        // Update the tool arguments to reference a real case so GetRecordDetails can succeed
        update new ExecutionStep__c(
            Id = [SELECT Id FROM ExecutionStep__c WHERE ToolCallId__c = 'call-ff-resume-001' AND StepType__c = 'ToolCall' LIMIT 1]
            .Id,
            ToolArguments__c = '{"recordId":"' + testCase.Id + '"}'
        );
        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, null);
        Test.stopTest();

        // Fail Fast mode should have selected RETRY_FAILED_TOOL.
        // Since the tool succeeded (real data), the execution should not remain Failed.
        AgentExecution__c updated = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :execution.Id];
        System.assertNotEquals('Failed', updated.ExecutionStatus__c, 'Fail Fast mode resume with RETRY_FAILED_TOOL should proceed when the tool succeeds');
    }

    @IsTest
    static void testResume_RetryFailedHttpTool_DoesNotPerformDmlBeforeCallout() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Resume HTTP Function LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Resume_HTTP_Function_Agent').withType('Direct').withLLM(llm.Id).save();
        update new AIAgentDefinition__c(Id = agent.Id, ErrorRecoveryMode__c = 'Fail Fast');
        agent = [SELECT Id, DeveloperName__c, RuntimeStrategy__c, LLMConfiguration__c, ErrorRecoveryMode__c FROM AIAgentDefinition__c WHERE Id = :agent.Id];

        AgentCapability__c capability = TestFactory.newCapability().withAgent(agent.Id).withName('resume_http_function_tool').build();
        capability.ImplementationType__c = 'Standard';
        capability.StandardActionType__c = 'HttpCallout';
        capability.BackendConfiguration__c = '{"namedCredential":"ResumeHttpNc","endpoint":"/retry","method":"GET"}';
        capability.Parameters__c = '{"type":"object","properties":{}}';
        insert capability;

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            ExecutionType__c = 'Direct',
            ExecutionStatus__c = 'Failed',
            ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
            CurrentTurnIdentifier__c = 'turn-resume-http-function-001',
            User__c = UserInfo.getUserId()
        );
        insert execution;

        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolCall',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                ToolCallId__c = 'call-resume-http-function-001',
                ToolArguments__c = '{}',
                TurnCount__c = 1
            ),
            new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = capability.CapabilityName__c,
                ToolCallId__c = 'call-resume-http-function-001',
                ToolResult__c = '{"isSuccess":false}',
                IsError__c = true,
                TurnCount__c = 1
            )
        };

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.serverError());

        Test.startTest();
        AgentExecutionService.ExecutionResult result = orchestrator.resume(execution.Id, new ExecutionResumeModels.ResumeOptions().withRetryFailedTool(true));
        Test.stopTest();

        System.assertEquals(capability.CapabilityName__c, 'resume_http_function_tool', 'Sanity check that the HTTP retry tool was configured');

        AgentExecution__c updated = [
            SELECT ExecutionStatus__c, FunctionResumeCount__c, LastFunctionResumeTimestamp__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :execution.Id
        ];
        System.assertEquals('Failed', updated.ExecutionStatus__c, 'Failed HTTP retry should fail gracefully instead of throwing a callout exception');
        System.assertEquals(1, Integer.valueOf(updated.FunctionResumeCount__c), 'Resume tracking should be updated after the tool call completes');
        System.assertNotEquals(null, updated.LastFunctionResumeTimestamp__c, 'Resume timestamp should be recorded');
        System.assert(String.isNotBlank(updated.ErrorMessage__c), 'Failure details should be preserved after the retry');
        System.assert(String.isNotBlank(result.errorCode), 'The resume result should include the tool failure code');
    }

    @IsTest
    static void testStart_RequiresUserId() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Func LLM Validate').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Func_Validate_Agent').withType('Direct').withLLM(llm.Id).save();

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userMessage = 'Summarize';

        DirectRuntimeService orchestrator = new DirectRuntimeService(agent);
        Boolean threw = false;
        try {
            orchestrator.start(agent.DeveloperName__c, payload);
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Missing userId should throw orchestration exception');
    }

    @IsTest
    static void testExecute_AgentCapability_CreatesChildExecutionWithParentPayload() {
        TestFactory.FunctionAgentSetup setup = createAgentCapabilityFunctionSetup('Direct_AgentCap_Create');
        Case testCase = TestFactory.newCase().withSubject('Agent capability case').save();

        AgentCapability__c agentCap = [
            SELECT CapabilityName__c, ImplementationDetail__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND ImplementationType__c = 'Agent'
            LIMIT 1
        ];

        Test.setMock(HttpCalloutMock.class, MockHttpResponses.toolCall(agentCap.CapabilityName__c, '{"request":"Summarize this"}'));

        Test.startTest();
        DirectRuntimeService orchestrator = new DirectRuntimeService(setup.agentDefinition);
        DirectExecutionResult result = orchestrator.execute('Run child agent', testCase.Id, UserInfo.getUserId(), 'turn-agent-cap-001', null);
        Test.stopTest();

        System.assertNotEquals(null, result.executionId, 'Should create parent execution');

        List<AgentExecution__c> childExecs = [
            SELECT Id, ParentExecution__c, AIAgentDefinition__r.DeveloperName__c, TriggerPayload__c, TriggerSource__c
            FROM AgentExecution__c
            WHERE ParentExecution__c = :result.executionId
        ];
        System.assert(childExecs.size() >= 1, 'Should create at least one child execution');

        AgentExecution__c firstChild = childExecs[0];
        System.assertEquals(
            agentCap.ImplementationDetail__c,
            firstChild.AIAgentDefinition__r.DeveloperName__c,
            'Child execution should target the configured child agent'
        );
        System.assertEquals('AgentCapability', firstChild.TriggerSource__c, 'Child trigger source should be AgentCapability');

        Map<String, Object> triggerData = (Map<String, Object>) JSON.deserializeUntyped(firstChild.TriggerPayload__c);
        System.assertNotEquals(null, triggerData.get('toolCallId'), 'Trigger payload should include toolCallId');
        System.assertEquals(agentCap.CapabilityName__c, triggerData.get('toolName'), 'Trigger payload should include toolName');
    }

    @IsTest
    static void testOnChildComplete_Success_CreatesToolResultStep() {
        TestFactory.FunctionAgentSetup setup = createAgentCapabilityFunctionSetup('Direct_AgentCap_Success');

        AgentCapability__c agentCap = [
            SELECT CapabilityName__c, ImplementationDetail__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND ImplementationType__c = 'Agent'
            LIMIT 1
        ];

        AIAgentDefinition__c childAgentDef = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c = :agentCap.ImplementationDetail__c
            LIMIT 1
        ];

        AgentExecution__c parentExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-onchild-func-001')
            .save();

        String toolCallId = 'call_agent_001';
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Completed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-child-func-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        childExec.TriggerSource__c = 'AgentCapability';
        childExec.TriggerPayload__c = JSON.serialize(
            new Map<String, String>{ 'toolCallId' => toolCallId, 'toolName' => agentCap.CapabilityName__c, 'parentExecutionId' => parentExec.Id }
        );
        update childExec;

        Account createdByChild = TestFactory.newAccount().withName('Child Propagated Account').save();
        insert new ContextReference__c(
            AgentExecution__c = childExec.Id,
            RecordId__c = createdByChild.Id,
            RecordType__c = 'Account',
            ReferenceRole__c = ContextManagerService.ReferenceRole.Created.name(),
            ReferenceSource__c = 'Tool Output',
            Status__c = ContextManagerService.ReferenceStatus.Active.name(),
            LastUsedAt__c = Datetime.now(),
            UseCount__c = 1,
            Explanation__c = 'Created by child execution.'
        );

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'childExecutionId' => childExec.Id,
            'completedAgent' => childAgentDef.DeveloperName__c,
            'success' => true,
            'response' => 'Child agent completed the analysis.',
            'errorMessage' => null,
            'errorCode' => null,
            'contextEffects' => new ContextManagerService().getPropagatableContextPayload(childExec.Id)
        };

        Test.startTest();
        DirectRuntimeService orch = new DirectRuntimeService(setup.agentDefinition);
        orch.onChildComplete(parentExec.Id, asyncPayload);
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT ToolCallId__c, ToolName__c, ToolResult__c, IsError__c, StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :parentExec.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResults.size(), 'Should create exactly one ToolResult step on parent');
        System.assertEquals(toolCallId, toolResults[0].ToolCallId__c, 'ToolResult should map back to the original toolCallId');
        System.assertEquals(agentCap.CapabilityName__c, toolResults[0].ToolName__c, 'ToolResult should reference the agent capability name');
        System.assertEquals(false, toolResults[0].IsError__c, 'Successful child should not be marked as error');

        ContextReference__c parentReference = [
            SELECT RecordId__c, ReferenceRole__c, ReferenceSource__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :parentExec.Id AND RecordId__c = :String.valueOf(createdByChild.Id)
            LIMIT 1
        ];
        System.assertEquals(ContextManagerService.ReferenceRole.Created.name(), parentReference.ReferenceRole__c);
        System.assertEquals('Tool Output', parentReference.ReferenceSource__c);
    }

    @IsTest
    static void testOnChildComplete_Failure_CreatesErrorToolResult() {
        TestFactory.FunctionAgentSetup setup = createAgentCapabilityFunctionSetup('Direct_AgentCap_Failure');

        AgentCapability__c agentCap = [
            SELECT CapabilityName__c, ImplementationDetail__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND ImplementationType__c = 'Agent'
            LIMIT 1
        ];

        AIAgentDefinition__c childAgentDef = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c = :agentCap.ImplementationDetail__c LIMIT 1];

        AgentExecution__c parentExec = TestFactory.newExecution()
            .withAgent(setup.agentDefinition.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_AWAITING_ACTION)
            .withTurnIdentifier('turn-onchild-fail-001')
            .save();

        String toolCallId = 'call_agent_fail_001';
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-child-fail-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        childExec.TriggerPayload__c = JSON.serialize(
            new Map<String, String>{ 'toolCallId' => toolCallId, 'toolName' => agentCap.CapabilityName__c, 'parentExecutionId' => parentExec.Id }
        );
        update childExec;

        Map<String, Object> asyncPayload = new Map<String, Object>{
            'childExecutionId' => childExec.Id,
            'completedAgent' => agentCap.ImplementationDetail__c,
            'success' => false,
            'response' => null,
            'errorMessage' => 'LLM rate limit exceeded',
            'errorCode' => 'RATE_LIMIT'
        };

        Test.startTest();
        DirectRuntimeService orch = new DirectRuntimeService(setup.agentDefinition);
        orch.onChildComplete(parentExec.Id, asyncPayload);
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT ToolCallId__c, ToolResult__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :parentExec.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResults.size(), 'Should create a ToolResult step even on failure');
        System.assertEquals(toolCallId, toolResults[0].ToolCallId__c, 'Should map back to original toolCallId');
        System.assertEquals(true, toolResults[0].IsError__c, 'Failed child should be marked as error');
    }
}
