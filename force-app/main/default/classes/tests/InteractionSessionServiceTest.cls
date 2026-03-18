@IsTest
private class InteractionSessionServiceTest {
    @IsTest
    static void testResolveOrCreateSession_ReusesConversationAnchor() {
        InteractionSessionService service = new InteractionSessionService();

        Test.startTest();
        InteractionRuntimeModels.InteractionSessionContext firstContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_CHAT,
            'chat-conversation-001',
            'user-001',
            'user-001',
            'Salesforce Chat',
            null,
            'Salesforce Chat UI',
            '[test] '
        );
        InteractionRuntimeModels.InteractionSessionContext secondContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_CHAT,
            'chat-conversation-001',
            'user-001',
            'user-001',
            'Salesforce Chat',
            null,
            'Salesforce Chat UI',
            '[test] '
        );
        Test.stopTest();

        System.assertNotEquals(null, firstContext, 'Session resolution should return a context');
        System.assertNotEquals(null, firstContext.sessionId, 'Session resolution should create a durable session');
        System.assertEquals(firstContext.sessionId, secondContext.sessionId, 'Conversation reuse should return the same durable session');
        System.assertEquals(RuntimeRegistryService.CHANNEL_CHAT, secondContext.channel);
    }

    @IsTest
    static void testResolveOrCreateSession_DiffersByProviderAndEndpointScope() {
        InteractionSessionService service = new InteractionSessionService();
        String providerKey = 'ScopedTestProvider';

        InteractionRuntimeModels.InteractionSessionContext firstContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_WHATSAPP,
            'conversation-001',
            'phone-id-001',
            '+15551230001',
            providerKey,
            null,
            '15551230001',
            '[test] '
        );
        InteractionRuntimeModels.InteractionSessionContext secondContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_WHATSAPP,
            'conversation-001',
            'phone-id-001',
            '+15551230001',
            providerKey,
            null,
            '15551239999',
            '[test] '
        );

        System.assertNotEquals(
            firstContext.sessionId,
            secondContext.sessionId,
            'Provider-backed messaging sessions should not collide when endpoint scope changes'
        );
    }

    @IsTest
    static void testResolveOrCreateSession_LeavesDirectExecutionStateless() {
        InteractionSessionService service = new InteractionSessionService();

        Test.startTest();
        InteractionRuntimeModels.InteractionSessionContext context = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_DIRECT,
            null,
            'API',
            'user-001',
            'Salesforce Direct',
            null,
            'API',
            '[test] '
        );
        Test.stopTest();

        System.assertNotEquals(null, context, 'Stateless Direct execution should still return a context object');
        System.assertEquals(null, context.sessionId, 'Stateless Direct execution should not create a durable interaction session');
        System.assertEquals(RuntimeRegistryService.CHANNEL_DIRECT, context.channel);
    }
}
