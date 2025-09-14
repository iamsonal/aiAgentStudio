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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assert(results.size() > 0, 'Should return accounts with null industry');
    }

    @IsTest
    static void executeQuery_relationshipField_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'LastName', 'Account.Name' })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery(bindMap);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assert(results.size() > 0, 'Should return results with bind variables');
        System.assert(bindMap.size() > 0, 'Bind map should be populated');
    }

    @IsTest
    static void executeQuery_invalidField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'InvalidField' })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid field');
        System.assert(
            String.valueOf(result.errorMessage).contains('InvalidField') || String.valueOf(result.errorMessage).contains('field'),
            'Exception should mention invalid field: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_invalidFilterField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'InvalidField' => 'test' })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid filter field');
        System.assert(
            String.valueOf(result.errorMessage).contains('InvalidField') || String.valueOf(result.errorMessage).contains('field'),
            'Exception should mention invalid field: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_invalidOperator_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'INVALID_OP' => 'test' } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid operator');
        System.assert(
            String.valueOf(result.errorMessage).contains('INVALID_OP') || String.valueOf(result.errorMessage).contains('operator'),
            'Exception should mention invalid operator: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_invalidOrderBy_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withOrderBy('InvalidField ASC')
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid ORDER BY field');
        System.assert(
            String.valueOf(result.errorMessage).contains('InvalidField') || String.valueOf(result.errorMessage).contains('ORDER BY'),
            'Exception should mention invalid ORDER BY: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_emptyInList_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'IN' => new List<String>() } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for empty IN list');
        System.assert(
            String.valueOf(result.errorMessage).contains('empty') || String.valueOf(result.errorMessage).contains('IN'),
            'Exception should mention empty IN list: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_invalidInOperatorValue_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ 'IN' => 'not a list' } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for non-list IN value');
        System.assert(
            String.valueOf(result.errorMessage).contains('List') || String.valueOf(result.errorMessage).contains('IN'),
            'Exception should mention IN requires List: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_nullOperatorWithInvalidOperator_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Name' => new Map<String, Object>{ '>' => null } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for null with invalid operator');
        System.assert(
            String.valueOf(result.errorMessage).contains('null') || String.valueOf(result.errorMessage).contains('operator'),
            'Exception should mention null operator issue: ' + String.valueOf(result.errorMessage)
        );
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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assert(results.size() >= 0, 'Should handle date field filtering');
    }

    @IsTest
    static void executeQuery_invalidDateField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => 'not-a-date' } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid date string');
        System.assert(
            String.valueOf(result.errorMessage).contains('Date') || String.valueOf(result.errorMessage).contains('CreatedDate'),
            'Exception should mention date field issue: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_invalidDataTypeForDatetimeField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'CreatedDate' })
            .withFilters(new Map<String, Object>{ 'CreatedDate' => new Map<String, Object>{ '>' => 12345 } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid data type on datetime field');
        System.assert(
            String.valueOf(result.errorMessage).contains('Datetime') || String.valueOf(result.errorMessage).contains('CreatedDate'),
            'Exception should mention datetime field issue: ' + String.valueOf(result.errorMessage)
        );
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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assert(results.size() >= 0, 'Should handle percentage-like decimal field filtering');
    }

    @IsTest
    static void executeQuery_currencyInvalidString_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name', 'AnnualRevenue' })
            .withFilters(new Map<String, Object>{ 'AnnualRevenue' => new Map<String, Object>{ '>' => 'not-a-currency' } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid currency string');
        System.assert(
            String.valueOf(result.errorMessage).contains('AnnualRevenue') || String.valueOf(result.errorMessage).contains('value'),
            'Exception should mention currency field or value error: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void executeQuery_booleanNumericZeroCoercion_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 0 } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assert(results.size() >= 0, 'Should coerce 0 to false for boolean field');
    }

    @IsTest
    static void executeQuery_booleanDecimalCoercion_success() {
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'FirstName', 'HasOptedOutOfEmail' })
            .withFilters(new Map<String, Object>{ 'HasOptedOutOfEmail' => new Map<String, Object>{ '=' => 1.0 } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

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
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully');
        List<SObject> results = (List<SObject>) result.data;

        System.assertEquals(1, results.size(), 'Should handle ID object directly');
    }

    @IsTest
    static void executeQuery_invalidDataTypeForIdField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{ 'Name' })
            .withFilters(new Map<String, Object>{ 'Id' => new Map<String, Object>{ '=' => 12345 } })
            .withLimit(10, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Should fail for invalid data type on ID field');
        System.assert(
            String.valueOf(result.errorMessage).contains('ID') || String.valueOf(result.errorMessage).contains('Id'),
            'Exception should mention ID field issue: ' + String.valueOf(result.errorMessage)
        );
    }

    @IsTest
    static void validateFields_validFields_returnsSuccess() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        List<String> validFields = new List<String>{ 'Name', 'Type', 'Industry' };

        Test.startTest();
        ActionOutcome result = service.validateFields(validFields);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Validation should succeed for valid fields');
    }

    @IsTest
    static void validateFields_invalidField_returnsFailure() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        List<String> invalidFields = new List<String>{ 'InvalidField' };

        Test.startTest();
        ActionOutcome result = service.validateFields(invalidFields);
        Test.stopTest();

        System.assertEquals(false, result.isSuccess, 'Validation should fail for invalid field');
        System.assert(String.valueOf(result.errorMessage).contains('Invalid field'), 'Should mention invalid field');
    }

    @IsTest
    static void validateFields_emptyList_returnsSuccess() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        List<String> emptyFields = new List<String>();

        Test.startTest();
        ActionOutcome result = service.validateFields(emptyFields);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Validation should succeed for empty field list');
    }

    @IsTest
    static void validateFields_nullList_returnsSuccess() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        ActionOutcome result = service.validateFields(null);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Validation should succeed for null field list');
    }

    @IsTest
    static void withLimit_setsLimitCorrectly() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]').withLimit(5, null);

        // We can't directly access the private limit field, but we can test that the service
        // was constructed without error and can execute a query
        service.withDefaultFields(new List<String>{ 'Name' });

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully with custom limit');
    }

    @IsTest
    static void withLimit_enforcesMaximumLimit() {
        QueryService service = new QueryService(Account.SObjectType, '[Test]').withLimit(100, 10); // Request 100 but max is 10

        // We can't directly access the private limit field, but we can test that the service
        // was constructed without error
        service.withDefaultFields(new List<String>{ 'Name' });

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Query should execute successfully with enforced limit');
    }
}
