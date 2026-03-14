/**
 * @description Focused tests for fail-closed channel delivery behavior.
 */
@IsTest
private class ChannelDeliveryPolicyServiceTest {
    @IsTest
    static void testApplyContentDelivery_FailsClosedWhenSameChannelReplyMissingSession() {
        AIAgentDefinition__c agent = createEmailAgent('DeliveryPolicyMissingSession');
        String turnIdentifier = 'turn-delivery-001';
        AgentExecution__c execution = createEmailExecution(agent.Id, null, 'support@example.com', turnIdentifier);

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
        System.assertEquals('Failed', refreshed.ExecutionStatus__c, 'Execution should be failed when same-channel enforcement cannot be satisfied');
    }

    @IsTest
    static void testApplyContentDelivery_FailsClosedWhenRouteKeyDiverges() {
        AIAgentDefinition__c agent = createEmailAgent('DeliveryPolicyRouteMismatch');
        InteractionSession__c session = new InteractionSession__c(
            Channel__c = RuntimeRegistryService.CHANNEL_EMAIL,
            ConversationKey__c = 'delivery-policy-thread-001',
            ParticipantExternalKey__c = 'customer@example.com',
            ReplyRouteKey__c = 'support@example.com',
            SessionStatus__c = 'Active'
        );
        insert session;

        String turnIdentifier = 'turn-delivery-002';
        AgentExecution__c execution = createEmailExecution(agent.Id, session.Id, 'billing@example.com', turnIdentifier);

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
    }

    private static AIAgentDefinition__c createEmailAgent(String name) {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName(name + '_LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName(name).withType('Iterative').withLLM(llm.Id).build();
        agent.RequiresSameChannelReply__c = true;
        insert agent;
        return agent;
    }

    private static AgentExecution__c createEmailExecution(Id agentId, Id interactionSessionId, String toAddress, String turnIdentifier) {
        Case sourceCase = TestFactory.newCase().withSubject('Delivery Policy Case').save();
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agentId)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Iterative')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withSourceRecord(sourceCase.Id)
            .withTurnIdentifier(turnIdentifier)
            .build();
        execution.InteractionChannel__c = RuntimeRegistryService.CHANNEL_EMAIL;
        execution.InteractionSession__c = interactionSessionId;
        execution.TriggerPayload__c = JSON.serialize(
            new Map<String, Object>{
                'toAddress' => toAddress,
                'fromAddress' => 'customer@example.com',
                'subject' => 'Need help',
                'inboundDedupKey' => 'dedup-' + String.valueOf(Crypto.getRandomLong()).replace('-', '')
            }
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
            TestFactory.createUserMessage('Customer email'),
            new AgentStateService(),
            new CapabilityExecutionService(),
            new AgentJobEnqueuer(),
            new ContextManagerService(),
            null,
            new IDecisionStepLogger.NoOp()
        );
    }
}
