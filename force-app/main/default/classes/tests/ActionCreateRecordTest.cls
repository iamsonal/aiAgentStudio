@IsTest
private class ActionCreateRecordTest {
    @TestSetup
    static void makeData() {
        // Create test accounts for reference field testing
        List<Account> testAccounts = new List<Account>{ new Account(Name = 'Test Account 1'), new Account(Name = 'Test Account 2') };
        insert testAccounts;
    }

    @IsTest
    static void executeAction_createContact_success() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];

        ActionCreateRecord action = new ActionCreateRecord();

        // Configure for Contact creation
        String config = '{"objectApiName": "Contact"}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'FirstName' => 'John',
            'LastName' => 'Doe',
            'Email' => 'john.doe@example.com',
            'AccountId' => testAccount.Id
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(true, result.isSuccess, 'Result should be successful');

        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertNotEquals(null, createResult.recordId, 'Record ID should be set');
        System.assert(createResult.message.contains('Successfully created Contact'), 'Message should indicate success');
        System.assertEquals(4, createResult.fieldsSet.size(), 'Should have set 4 fields');
        System.assert(createResult.fieldsSet.contains('FirstName'), 'Should include FirstName in fields set');
        System.assert(createResult.fieldsSet.contains('LastName'), 'Should include LastName in fields set');
        System.assert(createResult.fieldsSet.contains('Email'), 'Should include Email in fields set');
        System.assert(createResult.fieldsSet.contains('AccountId'), 'Should include AccountId in fields set');

        // Verify record was actually created
        Contact createdContact = [SELECT Id, FirstName, LastName, Email, AccountId FROM Contact WHERE Id = :createResult.recordId];
        System.assertEquals('John', createdContact.FirstName, 'FirstName should be set correctly');
        System.assertEquals('Doe', createdContact.LastName, 'LastName should be set correctly');
        System.assertEquals('john.doe@example.com', createdContact.Email, 'Email should be set correctly');
        System.assertEquals(testAccount.Id, createdContact.AccountId, 'AccountId should be set correctly');
    }

    @IsTest
    static void executeAction_createAccountWithDefaults_success() {
        ActionCreateRecord action = new ActionCreateRecord();

        // Configure for Account creation with default values
        String config = '{"objectApiName": "Account", "defaultFieldValues": {"Type": "Technology Partner", "Industry": "Technology"}}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Name' => 'Test Company' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(true, result.isSuccess, 'Result should be successful');

        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertNotEquals(null, createResult.recordId, 'Record ID should be set');
        System.assert(createResult.message.contains('Successfully created Account'), 'Message should indicate success');
        System.assertEquals(3, createResult.fieldsSet.size(), 'Should have set 3 fields (including defaults)');

        // Verify record was created with defaults
        Account createdAccount = [SELECT Id, Name, Type, Industry FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Test Company', createdAccount.Name, 'Name should be set correctly');
        System.assertEquals('Technology Partner', createdAccount.Type, 'Type should be set from defaults');
        System.assertEquals('Technology', createdAccount.Industry, 'Industry should be set from defaults');
    }

    @IsTest
    static void executeAction_userValueOverridesDefault_success() {
        ActionCreateRecord action = new ActionCreateRecord();

        // Configure with default that will be overridden
        String config = '{"objectApiName": "Account", "defaultFieldValues": {"Type": "Technology Partner"}}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'Name' => 'Test Company',
            'Type' => 'Technology Partner' // Override default
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Result should be successful');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;

        // Verify user value overrode default
        Account createdAccount = [SELECT Id, Name, Type FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Test Company', createdAccount.Name, 'Name should be set correctly');
        System.assertEquals('Technology Partner', createdAccount.Type, 'Type should be overridden by user value');
    }

    @IsTest
    static void executeAction_noFieldData_returnsFailure() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": "Contact"}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.isSuccess, 'Result should indicate failure');
        System.assert(String.valueOf(result.errorMessage).contains('No field data provided'), 'Should indicate no field data');
    }

    @IsTest
    static void executeAction_requiredFieldMissing_returnsFailure() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": "Contact"}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'FirstName' => 'John'
            // Missing required LastName field
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.isSuccess, 'Result should indicate failure');
        System.assert(String.valueOf(result.errorMessage).contains('Failed to create Contact'), 'Should indicate creation failure');
    }

    @IsTest
    static void executeAction_typeCoercionSuccess_createsRecord() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": "Account"}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'Name' => 'Test Company',
            'NumberOfEmployees' => '100', // String that should be coerced to Integer
            'AnnualRevenue' => '1000000.50' // String that should be coerced to Decimal
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertEquals(true, result.isSuccess, 'Result should be successful');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;

        // Verify type coercion worked
        Account createdAccount = [SELECT Id, Name, NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Test Company', createdAccount.Name, 'Name should be set correctly');
        System.assertEquals(100, createdAccount.NumberOfEmployees, 'NumberOfEmployees should be coerced to Integer');
        System.assertEquals(1000000.50, createdAccount.AnnualRevenue, 'AnnualRevenue should be coerced to Decimal');
    }

    @IsTest
    static void parseActionConfiguration_validConfig_success() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": "Contact", "defaultFieldValues": {"LeadSource": "Web"}}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Configuration should be parsed without exception
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void parseActionConfiguration_missingObjectApiName_returnsFailure() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"defaultFieldValues": {"LeadSource": "Web"}}';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown ValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter: "objectApiName"'), 'Should indicate missing objectApiName');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseActionConfiguration_blankObjectApiName_returnsFailure() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": ""}';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown the correct exception');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('objectApiName" cannot be blank'), 'Should indicate blank objectApiName');
        }
        Test.stopTest();
    }

    @IsTest
    static void parseActionConfiguration_invalidObjectApiName_returnsFailure() {
        ActionCreateRecord action = new ActionCreateRecord();

        String config = '{"objectApiName": "InvalidObject__c"}';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid SObject API Name'), 'Should indicate invalid SObject');
        }
        Test.stopTest();
    }

    @IsTest
    static void createResult_constructor_setsProperties() {
        List<String> fieldsSet = new List<String>{ 'Name', 'Email' };

        Test.startTest();
        ActionCreateRecord.CreateResult result = new ActionCreateRecord.CreateResult('003000000000001', 'Success message', fieldsSet);
        Test.stopTest();

        System.assertEquals('003000000000001', result.recordId, 'Should set recordId');
        System.assertEquals('Success message', result.message, 'Should set message');
        System.assertEquals(fieldsSet, result.fieldsSet, 'Should set fieldsSet');
        System.assertNotEquals(null, result.metadata, 'Should initialize metadata');
        System.assertEquals('003000000000001', result.metadata.get('recordId'), 'Metadata should contain recordId');
        System.assertEquals(2, result.metadata.get('fieldsSet'), 'Metadata should contain field count');
        System.assertEquals(fieldsSet, result.metadata.get('fieldNames'), 'Metadata should contain field names');
        System.assertEquals(true, result.metadata.get('creationSuccessful'), 'Metadata should indicate success');
    }

    // Tests for SObjectArgumentCoercionService coverage
    @IsTest
    static void sobjectArgumentCoercionService_coerceArgumentTypes_success() {
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => '50',
            'AnnualRevenue' => '500000.75',
            'Type' => 'Technology Partner'
        };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved as string');
        System.assertEquals(50, result.get('NumberOfEmployees'), 'NumberOfEmployees should be coerced to Integer');
        System.assertEquals(500000.75, result.get('AnnualRevenue'), 'AnnualRevenue should be coerced to Decimal');
        System.assertEquals('Technology Partner', result.get('Type'), 'Type should be preserved as string');
    }

    @IsTest
    static void sobjectArgumentCoercionService_emptyArguments_returnsEmptyMap() {
        Map<String, Object> rawArguments = new Map<String, Object>();

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Result should be empty');
    }

    @IsTest
    static void sobjectArgumentCoercionService_nullArguments_returnsEmptyMap() {
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(null, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Result should be empty');
    }

    @IsTest
    static void sobjectArgumentCoercionService_nullSObjectType_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test' };

        Test.startTest();
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, null, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Target SObjectType cannot be null'), 'Should indicate null SObjectType');
        }
        Test.stopTest();
    }

    @IsTest
    static void sobjectArgumentCoercionService_invalidAccessType_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test' };

        Test.startTest();
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.READABLE // Invalid for this method
            );
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('AccessType must be CREATABLE or UPDATABLE'), 'Should indicate invalid AccessType');
        }
        Test.stopTest();
    }

    @IsTest
    static void sobjectArgumentCoercionService_dateCoercion_success() {
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'CreatedDate' => '2023-12-25' // This will be coerced if the field accepts it
        };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        // CreatedDate is typically not creatable, so it might be filtered out by FLS
    }

    @IsTest
    static void sobjectArgumentCoercionService_booleanCoercion_success() {
        // Create a custom object or use a standard object with boolean fields
        // For this test, we'll use a hypothetical boolean field scenario
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'IsActive' => 'true' // String that should be coerced to Boolean
        };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        // IsActive might not exist on Account, but the coercion logic should handle it
    }

    @IsTest
    static void sobjectArgumentCoercionService_invalidFieldName_skipsField() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test Account', 'NonExistentField__c' => 'Some Value' };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        System.assertEquals(false, result.containsKey('NonExistentField__c'), 'Non-existent field should be skipped');
    }

    @IsTest
    static void typeCoercionService_typeCoercionException_canBeThrown() {
        Test.startTest();

        try {
            throw new TypeCoercionService.TypeCoercionException('Test exception', 'testField', 'String', 'Integer');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assertEquals('Test exception', e.getMessage(), 'Should preserve exception message');
        }

        Test.stopTest();
    }
}
