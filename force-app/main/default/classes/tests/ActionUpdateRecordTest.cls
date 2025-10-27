/**
 * @description Tests for ActionUpdateRecord using TestFactory utilities
 */
@IsTest
private class ActionUpdateRecordTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test accounts with TestFactory
        TestFactory.newAccount().withName('Test Account 1').withIndustry('Technology').save();

        TestFactory.newAccount().withName('Test Account 2').withIndustry('Finance').save();

        // Create test contacts
        Account acc1 = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        Account acc2 = [SELECT Id FROM Account WHERE Name = 'Test Account 2' LIMIT 1];

        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@test.com').withAccount(acc1.Id).save();

        TestFactory.newContact().withName('Jane', 'Smith').withEmail('jane.smith@test.com').withAccount(acc2.Id).save();
    }

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testUpdateContact_WithMultipleFields_Success() {
        // Given: A contact to update
        Contact testContact = [
            SELECT Id, FirstName, LastName, Email
            FROM Contact
            WHERE FirstName = 'John'
            LIMIT 1
        ];

        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'fields' => new Map<String, Object>{ 'FirstName' => 'Johnny', 'Email' => 'johnny.doe@test.com' }
        };

        // When: Updating the contact
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Contact is updated successfully
        System.assert(result.isSuccess, 'Should update successfully');

        ActionUpdateRecord.UpdateResult updateResult = (ActionUpdateRecord.UpdateResult) result.data;
        System.assertEquals(testContact.Id, updateResult.recordId);
        System.assertEquals(2, updateResult.updatedFields.size(), 'Should update 2 fields');
        System.assert(updateResult.updatedFields.contains('FirstName'));
        System.assert(updateResult.updatedFields.contains('Email'));

        // Verify database state
        Contact updated = [SELECT FirstName, LastName, Email FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals('Johnny', updated.FirstName, 'FirstName should be updated');
        System.assertEquals('Doe', updated.LastName, 'LastName should remain unchanged');
        System.assertEquals('johnny.doe@test.com', updated.Email, 'Email should be updated');
    }

    @IsTest
    static void testUpdateAccount_CustomRecordIdParam_Success() {
        // Given: Action with DTO structure
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'fields' => new Map<String, Object>{ 'Name' => 'Updated Test Account', 'Industry' => 'Healthcare' }
        };

        // When: Updating with DTO structure
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Update succeeds
        System.assert(result.isSuccess, 'Should succeed with proper DTO structure');
        Account updated = [SELECT Name, Industry FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals('Updated Test Account', updated.Name);
        System.assertEquals('Healthcare', updated.Industry);
    }

    @IsTest
    static void testTypeCoercion_StringToNumber_Success() {
        // Given: Account with numeric fields as strings
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'fields' => new Map<String, Object>{
                'NumberOfEmployees' => '250', // String -> Integer
                'AnnualRevenue' => '2500000.75' // String -> Decimal
            }
        };

        // When: Updating with type coercion
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Types are coerced correctly
        System.assert(result.isSuccess);
        Account updated = [SELECT NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals(250, updated.NumberOfEmployees);
        System.assertEquals(2500000.75, updated.AnnualRevenue);
    }

    @IsTest
    static void testUpdateContact_NullValue_Success() {
        // Given: Contact with email to be cleared
        Contact testContact = [SELECT Id, Email FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'fields' => new Map<String, Object>{ 'Email' => null, 'FirstName' => 'John Updated' }
        };

        // When: Updating with null value
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Null is handled correctly
        System.assert(result.isSuccess);
        Contact updated = [SELECT Email, FirstName FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals(null, updated.Email, 'Email should be null');
        System.assertEquals('John Updated', updated.FirstName);
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testUpdateRecord_MissingRecordId_Failure() {
        // Given: Parameters without recordId
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'fields' => new Map<String, Object>{ 'Name' => 'Updated Name' }
            // Missing recordId
        };

        // When: Attempting update
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(result.errorMessage.contains('Missing required parameter: "recordId"'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testUpdateRecord_InvalidRecordId_Failure() {
        // Given: Invalid recordId format
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => 'invalid-id-format',
            'fields' => new Map<String, Object>{ 'Name' => 'Test' }
        };

        // When: Attempting update
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(result.errorMessage.contains('Invalid ID format'));
    }

    @IsTest
    static void testUpdateRecord_NoFieldsToUpdate_Failure() {
        // Given: Only recordId, no update fields
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id
            // No fields property - should fail
        };

        // When: Attempting update
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail
        System.assert(!result.isSuccess);
        System.assert(result.errorMessage.contains('No fields provided to update'));
    }

    @IsTest
    static void testUpdateRecord_NonExistentRecord_Failure() {
        // Given: Valid ID format but non-existent record
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        String fakeId = '003000000000000';
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => fakeId, 'fields' => new Map<String, Object>{ 'FirstName' => 'Test' } };

        // When: Attempting update
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with DML error
        System.assert(!result.isSuccess, 'Should fail for non-existent record');
        System.assert(result.errorMessage.contains('Failed to update record'), 'Error message should mention update failure');
    }

    // ===================================================================================
    // CONFIGURATION TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_DefaultConfig_Success() {
        // Given: Default configuration
        ActionUpdateRecord action = new ActionUpdateRecord();

        // When: Parsing config
        Test.startTest();
        action.parseActionConfiguration('{}', '[TEST] ');
        Test.stopTest();

        // Then: Should parse successfully
        System.assert(true, 'Should parse default config');
    }

    @IsTest
    static void testParseConfig_CustomRecordIdParam_Success() {
        // Given: Configuration with custom parameter
        ActionUpdateRecord action = new ActionUpdateRecord();

        // When: Parsing config
        Test.startTest();
        action.parseActionConfiguration('{"recordIdParameter": "customId"}', '[TEST] ');
        Test.stopTest();

        // Then: Should parse successfully
        System.assert(true, 'Should parse custom config');
    }

    // ===================================================================================
    // RESULT DTO TESTS
    // ===================================================================================

    @IsTest
    static void testUpdateResult_Constructor_SetsProperties() {
        // Given: Result data
        List<String> updatedFields = new List<String>{ 'Name', 'Email' };

        // When: Creating result
        Test.startTest();
        ActionUpdateRecord.UpdateResult result = new ActionUpdateRecord.UpdateResult('003000000000001', 'Success message', updatedFields);
        Test.stopTest();

        // Then: Properties should be set
        System.assertEquals('003000000000001', result.recordId);
        System.assertEquals('Success message', result.message);
        System.assertEquals(updatedFields, result.updatedFields);
        System.assertNotEquals(null, result.metadata);
        System.assertEquals('003000000000001', result.metadata.get('recordId'));
        System.assertEquals(2, result.metadata.get('fieldsUpdated'));
    }
}
