@IsTest
private class IngressRequestedTriggerHandlerTest {
    private static final String CHAT_PROVIDER = 'SalesforceChat';
    private static final String CHAT_ENDPOINT_DEV = 'CoreChatIngress';
    private static final String CHAT_AGENT_NAME = 'Core Chat Ingress Agent';
    private static final String CHAT_ENDPOINT_IDENTIFIER = 'SalesforceChatUI';
    private class TestParticipantResolver implements IChannelParticipantResolver {
        private final Map<String, Id> resolvedRecordIdsByKey;

        private TestParticipantResolver(Map<String, Id> resolvedRecordIdsByKey) {
            this.resolvedRecordIdsByKey = resolvedRecordIdsByKey == null ? new Map<String, Id>() : resolvedRecordIdsByKey;
        }

        public Id resolveSourceRecordId(String participantKey, Id explicitSourceRecordId) {
            if (explicitSourceRecordId != null) {
                return explicitSourceRecordId;
            }
            return this.resolvedRecordIdsByKey.get(participantKey);
        }
    }

    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('Ingress PE LLM').save();
        TestFactory.newAgentDefinition().withName(CHAT_AGENT_NAME).withType('Conversational').withLLM(llm.Id).save();
    }

    @IsTest
    static void testHandle_ProcessesStagedIngressRow() {
        configureChatIngressFixture();
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Handled via chat runtime.'));
        IngressEvent__c eventRecord = new IngressEvent__c(
            IngressType__c = 'Webhook',
            Channel__c = RuntimeRegistryService.CHANNEL_CHAT,
            Provider__c = CHAT_PROVIDER,
            EventType__c = 'InboundMessage',
            ProcessingStatus__c = 'Verified',
            VerificationStatus__c = 'Verified',
            ProcessingMode__c = 'Staged',
            SubmissionOrigin__c = 'DirectExternal',
            EndpointDeveloperName__c = CHAT_ENDPOINT_DEV,
            EndpointIdentifier__c = CHAT_ENDPOINT_IDENTIFIER,
            ParticipantExternalKey__c = 'chat-user-001',
            ConversationKey__c = 'chat-conversation-001',
            ProviderMessageId__c = 'chat.pe.001',
            RawPayloadJson__c = '{"seed":true}',
            NormalizedPayloadJson__c = '{"providerEventType":"text","conversationKey":"chat-conversation-001","userId":"chat-user-001","messageId":"chat.pe.001",' +
                '"messageContent":"Need help with my case","timestamp":"1710000000","triggerSource":"API"}'
        );
        insert eventRecord;

        IngressRequestedTriggerHandler.handle(new List<IngressRequested__e>{ new IngressRequested__e(IngressEventId__c = String.valueOf(eventRecord.Id)) });

        IngressEvent__c updatedEvent = [
            SELECT ProcessingStatus__c, AgentExecution__c, InteractionSession__c, InteractionMessage__c
            FROM IngressEvent__c
            WHERE Id = :eventRecord.Id
            LIMIT 1
        ];
        System.assertEquals('Processed', updatedEvent.ProcessingStatus__c);
        System.assertNotEquals(null, updatedEvent.AgentExecution__c);
        System.assertNotEquals(null, updatedEvent.InteractionMessage__c);
    }

    @IsTest
    static void testHandle_IgnoresInvalidEventIds() {
        IngressRequestedTriggerHandler.handle(new List<IngressRequested__e>{ new IngressRequested__e(IngressEventId__c = 'not-an-id') });
        System.assert(true, 'Invalid event IDs should be ignored without throwing.');
    }

    @IsTest
    static void testHandle_DuplicateInboundReusesTransportLinksWithoutCreatingSession() {
        configureChatIngressFixture();

        InteractionSession__c existingSession = new InteractionSession__c(
            Channel__c = RuntimeRegistryService.CHANNEL_CHAT,
            ConversationKey__c = 'prior-conversation-key',
            ParticipantExternalKey__c = 'chat-user-duplicate',
            SessionStatus__c = 'Active'
        );
        insert existingSession;

        String duplicateDedupKey = new InteractionMessageService()
            .buildInboundDedupKey(RuntimeRegistryService.CHANNEL_CHAT, CHAT_PROVIDER, CHAT_ENDPOINT_IDENTIFIER, 'chat.pe.duplicate', null);
        Id existingMessageId = new InteractionMessageService()
            .recordInboundProcessing(
                existingSession.Id,
                null,
                RuntimeRegistryService.CHANNEL_CHAT,
                CHAT_PROVIDER,
                'chat.pe.duplicate',
                duplicateDedupKey,
                'turn-duplicate',
                '{"seed":"existing"}'
            );
        Integer sessionCountBefore = [SELECT COUNT() FROM InteractionSession__c];

        IngressEvent__c eventRecord = new IngressEvent__c(
            IngressType__c = 'Webhook',
            Channel__c = RuntimeRegistryService.CHANNEL_CHAT,
            Provider__c = CHAT_PROVIDER,
            EventType__c = 'InboundMessage',
            ProcessingStatus__c = 'Verified',
            VerificationStatus__c = 'Verified',
            ProcessingMode__c = 'Staged',
            SubmissionOrigin__c = 'DirectExternal',
            EndpointDeveloperName__c = CHAT_ENDPOINT_DEV,
            EndpointIdentifier__c = CHAT_ENDPOINT_IDENTIFIER,
            ParticipantExternalKey__c = 'chat-user-duplicate',
            ConversationKey__c = 'chat-conversation-duplicate',
            ProviderMessageId__c = 'chat.pe.duplicate',
            RawPayloadJson__c = '{"seed":true}',
            NormalizedPayloadJson__c = '{"providerEventType":"text","conversationKey":"chat-conversation-duplicate","userId":"chat-user-duplicate","messageId":"chat.pe.duplicate",' +
                '"messageContent":"Need help with my case","timestamp":"1710000000","triggerSource":"API"}'
        );
        insert eventRecord;

        IngressRequestedTriggerHandler.handle(new List<IngressRequested__e>{ new IngressRequested__e(IngressEventId__c = String.valueOf(eventRecord.Id)) });

        IngressEvent__c updatedEvent = [
            SELECT ProcessingStatus__c, InteractionSession__c, InteractionMessage__c
            FROM IngressEvent__c
            WHERE Id = :eventRecord.Id
            LIMIT 1
        ];
        Integer sessionCountAfter = [SELECT COUNT() FROM InteractionSession__c];

        System.assertEquals('Duplicate', updatedEvent.ProcessingStatus__c);
        System.assertEquals(existingSession.Id, updatedEvent.InteractionSession__c);
        System.assertEquals(existingMessageId, updatedEvent.InteractionMessage__c);
        System.assertEquals(sessionCountBefore, sessionCountAfter, 'Duplicate suppression should not create a new session.');
    }

    @IsTest
    static void testAccept_DirectInboundMessage_ProcessesThroughRuntime() {
        configureChatIngressFixture();
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Handled via chat runtime.'));
        NormalizedIngressModels.Request request = buildInboundMessageRequest('chat.direct.001', NormalizedIngressModels.MODE_DIRECT);

        Test.startTest();
        NormalizedIngressModels.AcceptResult result = new IngressProcessingService().accept(request, '[test] ');
        Test.stopTest();

        System.assertEquals(true, result.accepted);
        System.assertEquals(NormalizedIngressModels.MODE_DIRECT, result.processingMode);
        System.assertNotEquals(null, result.executionId, 'Direct normalized ingress should still reach AgentExecutionService.');

        List<InteractionMessage__c> messages = [
            SELECT Id, Channel__c, Direction__c
            FROM InteractionMessage__c
            WHERE ProviderMessageId__c = 'chat.direct.001'
            LIMIT 1
        ];
        System.assertEquals(1, messages.size());
        System.assertEquals(RuntimeRegistryService.CHANNEL_CHAT, messages[0].Channel__c);
        System.assertEquals('Inbound', messages[0].Direction__c);
    }

    @IsTest
    static void testAccept_StagedDeliveryStatus_UpdatesExistingTransportMessage() {
        configureChatIngressFixture();
        new InteractionMessageService()
            .recordOutboundMessage(null, null, RuntimeRegistryService.CHANNEL_CHAT, CHAT_PROVIDER, 'chat.status.001', 'turn-1', '{"seed":true}', 'Sent');

        NormalizedIngressModels.Request request = new NormalizedIngressModels.Request();
        request.ingressType = 'Webhook';
        request.channel = RuntimeRegistryService.CHANNEL_CHAT;
        request.provider = CHAT_PROVIDER;
        request.eventType = NormalizedIngressModels.EVENT_TYPE_DELIVERY_STATUS;
        request.processingMode = NormalizedIngressModels.MODE_STAGED;
        request.submissionOrigin = NormalizedIngressModels.ORIGIN_DIRECT_EXTERNAL;
        request.endpointDeveloperName = CHAT_ENDPOINT_DEV;
        request.endpointIdentifier = CHAT_ENDPOINT_IDENTIFIER;
        request.providerMessageId = 'chat.status.001';
        request.verificationStatus = 'Verified';
        request.normalizedPayloadJson = '{"providerStatus":"delivered","normalizedStatus":"Delivered"}';
        request.rawPayloadJson = '{"statuses":[{"id":"chat.status.001","status":"delivered"}]}';

        Test.startTest();
        NormalizedIngressModels.AcceptResult result = new IngressProcessingService().accept(request, '[test] ');
        Test.stopTest();

        System.assertEquals(true, result.accepted);
        System.assertNotEquals(null, result.ingressEventId);

        InteractionMessage__c message = [
            SELECT Status__c, ProviderStatus__c
            FROM InteractionMessage__c
            WHERE ProviderMessageId__c = 'chat.status.001'
            LIMIT 1
        ];
        System.assertEquals('Delivered', message.Status__c);
        System.assertEquals('delivered', message.ProviderStatus__c);

        IngressEvent__c ingressEvent = [
            SELECT ProcessingStatus__c, EventType__c
            FROM IngressEvent__c
            WHERE Id = :result.ingressEventId
            LIMIT 1
        ];
        System.assertEquals('Processed', ingressEvent.ProcessingStatus__c);
        System.assertEquals('DeliveryStatus', ingressEvent.EventType__c);
    }

    @IsTest
    static void testAccept_StagedIngress_PublishesPlatformEvent() {
        configureChatIngressFixture();
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.text('Handled staged ingress.'));
        NormalizedIngressModels.Request request = buildInboundMessageRequest('chat.staged.002', NormalizedIngressModels.MODE_STAGED);

        Test.startTest();
        NormalizedIngressModels.AcceptResult result = new IngressProcessingService().accept(request, '[test] ');
        Test.stopTest();

        System.assertEquals(true, result.accepted);
        System.assertNotEquals(null, result.ingressEventId);

        IngressEvent__c ingressEvent = [
            SELECT ProcessingStatus__c, EventType__c, InteractionMessage__c
            FROM IngressEvent__c
            WHERE Id = :result.ingressEventId
            LIMIT 1
        ];
        System.assertEquals('Processed', ingressEvent.ProcessingStatus__c);
        System.assertEquals('InboundMessage', ingressEvent.EventType__c);
        System.assertNotEquals(null, ingressEvent.InteractionMessage__c);
    }

    @IsTest
    static void testResolveSourceRecordId_UsesConfiguredResolver() {
        Case sourceCase = TestFactory.newCase().withSubject('Participant Resolver Case').save();
        configureDirectChannelWithParticipantResolver('PartRecResolutionTestResolver');
        IngressProcessingService.setTestParticipantResolver(
            'PartRecResolutionTestResolver',
            new TestParticipantResolver(new Map<String, Id>{ 'participant-001' => sourceCase.Id })
        );

        try {
            Id resolvedRecordId = IngressProcessingService.resolveSourceRecordId(RuntimeRegistryService.CHANNEL_DIRECT, 'participant-001', null);

            System.assertEquals(sourceCase.Id, resolvedRecordId, 'Configured resolver should supply the source record id.');
        } finally {
            IngressProcessingService.clearTestParticipantResolvers();
        }
    }

    @IsTest
    static void testResolveSourceRecordId_ExplicitSourceRecordWins() {
        Account explicitAccount = TestFactory.newAccount().withName('Explicit Source').save();
        Case resolvedCase = TestFactory.newCase().withSubject('Ignored Resolver Case').save();
        configureDirectChannelWithParticipantResolver('PartRecResolutionTestResolver');
        IngressProcessingService.setTestParticipantResolver(
            'PartRecResolutionTestResolver',
            new TestParticipantResolver(new Map<String, Id>{ 'participant-002' => resolvedCase.Id })
        );

        try {
            Id resolvedRecordId = IngressProcessingService.resolveSourceRecordId(RuntimeRegistryService.CHANNEL_DIRECT, 'participant-002', explicitAccount.Id);

            System.assertEquals(explicitAccount.Id, resolvedRecordId, 'Explicit source records should bypass resolver lookup.');
        } finally {
            IngressProcessingService.clearTestParticipantResolvers();
        }
    }

    @IsTest
    static void testResolveSourceRecordId_ReturnsNullWhenNoResolverConfigured() {
        configureDirectChannelWithParticipantResolver(null);

        try {
            Id resolvedRecordId = IngressProcessingService.resolveSourceRecordId(RuntimeRegistryService.CHANNEL_DIRECT, 'participant-003', null);

            System.assertEquals(null, resolvedRecordId, 'Service should return null when the channel has no participant resolver.');
        } finally {
            IngressProcessingService.clearTestParticipantResolvers();
        }
    }

    private static void configureChatIngressFixture() {
        InteractionChannelType__mdt chat = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_CHAT,
            InteractionAdapterClass__c = 'ChatChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForConversational__c = true,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ chat });

        ChannelEndpoint__mdt endpoint = new ChannelEndpoint__mdt();
        endpoint.DeveloperName = CHAT_ENDPOINT_DEV;
        endpoint.Channel__c = RuntimeRegistryService.CHANNEL_CHAT;
        endpoint.Provider__c = CHAT_PROVIDER;
        endpoint.EndpointIdentifier__c = CHAT_ENDPOINT_IDENTIFIER;
        endpoint.IsActive__c = true;
        endpoint.SupportsAutonomousReply__c = true;

        AgentChannelRoute__mdt route = new AgentChannelRoute__mdt();
        route.DeveloperName = CHAT_ENDPOINT_DEV + '_Default';
        route.AgentDeveloperName__c = CHAT_AGENT_NAME.replaceAll('\\W', '_');
        route.ChannelEndpoint__c = endpoint.DeveloperName;
        route.EntryObjectType__c = '*';
        route.Priority__c = 10;
        route.DefaultDeliveryMode__c = 'Auto Reply';
        route.InactivityTtlHours__c = 24;
        route.IsActive__c = true;

        ChannelRoutingService.setTestRoutingData(new List<ChannelEndpoint__mdt>{ endpoint }, new List<AgentChannelRoute__mdt>{ route });
    }

    private static void configureDirectChannelWithParticipantResolver(String resolverClassName) {
        InteractionChannelType__mdt direct = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_DIRECT,
            InteractionAdapterClass__c = 'DirectInteractionChannel',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            ParticipantResolverClass__c = resolverClassName,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ direct });
    }

    private static NormalizedIngressModels.Request buildInboundMessageRequest(String providerMessageId, String processingMode) {
        NormalizedIngressModels.Request request = new NormalizedIngressModels.Request();
        request.ingressType = 'Webhook';
        request.channel = RuntimeRegistryService.CHANNEL_CHAT;
        request.provider = CHAT_PROVIDER;
        request.eventType = NormalizedIngressModels.EVENT_TYPE_INBOUND_MESSAGE;
        request.processingMode = processingMode;
        request.submissionOrigin = NormalizedIngressModels.ORIGIN_DIRECT_EXTERNAL;
        request.endpointDeveloperName = CHAT_ENDPOINT_DEV;
        request.endpointIdentifier = CHAT_ENDPOINT_IDENTIFIER;
        request.participantExternalKey = 'chat-user-001';
        request.conversationKey = 'chat-conversation-001';
        request.providerMessageId = providerMessageId;
        request.messageContent = 'Need help with my case';
        request.verificationStatus = 'Verified';
        request.triggerSource = 'API';
        request.rawPayloadJson = '{"seed":true}';
        request.normalizedPayloadJson =
            '{"conversationKey":"chat-conversation-001","userId":"chat-user-001","messageId":"' +
            providerMessageId +
            '",' +
            '"messageContent":"Need help with my case","timestamp":"1710000000","triggerSource":"API","providerEventType":"text"}';
        return request;
    }
}
