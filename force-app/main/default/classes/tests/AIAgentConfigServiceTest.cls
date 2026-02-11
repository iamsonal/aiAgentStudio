/**
 * @description Focused tests for AIAgentConfigService using shared TestFactory helpers
 */
@IsTest
private class AIAgentConfigServiceTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('CfgSvc LLM').save();

        AIAgentDefinition__c agent = TestFactory.newAgentDefinition()
            .withName('CfgSvc_Agent')
            .withType('Function')
            .withLLM(llm.Id)
            .withAuditLevel('Standard')
            .save();

        TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Account').withName('cfgsvc_create_account').save();

        AgentCapability__c disabled = TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Contact').withName('cfgsvc_disabled_cap').build();
        disabled.ExposureLevel__c = 'Disabled';
        insert disabled;
    }

    @IsTest
    static void testGetAgentDefinition_ByIdAndDeveloperName() {
        AIAgentDefinition__c agent = [SELECT Id, DeveloperName__c FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'CfgSvc_Agent%' LIMIT 1];

        AIAgentDefinition__c byId = AIAgentConfigService.getAgentDefinition(agent.Id);
        System.assertEquals(agent.Id, byId.Id, 'Should return agent by Id');

        AIAgentDefinition__c byName = AIAgentConfigService.getAgentDefinitionByDeveloperName(agent.DeveloperName__c);
        System.assertEquals(agent.Id, byName.Id, 'Should return agent by developer name');
    }

    @IsTest
    static void testGetLLMConfiguration_ById() {
        LLMConfiguration__c llm = [SELECT Id FROM LLMConfiguration__c WHERE Name = 'CfgSvc LLM' LIMIT 1];

        LLMConfiguration__c loaded = AIAgentConfigService.getLLMConfiguration(llm.Id);
        System.assertEquals(llm.Id, loaded.Id, 'Should return LLM configuration by Id');
    }

    @IsTest
    static void testGetCapability_ByIdAndName() {
        AgentCapability__c capability = [
            SELECT Id, CapabilityName__c, AIAgentDefinition__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'cfgsvc_create_account'
            LIMIT 1
        ];

        AgentCapability__c byId = AIAgentConfigService.getCapabilityById(capability.Id);
        System.assertEquals(capability.Id, byId.Id, 'Should return capability by Id');

        AgentCapability__c byName = AIAgentConfigService.getCapability(capability.AIAgentDefinition__c, capability.CapabilityName__c);
        System.assertEquals(capability.Id, byName.Id, 'Should return capability by name');
    }

    @IsTest
    static void testGetCapabilitiesByAgentId_ExcludesDisabled() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'CfgSvc_Agent%' LIMIT 1];

        List<AgentCapability__c> capabilities = AIAgentConfigService.getCapabilitiesByAgentId(agent.Id);

        Boolean hasActive = false;
        Boolean hasDisabled = false;
        for (AgentCapability__c cap : capabilities) {
            if (cap.CapabilityName__c == 'cfgsvc_create_account') {
                hasActive = true;
            }
            if (cap.CapabilityName__c == 'cfgsvc_disabled_cap') {
                hasDisabled = true;
            }
        }

        System.assert(hasActive, 'Should return active capabilities');
        System.assert(!hasDisabled, 'Disabled capabilities should be excluded');
    }

    @IsTest
    static void testGetCapabilitiesByNames_ReturnsOnlyExisting() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'CfgSvc_Agent%' LIMIT 1];

        Set<String> names = new Set<String>{ 'cfgsvc_create_account', 'missing_capability' };
        Map<String, AgentCapability__c> results = AIAgentConfigService.getCapabilitiesByNames(agent.Id, names);

        System.assert(results.containsKey('cfgsvc_create_account'), 'Existing capability should be returned');
        System.assert(!results.containsKey('missing_capability'), 'Missing capability should not be returned');
    }

    @IsTest
    static void testGetCapability_Unknown_Throws() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c LIKE 'CfgSvc_Agent%' LIMIT 1];

        Boolean threw = false;
        try {
            AIAgentConfigService.getCapability(agent.Id, 'no_such_capability');
        } catch (AIAgentConfigService.ConfigurationException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Unknown capability should throw ConfigurationException');
    }
}
