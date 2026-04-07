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
            .withType('Direct')
            .withLLM(llm.Id)
            .withAuditLevel('Standard')
            .save();

        TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Account').withName('cfgsvc_create_account').save();

        AgentCapability__c disabled = TestFactory.newCapability().withAgent(agent.Id).forCreateRecord('Contact').withName('cfgsvc_disabled_cap').build();
        disabled.ExposureLevel__c = 'Disabled';
        insert disabled;
    }

    private static void configureTestExecutionIdentityProfiles() {
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

    @IsTest
    static void testResolveExecutionIdentityForAgent_BlankProfile_ReturnsCurrentUserContext() {
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().build();

        AIAgentConfigService.ResolvedExecutionIdentity resolved = AIAgentConfigService.resolveExecutionIdentityForAgent(agent);

        System.assertEquals(false, resolved.requiresPrivilegedContext, 'Blank profile should stay in current user context');
        System.assertEquals(null, resolved.profileDeveloperName, 'Blank profile should not resolve a profile key');
        System.assertEquals(null, resolved.namedCredentialDeveloperName, 'Blank profile should not resolve a Named Credential');
    }

    @IsTest
    static void testResolveExecutionIdentityForAgent_ProfileConfigured_ReturnsNamedCredential() {
        configureTestExecutionIdentityProfiles();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withExecutionIdentityProfile('FrameworkServiceUser').build();

        AIAgentConfigService.ResolvedExecutionIdentity resolved = AIAgentConfigService.resolveExecutionIdentityForAgent(agent);

        System.assertEquals(true, resolved.requiresPrivilegedContext, 'Configured profile should require privileged context');
        System.assertEquals('FrameworkServiceUser', resolved.profileDeveloperName, 'Resolved profile key should match the agent');
        System.assertEquals('AgentStudio_ServiceUser', resolved.namedCredentialDeveloperName, 'Resolver should return the metadata Named Credential');
    }

    @IsTest
    static void testResolveExecutionIdentityForExecution_UsesSnapshotValues() {
        configureTestExecutionIdentityProfiles();
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withLLM(llm.Id).withExecutionIdentityProfile('FrameworkServiceUser').save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionIdentity('FrameworkServiceUser', 'AgentStudio_ServiceUser')
            .save();

        update new AIAgentDefinition__c(Id = agent.Id, ExecutionIdentityProfileDeveloperName__c = null);

        AIAgentConfigService.ResolvedExecutionIdentity resolved = AIAgentConfigService.resolveExecutionIdentityForExecution(execution.Id);

        System.assertEquals(true, resolved.requiresPrivilegedContext, 'Existing execution should keep its snapshotted privileged identity');
        System.assertEquals('FrameworkServiceUser', resolved.profileDeveloperName, 'Execution snapshot should remain authoritative');
        System.assertEquals('AgentStudio_ServiceUser', resolved.namedCredentialDeveloperName, 'Execution snapshot should include the Named Credential');
    }
}
