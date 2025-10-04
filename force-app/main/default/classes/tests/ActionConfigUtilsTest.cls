@IsTest
private class ActionConfigUtilsTest {

    @IsTest
    static void testGetRequiredString_validString_returnsString() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'testValue' };

        // When
        String result = ActionConfigUtils.getRequiredString(params, 'testKey');

        // Then
        System.assertEquals('testValue', result, 'Should return the string value');
    }

    @IsTest
    static void testGetRequiredString_missingKey_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => 'testValue' };

        // When/Then
        try {
            ActionConfigUtils.getRequiredString(params, 'testKey');
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_nullValue_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => null };

        // When/Then
        try {
            ActionConfigUtils.getRequiredString(params, 'testKey');
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_blankString_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => '' };

        // When/Then
        try {
            ActionConfigUtils.getRequiredString(params, 'testKey');
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be blank'), 'Should indicate blank parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_whitespaceString_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => '   ' };

        // When/Then
        try {
            ActionConfigUtils.getRequiredString(params, 'testKey');
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be blank'), 'Should indicate blank parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_nonStringValue_returnsCoercedString() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 123 };

        // When
        String result = ActionConfigUtils.getRequiredString(params, 'testKey');

        // Then
        System.assertEquals('123', result, 'Should return the coerced string value');
    }

    @IsTest
    static void testGetOptionalString_validString_returnsString() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'testValue' };

        // When
        String result = ActionConfigUtils.getOptionalString(params, 'testKey');

        // Then
        System.assertEquals('testValue', result, 'Should return the string value');
    }

    @IsTest
    static void testGetOptionalString_missingKey_returnsNull() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => 'testValue' };

        // When
        String result = ActionConfigUtils.getOptionalString(params, 'testKey');

        // Then
        System.assertEquals(null, result, 'Should return null for missing key');
    }

    @IsTest
    static void testGetOptionalString_nullValue_returnsNull() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => null };

        // When
        String result = ActionConfigUtils.getOptionalString(params, 'testKey');

        // Then
        System.assertEquals(null, result, 'Should return null for null value');
    }

    @IsTest
    static void testGetOptionalString_nonStringValue_returnsCoercedString() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 123 };

        // When
        String result = ActionConfigUtils.getOptionalString(params, 'testKey');

        // Then
        System.assertEquals('123', result, 'Should return the coerced string value');
    }

    @IsTest
    static void testGetRequiredId_validId_returnsId() {
        // Given
        Id testId = '001000000000000AAA';
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testId };

        // When
        Id result = ActionConfigUtils.getRequiredId(params, 'testKey', null);

        // Then
        System.assertEquals(testId, result, 'Should return the Id value');
    }

    @IsTest
    static void testGetRequiredId_stringId_returnsId() {
        // Given
        Id testId = '001000000000000AAA';
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => '001000000000000AAA' };

        // When
        Id result = ActionConfigUtils.getRequiredId(params, 'testKey', null);

        // Then
        System.assertEquals(testId, result, 'Should return the coerced Id value');
    }

    @IsTest
    static void testGetRequiredId_missingKey_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => '001000000000000AAA' };

        // When/Then
        try {
            ActionConfigUtils.getRequiredId(params, 'testKey', null);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredId_invalidIdFormat_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'invalidId' };

        // When/Then
        try {
            ActionConfigUtils.getRequiredId(params, 'testKey', null);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid value for parameter'), 'Should indicate invalid value');
        }
    }

    @IsTest
    static void testGetRequiredId_withObjectType_validId_returnsId() {
        // Given
        Id testId = '001000000000000AAA'; // Account ID
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testId };

        // When
        Id result = ActionConfigUtils.getRequiredId(params, 'testKey', Account.SObjectType);

        // Then
        System.assertEquals(testId, result, 'Should return the Id value');
    }

    @IsTest
    static void testGetRequiredId_withObjectType_invalidObjectType_throwsException() {
        // Given
        Id testId = '005000000000000AAA'; // User ID, not Account ID
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testId };

        // When/Then
        try {
            ActionConfigUtils.getRequiredId(params, 'testKey', Account.SObjectType);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid object type'), 'Should indicate invalid object type');
        }
    }

    @IsTest
    static void testGetOptionalId_validId_returnsId() {
        // Given
        Id testId = '001000000000000AAA';
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testId };

        // When
        Id result = ActionConfigUtils.getOptionalId(params, 'testKey', null);

        // Then
        System.assertEquals(testId, result, 'Should return the Id value');
    }

    @IsTest
    static void testGetOptionalId_missingKey_returnsNull() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => '001000000000000AAA' };

        // When
        Id result = ActionConfigUtils.getOptionalId(params, 'testKey', null);

        // Then
        System.assertEquals(null, result, 'Should return null for missing key');
    }

    @IsTest
    static void testGetOptionalId_invalidIdFormat_returnsNull() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'invalidId' };

        // When
        Id result = ActionConfigUtils.getOptionalId(params, 'testKey', null);

        // Then
        System.assertEquals(null, result, 'Should return null for invalid Id format');
    }

    @IsTest
    static void testGetRequiredBoolean_validBoolean_returnsBoolean() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => true };

        // When
        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'testKey');

        // Then
        System.assertEquals(true, result, 'Should return the boolean value');
    }

    @IsTest
    static void testGetRequiredBoolean_stringBoolean_returnsBoolean() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'true' };

        // When
        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'testKey');

        // Then
        System.assertEquals(true, result, 'Should return the coerced boolean value');
    }

    @IsTest
    static void testGetRequiredBoolean_missingKey_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => true };

        // When/Then
        try {
            ActionConfigUtils.getRequiredBoolean(params, 'testKey');
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetOptionalBoolean_validBoolean_returnsBoolean() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => true };

        // When
        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'testKey', false);

        // Then
        System.assertEquals(true, result, 'Should return the boolean value');
    }

    @IsTest
    static void testGetOptionalBoolean_missingKey_returnsDefault() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => true };

        // When
        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'testKey', false);

        // Then
        System.assertEquals(false, result, 'Should return the default value for missing key');
    }

    @IsTest
    static void testGetOptionalBoolean_invalidValue_returnsDefault() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'invalid' };

        // When
        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'testKey', false);

        // Then
        System.assertEquals(false, result, 'Should return the default value for invalid value');
    }

    @IsTest
    static void testGetRequiredStringList_validList_returnsList() {
        // Given
        List<String> testList = new List<String>{ 'item1', 'item2', 'item3' };
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testList };

        // When
        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'testKey', false);

        // Then
        System.assertEquals(testList, result, 'Should return the list value');
    }

    @IsTest
    static void testGetRequiredStringList_missingKey_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => new List<String>{ 'item1' } };

        // When/Then
        try {
            ActionConfigUtils.getRequiredStringList(params, 'testKey', false);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredStringList_requireNonEmpty_emptyList_throwsException() {
        // Given
        List<String> testList = new List<String>();
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testList };

        // When/Then
        try {
            ActionConfigUtils.getRequiredStringList(params, 'testKey', true);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be empty'), 'Should indicate empty list');
        }
    }

    @IsTest
    static void testGetOptionalStringList_validList_returnsList() {
        // Given
        List<String> testList = new List<String>{ 'item1', 'item2', 'item3' };
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testList };

        // When
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'testKey');

        // Then
        System.assertEquals(testList, result, 'Should return the list value');
    }

    @IsTest
    static void testGetOptionalStringList_missingKey_returnsEmptyList() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => new List<String>{ 'item1' } };

        // When
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'testKey');

        // Then
        System.assertEquals(new List<String>(), result, 'Should return empty list for missing key');
    }

    @IsTest
    static void testGetRequiredMap_validMap_returnsMap() {
        // Given
        Map<String, Object> testMap = new Map<String, Object>{ 'key1' => 'value1', 'key2' => 'value2' };
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testMap };

        // When
        Map<String, Object> result = ActionConfigUtils.getRequiredMap(params, 'testKey', false);

        // Then
        System.assertEquals(testMap, result, 'Should return the map value');
    }

    @IsTest
    static void testGetRequiredMap_missingKey_throwsException() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => new Map<String, Object>{ 'key1' => 'value1' } };

        // When/Then
        try {
            ActionConfigUtils.getRequiredMap(params, 'testKey', false);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredMap_requireNonEmpty_emptyMap_throwsException() {
        // Given
        Map<String, Object> testMap = new Map<String, Object>();
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testMap };

        // When/Then
        try {
            ActionConfigUtils.getRequiredMap(params, 'testKey', true);
            System.assert(false, 'Expected ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be empty'), 'Should indicate empty map');
        }
    }

    @IsTest
    static void testGetOptionalMap_validMap_returnsMap() {
        // Given
        Map<String, Object> testMap = new Map<String, Object>{ 'key1' => 'value1', 'key2' => 'value2' };
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => testMap };

        // When
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'testKey');

        // Then
        System.assertEquals(testMap, result, 'Should return the map value');
    }

    @IsTest
    static void testGetOptionalMap_missingKey_returnsEmptyMap() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => new Map<String, Object>{ 'key1' => 'value1' } };

        // When
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'testKey');

        // Then
        System.assertEquals(new Map<String, Object>(), result, 'Should return empty map for missing key');
    }

    @IsTest
    static void testGetOptionalInteger_validInteger_returnsInteger() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 123 };

        // When
        Integer result = ActionConfigUtils.getOptionalInteger(params, 'testKey', 0);

        // Then
        System.assertEquals(123, result, 'Should return the integer value');
    }

    @IsTest
    static void testGetOptionalInteger_missingKey_returnsDefault() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'otherKey' => 123 };

        // When
        Integer result = ActionConfigUtils.getOptionalInteger(params, 'testKey', 0);

        // Then
        System.assertEquals(0, result, 'Should return the default value for missing key');
    }

    @IsTest
    static void testGetOptionalInteger_invalidValue_returnsDefault() {
        // Given
        Map<String, Object> params = new Map<String, Object>{ 'testKey' => 'invalid' };

        // When
        Integer result = ActionConfigUtils.getOptionalInteger(params, 'testKey', 0);

        // Then
        System.assertEquals(0, result, 'Should return the default value for invalid value');
    }

    @IsTest
    static void testArgumentValidationException_canBeThrown() {
        // When/Then
        try {
            throw new ActionConfigUtils.ArgumentValidationException('Test exception');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assertEquals('Test exception', e.getMessage(), 'Should preserve exception message');
        }
    }
}
