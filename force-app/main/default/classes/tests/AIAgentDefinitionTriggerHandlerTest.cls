/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@IsTest
private class AIAgentDefinitionTriggerHandlerTest {
    private static AIAgentDefinition__c buildAgent(Id llmId, String agentType, String recoveryMode) {
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llmId).withType(agentType).build();
        agent.ErrorRecoveryMode__c = recoveryMode;
        return agent;
    }

    private static String buildGraphForCapabilities(List<AgentCapability__c> capabilities) {
        List<String> entryTools = new List<String>();
        for (AgentCapability__c capability : capabilities) {
            if (String.isNotBlank(capability.CapabilityName__c)) {
                entryTools.add(capability.CapabilityName__c);
            }
        }
        return JSON.serialize(new Map<String, Object>{ 'version' => '3.0', 'entry' => entryTools, 'flow' => new List<Object>() });
    }

    private static TestFactory.AgentSetup createAgentWithGraph() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withStandardActions().save();

        List<AgentCapability__c> capabilities = [
            SELECT CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :setup.agentDefinition.Id AND ExposureLevel__c = 'External'
            ORDER BY CapabilityName__c ASC
        ];
        update new AIAgentDefinition__c(
            Id = setup.agentDefinition.Id,
            EnableToolFlowGraph__c = true,
            ToolFlowGraph__c = buildGraphForCapabilities(capabilities)
        );

        setup.agentDefinition = [
            SELECT
                Id,
                ToolFlowGraph__c,
                ToolFlowGraphWarning__c,
                EnableToolFlowGraph__c,
                EnableParallelToolCalling__c,
                RuntimeStrategy__c,
                InstructionsPrompt__c
            FROM AIAgentDefinition__c
            WHERE Id = :setup.agentDefinition.Id
        ];
        return setup;
    }

    private static AIAgentDefinition__c requeryAgent(Id agentDefId) {
        return [
            SELECT Id, ToolFlowGraph__c, ToolFlowGraphWarning__c, EnableToolFlowGraph__c
            FROM AIAgentDefinition__c
            WHERE Id = :agentDefId
        ];
    }

    @IsTest
    static void conversationalInsert_rejectsFailFastMode() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        Database.SaveResult result = Database.insert(buildAgent(llm.Id, 'Conversational', 'Fail Fast'), false);

        System.assertEquals(false, result.isSuccess(), 'Conversational agents should not allow Fail Fast mode');
        System.assert(result.getErrors()[0].getMessage().contains('Autonomous'), 'Validation should require Autonomous mode');
    }

    @IsTest
    static void emailUpdate_rejectsFailFastMode() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = buildAgent(llm.Id, 'Email', 'Autonomous');
        insert agent;

        Database.SaveResult result = Database.update(new AIAgentDefinition__c(Id = agent.Id, ErrorRecoveryMode__c = 'Fail Fast'), false);

        System.assertEquals(false, result.isSuccess(), 'Conversational email-channel agents should not allow Fail Fast mode on update');
        System.assert(result.getErrors()[0].getMessage().contains('Autonomous'), 'Validation should require Autonomous mode');
    }

    @IsTest
    static void conversationalInsert_defaultsBlankModeToAutonomous() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = buildAgent(llm.Id, 'Conversational', null);

        insert agent;

        agent = [
            SELECT ErrorRecoveryMode__c
            FROM AIAgentDefinition__c
            WHERE Id = :agent.Id
        ];
        System.assertEquals('Autonomous', agent.ErrorRecoveryMode__c, 'Conversational agents should default to Autonomous mode when blank');
    }

    @IsTest
    static void insert_defaultsBlankResumeModeToLlmFirst() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = buildAgent(llm.Id, 'Direct', 'Autonomous');
        agent.ResumeMode__c = null;

        insert agent;

        agent = [
            SELECT ResumeMode__c
            FROM AIAgentDefinition__c
            WHERE Id = :agent.Id
        ];
        System.assertEquals('LLM First', agent.ResumeMode__c, 'Agents should default Resume Mode to LLM First when blank');
    }

    @IsTest
    static void functionAgent_allowsFailFastMode() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = buildAgent(llm.Id, 'Direct', 'Fail Fast');

        insert agent;

        agent = [
            SELECT ErrorRecoveryMode__c
            FROM AIAgentDefinition__c
            WHERE Id = :agent.Id
        ];
        System.assertEquals('Fail Fast', agent.ErrorRecoveryMode__c, 'Direct agents should still allow Fail Fast mode');
    }

    @IsTest
    static void parallelToolCallingChange_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        Boolean currentVal = setup.agentDefinition.EnableParallelToolCalling__c;

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, EnableParallelToolCalling__c = !currentVal);
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after parallel calling toggle');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('Parallel'), 'Warning should mention parallel tool calling');
    }

    @IsTest
    static void runtimeStrategyChange_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, RuntimeStrategy__c = 'Direct');
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after runtime strategy change');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('Runtime strategy'), 'Warning should mention runtime strategy change');
    }

    @IsTest
    static void instructionsPromptChange_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, InstructionsPrompt__c = 'Always verify information before escalating to support.');
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after instructions prompt change');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('instructions'), 'Warning should mention instructions update');
    }

    @IsTest
    static void toolFlowGraphSave_clearsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        update new AIAgentDefinition__c(Id = agentId, ToolFlowGraphWarning__c = 'Stale: capabilities changed');

        String newGraph = '{"version":"3.0","entry":["tool_b"],"flow":[]}';

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, ToolFlowGraph__c = newGraph);
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be cleared after graph save');
    }

    @IsTest
    static void disableToolFlowGraph_clearsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        update new AIAgentDefinition__c(Id = agentId, ToolFlowGraphWarning__c = 'Stale: runtime strategy changed');

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, EnableToolFlowGraph__c = false);
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be cleared when tool flow graph is disabled');
    }

    @IsTest
    static void configChange_doesNotSetWarningWhenGraphBlank() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withStandardActions().save();
        Id agentId = setup.agentDefinition.Id;

        update new AIAgentDefinition__c(Id = agentId, EnableToolFlowGraph__c = true);

        Test.startTest();
        update new AIAgentDefinition__c(Id = agentId, EnableParallelToolCalling__c = false);
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertEquals(null, updated.ToolFlowGraphWarning__c, 'No warning should be set when ToolFlowGraph__c is blank');
    }

    @IsTest
    static void multipleConfigChanges_joinToolFlowGraphWarnings() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        Boolean currentParallel = setup.agentDefinition.EnableParallelToolCalling__c;

        Test.startTest();
        update new AIAgentDefinition__c(
            Id = agentId,
            EnableParallelToolCalling__c = !currentParallel,
            RuntimeStrategy__c = 'Direct',
            InstructionsPrompt__c = 'New instructions for multi-change test'
        );
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set for multiple changes');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('Parallel'), 'Warning should mention parallel calling');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('Runtime strategy'), 'Warning should mention runtime strategy');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('instructions'), 'Warning should mention instructions');
    }
}
