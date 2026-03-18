@IsTest
private class InboundInteractionPipelineServiceTest {
    @IsTest
    static void testResolve_ReusesSessionAndComputesDedupKey() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Inbound Pipeline Agent').withType('Conversational').withLLM(llm.Id).save();
        Case sourceCase = TestFactory.newCase().withSubject('Inbound Pipeline Case').save();

        Map<String, Object> triggerMetadata = new Map<String, Object>{
            'channel' => RuntimeRegistryService.CHANNEL_CHAT,
            'provider' => 'Salesforce Chat',
            'endpointIdentifier' => 'Salesforce Chat UI',
            'conversationKey' => 'thread-001',
            'userId' => 'customer@example.com',
            'messageId' => '<msg-001@example.com>'
        };

        InboundInteractionPipelineService service = new InboundInteractionPipelineService();
        InboundInteractionPipelineService.ResolvedInbound first = service.resolve(
            agent,
            new ChatChannelAdapter(),
            sourceCase.Id,
            'Need help with my case',
            new Map<String, Object>(triggerMetadata),
            '[test] '
        );
        InboundInteractionPipelineService.ResolvedInbound second = service.resolve(
            agent,
            new ChatChannelAdapter(),
            sourceCase.Id,
            'Following up on the same thread',
            new Map<String, Object>(triggerMetadata),
            '[test] '
        );

        System.assertNotEquals(null, first.sessionContext, 'Inbound resolution should create a session context');
        System.assertNotEquals(null, first.sessionContext.sessionId, 'Inbound resolution should create a durable interaction session');
        System.assertEquals(first.sessionContext.sessionId, second.sessionContext.sessionId, 'Same thread should reuse the same session');
        System.assert(String.isNotBlank(first.inboundDedupKey), 'Inbound resolution should compute a deduplication key');
        System.assertEquals(null, first.route, 'Without packaged route metadata the pipeline should leave route resolution empty');
    }
}
