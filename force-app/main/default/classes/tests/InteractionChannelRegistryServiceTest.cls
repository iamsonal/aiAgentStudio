@IsTest
private class InteractionChannelRegistryServiceTest {
    private static final String TEST_ADAPTER_CLASS_NAME = 'TestInteractionChannelOverride';

    private class TestInteractionChannel implements InteractionRuntimeModels.IInteractionChannel {
        public InteractionRuntimeModels.InteractionEnvelope normalizeInbound(String payloadJson, Id sourceRecordId, String userMessage) {
            return new InteractionRuntimeModels.InteractionEnvelope();
        }

        public InteractionRuntimeModels.InteractionSessionContext resolveOrCreateSession(
            AIAgentDefinition__c agentDefinition,
            InteractionRuntimeModels.InteractionEnvelope envelope,
            String logPrefix
        ) {
            return new InteractionRuntimeModels.InteractionSessionContext();
        }

        public String buildPromptAdditions(Id executionId, OrchestrationContext context) {
            return null;
        }

        public InteractionRuntimeModels.DeliveryDecision determineDeliveryAction(
            AIAgentDefinition__c agentDefinition,
            OrchestrationContext context,
            String contentResponse,
            String logPrefix
        ) {
            return new InteractionRuntimeModels.DeliveryDecision(InteractionRuntimeModels.DeliveryAction.None, null, null);
        }

        public InteractionRuntimeModels.ReviewPayload buildReviewPayload(
            AIAgentDefinition__c agentDefinition,
            OrchestrationContext context,
            String contentResponse,
            String logPrefix
        ) {
            return null;
        }

        public Boolean deliverReviewedPayload(String reviewedPayloadJson, OrchestrationContext context, String logPrefix) {
            return true;
        }

        public Boolean sendReply(String contentResponse, OrchestrationContext context, String logPrefix) {
            return true;
        }

        public Id createReviewArtifact(String contentResponse, OrchestrationContext context, String logPrefix) {
            return null;
        }

        public void suppressReply(OrchestrationContext context, String logPrefix) {
        }
    }

