@IsTest
private class ChannelRoutingServiceTest {
    private static final String CASE_CHAT_ENDPOINT = 'Salesforce Chat UI';
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
            'Salesforce Chat',
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

    @IsTest
    static void testResolveInboundRoute_IgnoresUnrelatedBrokenRouteReference() {
        ChannelEndpoint__mdt validEndpoint = new ChannelEndpoint__mdt();
        validEndpoint.DeveloperName = 'CaseSupport_Chat';
        validEndpoint.Channel__c = RuntimeRegistryService.CHANNEL_CHAT;
        validEndpoint.Provider__c = 'Salesforce Chat';
        validEndpoint.EndpointIdentifier__c = CASE_CHAT_ENDPOINT;
        validEndpoint.IsActive__c = true;
        validEndpoint.SupportsAutonomousReply__c = true;

        AgentChannelRoute__mdt validRoute = new AgentChannelRoute__mdt();
        validRoute.DeveloperName = 'CaseSupport_Chat_Route';
        validRoute.AgentDeveloperName__c = 'Case_Support_Chat_Agent';
        validRoute.ChannelEndpoint__c = 'CaseSupport_Chat';
        validRoute.EntryObjectType__c = 'Case';
        validRoute.Priority__c = 10;
        validRoute.DefaultDeliveryMode__c = 'Auto Reply';
        validRoute.InactivityTtlHours__c = 24;
        validRoute.IsActive__c = true;

        AgentChannelRoute__mdt brokenUnrelatedRoute = new AgentChannelRoute__mdt();
        brokenUnrelatedRoute.DeveloperName = 'Broken_Email_Route';
        brokenUnrelatedRoute.AgentDeveloperName__c = 'Case_Support_Chat_Agent';
        brokenUnrelatedRoute.ChannelEndpoint__c = 'Missing_Email_Endpoint';
        brokenUnrelatedRoute.EntryObjectType__c = 'EmailMessage';
        brokenUnrelatedRoute.Priority__c = 100;
        brokenUnrelatedRoute.DefaultDeliveryMode__c = 'Auto Reply';
        brokenUnrelatedRoute.InactivityTtlHours__c = 24;
        brokenUnrelatedRoute.IsActive__c = true;

        ChannelRoutingService.setTestRoutingData(
            new List<ChannelEndpoint__mdt>{ validEndpoint },
            new List<AgentChannelRoute__mdt>{ brokenUnrelatedRoute, validRoute }
        );
        try {
            ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService()
                .resolveInboundRoute(RuntimeRegistryService.CHANNEL_CHAT, 'Case', CASE_CHAT_ENDPOINT);

            System.assertNotEquals(null, route, 'Valid routing should still resolve when an unrelated route is broken.');
            System.assertEquals('Case_Support_Chat_Agent', route.agentDeveloperName);
        } finally {
            ChannelRoutingService.clearTestRoutingData();
        }
    }

    @IsTest
    static void testResolveInboundRoute_ThrowsForDuplicateEffectiveRouteKeys() {
        ChannelEndpoint__mdt endpoint = new ChannelEndpoint__mdt();
        endpoint.DeveloperName = 'CaseSupport_Chat';
        endpoint.Channel__c = RuntimeRegistryService.CHANNEL_CHAT;
        endpoint.Provider__c = 'Salesforce Chat';
        endpoint.EndpointIdentifier__c = CASE_CHAT_ENDPOINT;
        endpoint.IsActive__c = true;
        endpoint.SupportsAutonomousReply__c = true;

        AgentChannelRoute__mdt higherPriorityRoute = new AgentChannelRoute__mdt();
        higherPriorityRoute.DeveloperName = 'CaseSupport_Chat_Route_A';
        higherPriorityRoute.AgentDeveloperName__c = 'Case_Support_Chat_Agent';
        higherPriorityRoute.ChannelEndpoint__c = endpoint.DeveloperName;
        higherPriorityRoute.EntryObjectType__c = 'Case';
        higherPriorityRoute.Priority__c = 20;
        higherPriorityRoute.DefaultDeliveryMode__c = 'Auto Reply';
        higherPriorityRoute.InactivityTtlHours__c = 24;
        higherPriorityRoute.IsActive__c = true;

        AgentChannelRoute__mdt duplicateRoute = new AgentChannelRoute__mdt();
        duplicateRoute.DeveloperName = 'CaseSupport_Chat_Route_B';
        duplicateRoute.AgentDeveloperName__c = 'Case_Support_Chat_Agent';
        duplicateRoute.ChannelEndpoint__c = endpoint.DeveloperName;
        duplicateRoute.EntryObjectType__c = 'Case';
        duplicateRoute.Priority__c = 10;
        duplicateRoute.DefaultDeliveryMode__c = 'Auto Reply';
        duplicateRoute.InactivityTtlHours__c = 24;
        duplicateRoute.IsActive__c = true;

        ChannelRoutingService.setTestRoutingData(
            new List<ChannelEndpoint__mdt>{ endpoint },
            new List<AgentChannelRoute__mdt>{ duplicateRoute, higherPriorityRoute }
        );
        try {
            Boolean threw = false;
            try {
                new ChannelRoutingService().resolveInboundRoute(RuntimeRegistryService.CHANNEL_CHAT, 'Case', CASE_CHAT_ENDPOINT);
            } catch (AIAgentException.OrchestrationException e) {
                threw = true;
                System.assert(e.getMessage().contains('Duplicate active AgentChannelRoute__mdt configuration'));
                System.assert(e.getMessage().contains('CaseSupport_Chat_Route_A'));
                System.assert(e.getMessage().contains('CaseSupport_Chat_Route_B'));
            }
            System.assertEquals(true, threw, 'Duplicate effective route keys should fail fast.');
        } finally {
            ChannelRoutingService.clearTestRoutingData();
        }
    }

    @IsTest
    static void testResolveCompletionMode_CoercesAutoReplyWhenEndpointDisablesAutonomousReply() {
        AIAgentDefinition__c agentDefinition = new AIAgentDefinition__c(DefaultCompletionMode__c = 'Auto Reply');
        ChannelRoutingService.ResolvedRoute route = new ChannelRoutingService.ResolvedRoute();
        route.defaultDeliveryMode = 'Auto Reply';
        route.supportsAutonomousReply = false;

        String resolvedMode = new ChannelRoutingService().resolveCompletionMode(agentDefinition, route);

        System.assertEquals('Review Before Send', resolvedMode);
    }

    @IsTest
    static void testResolveEffectiveCompletionMode_PrefersExecutionValue() {
        AIAgentDefinition__c agentDefinition = new AIAgentDefinition__c(DefaultCompletionMode__c = 'Auto Reply');
        AgentExecution__c execution = new AgentExecution__c(CompletionMode__c = 'Route Only');

        String resolvedMode = new ChannelRoutingService().resolveEffectiveCompletionMode(agentDefinition, execution);

        System.assertEquals('Route Only', resolvedMode);
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
