/**
 * @description Tests for ActionGetRecords using TestFactory utilities
 */
@IsTest
private class ActionGetRecordsTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create full agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test accounts
        TestFactory.newAccount().withName('Test Account 1').withIndustry('Technology').save();
        TestFactory.newAccount().withName('Test Account 2').withIndustry('Finance').save();
        TestFactory.newAccount().withName('Another Company').withIndustry('Healthcare').save();

        // Create test contacts
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name];

        TestFactory.newContact().withName('John', 'Smith').withEmail('john.smith@test.com').withAccount(accounts[0].Id).save();
        TestFactory.newContact().withName('Jane', 'Doe').withEmail('jane.doe@test.com').withAccount(accounts[1].Id).save();
        TestFactory.newContact().withName('Bob', 'Johnson').withEmail('bob.johnson@test.com').save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testGetRecords_BasicQuery_Success() {
        // Given: Basic query configuration
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Account',
            'defaultFields' => new List<String>{'Id', 'Name'},
            'maxReturnToLLM' => 10
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        // When: Querying all accounts
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should return all accounts
        System.assert(result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        System.assertEquals('Account', queryResult.objectApiName);
        System.assertEquals(3, queryResult.count);
        System.assertEquals(3, queryResult.records.size());
        System.assertEquals(false, queryResult.truncated);
    }

    @IsTest
    static void testGetRecords_WithFilters_Success() {
        // Given: Query with filters
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Contact',
            'defaultFields' => new List<String>{'Id', 'FirstName', 'LastName', 'Email'},
            'maxReturnToLLM' => 10
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'filters' => new Map<String, Object>{'LastName' => 'Smith'}
        };

        // When: Querying with filter
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should return filtered results
        System.assert(result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        System.assertEquals(1, queryResult.count);
        System.assertEquals('John', queryResult.records[0].get('FirstName'));
        System.assertEquals('Smith', queryResult.records[0].get('LastName'));
    }

    @IsTest
    static void testGetRecords_WithLimitAndOrderBy_Success() {
        // Given: Query with limit and ordering
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Account',
            'defaultFields' => new List<String>{'Id', 'Name'},
            'maxReturnToLLM' => 10
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'limit' => 2,
            'orderBy' => 'Name ASC'
        };

        // When: Querying with limit and order
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should return ordered, limited results
        System.assert(result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        System.assertEquals(2, queryResult.records.size());
        System.assertEquals('Another Company', queryResult.records[0].get('Name'), 'Should be ordered alphabetically');
    }

    @IsTest
    static void testGetRecords_TruncatedResults_Success() {
        // Given: maxReturnToLLM smaller than result count
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Account',
            'defaultFields' => new List<String>{'Id', 'Name'},
            'maxReturnToLLM' => 2  // Less than 3 accounts
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        // When: Querying all accounts
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should truncate results
        System.assert(result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        System.assertEquals(3, queryResult.count, 'Total found');
        System.assertEquals(2, queryResult.records.size(), 'Returned to LLM');
        System.assertEquals(true, queryResult.truncated);
        System.assert(queryResult.message.contains('Showing the first 2'));
    }

    @IsTest
    static void testGetRecords_NoResults_Success() {
        // Given: Filter that matches nothing
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Contact',
            'defaultFields' => new List<String>{'Id', 'FirstName', 'LastName'},
            'maxReturnToLLM' => 10
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'filters' => new Map<String, Object>{'LastName' => 'NonExistentName'}
        };

        // When: Querying
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should return empty results successfully
        System.assert(result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        System.assertEquals(0, queryResult.count);
        System.assertEquals(0, queryResult.records.size());
        System.assertEquals('No Contact records found matching the criteria.', queryResult.message);
    }

    // ===================================================================================
    // CONFIGURATION TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_MissingObjectApiName_ThrowsException() {
        // Given: Configuration without objectApiName
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"invalidKey": "value"}';

        // When/Then: Should throw exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('objectApiName'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testParseConfig_InvalidObjectApiName_ThrowsException() {
        // Given: Invalid object name
        ActionGetRecords action = new ActionGetRecords();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'InvalidObject__c',
            'defaultFields' => new List<String>{'Id'},
            'maxReturnToLLM' => 10
        });

        // When/Then: Should throw exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid SObject API Name'));
        }
        Test.stopTest();
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testQueryResult_Constructor_SetsProperties() {
        // Given: Test data
        List<Account> testAccounts = [SELECT Id, Name FROM Account LIMIT 2];

        // When: Creating result
        Test.startTest();
        ActionGetRecords.QueryResult result = new ActionGetRecords.QueryResult(
            testAccounts,
            5,
            'Account',
            'Test message'
        );
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals(testAccounts, result.records);
        System.assertEquals(5, result.count);
        System.assertEquals('Account', result.objectApiName);
        System.assertEquals('Test message', result.message);
        System.assertEquals(true, result.truncated, '2 returned, 5 total');
        System.assertEquals(5, (Integer) result.metadata.get('totalFound'));
        System.assertEquals(2, (Integer) result.metadata.get('returned'));
        System.assertEquals(true, (Boolean) result.metadata.get('hasMore'));
    }
}