    private static void configureCoreChannelTypes() {
        InteractionChannelType__mdt chat = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_CHAT,
            InteractionAdapterClass__c = 'ChatChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForConversational__c = true,
            IsActive__c = true
        );
        InteractionChannelType__mdt direct = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_DIRECT,
            InteractionAdapterClass__c = 'DirectChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForDirect__c = true,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ chat, direct });
    }

    private static void configurePluggableChannelTypes() {
        InteractionChannelType__mdt chat = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_CHAT,
            InteractionAdapterClass__c = 'ChatChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForConversational__c = true,
            IsActive__c = true
        );
        InteractionChannelType__mdt direct = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_DIRECT,
            InteractionAdapterClass__c = 'DirectChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForDirect__c = true,
            IsActive__c = true
        );
        InteractionChannelType__mdt email = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_EMAIL,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            IsActive__c = true
        );
        InteractionChannelType__mdt whatsApp = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_WHATSAPP,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            IsActive__c = true
        );
        InteractionChannelType__mdt slack = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_SLACK,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            IsActive__c = true
        );
        InteractionChannelType__mdt teams = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_TEAMS,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ chat, direct, email, whatsApp, slack, teams });
    }

    @IsTest
    static void testResolveAdapter_ResolvesCoreChannelAdapters() {
        configureCoreChannelTypes();
        try {
            InteractionRuntimeModels.IInteractionChannel chatAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_CHAT
            );
            InteractionRuntimeModels.IInteractionChannel directAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_DIRECT
            );

            System.assert(chatAdapter instanceof ChatChannelAdapter, 'Chat channel should resolve to ChatChannelAdapter');
            System.assert(directAdapter instanceof DirectChannelAdapter, 'Direct channel should resolve to DirectChannelAdapter');
        } finally {
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testResolveIterativeRuntime_ResolvesCoreDescriptorDrivenRuntime() {
        configureCoreChannelTypes();
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Descriptor Runtime Agent').withType('Conversational').withLLM(llm.Id).save();

        IAgentRuntime chatRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_CHAT);
        IAgentRuntime directRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_DIRECT);

        System.assert(chatRuntime instanceof ChatConversationalRuntimeService, 'Chat should resolve to conversational runtime');
        System.assert(directRuntime instanceof ChatConversationalRuntimeService, 'Direct should resolve to the shared runtime descriptor');
    }

    @IsTest
    static void testResolveAdapter_RejectsUnsupportedChannel() {
        configureCoreChannelTypes();
        try {
            Boolean threw = false;
            try {
                InteractionChannelRegistryService.resolveAdapter(null, null, 'UnknownChannel');
            } catch (AIAgentException.OrchestrationException e) {
                threw = true;
                System.assert(e.getMessage().contains('Unsupported interaction channel'), 'Should fail fast on unknown channel keys');
            }

            System.assertEquals(true, threw, 'Unknown channels must fail instead of silently defaulting');
        } finally {
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testResolveAdapter_NormalizesChannelKeyCase() {
        configureCoreChannelTypes();
        try {
            InteractionRuntimeModels.IInteractionChannel chatAdapter = InteractionChannelRegistryService.resolveAdapter(null, null, ' chat ');

            System.assert(chatAdapter instanceof ChatChannelAdapter, 'Channel resolution should normalize casing and whitespace.');
        } finally {
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testResolveAdapter_ResolvesConfiguredPluggableChannelAdapters() {
        configurePluggableChannelTypes();
        InteractionChannelRegistryService.setTestAdapter(TEST_ADAPTER_CLASS_NAME, new TestInteractionChannel());

        try {
            InteractionRuntimeModels.IInteractionChannel emailAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_EMAIL
            );
            InteractionRuntimeModels.IInteractionChannel whatsAppAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_WHATSAPP
            );
            InteractionRuntimeModels.IInteractionChannel slackAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_SLACK
            );
            InteractionRuntimeModels.IInteractionChannel teamsAdapter = InteractionChannelRegistryService.resolveAdapter(
                null,
                null,
                RuntimeRegistryService.CHANNEL_TEAMS
            );

            System.assert(emailAdapter instanceof TestInteractionChannel, 'Email channel should resolve to the configured core test adapter');
            System.assert(whatsAppAdapter instanceof TestInteractionChannel, 'WhatsApp channel should resolve to the configured core test adapter');
            System.assert(slackAdapter instanceof TestInteractionChannel, 'Slack channel should resolve to the configured core test adapter');
            System.assert(teamsAdapter instanceof TestInteractionChannel, 'Teams channel should resolve to the configured core test adapter');
        } finally {
            InteractionChannelRegistryService.clearTestAdapters();
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testResolveIterativeRuntime_ResolvesConfiguredPluggableConversationalRuntimes() {
        configurePluggableChannelTypes();
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Pluggable Runtime Agent').withType('Conversational').withLLM(llm.Id).save();

        IAgentRuntime emailRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_EMAIL);
        IAgentRuntime whatsAppRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_WHATSAPP);
        IAgentRuntime slackRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_SLACK);
        IAgentRuntime teamsRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(agent, RuntimeRegistryService.CHANNEL_TEAMS);

        System.assert(emailRuntime instanceof ChatConversationalRuntimeService, 'Email should resolve using the configured conversational runtime');
        System.assert(whatsAppRuntime instanceof ChatConversationalRuntimeService, 'WhatsApp should reuse the shared conversational runtime');
        System.assert(slackRuntime instanceof ChatConversationalRuntimeService, 'Slack should reuse the shared conversational runtime');
        System.assert(teamsRuntime instanceof ChatConversationalRuntimeService, 'Teams should reuse the shared conversational runtime');
    }

    @IsTest
    static void testResolveDefaultChannelForStrategy_ThrowsWhenMultipleDefaultsConfigured() {
        InteractionChannelType__mdt first = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_CHAT,
            InteractionAdapterClass__c = 'ChatChannelAdapter',
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForConversational__c = true,
            IsActive__c = true
        );
        InteractionChannelType__mdt second = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_EMAIL,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForConversational__c = true,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ first, second });

        try {
            Boolean threw = false;
            try {
                InteractionChannelRegistryService.resolveDefaultChannelForStrategy(
                    String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational)
                );
            } catch (AIAgentException.OrchestrationException e) {
                threw = true;
                System.assert(e.getMessage().contains('Multiple active InteractionChannelType__mdt records are marked as the default'));
            }
            System.assertEquals(true, threw, 'Multiple defaults should fail fast.');
        } finally {
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }
}
