/**
 * @description Tests for QueryService using TestFactory utilities
 */
@IsTest
private class QueryServiceTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test accounts with various field types populated
        Account acc1 = TestFactory.newAccount()
            .withName('Test Account 1')
            .withIndustry('Technology')
            .save();
        acc1.AnnualRevenue = 1000000;
        acc1.NumberOfEmployees = 100;
        acc1.Phone = '555-0001';

        Account acc2 = TestFactory.newAccount()
            .withName('Test Account 2')
            .withIndustry('Finance')
            .save();
        acc2.AnnualRevenue = 2000000;
        acc2.NumberOfEmployees = 200;
        acc2.Phone = '555-0002';

        Account acc3 = TestFactory.newAccount()
            .withName('Test Account 3')
            .withIndustry('Technology')
            .save();
        acc3.AnnualRevenue = 500000;
        acc3.NumberOfEmployees = 50;

        update new List<Account>{acc1, acc2, acc3};

        // Create test contacts with dates and booleans
        List<Account> accounts = [SELECT Id FROM Account ORDER BY Name];
        Contact con1 = TestFactory.newContact()
            .withName('John', 'Doe')
            .withEmail('john@test.com')
            .withAccount(accounts[0].Id)
            .save();
        con1.Birthdate = Date.newInstance(1990, 5, 15);
        con1.DoNotCall = false;

        Contact con2 = TestFactory.newContact()
            .withName('Jane', 'Smith')
            .withEmail('jane@test.com')
            .withAccount(accounts[1].Id)
            .save();
        con2.Birthdate = Date.newInstance(1985, 10, 20);
        con2.DoNotCall = true;

        update new List<Contact>{con1, con2};
    }

    // ===================================================================================
    // SIMPLE QUERY TESTS
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_SimpleFilter_Success() {
        // Given: Query with simple filter
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Industry'})
            .withFilters(new Map<String, Object>{'Industry' => 'Technology'})
            .withLimit(10, null);

        // When: Executing query
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should return matching records
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            System.assertEquals('Technology', ((Account) record).Industry);
        }
    }

    @IsTest
    static void testExecuteQuery_ComplexFilter_Success() {
        // Given: Query with complex filter (comparison operator)
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Industry'})
            .withFilters(new Map<String, Object>{
                'Industry' => 'Technology'
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
    }

    @IsTest
    static void testExecuteQuery_WithOrderBy_Success() {
        // Given: Query with ORDER BY
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Industry'})
            .withOrderBy('Name ASC')
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Results should be ordered
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
    }

    @IsTest
    static void testExecuteQuery_WithRelationshipField_Success() {
        // Given: Query with relationship field
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'Account.Name'})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should include relationship data
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
    }

    @IsTest
    static void testExecuteQuery_InOperator_Success() {
        // Given: Query with IN operator
        List<String> names = new List<String>{'Test Account 1', 'Test Account 2'};
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Name' => new Map<String, Object>{'IN' => names}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should find both accounts
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(2, results.size());
    }

    @IsTest
    static void testExecuteQuery_NullFilter_Success() {
        // Given: Query with null filter (using filterable field)
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Industry'})
            .withFilters(new Map<String, Object>{'Phone' => null})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should handle null filter
        System.assert(result.isSuccess);
    }

    // ===================================================================================
    // VALIDATION TESTS
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_InvalidField_ReturnsFailure() {
        // Given: Query with invalid field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'InvalidField'})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('field'));
    }

    @IsTest
    static void testExecuteQuery_InvalidFilterField_ReturnsFailure() {
        // Given: Query with invalid filter field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{'InvalidField' => 'test'})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('field'));
    }

    @IsTest
    static void testExecuteQuery_InvalidOrderByField_ReturnsFailure() {
        // Given: Query with invalid ORDER BY field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withOrderBy('InvalidField ASC')
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('field'));
    }

    // ===================================================================================
    // ORDER BY VALIDATION TESTS
    // ===================================================================================

    @IsTest
    static void testValidateOrderBy_ValidClauses_Success() {
        // Test various valid ORDER BY clauses
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        Test.startTest();
        ActionOutcome result1 = service.withDefaultFields(new List<String>{'Name'})
            .withOrderBy('Name ASC').withLimit(5, null).executeQuery();
        ActionOutcome result2 = service.withDefaultFields(new List<String>{'Name'})
            .withOrderBy('Name DESC').withLimit(5, null).executeQuery();
        ActionOutcome result3 = service.withDefaultFields(new List<String>{'Name'})
            .withOrderBy('Name ASC NULLS FIRST').withLimit(5, null).executeQuery();
        Test.stopTest();

        System.assert(result1.isSuccess, 'ASC should be valid');
        System.assert(result2.isSuccess, 'DESC should be valid');
        System.assert(result3.isSuccess, 'NULLS FIRST should be valid');
    }

    @IsTest
    static void testValidateOrderBy_EmptyOrNull_Success() {
        // Test empty/null ORDER BY
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withOrderBy(null)
            .withLimit(5, null);

        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        System.assert(result.isSuccess, 'Null ORDER BY should be valid');
    }

    // ===================================================================================
    // FIELD VALIDATION TESTS
    // ===================================================================================

    @IsTest
    static void testValidateFields_ValidFields_Success() {
        // Given: Valid fields
        QueryService service = new QueryService(Account.SObjectType, '[Test]');
        List<String> validFields = new List<String>{'Name', 'Industry'};

        // When: Validating
        Test.startTest();
        ActionOutcome result = service.validateFields(validFields);
        Test.stopTest();

        // Then: Should succeed
        System.assert(result.isSuccess);
    }

    @IsTest
    static void testValidateFields_InvalidField_ReturnsFailure() {
        // Given: Invalid field
        QueryService service = new QueryService(Account.SObjectType, '[Test]');
        List<String> invalidFields = new List<String>{'InvalidField'};

        // When: Validating
        Test.startTest();
        ActionOutcome result = service.validateFields(invalidFields);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).contains('Invalid field'));
    }

    @IsTest
    static void testValidateFields_EmptyOrNull_Success() {
        // Given: Empty/null field lists
        QueryService service = new QueryService(Account.SObjectType, '[Test]');

        // When: Validating
        Test.startTest();
        ActionOutcome result1 = service.validateFields(new List<String>());
        ActionOutcome result2 = service.validateFields(null);
        Test.stopTest();

        // Then: Should succeed
        System.assert(result1.isSuccess);
        System.assert(result2.isSuccess);
    }

    // ===================================================================================
    // LIMIT TESTS
    // ===================================================================================

    @IsTest
    static void testWithLimit_SetsLimitCorrectly() {
        // Given: Query with limit
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withLimit(5, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should succeed with custom limit
        System.assert(result.isSuccess);
    }

    @IsTest
    static void testWithLimit_EnforcesMaximum() {
        // Given: Query with limit exceeding max
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withLimit(100, 10); // Request 100 but max is 10

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should succeed with enforced limit
        System.assert(result.isSuccess);
    }

    // ===================================================================================
    // BIND VARIABLE TESTS
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_WithBindVariables_PopulatesMap() {
        // Given: Query with bind variables
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{'Industry' => 'Technology'})
            .withLimit(10, null);

        Map<String, Object> bindMap = new Map<String, Object>();

        // When: Executing with bind map
        Test.startTest();
        ActionOutcome result = service.executeQuery(bindMap);
        Test.stopTest();

        // Then: Bind map should be populated
        System.assert(result.isSuccess);
        System.assert(bindMap.size() > 0);
    }

    // ===================================================================================
    // COMPARISON OPERATOR TESTS (Testing generateSingleConditionClause)
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_GreaterThanOperator_Success() {
        // Given: Query with > operator on numeric field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => new Map<String, Object>{'>' => 750000}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.AnnualRevenue > 750000, 'Revenue should be > 750000');
        }
    }

    @IsTest
    static void testExecuteQuery_LessThanOperator_Success() {
        // Given: Query with < operator on integer field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'NumberOfEmployees'})
            .withFilters(new Map<String, Object>{
                'NumberOfEmployees' => new Map<String, Object>{'<' => 150}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.NumberOfEmployees < 150, 'Employees should be < 150');
        }
    }

    @IsTest
    static void testExecuteQuery_GreaterThanOrEqualOperator_Success() {
        // Given: Query with >= operator
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => new Map<String, Object>{'>=' => 1000000}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.AnnualRevenue >= 1000000, 'Revenue should be >= 1000000');
        }
    }

    @IsTest
    static void testExecuteQuery_LessThanOrEqualOperator_Success() {
        // Given: Query with <= operator
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'NumberOfEmployees'})
            .withFilters(new Map<String, Object>{
                'NumberOfEmployees' => new Map<String, Object>{'<=' => 100}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.NumberOfEmployees <= 100, 'Employees should be <= 100');
        }
    }

    @IsTest
    static void testExecuteQuery_NotEqualOperator_Success() {
        // Given: Query with != operator
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Industry'})
            .withFilters(new Map<String, Object>{
                'Industry' => new Map<String, Object>{'!=' => 'Technology'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assertNotEquals('Technology', acc.Industry);
        }
    }

    @IsTest
    static void testExecuteQuery_LikeOperator_Success() {
        // Given: Query with LIKE operator
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Name' => new Map<String, Object>{'LIKE' => '%Account 1%'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(1, results.size());
        System.assert(((Account) results[0]).Name.contains('Account 1'));
    }

    @IsTest
    static void testExecuteQuery_NotEqualNull_Success() {
        // Given: Query with != null
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Phone'})
            .withFilters(new Map<String, Object>{
                'Phone' => new Map<String, Object>{'!=' => null}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assertNotEquals(null, acc.Phone);
        }
    }

    @IsTest
    static void testExecuteQuery_MultipleOperatorsSameField_Success() {
        // Given: Query with multiple operators on same field (range query)
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => new Map<String, Object>{
                    '>=' => 500000,
                    '<=' => 1500000
                }
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should apply both conditions
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.AnnualRevenue >= 500000 && acc.AnnualRevenue <= 1500000,
                'Revenue should be between 500000 and 1500000');
        }
    }

    // ===================================================================================
    // TYPE COERCION TESTS (Testing coerceFilterValue)
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_BooleanFilter_Success() {
        // Given: Query with boolean filter
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'DoNotCall'})
            .withFilters(new Map<String, Object>{'DoNotCall' => true})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            System.assertEquals(true, ((Contact) record).DoNotCall);
        }
    }

    @IsTest
    static void testExecuteQuery_BooleanStringCoercion_Success() {
        // Given: Query with string 'true' that should coerce to boolean
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'DoNotCall'})
            .withFilters(new Map<String, Object>{'DoNotCall' => 'false'})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should coerce and filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            System.assertEquals(false, ((Contact) record).DoNotCall);
        }
    }

    @IsTest
    static void testExecuteQuery_DateFilter_Success() {
        // Given: Query with date filter
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'Birthdate'})
            .withFilters(new Map<String, Object>{
                'Birthdate' => new Map<String, Object>{'>' => '1987-01-01'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should coerce date string and filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Contact con = (Contact) record;
            System.assert(con.Birthdate > Date.newInstance(1987, 1, 1), 'Birthdate should be after 1987-01-01');
        }
    }

    @IsTest
    static void testExecuteQuery_DecimalStringCoercion_Success() {
        // Given: Query with string numeric value that should coerce to decimal
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => new Map<String, Object>{'>' => '900000'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should coerce string to decimal and filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            Account acc = (Account) record;
            System.assert(acc.AnnualRevenue > 900000);
        }
    }

    @IsTest
    static void testExecuteQuery_IntegerCoercion_Success() {
        // Given: Query with integer field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'NumberOfEmployees'})
            .withFilters(new Map<String, Object>{
                'NumberOfEmployees' => new Map<String, Object>{'=' => 100}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assert(results.size() > 0);
        for (SObject record : results) {
            System.assertEquals(100, ((Account) record).NumberOfEmployees);
        }
    }

    @IsTest
    static void testExecuteQuery_IdCoercion_Success() {
        // Given: Get a valid account ID
        List<Account> accounts = [SELECT Id FROM Account LIMIT 1];
        String accountId = accounts[0].Id;

        // Query with string ID that should coerce to Id
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{'Id' => accountId})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should coerce string to Id and filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(1, results.size());
        System.assertEquals(accountId, results[0].Id);
    }

    @IsTest
    static void testExecuteQuery_EmailFieldFilter_Success() {
        // Given: Query with email field (string type)
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'Email'})
            .withFilters(new Map<String, Object>{'Email' => 'john@test.com'})
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should filter correctly
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(1, results.size());
        System.assertEquals('john@test.com', ((Contact) results[0]).Email);
    }

    // ===================================================================================
    // IN OPERATOR WITH DIFFERENT TYPES (Testing generateSingleConditionClause IN path)
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_InOperatorWithIntegers_Success() {
        // Given: Query with IN operator on integer field
        List<Integer> employeeCounts = new List<Integer>{50, 100};
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'NumberOfEmployees'})
            .withFilters(new Map<String, Object>{
                'NumberOfEmployees' => new Map<String, Object>{'IN' => employeeCounts}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should find accounts with matching employee counts
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(2, results.size());
    }

    @IsTest
    static void testExecuteQuery_InOperatorWithDecimals_Success() {
        // Given: Query with IN operator on decimal field
        List<Decimal> revenues = new List<Decimal>{1000000, 2000000};
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => new Map<String, Object>{'IN' => revenues}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should find accounts with matching revenues
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(2, results.size());
    }

    @IsTest
    static void testExecuteQuery_InOperatorWithIds_Success() {
        // Given: Query with IN operator on Id field
        List<Account> accounts = [SELECT Id FROM Account LIMIT 2];
        List<Id> accountIds = new List<Id>();
        for (Account acc : accounts) {
            accountIds.add(acc.Id);
        }

        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Id' => new Map<String, Object>{'IN' => accountIds}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should find specified accounts
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(2, results.size());
    }

    @IsTest
    static void testExecuteQuery_InOperatorWithDates_Success() {
        // Given: Query with IN operator on date field
        List<Date> dates = new List<Date>{
            Date.newInstance(1990, 5, 15),
            Date.newInstance(1985, 10, 20)
        };
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'LastName', 'Birthdate'})
            .withFilters(new Map<String, Object>{
                'Birthdate' => new Map<String, Object>{'IN' => dates}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should find contacts with matching birthdates
        System.assert(result.isSuccess);
        List<SObject> results = (List<SObject>) result.data;
        System.assertEquals(2, results.size());
    }

    // ===================================================================================
    // ERROR HANDLING TESTS (Testing coerceFilterValue error paths)
    // ===================================================================================

    @IsTest
    static void testExecuteQuery_InvalidDateFormat_ReturnsFailure() {
        // Given: Query with invalid date format
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'Birthdate'})
            .withFilters(new Map<String, Object>{
                'Birthdate' => 'not-a-date'
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('date'));
    }

    @IsTest
    static void testExecuteQuery_InvalidIdFormat_ReturnsFailure() {
        // Given: Query with invalid ID format
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Id' => 'not-a-valid-id'
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('ID'));
    }

    @IsTest
    static void testExecuteQuery_InvalidBooleanFormat_ReturnsFailure() {
        // Given: Query with invalid boolean format
        QueryService service = new QueryService(Contact.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'FirstName', 'DoNotCall'})
            .withFilters(new Map<String, Object>{
                'DoNotCall' => 'not-a-boolean'
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('Boolean'));
    }

    @IsTest
    static void testExecuteQuery_InvalidNumberFormat_ReturnsFailure() {
        // Given: Query with invalid number format
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'AnnualRevenue'})
            .withFilters(new Map<String, Object>{
                'AnnualRevenue' => 'not-a-number'
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
    }

    @IsTest
    static void testExecuteQuery_DecimalForIntegerField_ReturnsFailure() {
        // Given: Query with decimal value for integer field
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'NumberOfEmployees'})
            .withFilters(new Map<String, Object>{
                'NumberOfEmployees' => 100.5
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('Integer'));
    }

    @IsTest
    static void testExecuteQuery_InOperatorWithEmptyList_ReturnsFailure() {
        // Given: Query with IN operator and empty list
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Name' => new Map<String, Object>{'IN' => new List<String>()}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('empty'));
    }

    @IsTest
    static void testExecuteQuery_InOperatorWithNonList_ReturnsFailure() {
        // Given: Query with IN operator and non-list value
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Name' => new Map<String, Object>{'IN' => 'not-a-list'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('List'));
    }

    @IsTest
    static void testExecuteQuery_UnsupportedOperator_ReturnsFailure() {
        // Given: Query with unsupported operator
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name'})
            .withFilters(new Map<String, Object>{
                'Name' => new Map<String, Object>{'CONTAINS' => 'test'}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('operator'));
    }

    @IsTest
    static void testExecuteQuery_InvalidOperatorForNull_ReturnsFailure() {
        // Given: Query with invalid operator for null value (e.g., > null)
        QueryService service = new QueryService(Account.SObjectType, '[Test]')
            .withDefaultFields(new List<String>{'Name', 'Phone'})
            .withFilters(new Map<String, Object>{
                'Phone' => new Map<String, Object>{'>' => null}
            })
            .withLimit(10, null);

        // When: Executing
        Test.startTest();
        ActionOutcome result = service.executeQuery();
        Test.stopTest();

        // Then: Should fail with validation error
        System.assert(!result.isSuccess);
        System.assert(String.valueOf(result.errorMessage).containsIgnoreCase('null'));
    }
}
