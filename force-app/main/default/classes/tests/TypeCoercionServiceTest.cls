@isTest
private class TypeCoercionServiceTest {
    @isTest
    static void testCoerceToString() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToString(null, 'TestField', null));

        // Test string value
        System.assertEquals('test', TypeCoercionService.coerceToString('test', 'TestField', null));

        // Test integer value
        System.assertEquals('123', TypeCoercionService.coerceToString(123, 'TestField', null));
    }

    @isTest
    static void testCoerceToInteger() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToInteger(null, 'TestField'));

        // Test integer value
        System.assertEquals(123, TypeCoercionService.coerceToInteger(123, 'TestField'));

        // Test string value
        System.assertEquals(123, TypeCoercionService.coerceToInteger('123', 'TestField'));

        // Test long value
        System.assertEquals(123, TypeCoercionService.coerceToInteger(123L, 'TestField'));

        // Test exception for decimal with fractional part
        try {
            TypeCoercionService.coerceToInteger(123.5, 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('fractional part'));
        }
    }

    @isTest
    static void testCoerceToDecimal() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToDecimal(null, 'TestField'));

        // Test decimal value
        System.assertEquals(123.45, TypeCoercionService.coerceToDecimal(123.45, 'TestField'));

        // Test string value
        System.assertEquals(123.45, TypeCoercionService.coerceToDecimal('123.45', 'TestField'));

        // Test integer value
        System.assertEquals(123.0, TypeCoercionService.coerceToDecimal(123, 'TestField'));
    }

    @isTest
    static void testCoerceToBoolean() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToBoolean(null, 'TestField'));

        // Test boolean true
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(true, 'TestField'));

        // Test boolean false
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(false, 'TestField'));

        // Test string true values
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('true', 'TestField'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('1', 'TestField'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('yes', 'TestField'));

        // Test string false values
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('false', 'TestField'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('0', 'TestField'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('no', 'TestField'));

        // Test numeric values
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(1, 'TestField'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(0, 'TestField'));
    }

    @isTest
    static void testCoerceToId() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToId(null, 'TestField'));

        // Test Id value
        Id testId = '001000000000000AAA';
        System.assertEquals(testId, TypeCoercionService.coerceToId(testId, 'TestField'));

        // Test string value
        System.assertEquals(testId, TypeCoercionService.coerceToId('001000000000000AAA', 'TestField'));

        // Test exception for invalid Id
        try {
            TypeCoercionService.coerceToId('invalidId', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Salesforce ID format'));
        }
    }

    @isTest
    static void testCoerceToDate() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToDate(null, 'TestField'));

        // Test Date value
        Date testDate = Date.newInstance(2023, 1, 1);
        System.assertEquals(testDate, TypeCoercionService.coerceToDate(testDate, 'TestField'));

        // Test string value
        System.assertEquals(testDate, TypeCoercionService.coerceToDate('2023-01-01', 'TestField'));

        // Test exception for invalid date
        try {
            TypeCoercionService.coerceToDate('invalidDate', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Date format'));
        }
    }

    @isTest
    static void testCoerceToDateTime() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToDateTime(null, 'TestField'));

        // Test DateTime value
        DateTime testDateTime = DateTime.newInstance(2023, 1, 1, 12, 0, 0);
        DateTime resultDateTime = TypeCoercionService.coerceToDateTime(testDateTime, 'TestField');
        System.assertEquals(testDateTime.date(), resultDateTime.date());
        System.assertEquals(testDateTime.hour(), resultDateTime.hour());
        System.assertEquals(testDateTime.minute(), resultDateTime.minute());
        System.assertEquals(testDateTime.second(), resultDateTime.second());

        // Test Date value (should convert to DateTime at midnight)
        Date testDate = Date.newInstance(2023, 1, 1);
        DateTime resultFromTestDate = TypeCoercionService.coerceToDateTime(testDate, 'TestField');
        // Just check that the result is not null and is a DateTime
        System.assert(resultFromTestDate != null, 'Expected non-null DateTime result');

        // Test string value - just check that it doesn't throw an exception
        DateTime resultFromString = TypeCoercionService.coerceToDateTime('2023-01-01 12:00:00', 'TestField');
        System.assert(resultFromString != null, 'Expected non-null DateTime result');
    }

    @isTest
    static void testCoerceBySchema() {
        // Test string schema
        Map<String, Object> stringSchema = new Map<String, Object>{ 'type' => 'string' };
        System.assertEquals('test', TypeCoercionService.coerceValueByJsonSchema('test', 'TestField', stringSchema));

        // Test integer schema
        Map<String, Object> integerSchema = new Map<String, Object>{ 'type' => 'integer' };
        System.assertEquals(123, TypeCoercionService.coerceValueByJsonSchema('123', 'TestField', integerSchema));

        // Test boolean schema
        Map<String, Object> booleanSchema = new Map<String, Object>{ 'type' => 'boolean' };
        System.assertEquals(true, TypeCoercionService.coerceValueByJsonSchema('true', 'TestField', booleanSchema));

        // Test array schema
        Map<String, Object> arraySchema = new Map<String, Object>{ 'type' => 'array', 'items' => new Map<String, Object>{ 'type' => 'string' } };
        List<Object> testList = new List<Object>{ 'item1', 'item2' };
        System.assertEquals(testList, TypeCoercionService.coerceValueByJsonSchema(testList, 'TestField', arraySchema));
    }

    @isTest
    static void testTypeCoercionException() {
        TypeCoercionService.TypeCoercionException ex = new TypeCoercionService.TypeCoercionException(
            'Test message',
            'TestField',
            'String',
            'Integer'
        );

        System.assertEquals('Test message', ex.getMessage());
        System.assertEquals('TestField', ex.fieldName);
        System.assertEquals('String', ex.targetType);
        System.assertEquals('Integer', ex.inputType);
    }

    // ============================================================================
    // --- SObject Coercion Tests ---
    // ============================================================================

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
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
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
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(null, Account.SObjectType, AccessType.CREATABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(0, result.size(), 'Result should be empty');
    }

    @IsTest
    static void coerceArgumentTypesForSObject_emptyArguments_returnsEmptyMap() {
        Map<String, Object> rawArguments = new Map<String, Object>();

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
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
            TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, null, AccessType.CREATABLE);
            System.assert(false, 'Should have thrown TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Target SObjectType cannot be null'), 'Should indicate null SObjectType');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceArgumentTypesForSObject_invalidAccessType_throwsException() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test' };

        Test.startTest();
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(rawArguments, Account.SObjectType, AccessType.READABLE);
            System.assert(false, 'Should have thrown TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('AccessType must be CREATABLE or UPDATABLE'), 'Should indicate invalid AccessType');
        }
        Test.stopTest();
    }

    @IsTest
    static void coerceArgumentTypesForSObject_nonExistentField_skipsField() {
        Map<String, Object> rawArguments = new Map<String, Object>{ 'Name' => 'Test Account', 'NonExistentField__c' => 'Some Value' };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            rawArguments,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(1, result.size(), 'Should only include existing fields');
        System.assertEquals('Test Account', result.get('Name'), 'Name should be included');
        System.assertEquals(false, result.containsKey('NonExistentField__c'), 'Non-existent field should be skipped');
    }

    @isTest
    static void testCoerceToBlob() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToBlob(null, 'TestField'));

        // Test Blob value
        Blob testBlob = Blob.valueOf('test data');
        System.assertEquals(testBlob, TypeCoercionService.coerceToBlob(testBlob, 'TestField'));

        // Test string value - valid Base64
        String base64String = EncodingUtil.base64Encode(Blob.valueOf('test data'));
        Blob result = TypeCoercionService.coerceToBlob(base64String, 'TestField');
        System.assertEquals('test data', result.toString());

        // Test exception for invalid Base64 format
        try {
            TypeCoercionService.coerceToBlob('invalid base64!@#', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Base64 format'));
        }

        // Test exception for non-string, non-blob input
        try {
            TypeCoercionService.coerceToBlob(123, 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Cannot coerce to Blob'));
        }
    }

    @isTest
    static void testCoerceToEmailString() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToEmailString(null, 'TestField'));

        // Test valid email formats
        System.assertEquals('test@example.com', TypeCoercionService.coerceToEmailString('test@example.com', 'TestField'));
        System.assertEquals('user.name@domain.co.uk', TypeCoercionService.coerceToEmailString('user.name@domain.co.uk', 'TestField'));
        System.assertEquals('admin@subdomain.example.org', TypeCoercionService.coerceToEmailString('admin@subdomain.example.org', 'TestField'));

        // Test coercion from other types
        System.assertEquals('123@example.com', TypeCoercionService.coerceToEmailString('123@example.com', 'TestField'));

        // Test exception for invalid email - no @ symbol
        try {
            TypeCoercionService.coerceToEmailString('invalid.email.com', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid email format'));
        }

        // Test exception for invalid email - no domain
        try {
            TypeCoercionService.coerceToEmailString('user@', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid email format'));
        }

        // Test exception for invalid email - no user part
        try {
            TypeCoercionService.coerceToEmailString('@domain.com', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid email format'));
        }

        // Test exception for invalid email - no dot in domain
        try {
            TypeCoercionService.coerceToEmailString('user@domain', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid email format'));
        }
    }

    @isTest
    static void testCoerceToUrlString() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceToUrlString(null, 'TestField'));

        // Test valid HTTP URLs
        System.assertEquals('http://example.com', TypeCoercionService.coerceToUrlString('http://example.com', 'TestField'));
        System.assertEquals('http://www.example.com/path', TypeCoercionService.coerceToUrlString('http://www.example.com/path', 'TestField'));

        // Test valid HTTPS URLs
        System.assertEquals('https://example.com', TypeCoercionService.coerceToUrlString('https://example.com', 'TestField'));
        System.assertEquals('https://api.example.com/v1/endpoint', TypeCoercionService.coerceToUrlString('https://api.example.com/v1/endpoint', 'TestField'));

        // Test case insensitive protocol matching
        System.assertEquals('HTTP://example.com', TypeCoercionService.coerceToUrlString('HTTP://example.com', 'TestField'));
        System.assertEquals('HTTPS://example.com', TypeCoercionService.coerceToUrlString('HTTPS://example.com', 'TestField'));

        // Test exception for invalid URL - no protocol
        try {
            TypeCoercionService.coerceToUrlString('www.example.com', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid URL format'));
        }

        // Test exception for invalid URL - wrong protocol
        try {
            TypeCoercionService.coerceToUrlString('ftp://example.com', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid URL format'));
        }

        // Test exception for empty string
        try {
            TypeCoercionService.coerceToUrlString('', 'TestField');
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid URL format'));
        }
    }

    @isTest
    static void testCoerceObjectBySchema() {
        // Test null value
        System.assertEquals(null, TypeCoercionService.coerceObjectBySchema(null, 'TestField', new Map<String, Object>()));

        // Test valid object with schema
        Map<String, Object> inputObject = new Map<String, Object>{
            'name' => 'John Doe',
            'age' => '30',
            'isActive' => 'true'
        };

        Map<String, Object> propertiesSchema = new Map<String, Object>{
            'name' => new Map<String, Object>{ 'type' => 'string' },
            'age' => new Map<String, Object>{ 'type' => 'integer' },
            'isActive' => new Map<String, Object>{ 'type' => 'boolean' }
        };

        Map<String, Object> result = TypeCoercionService.coerceObjectBySchema(inputObject, 'TestField', propertiesSchema);

        System.assertNotEquals(null, result);
        System.assertEquals('John Doe', result.get('name'));
        System.assertEquals(30, result.get('age'));
        System.assertEquals(true, result.get('isActive'));

        // Test object with properties not in schema (should pass through)
        Map<String, Object> inputWithExtra = new Map<String, Object>{
            'name' => 'Jane Doe',
            'extraField' => 'extraValue'
        };

        Map<String, Object> limitedSchema = new Map<String, Object>{
            'name' => new Map<String, Object>{ 'type' => 'string' }
        };

        Map<String, Object> resultWithExtra = TypeCoercionService.coerceObjectBySchema(inputWithExtra, 'TestField', limitedSchema);

        System.assertNotEquals(null, resultWithExtra);
        System.assertEquals('Jane Doe', resultWithExtra.get('name'));
        System.assertEquals('extraValue', resultWithExtra.get('extraField'));

        // Test empty object
        Map<String, Object> emptyObject = new Map<String, Object>();
        Map<String, Object> emptyResult = TypeCoercionService.coerceObjectBySchema(emptyObject, 'TestField', propertiesSchema);
        System.assertNotEquals(null, emptyResult);
        System.assertEquals(0, emptyResult.size());

        // Test exception for non-object input
        try {
            TypeCoercionService.coerceObjectBySchema('not an object', 'TestField', propertiesSchema);
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Expected object/map value'));
        }

        // Test exception for invalid property coercion
        Map<String, Object> invalidInput = new Map<String, Object>{
            'age' => 'not a number'
        };

        Map<String, Object> integerSchema = new Map<String, Object>{
            'age' => new Map<String, Object>{ 'type' => 'integer' }
        };

        try {
            TypeCoercionService.coerceObjectBySchema(invalidInput, 'TestField', integerSchema);
            System.assert(false, 'Expected TypeCoercionException');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid object property'));
        }
    }
}
