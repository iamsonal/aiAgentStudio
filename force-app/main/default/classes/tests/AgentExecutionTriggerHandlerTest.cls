/**
 * @description Focused tests for trigger-based batch chaining keyed by BatchId__c.
 *   Migrated from workflow-based setup to pipeline-based setup.
 */
@IsTest
private class AgentExecutionTriggerHandlerTest {
    private static TestFactory.FunctionAgentSetup createAgentCapabilityFunctionSetup(String agentNamePrefix) {
        LLMConfiguration__c sharedLlm = TestFactory.newLLMConfiguration().withName(agentNamePrefix + ' LLM').save();
        AIAgentDefinition__c childAgent = TestFactory.newAgentDefinition().withName(agentNamePrefix + '_Child').withType('Direct').withLLM(sharedLlm.Id).save();

        AgentCapability__c agentCap = TestFactory.newCapability().forChildAgent(childAgent.DeveloperName__c).build();

        return TestFactory.createFunctionAgentSetup().withLlm(sharedLlm).withCapability(agentCap).withExecution().save();
    }

    @TestSetup
    static void setupData() {
        AIAgentFrameworkSettings__c settings = new AIAgentFrameworkSettings__c(SetupOwnerId = UserInfo.getOrganizationId(), BulkConcurrencyLimit__c = 2);
        insert settings;

        TestFactory.createPipelineSetup().save();
    }

    private static PipelineDefinition__c getPipelineDef() {
        return [SELECT Id FROM PipelineDefinition__c ORDER BY CreatedDate DESC LIMIT 1];
    }

    @IsTest
    static void testBatchChainingMovesPendingToProcessing() {
        AIAgentFrameworkSettings.clearCache();

        AIAgentDefinition__c childAgent = [SELECT Id FROM AIAgentDefinition__c ORDER BY CreatedDate ASC LIMIT 1];
        String batchId = 'BATCH-TRIGGER-CHAIN-1';

        AgentExecution__c exec1 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        AgentExecution__c exec2 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        AgentExecution__c exec3 = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        exec1.ExecutionStatus__c = 'Completed';
        exec2.ExecutionStatus__c = 'Completed';
        update new List<AgentExecution__c>{ exec1, exec2 };

        AgentExecution__c updatedExec3 = [
            SELECT ExecutionStatus__c, ProcessingStartedAt__c
            FROM AgentExecution__c
            WHERE Id = :exec3.Id
        ];

        System.assertEquals('Processing', updatedExec3.ExecutionStatus__c, 'Pending execution should be moved to Processing by trigger chaining');
        System.assertNotEquals(null, updatedExec3.ProcessingStartedAt__c, 'ProcessingStartedAt__c should be set when chaining');
    }

    @IsTest
    static void testBatchChainingRespectsConcurrencyLimit() {
        AIAgentFrameworkSettings__c settings = AIAgentFrameworkSettings__c.getOrgDefaults();
        settings.BulkConcurrencyLimit__c = 1;
        upsert settings;
        AIAgentFrameworkSettings.clearCache();

        AIAgentDefinition__c childAgent = [SELECT Id FROM AIAgentDefinition__c ORDER BY CreatedDate ASC LIMIT 1];
        String batchId = 'BATCH-TRIGGER-CHAIN-2';

        AgentExecution__c completedExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        AgentExecution__c processingExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();
        processingExec.ProcessingStartedAt__c = Datetime.now();
        update processingExec;

        AgentExecution__c pendingExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        completedExec.ExecutionStatus__c = 'Completed';
        update completedExec;

        AgentExecution__c updatedPending = [
            SELECT ExecutionStatus__c
            FROM AgentExecution__c
            WHERE Id = :pendingExec.Id
        ];

        System.assertEquals('Pending', updatedPending.ExecutionStatus__c, 'Pending execution should remain pending when concurrency limit reached');
    }

    @IsTest
    static void testBatchChaining_SkipsFutureRetryExecutions() {
        AIAgentFrameworkSettings__c settings = AIAgentFrameworkSettings__c.getOrgDefaults();
        settings.BulkConcurrencyLimit__c = 2;
        upsert settings;
        AIAgentFrameworkSettings.clearCache();

        AIAgentDefinition__c childAgent = [SELECT Id FROM AIAgentDefinition__c ORDER BY CreatedDate ASC LIMIT 1];
        String batchId = 'BATCH-TRIGGER-CHAIN-3';

        AgentExecution__c completedExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();

        AgentExecution__c futureRetryExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withBatchId(batchId)
            .save();
        futureRetryExec.NextRetryAt__c = Datetime.now().addMinutes(10);
        update futureRetryExec;

        completedExec.ExecutionStatus__c = 'Completed';
        update completedExec;

        AgentExecution__c updatedPending = [
            SELECT ExecutionStatus__c
            FROM AgentExecution__c
            WHERE Id = :futureRetryExec.Id
        ];

        System.assertEquals('Pending', updatedPending.ExecutionStatus__c, 'Future retry execution should remain pending and not be chained');
    }

