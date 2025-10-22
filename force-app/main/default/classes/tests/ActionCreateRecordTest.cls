/**
 * @description Tests for ActionCreateRecord using TestFactory utilities
 */
@IsTest
private class ActionCreateRecordTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test accounts using TestFactory
        TestFactory.newAccount()
            .withName('Test Account 1')
            .withIndustry('Technology')
            .save();

        TestFactory.newAccount()
            .withName('Test Account 2')
            .withIndustry('Finance')
            .save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testCreateContact_WithAllFields_Success() {
        // Given: An account and contact data
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Contact"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'FirstName' => 'John',
                'LastName' => 'Doe',
                'Email' => 'john.doe@example.com',
                'AccountId' => testAccount.Id
            }
        };

        // When: Creating a contact
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Contact is created successfully
        System.assert(result.isSuccess, 'Should create contact successfully');

        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertNotEquals(null, createResult.recordId, 'Should return record ID');
        System.assert(createResult.message.contains('Successfully created Contact'), 'Should have success message');
        System.assertEquals(4, createResult.fieldsSet.size(), 'Should set 4 fields');

        // Verify database state
        Contact created = [SELECT FirstName, LastName, Email, AccountId
                          FROM Contact WHERE Id = :createResult.recordId];
        System.assertEquals('John', created.FirstName);
        System.assertEquals('Doe', created.LastName);
        System.assertEquals('john.doe@example.com', created.Email);
        System.assertEquals(testAccount.Id, created.AccountId);
    }

    @IsTest
    static void testCreateAccount_WithDefaults_Success() {
        // Given: Action configured with default values
        ActionCreateRecord action = new ActionCreateRecord();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Account',
            'defaultFieldValues' => new Map<String, Object>{
                'Type' => 'Customer - Direct',
                'Industry' => 'Technology'
            }
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'Name' => 'New Tech Corp'
            }
        };

        // When: Creating account with defaults
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Account created with defaults applied
        System.assert(result.isSuccess, 'Should create account successfully');

        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT Name, Type, Industry FROM Account WHERE Id = :createResult.recordId];

        System.assertEquals('New Tech Corp', created.Name);
        System.assertEquals('Customer - Direct', created.Type, 'Should apply default Type');
        System.assertEquals('Technology', created.Industry, 'Should apply default Industry');
    }

    @IsTest
    static void testCreateAccount_UserValueOverridesDefault_Success() {
        // Given: Action with defaults that will be overridden
        ActionCreateRecord action = new ActionCreateRecord();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Account',
            'defaultFieldValues' => new Map<String, Object>{
                'Type' => 'Customer - Direct'
            }
        });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'Name' => 'Partner Corp',
                'Type' => 'Technology Partner' // Override default
            }
        };

        // When: Creating with override
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: User value takes precedence
        System.assert(result.isSuccess);
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT Type FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Technology Partner', created.Type, 'User value should override default');
    }

    @IsTest
    static void testTypeCoercion_StringToNumber_Success() {
        // Given: Numeric fields as strings
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'Name' => 'Big Corp',
                'NumberOfEmployees' => '500',        // String -> Integer
                'AnnualRevenue' => '10000000.50'     // String -> Decimal
            }
        };

        // When: Creating with type coercion
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Types are coerced correctly
        System.assert(result.isSuccess, 'Should succeed with type coercion');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :createResult.recordId];

        System.assertEquals(500, created.NumberOfEmployees, 'Should coerce to Integer');
        System.assertEquals(10000000.50, created.AnnualRevenue, 'Should coerce to Decimal');
    }

    // ===================================================================================
    // RECORDTYPE VALIDATION (NEW FEATURE)
    // ===================================================================================

    @IsTest
    static void testRecordTypeValidation_InvalidId_Failure() {
        // Given: Invalid RecordType ID
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'Name' => 'Test Account',
                'RecordTypeId' => '001000000000000' // Invalid ID format
            }
        };

        // When: Attempting to create with invalid RecordType
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!result.isSuccess, 'Should fail with invalid RecordType');
        System.assert(result.errorMessage.contains('RecordType'), 'Error should mention RecordType');
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testCreateRecord_NoFieldData_Failure() {
        // Given: Empty parameters
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Contact"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        // When: Creating with no data
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess, 'Should fail with no data');
        System.assert(result.errorMessage.contains('No field data provided'), 'Should indicate missing data');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testCreateContact_MissingRequiredField_Failure() {
        // Given: Contact data without required LastName
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Contact"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'FirstName' => 'John'
                // Missing required LastName
            }
        };

        // When: Creating incomplete contact
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with DML error
        System.assert(!result.isSuccess, 'Should fail without required field');
        System.assert(result.errorMessage.contains('Failed to create Contact'), 'Should indicate creation failure');
    }

    @IsTest
    static void testCreateRecord_InvalidFieldName_FiltersField() {
        // Given: Data with non-existent field
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{
                'Name' => 'Valid Name',
                'NonExistentField__c' => 'Invalid Value'
            }
        };

        // When: Creating with invalid field
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Valid fields are processed, invalid ones ignored
        System.assert(result.isSuccess, 'Should succeed by filtering invalid field');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertEquals(false, createResult.fieldsSet.contains('NonExistentField__c'),
                          'Should not include invalid field');
    }

    // ===================================================================================
    // CONFIGURATION TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_ValidConfig_Success() {
        // Given: Valid configuration
        ActionCreateRecord action = new ActionCreateRecord();
        String config = JSON.serialize(new Map<String, Object>{
            'objectApiName' => 'Contact',
            'defaultFieldValues' => new Map<String, Object>{
                'LeadSource' => 'Web'
            }
        });

        // When: Parsing configuration
        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Then: Should parse without error
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void testParseConfig_MissingObjectApiName_ThrowsException() {
        // Given: Configuration without objectApiName
        ActionCreateRecord action = new ActionCreateRecord();
        String config = '{"defaultFieldValues": {"Type": "Customer"}}';

        // When/Then: Should throw validation exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception for missing objectApiName');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('objectApiName'), 'Should mention missing parameter');
        }
        Test.stopTest();
    }

    @IsTest
    static void testParseConfig_InvalidObjectApiName_ThrowsException() {
        // Given: Invalid object name
        ActionCreateRecord action = new ActionCreateRecord();
        String config = '{"objectApiName": "NonExistentObject__c"}';

        // When/Then: Should throw validation exception
        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should throw exception for invalid object');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid SObject'), 'Should indicate invalid object');
        }
        Test.stopTest();
    }

    // ===================================================================================
    // TYPE COERCION SERVICE TESTS
    // ===================================================================================

    @IsTest
    static void testTypeCoercionService_ValidArguments_Success() {
        // Given: Raw arguments needing coercion
        Map<String, Object> rawArgs = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => '100',
            'AnnualRevenue' => '500000.75'
        };

        // When: Coercing types
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            rawArgs,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        // Then: Types should be coerced
        System.assertEquals('Test Account', result.get('Name'));
        System.assertEquals(100, result.get('NumberOfEmployees'));
        System.assertEquals(500000.75, result.get('AnnualRevenue'));
    }

    @IsTest
    static void testTypeCoercionService_NullSObjectType_ThrowsException() {
        // Given: Null SObjectType
        Map<String, Object> rawArgs = new Map<String, Object>{'Name' => 'Test'};

        // When/Then: Should throw exception
        Test.startTest();
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, null, AccessType.CREATABLE);
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('SObjectType cannot be null'));
        }
        Test.stopTest();
    }

    @IsTest
    static void testTypeCoercionService_EmptyArguments_ReturnsEmpty() {
        // Given: Empty arguments
        Map<String, Object> rawArgs = new Map<String, Object>();

        // When: Coercing
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            rawArgs,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        // Then: Should return empty map
        System.assertNotEquals(null, result);
        System.assertEquals(0, result.size());
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testCreateResult_Constructor_SetsProperties() {
        // Given: Result data
        List<String> fieldsSet = new List<String>{'Name', 'Email'};

        // When: Creating result
        Test.startTest();
        ActionCreateRecord.CreateResult result = new ActionCreateRecord.CreateResult(
            '003000000000001',
            'Success message',
            fieldsSet
        );
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals('003000000000001', result.recordId);
        System.assertEquals('Success message', result.message);
        System.assertEquals(fieldsSet, result.fieldsSet);
        System.assertNotEquals(null, result.metadata);
        System.assertEquals('003000000000001', result.metadata.get('recordId'));
        System.assertEquals(2, result.metadata.get('fieldsSet'));
        System.assertEquals(true, result.metadata.get('creationSuccessful'));
    }
}
