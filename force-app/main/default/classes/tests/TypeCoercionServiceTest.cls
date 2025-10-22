/**
 * @description Tests for TypeCoercionService using TestFactory utilities
 */
@IsTest
private class TypeCoercionServiceTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test data for reference fields
        TestFactory.newAccount().withName('Test Account').save();
    }

    // ===================================================================================
    // PRIMITIVE TYPE COERCION TESTS
    // ===================================================================================

    @IsTest
    static void testCoerceToString_VariousTypes_Success() {
        System.assertEquals(null, TypeCoercionService.coerceToString(null, 'Field', null));
        System.assertEquals('test', TypeCoercionService.coerceToString('test', 'Field', null));
        System.assertEquals('123', TypeCoercionService.coerceToString(123, 'Field', null));
    }

    @IsTest
    static void testCoerceToInteger_VariousTypes_Success() {
        System.assertEquals(null, TypeCoercionService.coerceToInteger(null, 'Field'));
        System.assertEquals(123, TypeCoercionService.coerceToInteger(123, 'Field'));
        System.assertEquals(123, TypeCoercionService.coerceToInteger('123', 'Field'));
        System.assertEquals(123, TypeCoercionService.coerceToInteger(123L, 'Field'));
    }

    @IsTest
    static void testCoerceToInteger_DecimalWithFraction_ThrowsException() {
        try {
            TypeCoercionService.coerceToInteger(123.5, 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('fractional part'));
        }
    }

    @IsTest
    static void testCoerceToDecimal_VariousTypes_Success() {
        System.assertEquals(null, TypeCoercionService.coerceToDecimal(null, 'Field'));
        System.assertEquals(123.45, TypeCoercionService.coerceToDecimal(123.45, 'Field'));
        System.assertEquals(123.45, TypeCoercionService.coerceToDecimal('123.45', 'Field'));
        System.assertEquals(123.0, TypeCoercionService.coerceToDecimal(123, 'Field'));
    }

    @IsTest
    static void testCoerceToBoolean_VariousValues_Success() {
        System.assertEquals(null, TypeCoercionService.coerceToBoolean(null, 'Field'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(true, 'Field'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('true', 'Field'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('1', 'Field'));
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(1, 'Field'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(false, 'Field'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('false', 'Field'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('0', 'Field'));
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(0, 'Field'));
    }

    @IsTest
    static void testCoerceToId_ValidAndInvalid() {
        // Valid cases
        Id testId = '001000000000000AAA';
        System.assertEquals(null, TypeCoercionService.coerceToId(null, 'Field'));
        System.assertEquals(testId, TypeCoercionService.coerceToId(testId, 'Field'));
        System.assertEquals(testId, TypeCoercionService.coerceToId('001000000000000AAA', 'Field'));

        // Invalid case
        try {
            TypeCoercionService.coerceToId('invalidId', 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Salesforce ID'));
        }
    }

    @IsTest
    static void testCoerceToDate_ValidAndInvalid() {
        // Valid cases
        Date testDate = Date.newInstance(2023, 1, 1);
        System.assertEquals(null, TypeCoercionService.coerceToDate(null, 'Field'));
        System.assertEquals(testDate, TypeCoercionService.coerceToDate(testDate, 'Field'));
        System.assertEquals(testDate, TypeCoercionService.coerceToDate('2023-01-01', 'Field'));

        // Invalid case
        try {
            TypeCoercionService.coerceToDate('invalid-date', 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Date format'));
        }
    }

    @IsTest
    static void testCoerceToDateTime_VariousTypes_Success() {
        // Valid cases
        DateTime testDateTime = DateTime.newInstance(2023, 1, 1, 12, 0, 0);
        System.assertEquals(null, TypeCoercionService.coerceToDateTime(null, 'Field'));

        DateTime result = TypeCoercionService.coerceToDateTime(testDateTime, 'Field');
        System.assertEquals(testDateTime.date(), result.date());

        // String datetime
        DateTime resultFromString = TypeCoercionService.coerceToDateTime('2023-01-01 12:00:00', 'Field');
        System.assertNotEquals(null, resultFromString);
    }

    // ===================================================================================
    // SPECIAL TYPE COERCION TESTS
    // ===================================================================================

    @IsTest
    static void testCoerceToBlob_ValidAndInvalid() {
        // Valid cases
        Blob testBlob = Blob.valueOf('test data');
        System.assertEquals(null, TypeCoercionService.coerceToBlob(null, 'Field'));
        System.assertEquals(testBlob, TypeCoercionService.coerceToBlob(testBlob, 'Field'));

        // Base64 string
        String base64 = EncodingUtil.base64Encode(Blob.valueOf('test data'));
        Blob result = TypeCoercionService.coerceToBlob(base64, 'Field');
        System.assertEquals('test data', result.toString());

        // Invalid cases
        try {
            TypeCoercionService.coerceToBlob('invalid base64!@#', 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid Base64'));
        }
    }

    @IsTest
    static void testCoerceToEmailString_ValidAndInvalid() {
        // Valid cases
        System.assertEquals(null, TypeCoercionService.coerceToEmailString(null, 'Field'));
        System.assertEquals('test@example.com', TypeCoercionService.coerceToEmailString('test@example.com', 'Field'));
        System.assertEquals('user@domain.co.uk', TypeCoercionService.coerceToEmailString('user@domain.co.uk', 'Field'));

        // Invalid cases
        try {
            TypeCoercionService.coerceToEmailString('invalid.email', 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid email format'));
        }
    }

    @IsTest
    static void testCoerceToUrlString_ValidAndInvalid() {
        // Valid cases
        System.assertEquals(null, TypeCoercionService.coerceToUrlString(null, 'Field'));
        System.assertEquals('http://example.com', TypeCoercionService.coerceToUrlString('http://example.com', 'Field'));
        System.assertEquals('https://api.example.com', TypeCoercionService.coerceToUrlString('https://api.example.com', 'Field'));

        // Invalid cases
        try {
            TypeCoercionService.coerceToUrlString('www.example.com', 'Field');
            System.assert(false, 'Should throw exception');
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.assert(e.getMessage().contains('Invalid URL format'));
        }
    }

    // ===================================================================================
    // SOBJECT COERCION TESTS
    // ===================================================================================

    @IsTest
    static void testCoerceArgumentTypesForSObject_ValidArgs_Success() {
        // Given: Valid arguments
        Map<String, Object> args = new Map<String, Object>{
            'Name' => 'Test Account',
            'NumberOfEmployees' => '100',
            'AnnualRevenue' => '1000000.50'
        };

        // When: Coercing
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            args,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        // Then: Types should be coerced
        System.assertNotEquals(null, result);
        System.assertEquals('Test Account', result.get('Name'));
        System.assertEquals(100, result.get('NumberOfEmployees'));
        System.assertEquals(1000000.50, result.get('AnnualRevenue'));
    }

    @IsTest
    static void testCoerceArgumentTypesForSObject_NullArgs_ReturnsEmpty() {
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            null,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void testCoerceArgumentTypesForSObject_NonExistentField_Skips() {
        // Given: Args with non-existent field
        Map<String, Object> args = new Map<String, Object>{
            'Name' => 'Test',
            'NonExistentField__c' => 'Value'
        };

        // When: Coercing
        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(
            args,
            Account.SObjectType,
            AccessType.CREATABLE
        );
        Test.stopTest();

        // Then: Should skip non-existent field
        System.assertEquals(1, result.size());
        System.assertEquals('Test', result.get('Name'));
        System.assertEquals(false, result.containsKey('NonExistentField__c'));
    }

    // ===================================================================================
    // NOTE: SCHEMA-BASED COERCION TESTS REMOVED
    // ===================================================================================
    // The following methods were removed during the DTO refactoring as they are no longer needed:
    // - coerceValueByJsonSchema
    // - coerceObjectBySchema
    // - coerceArrayBySchema
    //
    // These methods have been replaced with the Two-Pass Hybrid Deserialization Pattern
    // where DTOs are manually populated from untyped maps, and TypeCoercionService
    // is only used for SObject field-level type coercion via coerceArgumentTypesForSObject.

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testTypeCoercionException_Constructor() {
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
}
