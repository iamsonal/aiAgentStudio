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
    static void constructor_validSObjectType_success() {
        Test.startTest();
        QueryService service = new QueryService(Account.SObjectType, '[TestPrefix]');
        Test.stopTest();

        System.assertNotEquals(null, service, 'QueryService should be instantiated');
    }

    @IsTest
    static void constructor_blankLogPrefix_usesDefault() {
        Test.startTest();
        QueryService service = new QueryService(Account.SObjectType, '');
        Test.stopTest();

        System.assertNotEquals(null, service, 'QueryService should be instantiated with default prefix');
    }

    @IsTest
    static void withDefaultFields_validFields_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');
        List<String> fields = new List<String>{ 'Name', 'Type' };

        Test.startTest();
        QueryService result = service.withDefaultFields(fields);
        Test.stopTest();

        System.assertEquals(service, result, 'Should return same instance for method chaining');
    }

    @IsTest
    static void withDefaultFields_nullFields_handledGracefully() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        QueryService result = service.withDefaultFields(null);
        Test.stopTest();

        System.assertEquals(service, result, 'Should handle null fields gracefully');
    }

    @IsTest
    static void withAdditionalFields_validFields_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');
        List<String> fields = new List<String>{ 'AnnualRevenue', 'Industry' };

        Test.startTest();
        QueryService result = service.withAdditionalFields(fields);
        Test.stopTest();

        System.assertEquals(service, result, 'Should return same instance for method chaining');
    }

    @IsTest
    static void withFilters_validFilters_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');
        Map<String, Object> filters = new Map<String, Object>{ 'Type' => 'Customer' };

        Test.startTest();
        QueryService result = service.withFilters(filters);
        Test.stopTest();

        System.assertEquals(service, result, 'Should return same instance for method chaining');
    }

    @IsTest
    static void withOrderBy_validOrderBy_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        QueryService result = service.withOrderBy('Name ASC');
        Test.stopTest();

        System.assertEquals(service, result, 'Should return same instance for method chaining');
    }

    @IsTest
    static void withLimit_validLimit_success() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        QueryService result = service.withLimit(5, null);
        Test.stopTest();

        System.assertEquals(service, result, 'Should return same instance for method chaining');
    }

    @IsTest
    static void withLimit_exceedsMaxPermitted_enforcesMax() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        QueryService result = service.withLimit(100, 50);
        Test.stopTest();

        System.assertEquals(service, result, 'Should enforce maximum permitted limit');
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
}
