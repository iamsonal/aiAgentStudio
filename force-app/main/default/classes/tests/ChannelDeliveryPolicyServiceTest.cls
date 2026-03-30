/**
 * @description Focused tests for fail-closed channel delivery behavior using a core test adapter.
 */
@IsTest
private class ChannelDeliveryPolicyServiceTest {
    private static final String TEST_ADAPTER_CLASS_NAME = 'TestInteractionChannelOverride';
    private static String nextAction = 'None';
    private static String nextRouteKey;
    private static Boolean nextSendResult = true;
    private static String nextReviewPayloadJson;
    private static String nextReviewPayloadSummary;

    private static void resetTestInteractionChannelState() {
        nextAction = 'None';
        nextRouteKey = null;
        nextSendResult = true;
        nextReviewPayloadJson = '{"status":"ready"}';
        nextReviewPayloadSummary = 'Review the drafted response.';
    }

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
            InteractionRuntimeModels.DeliveryAction resolvedAction = InteractionRuntimeModels.DeliveryAction.None;
            if ('Send'.equalsIgnoreCase(nextAction)) {
                resolvedAction = InteractionRuntimeModels.DeliveryAction.Send;
            } else if ('Draft'.equalsIgnoreCase(nextAction)) {
                resolvedAction = InteractionRuntimeModels.DeliveryAction.Draft;
            } else if ('Suppress'.equalsIgnoreCase(nextAction)) {
                resolvedAction = InteractionRuntimeModels.DeliveryAction.Suppress;
            } else if ('Handoff'.equalsIgnoreCase(nextAction)) {
                resolvedAction = InteractionRuntimeModels.DeliveryAction.Handoff;
            }
            return new InteractionRuntimeModels.DeliveryDecision(resolvedAction, nextRouteKey, null);
        }

        public InteractionRuntimeModels.ReviewPayload buildReviewPayload(
            AIAgentDefinition__c agentDefinition,
            OrchestrationContext context,
            String contentResponse,
            String logPrefix
        ) {
            return new InteractionRuntimeModels.ReviewPayload(
                RuntimeRegistryService.CHANNEL_DIRECT,
                nextRouteKey,
                'dedup-review',
                nextReviewPayloadSummary,
                nextReviewPayloadJson
            );
        }

        public Boolean deliverReviewedPayload(String reviewedPayloadJson, OrchestrationContext context, String logPrefix) {
            return true;
        }

        public Boolean sendReply(String contentResponse, OrchestrationContext context, String logPrefix) {
            return nextSendResult;
        }

        public Id createReviewArtifact(String contentResponse, OrchestrationContext context, String logPrefix) {
            return null;
        }

        public void suppressReply(OrchestrationContext context, String logPrefix) {
        }
    }

    @IsTest
    static void testApplyContentDelivery_FailsClosedWhenSameChannelReplyMissingSession() {
        configureDirectChannelFixture('expected-route');
        try {
            AIAgentDefinition__c agent = createDirectAgent('DeliveryPolicyMissingSession');
            String turnIdentifier = 'turn-delivery-001';
            AgentExecution__c execution = createDirectExecution(agent.Id, null, turnIdentifier);

            ChannelDeliveryPolicyService.DeliveryResult result = new ChannelDeliveryPolicyService()
                .applyContentDelivery(buildContext(execution.Id, agent.Id, turnIdentifier), 'Reply body', '[test] ');

            AgentExecution__c refreshed = [
                SELECT ExecutionStatus__c, ProcessingStatus__c
                FROM AgentExecution__c
                WHERE Id = :execution.Id
            ];

            System.assertEquals(false, result.isSuccess, 'Missing durable session should fail closed');
            System.assertEquals(OrchestrationService.OUTCOME_FAILED, result.outcome, 'Missing session should be treated as a failed delivery');
            System.assert(result.statusMessage.contains('resolved interaction session'), 'Failure should explain the missing session anchor');
            System.assertEquals('Failed', refreshed.ExecutionStatus__c, 'Execution should fail when same-channel enforcement cannot be satisfied');
        } finally {
            InteractionChannelRegistryService.clearTestAdapters();
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testApplyContentDelivery_FailsClosedWhenRouteKeyDiverges() {
        configureDirectChannelFixture('different-route');
        try {
            AIAgentDefinition__c agent = createDirectAgent('DeliveryPolicyRouteMismatch');
            InteractionSession__c session = new InteractionSession__c(
                Channel__c = RuntimeRegistryService.CHANNEL_DIRECT,
                ConversationKey__c = 'delivery-policy-thread-001',
                ParticipantExternalKey__c = 'participant-001',
                ReplyRouteKey__c = 'expected-route',
                SessionStatus__c = 'Active'
            );
            insert session;

            String turnIdentifier = 'turn-delivery-002';
            AgentExecution__c execution = createDirectExecution(agent.Id, session.Id, turnIdentifier);

            ChannelDeliveryPolicyService.DeliveryResult result = new ChannelDeliveryPolicyService()
                .applyContentDelivery(buildContext(execution.Id, agent.Id, turnIdentifier), 'Reply body', '[test] ');

            AgentExecution__c refreshed = [
                SELECT ExecutionStatus__c, ProcessingStatus__c
                FROM AgentExecution__c
                WHERE Id = :execution.Id
            ];

            System.assertEquals(false, result.isSuccess, 'Route mismatches should fail closed');
            System.assert(result.statusMessage.contains('route does not match'), 'Failure should explain the route mismatch');
            System.assertEquals('Failed', refreshed.ExecutionStatus__c, 'Execution should fail when reply route diverges from the session');
        } finally {
            InteractionChannelRegistryService.clearTestAdapters();
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    @IsTest
    static void testApplyContentDelivery_CreatesReviewArtifactForDraftMode() {
        resetTestInteractionChannelState();
        nextAction = 'Draft';
        nextRouteKey = 'review-route';
        configureDefaultHitlExecutionIdentity();

        InteractionChannelType__mdt direct = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_DIRECT,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForDirect__c = true,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ direct });
        InteractionChannelRegistryService.setTestAdapter(TEST_ADAPTER_CLASS_NAME, new TestInteractionChannel());

        try {
            AIAgentDefinition__c agent = createDirectAgent('DeliveryPolicyDraftReview');
            InteractionSession__c session = new InteractionSession__c(
                Channel__c = RuntimeRegistryService.CHANNEL_DIRECT,
                ConversationKey__c = 'delivery-policy-thread-review',
                ParticipantExternalKey__c = 'participant-review',
                ReplyRouteKey__c = 'review-route',
                SessionStatus__c = 'Active'
            );
            insert session;

            String turnIdentifier = 'turn-delivery-draft-001';
            AgentExecution__c execution = createDirectExecution(agent.Id, session.Id, turnIdentifier);

            ChannelDeliveryPolicyService.DeliveryResult result = new ChannelDeliveryPolicyService()
                .applyContentDelivery(buildContext(execution.Id, agent.Id, turnIdentifier), 'Reply body for review', '[test] ');

            PendingHITLAction__c pendingAction = [
                SELECT ArtifactType__c, InteractionChannel__c, ReviewedPayloadJson__c
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :execution.Id
                LIMIT 1
            ];

            System.assertEquals(true, result.isSuccess, 'Draft mode should create a framework review artifact');
            System.assertEquals(
                HITLGatewayService.ARTIFACT_TYPE_OUTBOUND_DRAFT_REVIEW,
                pendingAction.ArtifactType__c,
                'Draft mode should create an outbound draft review artifact'
            );
            System.assertEquals(
                RuntimeRegistryService.CHANNEL_DIRECT,
                pendingAction.InteractionChannel__c,
                'Review artifact should track the execution channel'
            );
            System.assert(pendingAction.ReviewedPayloadJson__c.contains('"status":"ready"'), 'Reviewed payload JSON should be persisted');
        } finally {
            InteractionChannelRegistryService.clearTestAdapters();
            InteractionChannelRegistryService.clearTestChannelTypes();
        }
    }

    private static void configureDirectChannelFixture(String routeKey) {
        resetTestInteractionChannelState();
        nextAction = 'Send';
        nextRouteKey = routeKey;
        nextSendResult = true;

        InteractionChannelType__mdt direct = new InteractionChannelType__mdt(
            ChannelKey__c = RuntimeRegistryService.CHANNEL_DIRECT,
            InteractionAdapterClass__c = TEST_ADAPTER_CLASS_NAME,
            ConversationalRuntimeClass__c = 'ChatConversationalRuntimeService',
            DefaultForDirect__c = true,
            IsActive__c = true
        );
        InteractionChannelRegistryService.setTestChannelTypes(new List<InteractionChannelType__mdt>{ direct });
        InteractionChannelRegistryService.setTestAdapter(TEST_ADAPTER_CLASS_NAME, new TestInteractionChannel());
    }

    private static AIAgentDefinition__c createDirectAgent(String name) {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName(name + '_LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName(name).withType('Direct').withLLM(llm.Id).build();
        agent.RequiresSameChannelReply__c = true;
        insert agent;
        return agent;
    }

    private static AgentExecution__c createDirectExecution(Id agentId, Id interactionSessionId, String turnIdentifier) {
        Case sourceCase = TestFactory.newCase().withSubject('Delivery Policy Case').save();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agentId)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Direct')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withSourceRecord(sourceCase.Id)
            .withTurnIdentifier(turnIdentifier)
            .build();
        execution.InteractionChannel__c = RuntimeRegistryService.CHANNEL_DIRECT;
        execution.InteractionSession__c = interactionSessionId;
        execution.TriggerPayload__c = JSON.serialize(
            new Map<String, Object>{ 'triggerSource' => 'API', 'inboundDedupKey' => 'dedup-' + String.valueOf(Crypto.getRandomLong()).replace('-', '') }
        );
        insert execution;
        return execution;
    }

    private static OrchestrationContext buildContext(Id executionId, Id agentId, String turnIdentifier) {
        return new OrchestrationContext(
            null,
            executionId,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            agentId,
            turnIdentifier,
            1,
            TestFactory.createUserMessage('Customer reply'),
            new AgentStateService(),
            new CapabilityExecutionService(),
            new AgentJobEnqueuer(),
            new ContextManagerService(),
            null,
            new IDecisionStepLogger.NoOp()
        );
    }

    private static void configureDefaultHitlExecutionIdentity() {
        insert new AIAgentFrameworkSettings__c(DefaultHITLExecIdentityProfile__c = 'FrameworkServiceUser');
        AIAgentFrameworkSettings.clearCache();
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
}
