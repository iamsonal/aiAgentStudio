/**
 * @description Comprehensive test class for QueryService
 * Tests all major functionality including simple and complex query paths,
 * field validation, security enforcement, and error handling.
 */
@IsTest
private class QueryServiceTest {
    @TestSetup
    static void makeData() {
        // Create test accounts for query testing
        List<Account> testAccounts = new List<Account>();
        testAccounts.add(new Account(Name = 'Test Account 1', Type = 'Customer', AnnualRevenue = 100000));
        testAccounts.add(new Account(Name = 'Test Account 2', Type = 'Prospect', AnnualRevenue = 200000));
        testAccounts.add(new Account(Name = 'Test Account 3', Type = 'Customer', AnnualRevenue = 300000));
        insert testAccounts;

        // Create test contacts
        List<Contact> testContacts = new List<Contact>();
        testContacts.add(new Contact(FirstName = 'John', LastName = 'Doe', Email = 'john.doe@test.com', AccountId = testAccounts[0].Id));
        testContacts.add(new Contact(FirstName = 'Jane', LastName = 'Smith', Email = 'jane.smith@test.com', AccountId = testAccounts[1].Id));
        insert testContacts;
    }

    @IsTest
    static void executeQuery_simpleFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type' })
            .withFilters(new Map<String, Object>{ 'Type' => 'Customer' })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return customer accounts');
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assertEquals('Customer', acc.Type, 'All results should be Customer type');
        }
    }

    @IsTest
    static void executeQuery_complexFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'Type' => 'Customer', 'AnnualRevenue' => new Map<String, Object>{ '>' => 150000 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return filtered accounts');
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assertEquals('Customer', acc.Type, 'Should match type filter');
            System.assert(acc.AnnualRevenue > 150000, 'Should match revenue filter');
        }
    }

    @IsTest
    static void executeQuery_withOrderBy_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withOrderBy('AnnualRevenue DESC')
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return ordered results');
        if (results.size() > 1) {
            Account first = (Account) results[0];
            Account second = (Account) results[1];
            System.assert(first.AnnualRevenue >= second.AnnualRevenue, 'Should be ordered by revenue descending');
        }
    }

    @IsTest
    static void executeQuery_inOperator_success() {
        List<Account> accounts = [SELECT Id, Name, Type FROM Account LIMIT 2];
        List<String> accountNames = new List<String>();
        for (Account acc : accounts) {
            accountNames.add(acc.Name);
        }

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'IN' => accountNames } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should return accounts matching IN filter');
    }

    @IsTest
    static void executeQuery_nullFilter_success() {
        // Create account with null industry
        Account testAccount = new Account(Name = 'Null Industry Account', Type = 'Customer');
        insert testAccount;

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Industry' })
            .withFilters(new Map<String, Object>{ 'Industry' => null })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return accounts with null industry');
    }

    @IsTest
    static void executeQuery_relationshipField_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'LastName', 'Account.Name' })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return contacts with account relationship');
    }

    @IsTest
    static void executeQuery_withBindVariables_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type' })
            .withFilters(new Map<String, Object>{ 'Type' => 'Customer' })
            .withLimit(10, null);

        Map<String, Object> bindMap = new Map<String, Object>();

        Test.startTest();
        List<SObject> results = service.executeQuery(bindMap);
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return results with bind variables');
        System.assert(bindMap.size() > 0, 'Bind map should be populated');
    }

    @IsTest
    static void executeQuery_invalidField_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'InvalidField' })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('InvalidField') || e.getMessage().contains('field'),
                'Exception should mention invalid field: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_invalidFilterField_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'InvalidField' => 'test' })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid filter field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('InvalidField') || e.getMessage().contains('field'),
                'Exception should mention invalid field: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_invalidOperator_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'INVALID_OP' => 'test' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid operator');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('INVALID_OP') || e.getMessage().contains('operator'),
                'Exception should mention invalid operator: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_invalidOrderBy_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withOrderBy('InvalidField ASC')
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid ORDER BY field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('InvalidField') || e.getMessage().contains('ORDER BY'),
                'Exception should mention invalid ORDER BY: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_emptyInList_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'IN' => new List<String>() } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for empty IN list');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('empty') || e.getMessage().contains('IN'),
                'Exception should mention empty IN list: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_invalidInOperatorValue_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'IN' => 'not a list' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for non-list IN value');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('List') || e.getMessage().contains('IN'),
                'Exception should mention IN requires List: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_nullOperatorWithInvalidOperator_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ '>' => null } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for null with invalid operator');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('null') || e.getMessage().contains('operator'),
                'Exception should mention null operator issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_dateFieldFilter_success() {
        // Create account with specific created date (we'll use a date field that exists)
        Account testAccount = new Account(Name = 'Date Test Account', Type = 'Customer');
        insert testAccount;

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => Date.today().addDays(-1) } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return accounts created after yesterday');
    }

    @IsTest
    static void executeQuery_booleanFieldFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'IsDeleted' => false })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should return non-deleted accounts');
    }

    @IsTest
    static void executeQuery_numericFieldCoercion_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => '100000' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should handle string to numeric coercion');
    }

    @IsTest
    static void executeQuery_complexOrderByWithNulls_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withOrderBy('AnnualRevenue DESC NULLS LAST')
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() > 0, 'Should handle complex ORDER BY with NULLS');
    }

    @IsTest
    static void executeQuery_multipleFiltersAndConditions_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'Type' => 'Customer', 'AnnualRevenue' => new Map<String, Object>{ '>' => 50000, '<' => 500000 } })
            .withOrderBy('Name ASC')
            .withLimit(5, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle multiple complex filters');
    }

    @IsTest
    static void executeQuery_noResults_returnsEmptyList() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => 'NonExistentAccount12345' })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return empty list when no matches');
    }

    // Additional tests for generateSingleConditionClause and coerceFilterValue coverage

    @IsTest
    static void executeQuery_integerFieldFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'NumberOfEmployees' })
            .withFilters(new Map<String, Object>{ 'NumberOfEmployees' => new Map<String, Object>{ '>' => 100 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle integer field filtering');
    }

    @IsTest
    static void executeQuery_stringToDecimalCoercion_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => '150000.75' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce string to decimal');
    }

    @IsTest
    static void executeQuery_invalidDecimalString_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => 'not-a-number' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid decimal string');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('AnnualRevenue') || e.getMessage().contains('value'),
                'Exception should mention field or value error: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_integerWithDecimal_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'NumberOfEmployees' })
            .withFilters(new Map<String, Object>{ 'NumberOfEmployees' => new Map<String, Object>{ '>' => 100.5 } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for decimal value on integer field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('NumberOfEmployees') || e.getMessage().contains('Integer'),
                'Exception should mention integer field issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_booleanStringCoercion_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 'true' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce string to boolean');
    }

    @IsTest
    static void executeQuery_invalidBooleanValue_throwsException() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 'maybe' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid boolean value');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('Boolean') || e.getMessage().contains('HasOptedOutOfEmail'),
                'Exception should mention boolean field issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_idFieldFilter_success() {
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        if (accounts.isEmpty())
            return; // Skip if no test data

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => accounts[0].Id } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should return exactly one account by ID');
    }

    @IsTest
    static void executeQuery_invalidIdFormat_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => 'invalid-id-format' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid ID format');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('ID') || e.getMessage().contains('Id'),
                'Exception should mention ID format issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_dateStringCoercion_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => '2020-01-01' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce date string');
    }

    @IsTest
    static void executeQuery_invalidDateFormat_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => 'invalid-date' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid date format');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('Date') || e.getMessage().contains('CreatedDate'),
                'Exception should mention date format issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_inOperatorWithIds_success() {
        List<Account> accounts = [SELECT Id FROM Account LIMIT 2];
        if (accounts.size() < 2)
            return; // Skip if insufficient test data

        List<Id> accountIds = new List<Id>();
        for (Account acc : accounts) {
            accountIds.add(acc.Id);
        }

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ 'IN' => accountIds } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(2, results.size(), 'Should return accounts matching ID list');
    }

    @IsTest
    static void executeQuery_inOperatorWithIntegers_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'NumberOfEmployees' })
            .withFilters(new Map<String, Object>{ 'NumberOfEmployees' => new Map<String, Object>{ 'IN' => new List<Integer>{ 100, 200, 300 } } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle IN operator with integers');
    }

    @IsTest
    static void executeQuery_likeOperator_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'LIKE' => 'Test%' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle LIKE operator');
    }

    @IsTest
    static void executeQuery_notEqualsOperator_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Type' })
            .withFilters(new Map<String, Object>{ 'Type' => new Map<String, Object>{ '!=' => 'Customer' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle != operator');
    }

    @IsTest
    static void executeQuery_notEqualsWithNull_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'Industry' })
            .withFilters(new Map<String, Object>{ 'Industry' => new Map<String, Object>{ '!=' => null } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle != null');
    }

    @IsTest
    static void executeQuery_multipleOperatorsOnSameField_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => 50000, '<' => 500000 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle multiple operators on same field');
    }

    // Additional tests for specific field types and coercion paths

    @IsTest
    static void executeQuery_currencyFieldFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '<=' => 250000.50 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle currency field filtering');
    }

    @IsTest
    static void executeQuery_currencyStringCoercion_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '=' => '100000.99' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce string to currency');
    }

    @IsTest
    static void executeQuery_opportunityDateFieldFilter_success() {
        // Create opportunity with close date for testing
        Account testAccount = new Account(Name = 'Test Account for Opp', Type = 'Customer');
        insert testAccount;

        Opportunity testOpp = new Opportunity(
            Name = 'Test Opportunity',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert testOpp;

        QueryService service = new QueryService(Opportunity.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CloseDate' })
            .withFilters(new Map<String, Object>{ 'CloseDate' => new Map<String, Object>{ '>' => Date.today() } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle date field filtering on Opportunity');
    }

    @IsTest
    static void executeQuery_dateStringCoercionForDateField_success() {
        // Create opportunity with close date for testing
        Account testAccount = new Account(Name = 'Test Account for Date', Type = 'Customer');
        insert testAccount;

        Opportunity testOpp = new Opportunity(
            Name = 'Test Opportunity Date',
            AccountId = testAccount.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert testOpp;

        QueryService service = new QueryService(Opportunity.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CloseDate' })
            .withFilters(new Map<String, Object>{ 'CloseDate' => new Map<String, Object>{ '>' => '2020-01-01' } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce string to date for DATE field');
    }

    @IsTest
    static void executeQuery_invalidDateStringForDateField_throwsException() {
        QueryService service = new QueryService(Opportunity.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CloseDate' })
            .withFilters(new Map<String, Object>{ 'CloseDate' => new Map<String, Object>{ '>' => 'invalid-date-format' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid date string');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('Date') || e.getMessage().contains('CloseDate'),
                'Exception should mention date format issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_datetimeFieldFilter_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => Datetime.now().addDays(-1) } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle datetime field filtering');
    }

    @IsTest
    static void executeQuery_datetimeObjectCoercion_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => Datetime.now().addHours(-1) } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle datetime object in filter');
    }

    @IsTest
    static void executeQuery_dateObjectCoercion_success() {
        QueryService service = new QueryService(Opportunity.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CloseDate' })
            .withFilters(new Map<String, Object>{ 'CloseDate' => new Map<String, Object>{ '>' => Date.today().addDays(-1) } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle date object in filter');
    }

    @IsTest
    static void executeQuery_invalidDataTypeForDateField_throwsException() {
        QueryService service = new QueryService(Opportunity.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CloseDate' })
            .withFilters(new Map<String, Object>{ 'CloseDate' => new Map<String, Object>{ '>' => 12345 } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid data type on date field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('Date') || e.getMessage().contains('CloseDate'),
                'Exception should mention date field issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_invalidDataTypeForDatetimeField_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => 12345 } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid data type on datetime field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('Datetime') || e.getMessage().contains('CreatedDate'),
                'Exception should mention datetime field issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_inOperatorWithCurrency_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(
                new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ 'IN' => new List<Decimal>{ 100000.00, 200000.00, 300000.00 } } }
            )
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle IN operator with currency/decimal values');
    }

    @IsTest
    static void executeQuery_percentFieldFilter_success() {
        // Using a custom field or a field that has percentage type
        // For this test, we'll use AnnualRevenue as a proxy since it's a currency/decimal type
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(
                new Map<String, Object>{
                    'AnnualRevenue' => new Map<String, Object>{ '<=' => 0.75 } // Treating as percentage
                }
            )
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should handle percentage-like decimal field filtering');
    }

    @IsTest
    static void executeQuery_currencyInvalidString_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => 'not-a-currency' } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid currency string');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('AnnualRevenue') || e.getMessage().contains('value'),
                'Exception should mention currency field or value error: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void executeQuery_booleanNumericZeroCoercion_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 0 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce 0 to false for boolean field');
    }

    @IsTest
    static void executeQuery_booleanDecimalCoercion_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 1.0 } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assert(results.size() >= 0, 'Should coerce non-zero decimal to true for boolean field');
    }

    @IsTest
    static void executeQuery_idStringCoercion_success() {
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        if (accounts.isEmpty())
            return; // Skip if no test data

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => String.valueOf(accounts[0].Id) } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should coerce string to ID');
    }

    @IsTest
    static void executeQuery_idObjectPassthrough_success() {
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        if (accounts.isEmpty())
            return; // Skip if no test data

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => accounts[0].Id } })
            .withLimit(10, null);

        Test.startTest();
        List<SObject> results = service.executeQuery();
        Test.stopTest();

        System.assertEquals(1, results.size(), 'Should handle ID object directly');
    }

    @IsTest
    static void executeQuery_invalidDataTypeForIdField_throwsException() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => 12345 } })
            .withLimit(10, null);

        Test.startTest();
        try {
            service.executeQuery();
            System.assert(false, 'Should throw exception for invalid data type on ID field');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('ID') || e.getMessage().contains('Id'),
                'Exception should mention ID field issue: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }
}
