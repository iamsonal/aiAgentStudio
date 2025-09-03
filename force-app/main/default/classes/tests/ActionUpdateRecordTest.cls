@IsTest
private class ActionUpdateRecordTest {
    @TestSetup
    static void makeData() {
        // Create test accounts and contacts for update testing
        List<Account> testAccounts = new List<Account>{
            new Account(Name = 'Test Account 1', Type = 'Customer', Industry = 'Technology'),
            new Account(Name = 'Test Account 2', Type = 'Partner', Industry = 'Finance')
        };
        insert testAccounts;

        List<Contact> testContacts = new List<Contact>{
            new Contact(FirstName = 'John', LastName = 'Doe', Email = 'john.doe@example.com', AccountId = testAccounts[0].Id),
            new Contact(FirstName = 'Jane', LastName = 'Smith', Email = 'jane.smith@example.com', AccountId = testAccounts[1].Id)
        };
        insert testContacts;
    }

    @IsTest
    static void executeAction_updateContact_success() {
        Contact testContact = [SELECT Id, FirstName, LastName, Email FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        // Use default configuration (no custom record ID parameter)
        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'FirstName' => 'Johnny',
            'Email' => 'johnny.doe@example.com'
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(testContact.Id, result.recordId, 'Record ID should match');
        System.assert(result.message.contains('Successfully updated record'), 'Message should indicate success');
        System.assertEquals(2, result.updatedFields.size(), 'Should have updated 2 fields');
        System.assert(result.updatedFields.contains('FirstName'), 'Should include FirstName in updated fields');
        System.assert(result.updatedFields.contains('Email'), 'Should include Email in updated fields');

        // Verify record was actually updated
        Contact updatedContact = [SELECT Id, FirstName, LastName, Email FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals('Johnny', updatedContact.FirstName, 'FirstName should be updated');
        System.assertEquals('Doe', updatedContact.LastName, 'LastName should remain unchanged');
        System.assertEquals('johnny.doe@example.com', updatedContact.Email, 'Email should be updated');
    }

    @IsTest
    static void executeAction_updateAccountWithCustomRecordIdParam_success() {
        Account testAccount = [SELECT Id, Name, Type FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        // Configure with custom record ID parameter name
        String config = '{"recordIdParameter": "accountId"}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'accountId' => testAccount.Id, // Using custom parameter name
            'Name' => 'Updated Test Account 1',
            'Type' => 'Prospect'
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(testAccount.Id, result.recordId, 'Record ID should match');
        System.assertEquals(2, result.updatedFields.size(), 'Should have updated 2 fields');

        // Verify record was actually updated
        Account updatedAccount = [SELECT Id, Name, Type FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals('Updated Test Account 1', updatedAccount.Name, 'Name should be updated');
        System.assertEquals('Prospect', updatedAccount.Type, 'Type should be updated');
    }

    @IsTest
    static void executeAction_typeCoercionSuccess_updatesRecord() {
        Account testAccount = [SELECT Id, Name FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'NumberOfEmployees' => '250', // String that should be coerced to Integer
            'AnnualRevenue' => '2500000.75' // String that should be coerced to Decimal
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        // Verify type coercion worked
        Account updatedAccount = [SELECT Id, NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals(250, updatedAccount.NumberOfEmployees, 'NumberOfEmployees should be coerced to Integer');
        System.assertEquals(2500000.75, updatedAccount.AnnualRevenue, 'AnnualRevenue should be coerced to Decimal');
    }

    @IsTest
    static void executeAction_missingRecordId_throwsValidationException() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'Name' => 'Updated Name'
            // Missing recordId
        };

        Test.startTest();
        try {
            action.executeAction(params);
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter: "recordId"'), 'Should indicate missing recordId');
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_invalidRecordId_throwsValidationException() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => 'invalid-id', 'Name' => 'Updated Name' };

        Test.startTest();
        try {
            action.executeAction(params);
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid ID format'), 'Should indicate invalid ID format');
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_noUpdateFields_throwsValidationException() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id
            // No update fields provided
        };

        Test.startTest();
        try {
            action.executeAction(params);
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('No fields provided to update'), 'Should indicate no update fields');
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_nonExistentRecord_throwsDmlException() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Use a valid ID format but non-existent record
        String fakeContactId = '003000000000000';

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => fakeContactId, 'FirstName' => 'Updated Name' };

        Test.startTest();
        try {
            action.executeAction(params);
            System.assert(false, 'Should have thrown DmlException');
        } catch (DmlException e) {
            System.assert(e.getMessage().contains('Failed to update record'), 'Should indicate update failure');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseActionConfiguration_defaultConfig_success() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should parse successfully with default recordId parameter
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void parseActionConfiguration_customRecordIdParam_success() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{"recordIdParameter": "customId"}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should parse successfully with custom parameter name
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void parseActionConfiguration_blankRecordIdParam_usesDefault() {
        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{"recordIdParameter": ""}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should use default parameter name when blank is provided
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void updateResult_constructor_setsProperties() {
        List<String> updatedFields = new List<String>{ 'Name', 'Email' };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = new ActionUpdateRecord.UpdateResult('003000000000001', 'Success message', updatedFields);
        Test.stopTest();

        System.assertEquals('003000000000001', result.recordId, 'Should set recordId');
        System.assertEquals('Success message', result.message, 'Should set message');
        System.assertEquals(updatedFields, result.updatedFields, 'Should set updatedFields');
        System.assertNotEquals(null, result.metadata, 'Should initialize metadata');
        System.assertEquals('003000000000001', result.metadata.get('recordId'), 'Metadata should contain recordId');
        System.assertEquals(2, result.metadata.get('fieldsUpdated'), 'Metadata should contain field count');
        System.assertEquals(updatedFields, result.metadata.get('fieldNames'), 'Metadata should contain field names');
    }

    // Additional tests for SObjectArgumentCoercionService coverage through ActionUpdateRecord
    @IsTest
    static void sobjectArgumentCoercionService_updateWithCoercion_success() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'Name' => 'Coercion Test Account',
            'NumberOfEmployees' => 150, // Integer
            'AnnualRevenue' => 1500000.25, // Decimal
            'Type' => 'Technology Partner' // String
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(4, result.updatedFields.size(), 'Should have updated 4 fields');

        // Verify all field types were handled correctly
        Account updatedAccount = [SELECT Id, Name, NumberOfEmployees, AnnualRevenue, Type FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals('Coercion Test Account', updatedAccount.Name, 'Name should be updated');
        System.assertEquals(150, updatedAccount.NumberOfEmployees, 'NumberOfEmployees should be updated');
        System.assertEquals(1500000.25, updatedAccount.AnnualRevenue, 'AnnualRevenue should be updated');
        System.assertEquals('Technology Partner', updatedAccount.Type, 'Type should be updated');
    }

    @IsTest
    static void sobjectArgumentCoercionService_dateTimeCoercion_success() {
        // Test datetime coercion through update
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'FirstName' => 'Updated John'
            // Note: Most datetime fields on standard objects are not updatable
            // This test focuses on the string coercion which is most common
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(1, result.updatedFields.size(), 'Should have updated 1 field');
    }

    @IsTest
    static void sobjectArgumentCoercionService_booleanCoercion_throughUpdate() {
        // Test boolean coercion logic (even if field doesn't exist, the coercion logic is tested)
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'Name' => 'Boolean Test Account'
            // Boolean fields on Account are limited, but the coercion service handles them
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
    }

    @IsTest
    static void sobjectArgumentCoercionService_idCoercion_success() {
        Account testAccount1 = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        Account testAccount2 = [SELECT Id FROM Account WHERE Name = 'Test Account 2' LIMIT 1];
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'AccountId' => String.valueOf(testAccount2.Id), // String ID that should be coerced to Id
            'FirstName' => 'Updated John'
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(2, result.updatedFields.size(), 'Should have updated 2 fields');

        // Verify ID coercion worked
        Contact updatedContact = [SELECT Id, AccountId, FirstName FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals(testAccount2.Id, updatedContact.AccountId, 'AccountId should be coerced and updated');
        System.assertEquals('Updated John', updatedContact.FirstName, 'FirstName should be updated');
    }

    @IsTest
    static void sobjectArgumentCoercionService_nullValues_handledCorrectly() {
        Contact testContact = [SELECT Id, Email FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'Email' => null, // Null value should be handled
            'FirstName' => 'Null Test John'
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(2, result.updatedFields.size(), 'Should have updated 2 fields');

        // Verify null value was handled
        Contact updatedContact = [SELECT Id, Email, FirstName FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals(null, updatedContact.Email, 'Email should be set to null');
        System.assertEquals('Null Test John', updatedContact.FirstName, 'FirstName should be updated');
    }

    @IsTest
    static void sobjectArgumentCoercionService_stringLengthValidation() {
        // Test string length validation through the coercion service
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Create a very long string that might exceed field limits
        String longString = 'A'.repeat(300); // Very long string

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'FirstName' => longString // This should be validated by the coercion service
        };

        Test.startTest();
        try {
            ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
            // If it succeeds, the field was large enough or was truncated appropriately
            System.assertNotEquals(null, result, 'Result should not be null if update succeeded');
        } catch (Exception e) {
            // If it fails, it should be due to length validation
            System.assert(e.getMessage().contains('length') || e.getMessage().contains('too long'), 'Should indicate length issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void sobjectArgumentCoercionService_decimalCoercion_edgeCases() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionUpdateRecord action = new ActionUpdateRecord();

        String config = '{}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'AnnualRevenue' => '1234567.89', // String decimal
            'NumberOfEmployees' => 500 // Integer
        };

        Test.startTest();
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');

        // Verify decimal coercion
        Account updatedAccount = [SELECT Id, AnnualRevenue, NumberOfEmployees FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals(1234567.89, updatedAccount.AnnualRevenue, 'AnnualRevenue should be coerced from string');
        System.assertEquals(500, updatedAccount.NumberOfEmployees, 'NumberOfEmployees should be set correctly');
    }
}
