/**
 * @description Focused tests for the minimal ContextManagerService reference model.
 */
@IsTest
private class ContextManagerServiceTest {
    @TestSetup
    static void setupData() {
        TestFactory.createFullAgentSetup().save();
    }

    @IsTest
    static void testCommitExecutionTurnContext_CreatesPrimaryAndCreatedReferences() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account pageContext = TestFactory.newAccount().withName('Page Context').save();
        Contact actionRecord = new Contact(LastName = 'Created By Agent', AccountId = pageContext.Id);
        insert actionRecord;

        ContextManagerService service = new ContextManagerService();
        service.commitExecutionTurnContext(execution.Id, 1, pageContext.Id, actionRecord.Id);

        Map<String, ContextReference__c> referencesByRecordId = new Map<String, ContextReference__c>();
        for (ContextReference__c reference : [
            SELECT
                AgentExecution__c,
                InteractionSession__c,
                RecordId__c,
                RecordType__c,
                ReferenceRole__c,
                ReferenceSource__c,
                Status__c,
                LastUsedAt__c,
                UseCount__c,
                Explanation__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :execution.Id
        ]) {
            referencesByRecordId.put(reference.RecordId__c, reference);
        }

        System.assertEquals(2, referencesByRecordId.size(), 'Should create two minimal context references');

        ContextReference__c pageReference = referencesByRecordId.get(String.valueOf(pageContext.Id));
        System.assertEquals('Account', pageReference.RecordType__c);
        System.assertEquals(ContextManagerService.ReferenceRole.Primary.name(), pageReference.ReferenceRole__c);
        System.assertEquals('Page Context', pageReference.ReferenceSource__c);
        System.assertEquals(ContextManagerService.ReferenceStatus.Active.name(), pageReference.Status__c);
        System.assertEquals(1, pageReference.UseCount__c.intValue());
        System.assert(String.isNotBlank(pageReference.Explanation__c), 'Primary reference should have an admin-friendly explanation');

