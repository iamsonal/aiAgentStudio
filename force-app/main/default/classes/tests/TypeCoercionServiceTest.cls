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
}
