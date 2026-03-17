/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@IsTest
private class AgentCapabilityTriggerHandlerTest {
    private static AIAgentDefinition__c createAgent(String name, String type, Id llmId) {
        return TestFactory.newAgentDefinition().withName(name).withType(type).withLLM(llmId).save();
    }

    private static AgentCapability__c buildAgentCapability(Id parentAgentId, String childDeveloperName) {
        AgentCapability__c capability = TestFactory.newCapability().forChildAgent(childDeveloperName).build();
        capability.AIAgentDefinition__c = parentAgentId;
        return capability;
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

        return setup;
    }

    private static AIAgentDefinition__c requeryAgent(Id agentDefId) {
        return [
            SELECT Id, ToolFlowGraphWarning__c
            FROM AIAgentDefinition__c
            WHERE Id = :agentDefId
        ];
    }

    @IsTest
    static void insertAgentCapability_requiresActiveChildAgent() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c parentAgent = createAgent('Parent Agent Validation', 'Direct', llm.Id);

        Database.SaveResult result = Database.insert(buildAgentCapability(parentAgent.Id, 'Missing_Child_Agent'), false);

        System.assertEquals(false, result.isSuccess(), 'Insert should fail when child agent does not exist');
        System.assert(result.getErrors()[0].getMessage().contains('active child agent'), 'Error should require an active child agent');
    }

    @IsTest
    static void insertAgentCapability_rejectsSelfReference() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c parentAgent = createAgent('Self Ref Parent Agent', 'Direct', llm.Id);

        Database.SaveResult result = Database.insert(buildAgentCapability(parentAgent.Id, parentAgent.DeveloperName__c), false);

        System.assertEquals(false, result.isSuccess(), 'Insert should fail when parent agent references itself');
        System.assert(result.getErrors()[0].getMessage().contains('cannot target the same agent'), 'Error should mention self-reference');
    }

    @IsTest
    static void insertAgentCapability_clearsStandardActionTypeForAgent() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c parentAgent = createAgent('Parent Agent Cleanup', 'Direct', llm.Id);
        AIAgentDefinition__c childAgent = createAgent('Child Agent Cleanup', 'Direct', llm.Id);

        AgentCapability__c capability = buildAgentCapability(parentAgent.Id, childAgent.DeveloperName__c);
        capability.StandardActionType__c = 'GetRecordDetails';

        insert capability;

        capability = [
            SELECT StandardActionType__c, ImplementationDetail__c
            FROM AgentCapability__c
            WHERE Id = :capability.Id
        ];
        System.assertEquals(null, capability.StandardActionType__c, 'StandardActionType__c should be cleared for Agent capabilities');
        System.assertEquals(
            childAgent.DeveloperName__c,
            capability.ImplementationDetail__c,
            'Implementation detail should keep the child agent developer name'
        );
    }

    @IsTest
    static void insertAgentCapability_trimsImplementationDetail() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c parentAgent = createAgent('Parent Agent Trim', 'Direct', llm.Id);
        AIAgentDefinition__c childAgent = createAgent('Child Agent Trim', 'Direct', llm.Id);

        AgentCapability__c capability = buildAgentCapability(parentAgent.Id, '  ' + childAgent.DeveloperName__c + '  ');

        insert capability;

        capability = [SELECT ImplementationDetail__c FROM AgentCapability__c WHERE Id = :capability.Id];
        System.assertEquals(childAgent.DeveloperName__c, capability.ImplementationDetail__c, 'Implementation detail should be trimmed before save');
    }

    @IsTest
    static void capabilityInsert_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        Test.startTest();
        AgentCapability__c newCap = TestFactory.newCapability()
            .withAgent(agentId)
            .withName('new_capability_warning_test')
            .forCustomApex('ActionCaseProcessing')
            .build();
        insert newCap;
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after capability insert');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('added'), 'Warning should mention capabilities were added');
    }

    @IsTest
    static void capabilityUpdate_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        AgentCapability__c existingCap = [
            SELECT Id, Description__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agentId
            LIMIT 1
        ];

        Test.startTest();
        existingCap.Description__c = 'Updated description for warning test';
        update existingCap;
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after capability update');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('modified'), 'Warning should mention capabilities were modified');
    }

    @IsTest
    static void capabilityDelete_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        AgentCapability__c existingCap = [
            SELECT Id
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agentId
            LIMIT 1
        ];

        Test.startTest();
        delete existingCap;
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after capability delete');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('removed'), 'Warning should mention capabilities were removed');
    }

    @IsTest
    static void capabilityUndelete_setsToolFlowGraphWarning() {
        TestFactory.AgentSetup setup = createAgentWithGraph();
        Id agentId = setup.agentDefinition.Id;

        AgentCapability__c existingCap = [
            SELECT Id
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agentId
            LIMIT 1
        ];
        delete existingCap;

        update new AIAgentDefinition__c(Id = agentId, ToolFlowGraphWarning__c = null);

        Test.startTest();
        undelete existingCap;
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertNotEquals(null, updated.ToolFlowGraphWarning__c, 'Warning should be set after capability undelete');
        System.assert(updated.ToolFlowGraphWarning__c.containsIgnoreCase('restored'), 'Warning should mention capabilities were restored');
    }

    @IsTest
    static void capabilityMutation_doesNotSetToolFlowGraphWarningWhenGraphDisabled() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().withStandardActions().save();
        Id agentId = setup.agentDefinition.Id;

        Test.startTest();
        AgentCapability__c newCap = TestFactory.newCapability().withAgent(agentId).withName('new_cap_no_warn').forCustomApex('ActionCaseProcessing').build();
        insert newCap;
        Test.stopTest();

        AIAgentDefinition__c updated = requeryAgent(agentId);
        System.assertEquals(null, updated.ToolFlowGraphWarning__c, 'No warning should be set when flow graph is not enabled');
    }
}
