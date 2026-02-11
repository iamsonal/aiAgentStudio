/**
 * @description Focused tests for ContextManagerService categorization and relevance behavior
 */
@IsTest
private class ContextManagerServiceTest {
    @TestSetup
    static void setupData() {
        TestFactory.createFullAgentSetup().save();
    }

    @IsTest
    static void testGetStructuredContext_CategorizesItems() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account accPinned = TestFactory.newAccount().withName('Pinned').save();
        Account accPrimary = TestFactory.newAccount().withName('Primary').save();
        Account accRecent = TestFactory.newAccount().withName('Recent').save();
        Account accRelated = TestFactory.newAccount().withName('Related').save();
        Account accStale = TestFactory.newAccount().withName('Stale').save();

        Integer currentTurn = 20;

        ContextManagerService.ContextItem pinnedItem = new ContextManagerService.ContextItem(accPinned.Id, ContextManagerService.ContextType.PINNED, 1, null);
        pinnedItem.lastAccessed = currentTurn - 5;
        ContextLedgerItem__c pinnedRecord = pinnedItem.toRecord(execution.Id);

        ContextManagerService.ContextItem primaryItem = new ContextManagerService.ContextItem(
            accPrimary.Id,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            2,
            null
        );
        primaryItem.lastAccessed = currentTurn - 3;
        ContextLedgerItem__c primaryRecord = primaryItem.toRecord(execution.Id);

        ContextManagerService.ContextItem recentItem = new ContextManagerService.ContextItem(
            accRecent.Id,
            ContextManagerService.ContextType.USER_MENTIONED,
            5,
            null
        );
        recentItem.lastAccessed = currentTurn - 1;
        ContextLedgerItem__c recentRecord = recentItem.toRecord(execution.Id);

        ContextManagerService.ContextItem relatedItem = new ContextManagerService.ContextItem(
            accRelated.Id,
            ContextManagerService.ContextType.ACTION_GENERATED,
            6,
            null
        );
        relatedItem.lastAccessed = currentTurn - 5;
        ContextLedgerItem__c relatedRecord = relatedItem.toRecord(execution.Id);

        ContextManagerService.ContextItem staleItem = new ContextManagerService.ContextItem(
            accStale.Id,
            ContextManagerService.ContextType.BACKGROUND_CONTEXT,
            1,
            null
        );
        staleItem.lastAccessed = currentTurn - 15;
        ContextLedgerItem__c staleRecord = staleItem.toRecord(execution.Id);

        insert new List<ContextLedgerItem__c>{ pinnedRecord, primaryRecord, recentRecord, relatedRecord, staleRecord };

        ContextManagerService svc = new ContextManagerService();
        Map<String, List<ContextManagerService.ContextItem>> structured = svc.getStructuredContext(execution.Id, currentTurn);

