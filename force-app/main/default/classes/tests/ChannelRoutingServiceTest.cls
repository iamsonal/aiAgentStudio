@IsTest
private class ChannelRoutingServiceTest {
    private static final String SAMPLE_ENDPOINT = 'sample-routing@example.invalid';
    private static final String MISSING_AGENT_ENDPOINT = 'missing-agent-routing@example.invalid';

    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Sample Route LLM').save();
        TestFactory.newAgentDefinition().withName('Sample Route Target Agent').withType('Iterative').withLLM(llm.Id).save();
    }

    @IsTest
    static void testResolveInboundRoute_ResolvesPackagedSampleRoute() {
        ChannelRoutingService service = new ChannelRoutingService();

        ChannelRoutingService.ResolvedRoute route = service.resolveInboundRoute(RuntimeRegistryService.CHANNEL_EMAIL, 'Case', SAMPLE_ENDPOINT);

        System.assertNotEquals(null, route, 'Sample route should resolve for the packaged endpoint template');
        System.assertEquals('Sample_Route_Target_Agent', route.agentDeveloperName, 'Route should target the packaged sample agent developer name');
        System.assertEquals('Sample_Email_Inbound_Route', route.endpointDeveloperName, 'Route should bind to the packaged endpoint template');
        System.assertEquals('Sample_Route_Session', route.sessionPolicyDeveloperName, 'Route should bind to the packaged session-policy template');

        SessionPolicy__mdt sessionPolicy = service.loadSessionPolicy(route, 'Case');
        System.assertNotEquals(null, sessionPolicy, 'Named sample session policy should load successfully');
        System.assertEquals('Sample_Route_Session', sessionPolicy.DeveloperName, 'Loaded policy should match the packaged sample template');
    }

    @IsTest
    static void testResolveInboundRoute_ThrowsWhenSampleRouteTargetsMissingAgent() {
        ChannelRoutingService service = new ChannelRoutingService();

        try {
            service.resolveInboundRoute(RuntimeRegistryService.CHANNEL_EMAIL, 'Case', MISSING_AGENT_ENDPOINT);
            System.assert(false, 'Expected active route with missing agent developer name to fail fast');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Missing_Sample_Route_Agent'), 'Failure should identify the missing agent developer name');
        }
    }

    @IsTest
    static void testLoadSessionPolicy_ThrowsWhenNamedPolicyMissing() {
        ChannelRoutingService service = new ChannelRoutingService();
        ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService.ResolvedRoute();
        route.endpointDeveloperName = 'AdHocEndpoint';
        route.sessionPolicyDeveloperName = 'Missing_Session_Policy';

        try {
            service.loadSessionPolicy(route, 'Case');
            System.assert(false, 'Expected missing named session policy to fail fast');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Missing_Session_Policy'), 'Failure should identify the missing session policy developer name');
        }
    }
}