        ContextReference__c createdReference = referencesByRecordId.get(String.valueOf(actionRecord.Id));
        System.assertEquals('Contact', createdReference.RecordType__c);
        System.assertEquals(ContextManagerService.ReferenceRole.Created.name(), createdReference.ReferenceRole__c);
        System.assertEquals('Tool Output', createdReference.ReferenceSource__c);
        System.assertEquals(ContextManagerService.ReferenceStatus.Active.name(), createdReference.Status__c);
    }

    @IsTest
    static void testCommitContextDelta_CreatesTypedReferences() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account pageContext = TestFactory.newAccount().withName('Delta Page Context').save();
        Contact createdContact = new Contact(LastName = 'Delta Created Contact');
        insert createdContact;

        ContextManagerService service = new ContextManagerService();
        service.commitContextDelta(
            execution.Id,
            1,
            new List<ContextManagerService.ContextDeltaItem>{
                new ContextManagerService.ContextDeltaItem(
                    pageContext.Id,
                    ContextManagerService.ReferenceRole.Primary,
                    ContextManagerService.ReferenceSource.PageContext,
                    'Primary record for this turn.'
                ),
                new ContextManagerService.ContextDeltaItem(
                    createdContact.Id,
                    ContextManagerService.ReferenceRole.Created,
                    ContextManagerService.ReferenceSource.ToolOutput,
                    'Created by a tool.'
                )
            }
        );

        List<ContextReference__c> references = [
            SELECT RecordId__c, ReferenceRole__c, ReferenceSource__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :execution.Id
        ];
        System.assertEquals(2, references.size(), 'Typed context delta API should persist both anchors');
    }

    @IsTest
    static void testCommitExecutionTurnContext_ReusesExistingReference() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account pageContext = TestFactory.newAccount().withName('Repeated Page Context').save();

        ContextManagerService service = new ContextManagerService();
        service.commitExecutionTurnContext(execution.Id, 1, pageContext.Id, null);
        service.commitExecutionTurnContext(execution.Id, 2, pageContext.Id, null);

        List<ContextReference__c> references = [
            SELECT RecordId__c, UseCount__c, LastUsedAt__c
            FROM ContextReference__c
            WHERE AgentExecution__c = :execution.Id AND RecordId__c = :String.valueOf(pageContext.Id)
        ];
        System.assertEquals(1, references.size(), 'The same record should be updated instead of duplicated');
        System.assertEquals(2, references[0].UseCount__c.intValue(), 'Use count should increment when the reference is refreshed');
        System.assertNotEquals(null, references[0].LastUsedAt__c, 'Last used timestamp should be recorded');
    }

    @IsTest
    static void testGetRelevantRecordIds_ReusesInteractionSessionContinuity() {
        Account accountRecord = new Account(Name = 'Session Reference Account');
        insert accountRecord;

        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Session Reference Agent').withType('Conversational').withLLM(llm.Id).save();

        InteractionSession__c session = new InteractionSession__c(
            Channel__c = RuntimeRegistryService.CHANNEL_CHAT,
            ConversationKey__c = 'session-reference-001',
            ParticipantExternalKey__c = 'user-001',
            SessionStatus__c = 'Active'
        );
        insert session;

        AgentExecution__c firstExecution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-reference-001')
            .save();
        AgentExecution__c secondExecution = TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withStatus('Processing')
            .withProcessingStatus(AIAgentConstants.STATUS_PROCESSING)
            .withTurnIdentifier('turn-reference-002')
            .save();

        update new List<AgentExecution__c>{
            new AgentExecution__c(Id = firstExecution.Id, InteractionSession__c = session.Id),
            new AgentExecution__c(Id = secondExecution.Id, InteractionSession__c = session.Id)
        };

        ContextManagerService service = new ContextManagerService();
        service.commitExecutionTurnContext(firstExecution.Id, 1, accountRecord.Id, null);

        Set<Id> relevantIds = service.getRelevantRecordIds(secondExecution.Id);
        System.assert(relevantIds.contains(accountRecord.Id), 'A later execution in the same interaction session should reuse session-scoped references');
    }

    @IsTest
    static void testBuildTurnContextDelta_IncludesStructuredMentionsAndSystemSourceRecord() {
        Id agentId = [SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id;
        Account pageContext = TestFactory.newAccount().withName('Turn Delta Page').save();
        Contact sourceContact = TestFactory.newContact().withName('Turn', 'Source').save();
        Case mentionedCase = TestFactory.newCase().withSubject('Mentioned From Payload').save();
        Account relatedAccount = TestFactory.newAccount().withName('Related From Payload').save();

        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent(agentId)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withSourceRecord(sourceContact.Id)
            .save();
        update new AgentExecution__c(
            Id = execution.Id,
            TriggerPayload__c = JSON.serialize(
                new Map<String, Object>{
                    'mentionedRecordIds' => new List<String>{ String.valueOf(mentionedCase.Id) },
                    'relatedRecordIds' => new List<String>{ String.valueOf(relatedAccount.Id) }
                }
            )
        );

        ContextManagerService service = new ContextManagerService();
        List<ContextManagerService.ContextDeltaItem> deltaItems = service.buildTurnContextDelta(execution.Id, pageContext.Id, null);

        Map<String, ContextManagerService.ContextDeltaItem> deltaByRecordId = new Map<String, ContextManagerService.ContextDeltaItem>();
        for (ContextManagerService.ContextDeltaItem item : deltaItems) {
            deltaByRecordId.put(item.recordId, item);
        }

        System.assertEquals(4, deltaByRecordId.size(), 'Turn delta should include page, source, mention, and related anchors');
        System.assertEquals(ContextManagerService.ReferenceRole.Primary, deltaByRecordId.get(String.valueOf(pageContext.Id)).referenceRole);
        System.assertEquals(ContextManagerService.ReferenceRole.Related, deltaByRecordId.get(String.valueOf(sourceContact.Id)).referenceRole);
        System.assertEquals(ContextManagerService.ReferenceRole.Mentioned, deltaByRecordId.get(String.valueOf(mentionedCase.Id)).referenceRole);
        System.assertEquals(ContextManagerService.ReferenceRole.Related, deltaByRecordId.get(String.valueOf(relatedAccount.Id)).referenceRole);
    }
}
