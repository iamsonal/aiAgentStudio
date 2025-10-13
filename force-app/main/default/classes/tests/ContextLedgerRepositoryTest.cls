/**
 * @description Test class for ContextLedgerRepository
 * Tests repository pattern implementation for ContextLedgerItem__c data access
 */
@IsTest
private class ContextLedgerRepositoryTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
    }

    private static TestFactory.AgentSetup getTestSetup() {
        return new TestFactory.AgentSetup();
    }

    private static ContextLedgerItem__c createLedgerItem(
        Id executionId,
        String recordId,
        String status,
        Decimal relevanceScore
    ) {
        return new ContextLedgerItem__c(
            AgentExecution__c = executionId,
            RecordId__c = recordId,
            RecordType__c = 'Account',
            ContextType__c = 'IMPLICIT_PRIMARY',
            Status__c = status,
            TurnAdded__c = 1,
            LastAccessedTurn__c = 1,
            AccessCount__c = 1,
            RelevanceScore__c = relevanceScore
        );
    }

    // ===================================================================================
    // INSERT OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testInsertItem_SingleItem_Success() {
        // Given: Single ledger item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0);
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Inserting item
        Test.startTest();
        ContextLedgerItem__c result = repo.insertItem(item);
        Test.stopTest();

        // Then: Should insert successfully
        System.assertNotEquals(null, result.Id, 'Item should have ID after insert');

        List<ContextLedgerItem__c> queried = [SELECT Id, RecordId__c FROM ContextLedgerItem__c WHERE Id = :result.Id];
        System.assertEquals(1, queried.size(), 'Should find inserted item');
        System.assertEquals('001TestRecord001', queried[0].RecordId__c);
    }

    @IsTest
    static void testInsertItems_MultipleItems_Success() {
        // Given: Multiple ledger items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8),
            createLedgerItem(execution.Id, '001TestRecord003', 'ARCHIVED', 0.5)
        };
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Inserting items in bulk
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.insertItems(items);
        Test.stopTest();

        // Then: Should insert all items
        System.assertEquals(3, results.size(), 'Should return all inserted items');
        for (ContextLedgerItem__c item : results) {
            System.assertNotEquals(null, item.Id, 'Each item should have ID');
        }

        List<ContextLedgerItem__c> queried = [SELECT Id FROM ContextLedgerItem__c WHERE AgentExecution__c = :execution.Id];
        System.assertEquals(3, queried.size(), 'Should insert 3 items');
    }

    @IsTest
    static void testInsertItems_EmptyList_ReturnsEmptyList() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Inserting empty list
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.insertItems(new List<ContextLedgerItem__c>());
        Test.stopTest();

        // Then: Should return empty list
        System.assertEquals(0, results.size(), 'Should return empty list');
    }

    @IsTest
    static void testInsertItems_NullList_ReturnsEmptyList() {
        // Given: Null list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Inserting null list
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.insertItems(null);
        Test.stopTest();

        // Then: Should return empty list
        System.assertEquals(0, results.size(), 'Should return empty list for null input');
    }

    // ===================================================================================
    // UPSERT OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testUpsertItems_NewItems_InsertsAll() {
        // Given: New ledger items (not yet in database)
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001NewRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001NewRecord002', 'ACTIVE', 0.9)
        };
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Upserting new items
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.upsertItems(items);
        Test.stopTest();

        // Then: Should insert all items
        System.assertEquals(2, results.size(), 'Should return 2 items');
        List<ContextLedgerItem__c> queried = [SELECT Id, RecordId__c FROM ContextLedgerItem__c WHERE AgentExecution__c = :execution.Id];
        System.assertEquals(2, queried.size(), 'Should insert 2 new items');
    }

    @IsTest
    static void testUpsertItems_ExistingItems_UpdatesAll() {
        // Given: Existing items in database
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c existing = createLedgerItem(execution.Id, '001ExistingRec', 'ACTIVE', 0.5);
        insert existing;

        // Prepare update with same composite key but different relevance
        ContextLedgerItem__c updateItem = createLedgerItem(execution.Id, '001ExistingRec', 'ACTIVE', 1.0);
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Upserting existing item
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.upsertItems(new List<ContextLedgerItem__c>{ updateItem });
        Test.stopTest();

        // Then: Should update existing item
        System.assertEquals(1, results.size(), 'Should return 1 item');
        System.assertEquals(existing.Id, results[0].Id, 'Should have same ID as existing');

        ContextLedgerItem__c queried = [SELECT Id, RelevanceScore__c FROM ContextLedgerItem__c WHERE Id = :existing.Id];
        System.assertEquals(1.0, queried.RelevanceScore__c, 'Should update relevance score');
    }

    @IsTest
    static void testUpsertItems_MixedNewAndExisting_UpsertsBoth() {
        // Given: Mix of new and existing items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c existing = createLedgerItem(execution.Id, '001ExistingRec', 'ACTIVE', 0.5);
        insert existing;

        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001ExistingRec', 'ACTIVE', 1.0), // Update
            createLedgerItem(execution.Id, '001NewRecord001', 'ACTIVE', 0.9)  // Insert
        };
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Upserting mixed items
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.upsertItems(items);
        Test.stopTest();

        // Then: Should update existing and insert new
        System.assertEquals(2, results.size(), 'Should return 2 items');

        List<ContextLedgerItem__c> queried = [SELECT Id, RecordId__c FROM ContextLedgerItem__c WHERE AgentExecution__c = :execution.Id];
        System.assertEquals(2, queried.size(), 'Should have 2 total items');
    }

    @IsTest
    static void testUpsertItems_EmptyList_ReturnsEmptyList() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Upserting empty list
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.upsertItems(new List<ContextLedgerItem__c>());
        Test.stopTest();

        // Then: Should return empty list
        System.assertEquals(0, results.size(), 'Should return empty list');
    }

    // ===================================================================================
    // QUERY BUILDER TESTS
    // ===================================================================================

    @IsTest
    static void testQueryBuilder_ForExecution_ReturnsCorrectItems() {
        // Given: Items for specific execution
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying by execution
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .execute();
        Test.stopTest();

        // Then: Should return items for execution
        System.assertEquals(2, results.size(), 'Should return 2 items');
    }

    @IsTest
    static void testQueryBuilder_WithStatus_FiltersCorrectly() {
        // Given: Items with different statuses
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord003', 'PRUNED', 0.5)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying by status
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withStatus('ACTIVE')
            .execute();
        Test.stopTest();

        // Then: Should return only ACTIVE items
        System.assertEquals(1, results.size(), 'Should return only ACTIVE item');
        System.assertEquals('ACTIVE', results[0].Status__c);
    }

    @IsTest
    static void testQueryBuilder_WithMultipleStatuses_FiltersCorrectly() {
        // Given: Items with different statuses
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord003', 'PRUNED', 0.5)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with multiple statuses
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withStatuses(new Set<String>{'ACTIVE', 'ARCHIVED'})
            .execute();
        Test.stopTest();

        // Then: Should return ACTIVE and ARCHIVED items
        System.assertEquals(2, results.size(), 'Should return 2 items');
    }

    @IsTest
    static void testQueryBuilder_WithContextType_FiltersCorrectly() {
        // Given: Items with different context types
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item1 = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0);
        item1.ContextType__c = 'IMPLICIT_PRIMARY';
        ContextLedgerItem__c item2 = createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8);
        item2.ContextType__c = 'ACTION_GENERATED';
        insert new List<ContextLedgerItem__c>{ item1, item2 };

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying by context type
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withContextType('IMPLICIT_PRIMARY')
            .execute();
        Test.stopTest();

        // Then: Should return only IMPLICIT_PRIMARY items
        System.assertEquals(1, results.size(), 'Should return only IMPLICIT_PRIMARY item');
        System.assertEquals('IMPLICIT_PRIMARY', results[0].ContextType__c);
    }

    @IsTest
    static void testQueryBuilder_WithMinRelevance_FiltersCorrectly() {
        // Given: Items with different relevance scores
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.7),
            createLedgerItem(execution.Id, '001TestRecord003', 'ACTIVE', 0.3)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with min relevance
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withMinRelevance(0.5)
            .execute();
        Test.stopTest();

        // Then: Should return items with relevance >= 0.5
        System.assertEquals(2, results.size(), 'Should return items with relevance >= 0.5');
        for (ContextLedgerItem__c item : results) {
            System.assert(item.RelevanceScore__c >= 0.5, 'All items should have relevance >= 0.5');
        }
    }

    @IsTest
    static void testQueryBuilder_WithMaxTurnsSinceAccess_FiltersCorrectly() {
        // Given: Items with different last accessed turns
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item1 = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0);
        item1.LastAccessedTurn__c = 10;
        ContextLedgerItem__c item2 = createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8);
        item2.LastAccessedTurn__c = 8; // Changed from 5 to 8 to be within 5 turns of current turn 12
        ContextLedgerItem__c item3 = createLedgerItem(execution.Id, '001TestRecord003', 'ACTIVE', 0.7);
        item3.LastAccessedTurn__c = 2;
        insert new List<ContextLedgerItem__c>{ item1, item2, item3 };

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with max turns since access (current turn = 12, max = 5)
        // minLastAccessedTurn = 12 - 5 = 7, so items with LastAccessedTurn >= 7 should be returned
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withMaxTurnsSinceAccess(5, 12)
            .execute();
        Test.stopTest();

        // Then: Should return items accessed within last 5 turns (turn >= 7)
        System.assertEquals(2, results.size(), 'Should return items accessed within 5 turns');
        for (ContextLedgerItem__c item : results) {
            System.assert(item.LastAccessedTurn__c >= 7, 'Items should be accessed within 5 turns');
        }
    }

    @IsTest
    static void testQueryBuilder_WithOrderBy_SortsCorrectly() {
        // Given: Items with different relevance scores
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord003', 'ACTIVE', 0.8)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with custom order
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .orderBy('RelevanceScore__c ASC')
            .execute();
        Test.stopTest();

        // Then: Should return items in ascending order
        System.assertEquals(3, results.size());
        System.assertEquals(0.5, results[0].RelevanceScore__c);
        System.assertEquals(0.8, results[1].RelevanceScore__c);
        System.assertEquals(1.0, results[2].RelevanceScore__c);
    }

    @IsTest
    static void testQueryBuilder_WithLimit_ReturnsLimitedResults() {
        // Given: Multiple items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>();
        for (Integer i = 0; i < 10; i++) {
            items.add(createLedgerItem(execution.Id, '001TestRec' + i, 'ACTIVE', 1.0));
        }
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with limit
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .limitTo(5)
            .execute();
        Test.stopTest();

        // Then: Should return only 5 items
        System.assertEquals(5, results.size(), 'Should return only 5 items');
    }

    @IsTest
    static void testQueryBuilder_ChainedFilters_AppliesAll() {
        // Given: Mixed items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.9),
            createLedgerItem(execution.Id, '001TestRecord003', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord004', 'ACTIVE', 0.3)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Querying with chained filters
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.queryBuilder()
            .forExecution(execution.Id)
            .withStatus('ACTIVE')
            .withMinRelevance(0.8)
            .limitTo(10)
            .execute();
        Test.stopTest();

        // Then: Should apply all filters
        System.assertEquals(2, results.size(), 'Should return 2 items matching all criteria');
        for (ContextLedgerItem__c item : results) {
            System.assertEquals('ACTIVE', item.Status__c);
            System.assert(item.RelevanceScore__c >= 0.8);
        }
    }

    // ===================================================================================
    // READ OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testGetActiveItemsForExecution_ReturnsOnlyActive() {
        // Given: Mixed status items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord003', 'ACTIVE', 0.7)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Getting active items
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.getActiveItemsForExecution(execution.Id);
        Test.stopTest();

        // Then: Should return only ACTIVE items
        System.assertEquals(2, results.size(), 'Should return only ACTIVE items');
        for (ContextLedgerItem__c item : results) {
            System.assertEquals('ACTIVE', item.Status__c);
        }
    }

    @IsTest
    static void testGetAllItemsForExecution_ReturnsAllStatuses() {
        // Given: Mixed status items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord003', 'PRUNED', 0.5)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Getting all items
        Test.startTest();
        List<ContextLedgerItem__c> results = repo.getAllItemsForExecution(execution.Id);
        Test.stopTest();

        // Then: Should return all items regardless of status
        System.assertEquals(3, results.size(), 'Should return all items');
    }

    @IsTest
    static void testGetItemByRecordId_ExistingItem_ReturnsItem() {
        // Given: Existing item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0);
        insert item;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Getting item by record ID
        Test.startTest();
        ContextLedgerItem__c result = repo.getItemByRecordId(execution.Id, '001TestRecord001');
        Test.stopTest();

        // Then: Should return the item
        System.assertNotEquals(null, result, 'Should find item');
        System.assertEquals(item.Id, result.Id);
        System.assertEquals('001TestRecord001', result.RecordId__c);
    }

    @IsTest
    static void testGetItemByRecordId_NonExistentItem_ReturnsNull() {
        // Given: Execution with no matching item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Getting non-existent item
        Test.startTest();
        ContextLedgerItem__c result = repo.getItemByRecordId(execution.Id, '001NonExistent');
        Test.stopTest();

        // Then: Should return null
        System.assertEquals(null, result, 'Should return null for non-existent item');
    }

    @IsTest
    static void testGetCountsByStatus_ReturnsCorrectCounts() {
        // Given: Items with different statuses
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.9),
            createLedgerItem(execution.Id, '001TestRecord003', 'ARCHIVED', 0.8),
            createLedgerItem(execution.Id, '001TestRecord004', 'PRUNED', 0.5)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Getting counts by status
        Test.startTest();
        Map<String, Integer> counts = repo.getCountsByStatus(execution.Id);
        Test.stopTest();

        // Then: Should return correct counts
        System.assertEquals(2, counts.get('ACTIVE'), 'Should have 2 ACTIVE items');
        System.assertEquals(1, counts.get('ARCHIVED'), 'Should have 1 ARCHIVED item');
        System.assertEquals(1, counts.get('PRUNED'), 'Should have 1 PRUNED item');
    }

    // ===================================================================================
    // UPDATE OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testUpdateItem_UpdatesSuccessfully() {
        // Given: Existing item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5);
        insert item;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Updating item
        item.RelevanceScore__c = 1.0;
        Test.startTest();
        repo.updateItem(item);
        Test.stopTest();

        // Then: Should update successfully
        ContextLedgerItem__c queried = [SELECT RelevanceScore__c FROM ContextLedgerItem__c WHERE Id = :item.Id];
        System.assertEquals(1.0, queried.RelevanceScore__c, 'Should update relevance score');
    }

    @IsTest
    static void testUpdateItems_UpdatesMultiple() {
        // Given: Multiple existing items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.6)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Updating items
        for (ContextLedgerItem__c item : items) {
            item.Status__c = 'ARCHIVED';
        }
        Test.startTest();
        repo.updateItems(items);
        Test.stopTest();

        // Then: Should update all items
        List<ContextLedgerItem__c> queried = [SELECT Status__c FROM ContextLedgerItem__c WHERE Id IN :items];
        System.assertEquals(2, queried.size());
        for (ContextLedgerItem__c item : queried) {
            System.assertEquals('ARCHIVED', item.Status__c);
        }
    }

    @IsTest
    static void testUpdateItems_EmptyList_DoesNothing() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Updating empty list
        Test.startTest();
        repo.updateItems(new List<ContextLedgerItem__c>());
        Test.stopTest();

        // Then: Should not throw exception
        System.assert(true, 'Should handle empty list gracefully');
    }

    @IsTest
    static void testUpdateItemWithVersionCheck_CorrectVersion_UpdatesSuccessfully() {
        // Given: Existing item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5);
        insert item;

        // Query to get LastModifiedDate
        ContextLedgerItem__c queried = [SELECT Id, LastModifiedDate FROM ContextLedgerItem__c WHERE Id = :item.Id];
        Datetime lastModified = queried.LastModifiedDate;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Updating with correct version
        item.RelevanceScore__c = 1.0;
        Test.startTest();
        Boolean success = repo.updateItemWithVersionCheck(item, lastModified);
        Test.stopTest();

        // Then: Should update successfully
        System.assertEquals(true, success, 'Should update with correct version');
        ContextLedgerItem__c updated = [SELECT RelevanceScore__c FROM ContextLedgerItem__c WHERE Id = :item.Id];
        System.assertEquals(1.0, updated.RelevanceScore__c);
    }

    @IsTest
    static void testUpdateItemWithVersionCheck_WrongVersion_ReturnsFalse() {
        // Given: Existing item
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5);
        insert item;

        // Simulate wrong version
        Datetime wrongVersion = Datetime.now().addDays(-1);

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Updating with wrong version
        item.RelevanceScore__c = 1.0;
        Test.startTest();
        Boolean success = repo.updateItemWithVersionCheck(item, wrongVersion);
        Test.stopTest();

        // Then: Should fail version check
        System.assertEquals(false, success, 'Should fail with wrong version');
        ContextLedgerItem__c queried = [SELECT RelevanceScore__c FROM ContextLedgerItem__c WHERE Id = :item.Id];
        System.assertEquals(0.5, queried.RelevanceScore__c, 'Should not update with wrong version');
    }

    @IsTest
    static void testUpdateItemWithVersionCheck_DeletedItem_ReturnsFalse() {
        // Given: Item that will be deleted
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c item = createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 0.5);
        insert item;

        // Delete the item to simulate deleted scenario
        Id deletedId = item.Id;
        delete item;

        ContextLedgerRepository repo = new ContextLedgerRepository();
        ContextLedgerItem__c deletedItem = new ContextLedgerItem__c(Id = deletedId);

        // When: Updating deleted item
        Test.startTest();
        Boolean success = repo.updateItemWithVersionCheck(deletedItem, Datetime.now());
        Test.stopTest();

        // Then: Should return false
        System.assertEquals(false, success, 'Should return false for deleted item');
    }

    // ===================================================================================
    // DELETE OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testDeleteItems_DeletesSuccessfully() {
        // Given: Existing items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Deleting items
        Test.startTest();
        repo.deleteItems(items);
        Test.stopTest();

        // Then: Should delete items
        List<ContextLedgerItem__c> queried = [SELECT Id FROM ContextLedgerItem__c WHERE Id IN :items];
        System.assertEquals(0, queried.size(), 'Should delete all items');
    }

    @IsTest
    static void testDeleteItems_EmptyList_DoesNothing() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Deleting empty list
        Test.startTest();
        repo.deleteItems(new List<ContextLedgerItem__c>());
        Test.stopTest();

        // Then: Should not throw exception
        System.assert(true, 'Should handle empty list gracefully');
    }

    @IsTest
    static void testSoftDeleteItems_MarkesAsPruned() {
        // Given: Existing items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Soft deleting items
        Test.startTest();
        repo.softDeleteItems(items, 'Test pruning reason');
        Test.stopTest();

        // Then: Should mark as PRUNED
        List<ContextLedgerItem__c> queried = [
            SELECT Status__c, PrunedReason__c, PrunedAt__c
            FROM ContextLedgerItem__c
            WHERE Id IN :items
        ];
        System.assertEquals(2, queried.size(), 'Items should still exist');
        for (ContextLedgerItem__c item : queried) {
            System.assertEquals('PRUNED', item.Status__c);
            System.assertEquals('Test pruning reason', item.PrunedReason__c);
            System.assertNotEquals(null, item.PrunedAt__c);
        }
    }

    @IsTest
    static void testSoftDeleteItems_EmptyList_DoesNothing() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Soft deleting empty list
        Test.startTest();
        repo.softDeleteItems(new List<ContextLedgerItem__c>(), 'Test reason');
        Test.stopTest();

        // Then: Should not throw exception
        System.assert(true, 'Should handle empty list gracefully');
    }

    @IsTest
    static void testArchiveItems_MarkesAsArchived() {
        // Given: Existing items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0),
            createLedgerItem(execution.Id, '001TestRecord002', 'ACTIVE', 0.8)
        };
        insert items;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Archiving items
        Test.startTest();
        repo.archiveItems(items);
        Test.stopTest();

        // Then: Should mark as ARCHIVED
        List<ContextLedgerItem__c> queried = [SELECT Status__c FROM ContextLedgerItem__c WHERE Id IN :items];
        System.assertEquals(2, queried.size());
        for (ContextLedgerItem__c item : queried) {
            System.assertEquals('ARCHIVED', item.Status__c);
        }
    }

    @IsTest
    static void testArchiveItems_EmptyList_DoesNothing() {
        // Given: Empty list
        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Archiving empty list
        Test.startTest();
        repo.archiveItems(new List<ContextLedgerItem__c>());
        Test.stopTest();

        // Then: Should not throw exception
        System.assert(true, 'Should handle empty list gracefully');
    }

    // ===================================================================================
    // BATCH OPERATIONS TESTS
    // ===================================================================================

    @IsTest
    static void testDeletePrunedItemsOlderThan_DeletesOldPrunedItems() {
        // Given: Pruned items with different ages
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c oldPruned = createLedgerItem(execution.Id, '001TestRecord001', 'PRUNED', 0.5);
        oldPruned.PrunedAt__c = Datetime.now().addDays(-40);

        ContextLedgerItem__c recentPruned = createLedgerItem(execution.Id, '001TestRecord002', 'PRUNED', 0.5);
        recentPruned.PrunedAt__c = Datetime.now().addDays(-10);

        ContextLedgerItem__c active = createLedgerItem(execution.Id, '001TestRecord003', 'ACTIVE', 1.0);

        insert new List<ContextLedgerItem__c>{ oldPruned, recentPruned, active };

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Deleting pruned items older than 30 days
        Test.startTest();
        Integer deleteCount = repo.deletePrunedItemsOlderThan(30);
        Test.stopTest();

        // Then: Should delete only old pruned item
        System.assertEquals(1, deleteCount, 'Should delete 1 old pruned item');

        List<ContextLedgerItem__c> remaining = [SELECT Id, Status__c FROM ContextLedgerItem__c WHERE AgentExecution__c = :execution.Id];
        System.assertEquals(2, remaining.size(), 'Should have 2 remaining items');

        // Verify old pruned item is deleted
        List<ContextLedgerItem__c> oldItems = [SELECT Id FROM ContextLedgerItem__c WHERE Id = :oldPruned.Id];
        System.assertEquals(0, oldItems.size(), 'Old pruned item should be deleted');
    }

    @IsTest
    static void testDeletePrunedItemsOlderThan_NoOldItems_ReturnsZero() {
        // Given: No old pruned items
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        ContextLedgerItem__c recentPruned = createLedgerItem(execution.Id, '001TestRecord001', 'PRUNED', 0.5);
        recentPruned.PrunedAt__c = Datetime.now().addDays(-5);
        insert recentPruned;

        ContextLedgerRepository repo = new ContextLedgerRepository();

        // When: Deleting pruned items older than 30 days
        Test.startTest();
        Integer deleteCount = repo.deletePrunedItemsOlderThan(30);
        Test.stopTest();

        // Then: Should delete nothing
        System.assertEquals(0, deleteCount, 'Should delete 0 items');
    }

    // ===================================================================================
    // QUERY RESULT WRAPPER TESTS
    // ===================================================================================

    @IsTest
    static void testQueryResult_Constructor_InitializesCorrectly() {
        // Given: Query result data
        AgentExecution__c execution = [SELECT Id FROM AgentExecution__c LIMIT 1];
        List<ContextLedgerItem__c> items = new List<ContextLedgerItem__c>{
            createLedgerItem(execution.Id, '001TestRecord001', 'ACTIVE', 1.0)
        };

        // When: Creating QueryResult
        Test.startTest();
        ContextLedgerRepository.QueryResult result = new ContextLedgerRepository.QueryResult(items, 100, true);
        Test.stopTest();

        // Then: Should initialize properly
        System.assertEquals(1, result.items.size());
        System.assertEquals(100, result.totalCount);
        System.assertEquals(true, result.hasMore);
    }

    @IsTest
    static void testQueryResult_NullItems_InitializesEmptyList() {
        // Given: Null items

        // When: Creating QueryResult with null
        Test.startTest();
        ContextLedgerRepository.QueryResult result = new ContextLedgerRepository.QueryResult(null, 0, false);
        Test.stopTest();

        // Then: Should initialize with empty list
        System.assertNotEquals(null, result.items);
        System.assertEquals(0, result.items.size());
        System.assertEquals(0, result.totalCount);
        System.assertEquals(false, result.hasMore);
    }
}

