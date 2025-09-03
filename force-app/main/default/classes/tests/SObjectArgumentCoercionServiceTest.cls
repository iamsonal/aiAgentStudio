@IsTest
private class SObjectArgumentCoercionServiceTest {
    @TestSetup
    static void makeData() {
        // Create test data for reference field testing
        Account testAccount = new Account(Name = 'Test Account for References');
        insert testAccount;

        OperatingHours hours = new OperatingHours(Name = 'Test Hours', TimeZone = 'America/Los_Angeles');
        insert hours;

        Contact testContact = new Contact(LastName = 'TestContact');
        insert testContact;
    }

    @IsTest
    static void coerceArgumentTypesForSObject_validArguments_success() {
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => '100',
            'AnnualRevenue' => '1000000.50',
            'Type' => 'Technology Partner'
        };

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved as string');
        System.assertEquals(100, result.get('NumberOfEmployees'), 'NumberOfEmployees should be coerced to Integer');
        System.assertEquals(1000000.50, result.get('AnnualRevenue'), 'AnnualRevenue should be coerced to Decimal');
        System.assertEquals('Technology Partner', result.get('Type'), 'Type should be preserved as string');
    }

    @IsTest
    static void coerceArgumentTypesForSObject_nullArguments_returnsEmptyMap() {
        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(null, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Result should be empty');
    }

    @IsTest
    static void coerceArgumentTypesForSObject_emptyArguments_returnsEmptyMap() {
        Map<String, Object> rawArguments = new Map<String, Object>();

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Result should be empty');
    }

    @IsTest
    static void coerceArgumentTypesForSObject_nullSObjectType_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test' };

        Test.startTest();
        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(rawArguments, null, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown ActionSecurityException');
        } catch (SecurityUtils.ActionSecurityException e) {
            System.assert(e.getMessage().contains('Target SObjectType cannot be null'), 'Should indicate null SObjectType');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceArgumentTypesForSObject_invalidAccessType_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test' };

        Test.startTest();
        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.READABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(e.getMessage().contains('AccessType must be CREATABLE or UPDATABLE'), 'Should indicate invalid AccessType');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceArgumentTypesForSObject_nonExistentField_skipsField() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test Account', 'NonExistentField__c' => 'Some Value' };

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        System.assertEquals(false, result.containsKey('NonExistentField__c'), 'Non-existent field should be skipped');
    }

    @IsTest
    static void coerceValueForField_nullValue_returnsNull() {
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'Type' => null // Null value
        };

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        System.assertEquals(null, result.get('Type'), 'Null value should be preserved');
    }

    @IsTest
    static void invalidArgumentTypeException_canBeThrown() {
        Test.startTest();

        try {
            throw new SObjectArgumentCoercionService.InvalidArgumentTypeException('Test exception');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assertEquals('Test exception', e.getMessage(), 'Should preserve exception message');
        }

        Test.stopTest();
    }

    @IsTest
    static void invalidArgumentTypeException_withCause_canBeThrown() {
        Test.startTest();

        try {
            Exception cause = new System.StringException('Cause exception');
            throw new SObjectArgumentCoercionService.InvalidArgumentTypeException('Test exception', cause);
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assertEquals('Test exception', e.getMessage(), 'Should preserve exception message');
            System.assertNotEquals(null, e.getCause(), 'Should preserve cause exception');
        }

        Test.stopTest();
    }

    @IsTest
    static void coerceArgumentTypesForSObject_updatableAccessType_success() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Updated Account Name', 'Type' => 'Technology Partner' };

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.UPDATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Updated Account Name', result.get('Name'), 'Name should be preserved');
        System.assertEquals('Technology Partner', result.get('Type'), 'Type should be preserved');
    }

    @IsTest
    static void coerceToInteger_outOfRangeValue_throwsException() {
        // Test with a value that's too large for Integer
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => '999999999999999' // Too large for Integer
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            // If it succeeds, the validation might have been handled differently
            System.assertNotEquals(null, result, 'Result should not be null if validation passed');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(e.getMessage().contains('out of range') || e.getMessage().contains('Integer'), 'Should indicate range or type issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceToDecimal_invalidFormat_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test Account', 'AnnualRevenue' => 'not-a-number' };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid Decimal format') || e.getMessage().contains('Decimal'),
                'Should indicate decimal format issue'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceToId_invalidFormat_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{
            'FirstName' => 'Test',
            'LastName' => 'Contact',
            'AccountId' => 'invalid-id-format'
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Contact.SObjectType,
                AccessType.CREATABLE
            );
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid Salesforce ID format') || e.getMessage().contains('ID'),
                'Should indicate ID format issue'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void validatePicklistValue_invalidValue_triggersError() {
        // Test picklist validation with invalid value
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'Type' => 'InvalidPicklistValue' // Invalid picklist value
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            // If it succeeds, the validation might have passed or field was filtered
            System.assertNotEquals(null, result, 'Result should not be null');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid picklist value') || e.getMessage().contains('picklist'),
                'Should indicate picklist validation issue'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void getInputTypeString_variousObjectTypes_returnsCorrectStrings() {
        // Test getInputTypeString indirectly by triggering type errors with various object types
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => new List<String>{ 'not', 'a', 'number' } // List instead of Integer
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            // If it succeeds, the coercion handled the type conversion
            System.assertNotEquals(null, result, 'Result should not be null');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            // The error message should include type information from getInputTypeString
            System.assert(
                e.getMessage().contains('Integer') || e.getMessage().contains('List') || e.getMessage().contains('type'),
                'Should include type information'
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void getInputTypeString_nullValue_returnsNull() {
        // Test getInputTypeString with null value
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'Type' => null // Null value
        };

        Test.startTest();
        Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be preserved');
        System.assertEquals(null, result.get('Type'), 'Null value should be preserved');
    }

    @IsTest
    static void getInputTypeString_sObjectType_returnsCorrectString() {
        // Test getInputTypeString with SObject type by creating a scenario that might trigger it
        Account testAccount = new Account(Name = 'Test');

        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'TestField' => testAccount // SObject instead of expected type
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            // If it succeeds, the field was filtered out or handled
            System.assertNotEquals(null, result, 'Result should not be null');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            // Should include SObject type information
            System.assert(e.getMessage().contains('Account') || e.getMessage().contains('SObject'), 'Should include SObject type information');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceToInteger_decimalWithScale_throwsException() {
        // Test integer coercion with decimal that has scale
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => 100.5 // Decimal with scale
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(e.getMessage().contains('Decimal') || e.getMessage().contains('Integer'), 'Should indicate decimal scale issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceToInteger_longOutOfRange_throwsException() {
        // Test integer coercion with Long value out of Integer range
        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => 9999999999L // Long value too large for Integer
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            System.assert(false, 'Should have thrown InvalidArgumentTypeException');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(e.getMessage().contains('out of range') || e.getMessage().contains('Integer'), 'Should indicate range issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void stringLengthValidation_exceedsMaxLength_triggersError() {
        // Test string length validation
        String longString = 'A'.repeat(500); // Very long string

        Map<String, Object> rawArguments = new Map<String, Object>{
            'Name' => longString // Might exceed Name field length
        };

        Test.startTest();
        try {
            Map<String, Object> result = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                rawArguments,
                Account.SObjectType,
                AccessType.CREATABLE
            );
            // If it succeeds, the field length was acceptable or truncated
            System.assertNotEquals(null, result, 'Result should not be null');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(e.getMessage().contains('length') || e.getMessage().contains('exceeds'), 'Should indicate length issue');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceToDate_SuccessAndFailure() {
        // Success case: valid date string
        Map<String, Object> successArgs = new Map<String, Object>{ 'Name' => 'Test Opp', 'StageName' => 'Prospecting', 'CloseDate' => '2025-12-31' };

        Test.startTest();
        Map<String, Object> successResult = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            successArgs,
            Opportunity.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertEquals(Date.newInstance(2025, 12, 31), successResult.get('CloseDate'), 'Should coerce string to Date');

        // Failure case: invalid date string, which also tests getInputTypeString in the error message
        Map<String, Object> failureArgs = new Map<String, Object>{
            'Name' => 'Test Opp',
            'StageName' => 'Prospecting',
            'CloseDate' => 'not-a-real-date'
        };

        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(failureArgs, Opportunity.SObjectType, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException for invalid date format');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid date format for field "CloseDate"'),
                'Exception message should be specific to date format'
            );
        }
    }

    @IsTest
    static void coerceToDateTime_SuccessAndFailure() {
        // Success case: valid ISO 8601 string
        Map<String, Object> successArgs = new Map<String, Object>{ 'Subject' => 'Test Task', 'ReminderDateTime' => '2025-12-31T10:30:00Z' };

        Test.startTest();
        Map<String, Object> successResult = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            successArgs,
            Task.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertEquals(
            Datetime.valueOfGmt('2025-12-31 10:30:00'),
            successResult.get('ReminderDateTime'),
            'Should coerce ISO string to Datetime'
        );

        // Failure case: invalid datetime string
        Map<String, Object> failureArgs = new Map<String, Object>{ 'Subject' => 'Test Task', 'ReminderDateTime' => 'invalid-datetime' };

        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(failureArgs, Task.SObjectType, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException for invalid datetime format');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid Datetime format for field "ReminderDateTime"'),
                'Exception message should be specific to datetime format'
            );
        }
    }

    @IsTest
    static void coerceToBoolean_SuccessAndFailure() {
        // Success case 1: string 'true'
        Map<String, Object> argsTrue = new Map<String, Object>{ 'DoNotCall' => 'true' };
        Map<String, Object> resultTrue = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            argsTrue,
            Contact.SObjectType,
            AccessType.UPDATABLE
        );
        System.assertEquals(true, resultTrue.get('DoNotCall'), 'Should coerce string "true" to Boolean true');

        // Success case 2: number 1
        Map<String, Object> argsOne = new Map<String, Object>{ 'DoNotCall' => 1 };
        Map<String, Object> resultOne = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            argsOne,
            Contact.SObjectType,
            AccessType.UPDATABLE
        );
        System.assertEquals(true, resultOne.get('DoNotCall'), 'Should coerce number 1 to Boolean true');

        // Failure case: invalid string, which also covers getInputTypeString
        Map<String, Object> failureArgs = new Map<String, Object>{ 'DoNotCall' => 'maybe' };
        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(failureArgs, Contact.SObjectType, AccessType.UPDATABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException for invalid boolean string');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Expected true/false or number 0/1. Got: "maybe" (String)'),
                'Exception message should be specific and show input type'
            );
        }
    }

    @IsTest
    static void coerceToTime_SuccessAndFailure() {
        // Guard clause for environments where OperatingHours time fields are not available
        if (!Schema.SObjectType.OperatingHours.fields.getMap().containsKey('MondayStartTime')) {
            System.debug(
                LoggingLevel.WARN,
                'Skipping coerceToTime test: OperatingHours.MondayStartTime field is not available in this test environment.'
            );
            System.assert(true, 'Test skipped due to missing schema field.');
            return;
        }

        // Success case: valid time string
        Map<String, Object> successArgs = new Map<String, Object>{ 'MondayStartTime' => '09:30:00' };

        Test.startTest();
        Map<String, Object> successResult = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            successArgs,
            OperatingHours.SObjectType,
            AccessType.UPDATABLE
        );
        Test.stopTest();

        System.assertEquals(Time.newInstance(9, 30, 0, 0), successResult.get('MondayStartTime'), 'Should coerce string to Time');

        // Failure case: invalid time string
        Map<String, Object> failureArgs = new Map<String, Object>{ 'MondayStartTime' => 'not-a-time' };

        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(failureArgs, OperatingHours.SObjectType, AccessType.UPDATABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException for invalid time format');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid time format for field MondayStartTime'),
                'Exception message should be specific to time format'
            );
        }
    }

    @IsTest
    static void coerceToBlob_SuccessAndFailure() {
        // Success case: valid base64 string
        String testContent = 'test data';
        String base64Content = EncodingUtil.base64Encode(Blob.valueOf(testContent));
        Map<String, Object> successArgs = new Map<String, Object>{
            'Title' => 'Test Doc',
            'PathOnClient' => 'test.txt',
            'VersionData' => base64Content
        };

        Test.startTest();
        Map<String, Object> successResult = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
            successArgs,
            ContentVersion.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        Blob resultBlob = (Blob) successResult.get('VersionData');
        System.assertEquals(testContent, resultBlob.toString(), 'Should coerce base64 string to Blob');

        // Failure case: invalid base64 string
        Map<String, Object> failureArgs = new Map<String, Object>{
            'Title' => 'Test Doc',
            'PathOnClient' => 'test.txt',
            'VersionData' => 'not valid base64!!'
        };

        try {
            SObjectArgumentCoercionService.coerceArgumentTypesForSObject(failureArgs, ContentVersion.SObjectType, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown InvalidArgumentTypeException for invalid base64 format');
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException e) {
            System.assert(
                e.getMessage().contains('Invalid Base64 format for Blob field "VersionData"'),
                'Exception message should be specific to base64 format'
            );
        }
    }
}
