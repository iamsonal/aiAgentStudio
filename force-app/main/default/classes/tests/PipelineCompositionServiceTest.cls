@IsTest
private class PipelineCompositionServiceTest {
    @IsTest
    static void testStartExecution_RequiresSourceRecord() {
        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();

        try {
            PipelineCompositionService.startExecution('AnyPipeline', payload);
            System.assert(false, 'Expected pipeline composition start to require at least one source record');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(
                e.getMessage().contains('requires at least one source record'),
                'Failure should explain the missing pipeline source record requirement'
            );
        }
    }

    @IsTest
    static void testStartExecution_StartsPipelineComposition() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Pipeline Composition LLM').save();
        AIAgentDefinition__c childAgent = TestFactory.newAgentDefinition().withName('Pipeline Composition Child').withType('SingleShot').withLLM(llm.Id).save();

        PipelineDefinition__c pipelineDef = new PipelineDefinition__c(
            Name = 'Pipeline Composition Start',
            DeveloperName__c = 'Pipeline_Composition_Start',
            IsActive__c = true
        );
        insert pipelineDef;

        insert new PipelineStep__c(PipelineDefinition__c = pipelineDef.Id, ChildAgent__c = childAgent.Id, ExecutionOrder__c = 1, IsActive__c = true);

        Account sourceRecord = new Account(Name = 'Pipeline Composition Account');
        insert sourceRecord;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = sourceRecord.Id;
        payload.triggerSource = 'Apex';

        AgentExecutionService.ExecutionResult result = PipelineCompositionService.startExecution(pipelineDef.DeveloperName__c, payload);

        System.assertEquals(true, result.success, 'Composition service should start a pipeline successfully');
        System.assertNotEquals(null, result.executionId, 'Composition service should return the parent execution Id');

        AgentExecution__c parentExecution = [
            SELECT ExecutionType__c, PipelineDefinition__c, ExecutionStatus__c, TriggerSource__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
            LIMIT 1
        ];
        System.assertEquals(
            AIAgentConstants.EXECUTION_MODE_PIPELINE,
            parentExecution.ExecutionType__c,
            'Parent execution should be marked as a pipeline composition'
        );
        System.assertEquals(pipelineDef.Id, parentExecution.PipelineDefinition__c, 'Parent execution should reference the pipeline definition');
        System.assertEquals(
            'Pending',
            parentExecution.ExecutionStatus__c,
            'Pipeline start should leave the parent execution pending until the worker/child lifecycle advances it'
        );
        System.assertEquals('Apex', parentExecution.TriggerSource__c, 'Trigger source should flow through the composition boundary');
    }

    @IsTest
    static void testAgentExecutionService_StartExecutionRoutesPipelineThroughCompositionBoundary() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Pipeline Entry LLM').save();
        AIAgentDefinition__c childAgent = TestFactory.newAgentDefinition().withName('Pipeline Entry Child').withType('SingleShot').withLLM(llm.Id).save();

        PipelineDefinition__c pipelineDef = new PipelineDefinition__c(
            Name = 'Pipeline Entry Routing',
            DeveloperName__c = 'Pipeline_Entry_Routing',
            IsActive__c = true
        );
        insert pipelineDef;

        insert new PipelineStep__c(PipelineDefinition__c = pipelineDef.Id, ChildAgent__c = childAgent.Id, ExecutionOrder__c = 1, IsActive__c = true);

        Account sourceRecord = new Account(Name = 'Pipeline Entry Account');
        insert sourceRecord;

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.sourceRecordId = sourceRecord.Id;
        payload.triggerSource = 'API';

        AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(pipelineDef.DeveloperName__c, payload);

        System.assertEquals(true, result.success, 'Unified public entry should route pipeline names successfully');
        AgentExecution__c parentExecution = [
            SELECT ExecutionType__c, PipelineDefinition__c, TriggerSource__c
            FROM AgentExecution__c
            WHERE Id = :result.executionId
            LIMIT 1
        ];
        System.assertEquals(AIAgentConstants.EXECUTION_MODE_PIPELINE, parentExecution.ExecutionType__c, 'Execution should be marked as pipeline composition');
        System.assertEquals(
            pipelineDef.Id,
            parentExecution.PipelineDefinition__c,
            'Pipeline definition should be resolved directly, not through agent strategy indirection'
        );
        System.assertEquals('API', parentExecution.TriggerSource__c, 'Public entrypoint should preserve the trigger source');
    }

    @IsTest
    static void testStrategyRegistryRejectsPipelineCompositionMode() {
        System.assertEquals(
            false,
            ExecutionStrategyRegistryService.isKnownStrategyKey(AIAgentConstants.EXECUTION_MODE_PIPELINE),
            'Pipeline composition mode should not resolve as a normal agent runtime strategy'
        );
        System.assertEquals(
            null,
            ExecutionStrategyRegistryService.resolveDescriptor(AIAgentConstants.EXECUTION_MODE_PIPELINE),
            'Pipeline composition mode should not expose a strategy descriptor'
        );
    }

    @IsTest
    static void testRuntimeTraitsIgnorePipelineCompositionExecutions() {
        PipelineDefinition__c pipelineDef = new PipelineDefinition__c(
            Name = 'Pipeline Composition Traits',
            DeveloperName__c = 'Pipeline_Composition_Traits',
            IsActive__c = true
        );
        insert pipelineDef;

        AgentExecution__c execution = new AgentExecution__c(
            User__c = UserInfo.getUserId(),
            PipelineDefinition__c = pipelineDef.Id,
            ExecutionType__c = AIAgentConstants.EXECUTION_MODE_PIPELINE,
            ExecutionStatus__c = 'Processing',
            ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING
        );
        insert execution;

        InteractionRuntimeModels.TraitSet traits = RuntimeRegistryService.getTraits(execution.Id);
        System.assertEquals(false, traits.supportsContextLedger, 'Pipeline executions should not inherit iterative runtime traits');
        System.assertEquals(false, traits.routesFailuresBackToUser, 'Pipeline executions should not resolve as conversational runtimes');
        System.assertEquals(false, traits.supportsSameExecutionResume, 'Pipeline executions should not resolve through agent-runtime resume traits');
    }

    @IsTest
    static void testResumeExecution_RejectsNonPipelineExecution() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Non Pipeline Resume LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Non Pipeline Resume Agent').withType('Iterative').withLLM(llm.Id).save();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Iterative')
            .withStatus('Failed')
            .withProcessingStatus(AIAgentConstants.STATUS_FAILED)
            .save();

        try {
            PipelineCompositionService.resumeExecution(execution.Id, new ExecutionResumeModels.ResumeOptions().withReason('Test'));
            System.assert(false, 'Expected pipeline composition resume to reject non-pipeline executions');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('not a pipeline composition run'), 'Failure should make the composition boundary explicit');
        }
    }
}
