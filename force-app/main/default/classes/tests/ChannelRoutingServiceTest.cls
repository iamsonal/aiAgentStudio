@IsTest
private class ChannelRoutingServiceTest {
    private static final String CASE_CHAT_ENDPOINT = 'SalesforceChatUI';
    private static final String DIRECT_ENDPOINT = 'DirectApi';
    private static final String MISSING_AGENT_ENDPOINT = 'MissingDirectApi';

    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Core Routing LLM').save();
        TestFactory.newAgentDefinition().withName('Case Support Chat Agent').withType('Conversational').withLLM(llm.Id).save();
        TestFactory.newAgentDefinition().withName('Direct Support Agent').withType('Direct').withLLM(llm.Id).save();
    }

    @IsTest
    static void testResolveInboundRoute_ResolvesCaseSpecificChatRoute() {
        configureRoutingFixture(
            RuntimeRegistryService.CHANNEL_CHAT,
            'CaseSupport_Chat',
            'SalesforceChat',
            CASE_CHAT_ENDPOINT,
            null,
            'Case_Support_Chat_Agent',
            'Case'
        );

        ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService()
            .resolveInboundRoute(RuntimeRegistryService.CHANNEL_CHAT, 'Case', CASE_CHAT_ENDPOINT);

        System.assertNotEquals(null, route, 'Case-specific chat route should resolve.');
        System.assertEquals('Case_Support_Chat_Agent', route.agentDeveloperName);
        System.assertEquals('CaseSupport_Chat', route.endpointDeveloperName);
        System.assertEquals(24, Integer.valueOf(route.inactivityTtlHours));
    }

    @IsTest
    static void testResolveInboundRoute_ThrowsWhenRouteTargetsMissingAgent() {
        configureRoutingFixture(
            RuntimeRegistryService.CHANNEL_DIRECT,
            'MissingAgent_Direct',
            'CoreDirectProvider',
            MISSING_AGENT_ENDPOINT,
            'direct-route-missing',
            'Missing_Direct_Agent',
            '*'
        );

        try {
            new ChannelRoutingService().resolveInboundRoute(RuntimeRegistryService.CHANNEL_DIRECT, null, MISSING_AGENT_ENDPOINT);
            System.assert(false, 'Expected active route with missing agent developer name to fail fast');
        } catch (AIAgentException.OrchestrationException e) {
            System.assert(e.getMessage().contains('Missing_Direct_Agent'), 'Failure should identify the missing agent developer name');
        }
    }

    @IsTest
    static void testResolveInboundRoute_ResolvesRecordlessDirectRouteWithRouteKey() {
        configureRoutingFixture(
            RuntimeRegistryService.CHANNEL_DIRECT,
            'DirectSupport_Api',
            'CoreDirectProvider',
            DIRECT_ENDPOINT,
            'direct-route-001',
            'Direct_Support_Agent',
            '*'
        );

        ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService()
            .resolveInboundRoute(RuntimeRegistryService.CHANNEL_DIRECT, null, DIRECT_ENDPOINT);

        System.assertNotEquals(null, route, 'Recordless direct route should resolve using endpoint metadata.');
        System.assertEquals('Direct_Support_Agent', route.agentDeveloperName);
        System.assertEquals('direct-route-001', route.routeKey, 'Resolved route should expose the transport route key.');
        System.assertEquals('DirectSupport_Api', route.endpointDeveloperName);
    }

    private static void configureRoutingFixture(
        String channel,
        String endpointDeveloperName,
        String provider,
        String endpointIdentifier,
        String routeKey,
        String agentDeveloperName,
        String entryObjectType
    ) {
        ChannelEndpoint__mdt endpoint = new ChannelEndpoint__mdt();
        endpoint.DeveloperName = endpointDeveloperName;
        endpoint.Channel__c = channel;
        endpoint.Provider__c = provider;
        endpoint.EndpointIdentifier__c = endpointIdentifier;
        endpoint.RouteKey__c = routeKey;
        endpoint.IsActive__c = true;
        endpoint.SupportsAutonomousReply__c = true;

        AgentChannelRoute__mdt route = new AgentChannelRoute__mdt();
        route.DeveloperName = endpointDeveloperName + '_Route';
        route.AgentDeveloperName__c = agentDeveloperName;
        route.ChannelEndpoint__c = endpoint.DeveloperName;
        route.EntryObjectType__c = entryObjectType;
        route.Priority__c = 10;
        route.DefaultDeliveryMode__c = 'Auto Reply';
        route.InactivityTtlHours__c = 24;
        route.IsActive__c = true;

        ChannelRoutingService.setTestRoutingData(new List<ChannelEndpoint__mdt>{ endpoint }, new List<AgentChannelRoute__mdt>{ route });
    }
}
