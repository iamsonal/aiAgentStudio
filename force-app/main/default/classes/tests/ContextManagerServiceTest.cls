@isTest
private class ContextManagerServiceTest {
    @TestSetup
    static void makeData() {
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @isTest
    static void testContextItemConstructor() {
        Id testId = '001000000000000AAA';
        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(
            testId,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        System.assertEquals('001000000000000AAA', item.id);
        System.assertEquals('Account', item.type); // Assuming Account based on test ID
        System.assertEquals(ContextManagerService.ContextType.IMPLICIT_PRIMARY, item.contextType);
        System.assertEquals(ContextManagerService.ContextStatus.ACTIVE, item.status);
        System.assertEquals(1, item.turnAdded);
        System.assertEquals(1, item.lastAccessed);
        System.assertEquals(1, item.accessCount);
        System.assertEquals(200.0, item.relevanceScore); // 2x base score for IMPLICIT_PRIMARY
        System.assertEquals(null, item.sourceId);
        System.assertEquals(new List<String>(), item.childIds);
        System.assertEquals(new Map<String, Object>(), item.metadata);
    }

    @isTest
    static void testContextItemRecordAccess() {
        Id testId = '001000000000000AAA';
        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(
            testId,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        // Record access at turn 2
        item.recordAccess(2);

        System.assertEquals(2, item.lastAccessed);
        System.assertEquals(2, item.accessCount);
    }

    @isTest
    static void testContextItemAddChild() {
        Id testId = '001000000000000AAA';
        Id childId = '002000000000000AAA';

        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(
            testId,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        item.addChild('002000000000000AAA');
        System.assertEquals(new List<String>{ '002000000000000AAA' }, item.childIds);

        // Adding same child again should not duplicate
        item.addChild('002000000000000AAA');
        System.assertEquals(1, item.childIds.size());
    }

    @isTest
    static void testContextItemMetadata() {
        Id testId = '001000000000000AAA';
        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(
            testId,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        item.setMetadata('testKey', 'testValue');
        System.assertEquals('testValue', item.getMetadata('testKey'));
        System.assertEquals(null, item.getMetadata('nonExistentKey'));
    }

    @isTest
    static void testContextItemCompareTo() {
        Id testId1 = '001000000000000AAA';
        Id testId2 = '002000000000000AAA';

        ContextManagerService.ContextItem item1 = new ContextManagerService.ContextItem(
            testId1,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        ContextManagerService.ContextItem item2 = new ContextManagerService.ContextItem(
            testId2,
            ContextManagerService.ContextType.RELATED_RECORD,
            1,
            null
        );

        // item1 should have higher relevance score, so should come first
        System.assertEquals(-1, item1.compareTo(item2));
        System.assertEquals(1, item2.compareTo(item1));

        // Same items should be equal
        System.assertEquals(0, item1.compareTo(item1));
    }

    @isTest
    static void testContextItemGetTemporalLabel() {
        Id testId = '001000000000000AAA';
        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(
            testId,
            ContextManagerService.ContextType.IMPLICIT_PRIMARY,
            1,
            null
        );

        System.assertEquals('Current Turn', item.getTemporalLabel(1));
        System.assertEquals('Last Turn', item.getTemporalLabel(2));
        System.assertEquals('2 turns ago', item.getTemporalLabel(3));
        System.assertEquals('Recently', item.getTemporalLabel(5));
        System.assertEquals('Earlier in conversation', item.getTemporalLabel(15));
    }

    @isTest
    static void testContextManagementException() {
        ContextManagerService.ContextManagementException ex = new ContextManagerService.ContextManagementException('Test message');
        System.assertEquals('Test message', ex.getMessage());
    }

    @isTest
    static void testGetContextLedgerWithNullSessionId() {
        ContextManagerService service = new ContextManagerService();
        List<ContextManagerService.ContextItem> result = service.getContextLedger(null);
        System.assertEquals(new List<ContextManagerService.ContextItem>(), result);
    }

    @isTest
    static void testGetContextLedgerWithNullSessionIdAndTurn() {
        ContextManagerService service = new ContextManagerService();
        List<ContextManagerService.ContextItem> result = service.getContextLedger(null, 1);
        System.assertEquals(new List<ContextManagerService.ContextItem>(), result);
    }

    @isTest
    static void testAddContextItem() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        ContextManagerService service = new ContextManagerService();
        Id testRecordId = '001000000000000AAA';

        Test.startTest();
        service.addContextItem(session.Id, testRecordId, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null, null);
        Test.stopTest();

        // Verify the item was added by retrieving the context ledger
        List<ContextManagerService.ContextItem> ledger = service.getContextLedger(session.Id, 1);
        System.assertEquals(1, ledger.size());
        System.assertEquals('001000000000000AAA', ledger[0].id);
    }

    @isTest
    static void testRemoveContextItem() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        ContextManagerService service = new ContextManagerService();
        Id testRecordId = '001000000000000AAA';

        // Add an item first
        Test.startTest();
        service.addContextItem(session.Id, testRecordId, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null, null);

        // Then remove it
        service.removeContextItem(session.Id, testRecordId);
        Test.stopTest();

        // Verify the item was removed
        List<ContextManagerService.ContextItem> ledger = service.getContextLedger(session.Id, 1);
        System.assertEquals(0, ledger.size());
    }

    @isTest
    static void testGetFilteredContext() {
        // Create a test chat session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        ContextManagerService service = new ContextManagerService();
        Id testRecordId1 = '001000000000000AAA';
        Id testRecordId2 = '002000000000000AAA';

        // Add items of different types
        Test.startTest();
        service.addContextItem(session.Id, testRecordId1, ContextManagerService.ContextType.IMPLICIT_PRIMARY, 1, null, null);

        service.addContextItem(session.Id, testRecordId2, ContextManagerService.ContextType.RELATED_RECORD, 1, null, null);
        Test.stopTest();

        // Get filtered context for specific types
        Set<ContextManagerService.ContextType> filterTypes = new Set<ContextManagerService.ContextType>{
            ContextManagerService.ContextType.IMPLICIT_PRIMARY
        };

        List<ContextManagerService.ContextItem> filtered = service.getFilteredContext(session.Id, 1, filterTypes, 0);

        System.assertEquals(1, filtered.size());
        System.assertEquals(ContextManagerService.ContextType.IMPLICIT_PRIMARY, filtered[0].contextType);
    }
}
