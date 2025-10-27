/**
 * @description Tests for ActionFindEntities using TestFactory utilities
 */
@IsTest
private class ActionFindEntitiesTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create accounts using TestFactory
        TestFactory.newAccount().withName('Acme Corporation').withIndustry('Technology').save();

        TestFactory.newAccount().withName('Global Industries').withIndustry('Manufacturing').save();

        TestFactory.newAccount().withName('Tech Solutions Inc').withIndustry('Technology').save();

        // Create contacts
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name];

        TestFactory.newContact().withName('John', 'Smith').withEmail('john.smith@acme.com').withAccount(accounts[0].Id).save();

        TestFactory.newContact().withName('Jane', 'Doe').withEmail('jane.doe@global.com').withAccount(accounts[1].Id).save();

        TestFactory.newContact().withName('Robert', 'Johnson').withEmail('bob.johnson@tech.com').save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testFindEntities_SingleMatch_Success() {
        // Given: Search for specific contact
        Contact expected = [SELECT Id FROM Contact WHERE Email = 'john.smith@acme.com' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expected.Id });

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Contact' },
            'fieldsToReturn' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' },
            'filters' => new Map<String, Object>{ 'Email' => 'john.smith@acme.com' }
        };

        // When: Searching
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should find one record
        System.assert(result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(1, queryResult.count);
        System.assertEquals(1, queryResult.records.size());
        System.assertEquals(expected.Id, queryResult.records[0].Id);
    }

    @IsTest
    static void testFindEntities_MultipleMatches_Success() {
        // Given: Multiple accounts with same industry
        List<Account> accounts = [SELECT Id FROM Account WHERE Industry = 'Technology'];
        Test.setFixedSearchResults(new List<Id>(new Map<Id, Account>(accounts).keySet()));

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name', 'Industry' },
            'filters' => new Map<String, Object>{ 'Industry' => 'Technology' },
            'limit' => 10
        };

        // When: Searching
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should find multiple records
        System.assert(result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(2, queryResult.count);
        System.assertEquals(2, queryResult.records.size());
    }

    @IsTest
    static void testFindEntities_NoMatches_Success() {
        // Given: Search query with no results
        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Name' => 'NonExistent12345' }
        };

        // When: Searching
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should succeed with zero results
        System.assert(result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(0, queryResult.count);
        System.assertEquals(0, queryResult.records.size());
    }

    @IsTest
    static void testFindEntities_WithLimit_Success() {
        // Given: Multiple records but limited results
        List<Account> accounts = [SELECT Id FROM Account WHERE Industry = 'Technology'];
        Test.setFixedSearchResults(new List<Id>(new Map<Id, Account>(accounts).keySet()));

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Industry' => 'Technology' },
            'queryLimit' => 1
        };

        // When: Searching with limit
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should respect limit
        System.assert(result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(1, queryResult.count);
        System.assertEquals(1, queryResult.records.size());
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testFindEntities_MissingRequiredParams_Failure() {
        // Given: Missing sObjectTypes parameter
        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Name' => 'Test' }
            // Missing sObjectTypes
        };

        // When: Attempting search
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!result.isSuccess, 'Should fail when missing required parameters');
        System.assert(
            result.errorMessage.contains('sObjectTypes') || result.errorMessage.contains('required'),
            'Error message should indicate missing required parameter'
        );
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testQueryResult_Constructor_WithRecords() {
        // Given: Test records
        Account testAccount = new Account(Id = '001000000000001AAA', Name = 'Test Account');
        List<SObject> testRecords = new List<SObject>{ testAccount };
        List<String> sObjectTypes = new List<String>{ 'Account' };

        // When: Creating result
        Test.startTest();
        ActionFindEntities.QueryResult result = new ActionFindEntities.QueryResult(testRecords, sObjectTypes);
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals(1, result.count);
        System.assertEquals(1, result.records.size());
        System.assertEquals('Found 1 record(s) matching the criteria.', result.message);
        System.assertEquals(1, (Integer) result.metadata.get('totalFound'));
        System.assertEquals(sObjectTypes, (List<String>) result.metadata.get('sObjectTypesSearched'));
    }

    @IsTest
    static void testQueryResult_Constructor_Empty() {
        // Given: Empty results
        List<SObject> testRecords = new List<SObject>();
        List<String> sObjectTypes = new List<String>{ 'Account' };

        // When: Creating result
        Test.startTest();
        ActionFindEntities.QueryResult result = new ActionFindEntities.QueryResult(testRecords, sObjectTypes);
        Test.stopTest();

        // Then: Should handle empty list
        System.assertEquals(0, result.count);
        System.assertEquals(0, result.records.size());
        System.assertEquals('Found 0 record(s) matching the criteria.', result.message);
    }
}
