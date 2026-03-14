/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

@IsTest
private class InteractionChannelRuntimeTest {
    @IsTest
    static void testInteractionSessionServiceReusesConversationAnchor() {
        InteractionSessionService service = new InteractionSessionService();

        Test.startTest();
        InteractionRuntimeModels.InteractionSessionContext firstContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_CHAT,
            'chat-conversation-001',
            'user-001',
            'user-001',
            'SalesforceChat',
            null,
            'SalesforceChatUI',
            '[test] '
        );
        InteractionRuntimeModels.InteractionSessionContext secondContext = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_CHAT,
            'chat-conversation-001',
            'user-001',
            'user-001',
            'SalesforceChat',
            null,
            'SalesforceChatUI',
            '[test] '
        );
        Test.stopTest();

        System.assertNotEquals(null, firstContext);
        System.assertNotEquals(null, firstContext.sessionId);
        System.assertEquals(firstContext.sessionId, secondContext.sessionId, 'Conversation reuse should return the same durable session');
        System.assertEquals(RuntimeRegistryService.CHANNEL_CHAT, secondContext.channel);
    }

    @IsTest
    static void testInteractionChannelRegistryResolvesConcreteAdapters() {
        InteractionRuntimeModels.IInteractionChannel chatAdapter = InteractionChannelRegistryService.resolveAdapter(
            null,
            null,
            RuntimeRegistryService.CHANNEL_CHAT
        );
        InteractionRuntimeModels.IInteractionChannel apiAdapter = InteractionChannelRegistryService.resolveAdapter(
            null,
            null,
            RuntimeRegistryService.CHANNEL_API
        );
        InteractionRuntimeModels.IInteractionChannel emailAdapter = InteractionChannelRegistryService.resolveAdapter(
            null,
            null,
            RuntimeRegistryService.CHANNEL_EMAIL
        );

        System.assert(chatAdapter instanceof ChatChannelAdapter, 'Chat channel should resolve to ChatChannelAdapter');
        System.assert(apiAdapter instanceof ApiInteractionChannel, 'API channel should resolve to ApiInteractionChannel');
        System.assert(emailAdapter instanceof EmailChannelAdapter, 'Email channel should resolve to EmailChannelAdapter');
    }

    @IsTest
    static void testInteractionChannelRegistryResolvesDescriptorDrivenRuntime() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c iterativeAgent = TestFactory.newAgentDefinition()
            .withName('Descriptor Runtime Agent')
            .withType('Iterative')
            .withLLM(llm.Id)
            .save();

        IAgentRuntime chatRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(iterativeAgent, RuntimeRegistryService.CHANNEL_CHAT);
        IAgentRuntime emailRuntime = InteractionChannelRegistryService.resolveIterativeRuntime(iterativeAgent, RuntimeRegistryService.CHANNEL_EMAIL);

        System.assert(chatRuntime instanceof ChatIterativeRuntimeService, 'Chat should resolve to conversational iterative runtime');
        System.assert(emailRuntime instanceof EmailIterativeRuntimeService, 'Email should resolve to email iterative runtime');
    }

    @IsTest
    static void testInteractionChannelRegistryRejectsUnsupportedChannel() {
        Boolean threw = false;
        try {
            InteractionChannelRegistryService.resolveAdapter(null, null, 'WhatsApp');
        } catch (AIAgentException.OrchestrationException e) {
            threw = true;
            System.assert(e.getMessage().contains('Unsupported interaction channel'), 'Should fail fast on unknown channel keys');
        }

        System.assertEquals(true, threw, 'Unknown channels must fail instead of silently defaulting');
    }

    @IsTest
    static void testContextLedgerUsesInteractionSessionContinuity() {
        Account accountRecord = new Account(Name = 'Session Ledger Account');
        insert accountRecord;

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Session Ledger Agent').withType('Iterative').withLLM(llm.Id).save();

        InteractionSession__c session = new InteractionSession__c(
            Channel__c = RuntimeRegistryService.CHANNEL_CHAT,
            ConversationKey__c = 'session-ledger-001',
            ParticipantExternalKey__c = 'user-001',
            SessionStatus__c = 'Active'
        );
        insert session;

        AgentExecution__c firstExecution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Iterative')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-session-001')
            .save();
        AgentExecution__c secondExecution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Iterative')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-session-002')
            .save();

        update new List<AgentExecution__c>{
            new AgentExecution__c(Id = firstExecution.Id, InteractionSession__c = session.Id),
            new AgentExecution__c(Id = secondExecution.Id, InteractionSession__c = session.Id)
        };

        ContextManagerService contextManager = new ContextManagerService();
        contextManager.commitExecutionTurnContext(firstExecution.Id, 1, accountRecord.Id, null);

        List<ContextManagerService.ContextItem> ledger = contextManager.getContextLedger(secondExecution.Id, 2);
        System.assertEquals(1, ledger.size(), 'A later execution in the same interaction session should reuse session-scoped context');
        System.assertEquals(String.valueOf(accountRecord.Id), ledger[0].id);
    }

    @IsTest
    static void testInteractionSessionServiceLeavesStatelessApiWithoutSessionRecord() {
        InteractionSessionService service = new InteractionSessionService();

        Test.startTest();
        InteractionRuntimeModels.InteractionSessionContext context = service.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_API,
            null,
            'API',
            'user-001',
            'SalesforceAPI',
            null,
            'API',
            '[test] '
        );
        Test.stopTest();

        System.assertNotEquals(null, context, 'Stateless API execution should still return a context object');
        System.assertEquals(null, context.sessionId, 'Stateless API execution should not create a durable interaction session');
        System.assertEquals(RuntimeRegistryService.CHANNEL_API, context.channel);
    }

    @IsTest
    static void testInboundInteractionPipelineResolvesEmailSessionAndDedupKey() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Email Pipeline Agent').withType('Iterative').withLLM(llm.Id).save();
        Case sourceCase = TestFactory.newCase().withSubject('Email Pipeline Case').save();

        Map<String, Object> triggerMetadata = new Map<String, Object>{
            'threadIdentifier' => 'thread-001',
            'fromAddress' => 'customer@example.com',
            'toAddress' => 'support@example.com',
            'messageId' => '<msg-001@example.com>',
            'messageDate' => String.valueOf(Datetime.now())
        };

        InboundInteractionPipelineService service = new InboundInteractionPipelineService();
        InboundInteractionPipelineService.ResolvedInbound first = service.resolveEmailInbound(
            agent,
            sourceCase.Id,
            'Need help with my case',
            new Map<String, Object>(triggerMetadata),
            '[test] '
        );
        InboundInteractionPipelineService.ResolvedInbound second = service.resolveEmailInbound(
            agent,
            sourceCase.Id,
            'Following up on the same thread',
            new Map<String, Object>(triggerMetadata),
            '[test] '
        );

        System.assertNotEquals(null, first.sessionContext, 'Email inbound should resolve a session context');
        System.assertNotEquals(null, first.sessionContext.sessionId, 'Email inbound should create a durable interaction session');
        System.assertEquals(first.sessionContext.sessionId, second.sessionContext.sessionId, 'Same thread should reuse the same session');
        System.assert(String.isNotBlank(first.inboundDedupKey), 'Email inbound should compute a deduplication key');
        System.assertEquals(null, first.route, 'Without packaged route metadata the pipeline should leave route resolution empty');
    }
}
