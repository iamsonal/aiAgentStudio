@IsTest
private class ActionFindEntitiesTest {
    @TestSetup
    static void makeData() {
        // Create test accounts
        List<Account> accounts = new List<Account>();
        accounts.add(new Account(Name = 'Acme Corporation', Industry = 'Technology', Phone = '555-123-4567'));
        accounts.add(new Account(Name = 'Global Industries', Industry = 'Manufacturing', Phone = '555-987-6543'));
        accounts.add(new Account(Name = 'Tech Solutions Inc', Industry = 'Technology'));
        insert accounts;

        // Create test contacts
        List<Contact> contacts = new List<Contact>();
        contacts.add(
            new Contact(FirstName = 'John', LastName = 'Smith', Email = 'john.smith@acme.com', Phone = '555-111-2222', AccountId = accounts[0].Id)
        );
        contacts.add(
            new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane.doe@global.com', MobilePhone = '555-333-4444', AccountId = accounts[1].Id)
        );
        contacts.add(new Contact(FirstName = 'Robert', LastName = 'Johnson', Email = 'bob.johnson@tech.com', Phone = '555-555-6666'));
        insert contacts;
    }

    @IsTest
    static void executeAction_success_singleMatch() {
        Contact expectedContact = [SELECT Id, FirstName, LastName, Email FROM Contact WHERE Email = 'john.smith@acme.com' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expectedContact.Id });

        ActionFindEntities action = new ActionFindEntities();
        // No configuration needed for this action
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Contact' },
            'fieldsToReturn' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' },
            'filters' => new Map<String, Object>{ 'Email' => 'john.smith@acme.com' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(1, queryResult.count);
        System.assertEquals(1, queryResult.records.size());
        System.assertEquals(expectedContact.Id, queryResult.records[0].Id);
    }

    @IsTest
    static void executeAction_success_multipleMatches() {
        Map<Id, Account> accountMap = new Map<Id, Account>([SELECT Id, Name FROM Account WHERE Industry = 'Technology' LIMIT 2]);
        Test.setFixedSearchResults(new List<Id>(accountMap.keySet()));

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Industry' => 'Technology' },
            'limit' => 10
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(2, queryResult.count);
        System.assertEquals(2, queryResult.records.size());
    }

    @IsTest
    static void executeAction_success_noMatches() {
        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Name' => 'NonExistentAccount12345' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(0, queryResult.count);
        System.assertEquals(0, queryResult.records.size());
    }

    @IsTest
    static void executeAction_failure_missingRequiredParams() {
        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        // Missing sObjectTypes
        Map<String, Object> params = new Map<String, Object>{
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Name' => 'Test' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(result.errorMessage.contains('sObjectTypes, fieldsToReturn, and filters are all required'));
    }

    @IsTest
    static void executeAction_success_withLimit() {
        Map<Id, Account> accountMap = new Map<Id, Account>([SELECT Id, Name FROM Account WHERE Industry = 'Technology' LIMIT 2]);
        Test.setFixedSearchResults(new List<Id>(accountMap.keySet()));

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name' },
            'filters' => new Map<String, Object>{ 'Industry' => 'Technology' },
            'limit' => 1
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(1, queryResult.count);
        System.assertEquals(1, queryResult.records.size());
    }

    @IsTest
    static void queryResult_constructor_success() {
        List<SObject> testRecords = new List<SObject>();
        Account testAccount = new Account(Id = '001000000000001AAA', Name = 'Test Account');
        testRecords.add(testAccount);

        List<String> sObjectTypes = new List<String>{ 'Account' };

        Test.startTest();
        ActionFindEntities.QueryResult result = new ActionFindEntities.QueryResult(testRecords, sObjectTypes);
        Test.stopTest();

        System.assertEquals(1, result.count);
        System.assertEquals(1, result.records.size());
        System.assertEquals('Found 1 record(s) matching the criteria.', result.message);
        System.assertEquals(1, (Integer) result.metadata.get('totalFound'));
        System.assertEquals(sObjectTypes, (List<String>) result.metadata.get('sObjectTypesSearched'));
    }

    @IsTest
    static void executeAction_success_respectsFieldsToReturnAndFLS() {
        Account expectedAccount = [SELECT Id, Name, Phone, AccountNumber FROM Account WHERE Name = 'Acme Corporation' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expectedAccount.Id });

        ActionFindEntities action = new ActionFindEntities();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'sObjectTypes' => new List<String>{ 'Account' },
            'fieldsToReturn' => new List<String>{ 'Id', 'Name', 'Phone', 'AccountNumber' },
            'filters' => new Map<String, Object>{ 'Name' => 'Acme' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(true, result.isSuccess, 'Action should be successful');

        ActionFindEntities.QueryResult queryResult = (ActionFindEntities.QueryResult) result.data;
        System.assertEquals(1, queryResult.count, 'Should find one record');

        SObject returnedRecord = queryResult.records[0];
        System.assertEquals(expectedAccount.Id, returnedRecord.Id, 'Correct record ID should be returned');

        System.assertEquals(expectedAccount.Name, returnedRecord.get('Name'), 'Name field should be returned');
        System.assertEquals(expectedAccount.Phone, returnedRecord.get('Phone'), 'Phone field should be returned');
    }

    @IsTest
    static void queryResult_constructor_empty() {
        List<SObject> testRecords = new List<SObject>();
        List<String> sObjectTypes = new List<String>{ 'Account' };

        Test.startTest();
        ActionFindEntities.QueryResult result = new ActionFindEntities.QueryResult(testRecords, sObjectTypes);
        Test.stopTest();

        System.assertEquals(0, result.count);
        System.assertEquals(0, result.records.size());
        System.assertEquals('Found 0 record(s) matching the criteria.', result.message);
        System.assertEquals(0, (Integer) result.metadata.get('totalFound'));
    }
}