    @IsTest
    static void testChildFailure_UsesLatestExecutionStepError() {
        PipelineDefinition__c pipelineDef = getPipelineDef();
        List<PipelineStep__c> steps = [
            SELECT ChildAgent__c, ChildAgent__r.DeveloperName__c, ExecutionOrder__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :pipelineDef.Id
            ORDER BY ExecutionOrder__c ASC
            LIMIT 2
        ];

        AgentExecution__c parentExec = TestFactory.newPipelineExecution(pipelineDef.Id)
            .withUser(UserInfo.getUserId())
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-parent-error-001')
            .save();
        parentExec.CurrentPipelineStep__c = String.valueOf(Integer.valueOf(steps[0].ExecutionOrder__c));
        update parentExec;

        List<PipelineRunStep__c> runSteps = new List<PipelineRunStep__c>();
        Integer stepOrder = 1;
        for (PipelineStep__c step : steps) {
            runSteps.add(
                new PipelineRunStep__c(
                    AgentExecution__c = parentExec.Id,
                    StepName__c = step.ChildAgent__r.DeveloperName__c,
                    StepOrder__c = stepOrder,
                    Status__c = 'in_progress'
                )
            );
            stepOrder++;
        }
        insert runSteps;

        AIAgentDefinition__c childAgent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c WHERE Id = :steps[0].ChildAgent__c LIMIT 1];
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Pending')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-child-error-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        update childExec;

        ExecutionStep__c firstError = new ExecutionStep__c(
            AgentExecution__c = childExec.Id,
            StepType__c = 'Error',
            StepRole__c = 'Assistant',
            Content__c = 'First failure',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-2)
        );
        insert firstError;

        ExecutionStep__c latestError = new ExecutionStep__c(
            AgentExecution__c = childExec.Id,
            StepType__c = 'Error',
            StepRole__c = 'Assistant',
            Content__c = 'Latest failure',
            TurnCount__c = 1,
            Timestamp__c = Datetime.now().addMinutes(-1)
        );
        insert latestError;

        childExec.ExecutionStatus__c = 'Failed';
        update childExec;

        AgentExecution__c updatedParent = [
            SELECT ExecutionStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :parentExec.Id
            LIMIT 1
        ];
        System.assertEquals('Failed', updatedParent.ExecutionStatus__c, 'Pipeline should fail on child error');
        System.assert(
            updatedParent.ErrorMessage__c != null && updatedParent.ErrorMessage__c.contains('Latest failure'),
            'Pipeline error should use the most recent execution-step message'
        );
    }

    @IsTest
    static void testChildComplete_NotifyThrows_FailsParentWithError() {
        // Create a pipeline definition that intentionally has NO PipelineStep__c records.
        // SequentialPipelineOrchestrator.configurePipeline() throws when no steps exist.
        PipelineDefinition__c emptyPipeline = new PipelineDefinition__c(Name = 'Empty Pipeline', DeveloperName__c = 'Empty_Pipeline_Test', IsActive__c = true);
        insert emptyPipeline;

        AgentExecution__c parentExec = new AgentExecution__c(
            PipelineDefinition__c = emptyPipeline.Id,
            User__c = UserInfo.getUserId(),
            ExecutionType__c = 'Pipeline',
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
            TriggerSource__c = 'Apex',
            CurrentPipelineStep__c = 'some_step'
        );
        insert parentExec;

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c childAgentDef = TestFactory.newAgentDefinition().withType('Direct').withLLM(llm.Id).save();

        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        update childExec;

        childExec.ExecutionStatus__c = 'Completed';
        update childExec;

        AgentExecution__c updatedParent = [
            SELECT ExecutionStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :parentExec.Id
        ];
        System.assertEquals('Failed', updatedParent.ExecutionStatus__c, 'Parent must be Failed when notify throws, not stuck in Processing');
        System.assertNotEquals(null, updatedParent.ErrorMessage__c, 'Error message must be populated so the failure cause is visible');
    }

    @IsTest
    static void testChildCompletion_RoutesToParentRuntime() {
        TestFactory.FunctionAgentSetup setup = createAgentCapabilityFunctionSetup('Trigger_Route');

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
            .withTurnIdentifier('turn-trigger-route-001')
            .save();

        String toolCallId = 'call_agent_trigger_001';
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-child-trigger-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        childExec.TriggerSource__c = 'AgentCapability';
        childExec.TriggerPayload__c = JSON.serialize(
            new Map<String, String>{ 'toolCallId' => toolCallId, 'toolName' => agentCap.CapabilityName__c, 'parentExecutionId' => parentExec.Id }
        );
        update childExec;

        Test.startTest();
        childExec.ExecutionStatus__c = 'Completed';
        update childExec;
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT ToolCallId__c, ToolName__c, StepType__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :parentExec.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResults.size(), 'Trigger handler should route to the parent runtime, which creates a ToolResult');
        System.assertEquals(toolCallId, toolResults[0].ToolCallId__c, 'ToolResult should reference the original toolCallId from child TriggerPayload');
    }

    @IsTest
    static void testChildFailure_RoutesToParentAndCreatesErrorResult() {
        TestFactory.FunctionAgentSetup setup = createAgentCapabilityFunctionSetup('Trigger_Fail');

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
            .withTurnIdentifier('turn-trigger-fail-001')
            .save();

        String toolCallId = 'call_agent_trigger_fail_001';
        AgentExecution__c childExec = TestFactory.newExecution()
            .withAgent(childAgentDef.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-child-trigger-fail-001')
            .save();
        childExec.ParentExecution__c = parentExec.Id;
        childExec.TriggerSource__c = 'AgentCapability';
        childExec.TriggerPayload__c = JSON.serialize(
            new Map<String, String>{ 'toolCallId' => toolCallId, 'toolName' => agentCap.CapabilityName__c, 'parentExecutionId' => parentExec.Id }
        );
        update childExec;

        Test.startTest();
        childExec.ExecutionStatus__c = 'Failed';
        update childExec;
        Test.stopTest();

        List<ExecutionStep__c> toolResults = [
            SELECT ToolCallId__c, IsError__c, Content__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :parentExec.Id AND StepType__c = 'ToolResult'
        ];
        System.assertEquals(1, toolResults.size(), 'Trigger handler should route failed child to the parent runtime');
        System.assertEquals(true, toolResults[0].IsError__c, 'ToolResult for failed child should be marked as error');
    }
}
