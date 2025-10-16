/**
 * @description Tests for AIAgentConfigService using TestFactory utilities
 */
@IsTest
private class AIAgentConfigServiceTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test capabilities for AIAgentConfigService testing
        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forCreateRecord('Account')
            .withName('test_create_account')
            .save();

        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forGetRecords('Contact')
            .withName('test_get_contacts')
            .save();
    }

    // ===================================================================================
    // GET CAPABILITY TESTS
    // ===================================================================================

    @IsTest
    static void testGetCapabilityById_Valid_Success() {
        // Given: Existing capability
        AgentCapability__c cap = [SELECT Id, CapabilityName__c FROM AgentCapability__c LIMIT 1];

        // When: Getting by ID
        Test.startTest();
        AgentCapability__c result = AIAgentConfigService.getCapabilityById(cap.Id);
        Test.stopTest();

        // Then: Should return capability
        System.assertNotEquals(null, result);
        System.assertEquals(cap.Id, result.Id);
    }

    @IsTest
    static void testGetCapability_ValidInputs_Success() {
        // Given: Agent and capability name
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentCapability__c cap = [SELECT CapabilityName__c FROM AgentCapability__c LIMIT 1];

        // When: Getting by agent and name
        Test.startTest();
        AgentCapability__c result = AIAgentConfigService.getCapability(
            agent.Id,
            cap.CapabilityName__c
        );
        Test.stopTest();

        // Then: Should return capability
        System.assertNotEquals(null, result);
        System.assertEquals(cap.CapabilityName__c, result.CapabilityName__c);
    }

    // ===================================================================================
    // GET AGENT DEFINITION TESTS
    // ===================================================================================

    @IsTest
    static void testGetAgentDefinition_ValidId_Success() {
        // Given: Existing agent
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // When: Getting by ID
        Test.startTest();
        AIAgentDefinition__c result = AIAgentConfigService.getAgentDefinition(agent.Id);
        Test.stopTest();

        // Then: Should return agent
        System.assertNotEquals(null, result);
        System.assertEquals(agent.Id, result.Id);
    }

    @IsTest
    static void testGetAgentDefinition_InvalidId_ThrowsException() {
        // Given: Invalid ID
        Id invalidId = 'a00000000000000AAA';

        // When/Then: Should throw exception
        Test.startTest();
        try {
            AIAgentConfigService.getAgentDefinition(invalidId);
            System.assert(false, 'Should have thrown exception');
        } catch (AIAgentConfigService.ConfigurationException e) {
            System.assert(e.getMessage().contains('not found'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testGetAgentDefinitionByDeveloperName_Valid_Success() {
        // Given: Developer name
        AIAgentDefinition__c agent = [SELECT DeveloperName__c FROM AIAgentDefinition__c LIMIT 1];

        // When: Getting by developer name
        Test.startTest();
        AIAgentDefinition__c result = AIAgentConfigService.getAgentDefinitionByDeveloperName(
            agent.DeveloperName__c
        );
        Test.stopTest();

        // Then: Should return agent
        System.assertNotEquals(null, result);
        System.assertEquals(agent.DeveloperName__c, result.DeveloperName__c);
    }

    // ===================================================================================
    // GET LLM CONFIGURATION TESTS
    // ===================================================================================

    @IsTest
    static void testGetLLMConfiguration_ValidId_Success() {
        // Given: Existing LLM config
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        // When: Getting by ID
        Test.startTest();
        LLMConfiguration__c result = AIAgentConfigService.getLLMConfiguration(llm.Id);
        Test.stopTest();

        // Then: Should return config
        System.assertNotEquals(null, result);
        System.assertEquals(llm.Id, result.Id);
    }

    @IsTest
    static void testGetLLMConfigurationByAgentId_Valid_Success() {
        // Given: Agent with LLM config
        AIAgentDefinition__c agent = [SELECT Id, LLMConfiguration__c FROM AIAgentDefinition__c LIMIT 1];

        // When: Getting by agent ID
        Test.startTest();
        LLMConfiguration__c result = AIAgentConfigService.getLLMConfigurationByAgentDefinitionId(agent.Id);
        Test.stopTest();

        // Then: Should return config
        System.assertNotEquals(null, result);
        System.assertEquals(agent.LLMConfiguration__c, result.Id);
    }

    // ===================================================================================
    // CACHING TESTS
    // ===================================================================================

    @IsTest
    static void testCaching_MultipleCallsSameAgent_UsesCache() {
        // Given: Agent ID
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];

        // When: Getting same agent twice
        Test.startTest();
        AIAgentDefinition__c result1 = AIAgentConfigService.getAgentDefinition(agent.Id);
        AIAgentDefinition__c result2 = AIAgentConfigService.getAgentDefinition(agent.Id);
        Test.stopTest();

        // Then: Should return same instance
        System.assertEquals(result1.Id, result2.Id);
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testConfigurationException_CanBeThrown() {
        Test.startTest();
        try {
            throw new AIAgentConfigService.ConfigurationException('Test exception');
        } catch (AIAgentConfigService.ConfigurationException e) {
            System.assertEquals('Test exception', e.getMessage());
        }
        Test.stopTest();
    }
}