        System.assert(containsId(structured.get('pinned'), String.valueOf(accPinned.Id)), 'Pinned item should be categorized as pinned');
        System.assert(containsId(structured.get('primary'), String.valueOf(accPrimary.Id)), 'Primary item should be categorized as primary');
        System.assert(containsId(structured.get('recent'), String.valueOf(accRecent.Id)), 'Recent item should be categorized as recent');
        System.assert(containsId(structured.get('related'), String.valueOf(accRelated.Id)), 'Related item should be categorized as related');
        System.assert(containsId(structured.get('stale'), String.valueOf(accStale.Id)), 'Stale item should be categorized as stale');
    }

    @IsTest
    static void testContextItemUpdateRelevance_PinnedNeverDecays() {
        Account acc = TestFactory.newAccount().withName('Pinned Relevance').save();
        ContextManagerService.ContextItem pinned = new ContextManagerService.ContextItem(acc.Id, ContextManagerService.ContextType.PINNED, 1, null);
        pinned.lastAccessed = 1;
        pinned.accessCount = 1;

        pinned.updateRelevance(100);

        System.assertEquals(9999.0, pinned.relevanceScore, 'Pinned relevance should remain at pinned score');
        System.assertEquals(ContextManagerService.ContextStatus.ACTIVE, pinned.status, 'Pinned items should remain active');
    }

    @IsTest
    static void testCommitExecutionTurnContext_PromotesPageAndLinksChild() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account pageContext = TestFactory.newAccount().withName('Page Context').save();
        Contact actionRecord = new Contact(LastName = 'Action Child', AccountId = pageContext.Id);
        insert actionRecord;

        ContextLedgerItem__c existing = new ContextLedgerItem__c(
            AgentExecution__c = execution.Id,
            RecordId__c = pageContext.Id,
            RecordType__c = 'Account',
            ContextType__c = ContextManagerService.ContextType.USER_MENTIONED.name(),
            Status__c = ContextManagerService.ContextStatus.ACTIVE.name(),
            TurnAdded__c = 1,
            LastAccessedTurn__c = 1,
            AccessCount__c = 1,
            RelevanceScore__c = 100
        );
        insert existing;

        ContextManagerService svc = new ContextManagerService();
        svc.commitExecutionTurnContext(execution.Id, 5, pageContext.Id, actionRecord.Id);

        ContextLedgerItem__c updatedPage = [
            SELECT ContextType__c, OriginalContextType__c, ChildRecordIds__c
            FROM ContextLedgerItem__c
            WHERE AgentExecution__c = :execution.Id AND RecordId__c = :pageContext.Id
            LIMIT 1
        ];
        System.assertEquals(
            ContextManagerService.ContextType.IMPLICIT_PRIMARY.name(),
            updatedPage.ContextType__c,
            'Page context should be promoted to primary'
        );
        System.assertEquals(
            ContextManagerService.ContextType.USER_MENTIONED.name(),
            updatedPage.OriginalContextType__c,
            'Original context type should be preserved'
        );
        System.assert(
            updatedPage.ChildRecordIds__c != null && updatedPage.ChildRecordIds__c.contains(String.valueOf(actionRecord.Id)),
            'Page context should link to child action record'
        );

        ContextLedgerItem__c actionItem = [
            SELECT ContextType__c, SourceRecordId__c, Metadata__c
            FROM ContextLedgerItem__c
            WHERE AgentExecution__c = :execution.Id AND RecordId__c = :actionRecord.Id
            LIMIT 1
        ];
        System.assertEquals(
            ContextManagerService.ContextType.ACTION_GENERATED.name(),
            actionItem.ContextType__c,
            'Action record should be stored as action-generated context'
        );
        System.assertEquals(String.valueOf(pageContext.Id), actionItem.SourceRecordId__c, 'Action record should reference page context as source');
        Map<String, Object> metadata = (Map<String, Object>) JSON.deserializeUntyped(actionItem.Metadata__c);
        System.assertEquals(true, metadata.get('createdByAgent'), 'Action metadata should mark createdByAgent');
    }

    @IsTest
    static void testGetFilteredContext_FiltersByTypeAndRelevance() {
        AgentExecution__c execution = TestFactory.newExecution()
            .withAgent([SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .save();

        Account actionAccount = TestFactory.newAccount().withName('Action Context').save();
        Account mentionAccount = TestFactory.newAccount().withName('Mention Context').save();

        insert new List<ContextLedgerItem__c>{
            new ContextLedgerItem__c(
                AgentExecution__c = execution.Id,
                RecordId__c = actionAccount.Id,
                RecordType__c = 'Account',
                ContextType__c = ContextManagerService.ContextType.ACTION_GENERATED.name(),
                Status__c = ContextManagerService.ContextStatus.ACTIVE.name(),
                TurnAdded__c = 5,
                LastAccessedTurn__c = 5,
                AccessCount__c = 1,
                RelevanceScore__c = 180
            ),
            new ContextLedgerItem__c(
                AgentExecution__c = execution.Id,
                RecordId__c = mentionAccount.Id,
                RecordType__c = 'Account',
                ContextType__c = ContextManagerService.ContextType.USER_MENTIONED.name(),
                Status__c = ContextManagerService.ContextStatus.ACTIVE.name(),
                TurnAdded__c = 5,
                LastAccessedTurn__c = 5,
                AccessCount__c = 1,
                RelevanceScore__c = 160
            )
        };

        ContextManagerService svc = new ContextManagerService();
        List<ContextManagerService.ContextItem> filtered = svc.getFilteredContext(
            execution.Id,
            5,
            new Set<ContextManagerService.ContextType>{ ContextManagerService.ContextType.ACTION_GENERATED },
            50
        );

        System.assertEquals(1, filtered.size(), 'Filtered context should return only action-generated items');
        System.assertEquals(String.valueOf(actionAccount.Id), filtered[0].id, 'Filtered item should match action record');
    }

    private static Boolean containsId(List<ContextManagerService.ContextItem> items, String idValue) {
        if (items == null) {
            return false;
        }
        for (ContextManagerService.ContextItem item : items) {
            if (item != null && item.id == idValue) {
                return true;
            }
        }
        return false;
    }
}
