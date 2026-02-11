/**
 * @description Tests for ActionConfigUtils parameter extraction helpers.
 * Covers both success and error paths for all required/optional extraction methods.
 */
@IsTest
private class ActionConfigUtilsTest {
    // ========== getRequiredString ==========

    @IsTest
    static void testRequiredString_ValidValue_ReturnsString() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => 'Alice' };
        System.assertEquals('Alice', ActionConfigUtils.getRequiredString(params, 'name'));
    }

    @IsTest
    static void testRequiredString_NumericValue_CoercesToString() {
        Map<String, Object> params = new Map<String, Object>{ 'count' => 42 };
        System.assertEquals('42', ActionConfigUtils.getRequiredString(params, 'count'));
    }

    @IsTest
    static void testRequiredString_BlankValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => '   ' };
        try {
            ActionConfigUtils.getRequiredString(params, 'name');
            System.assert(false, 'Should throw for blank value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be blank'), 'Message should mention blank');
        }
    }

    @IsTest
    static void testRequiredString_NullParams_Throws() {
        try {
            ActionConfigUtils.getRequiredString(null, 'name');
            System.assert(false, 'Should throw for null params');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('name'), 'Message should mention the key');
        }
    }

    @IsTest
    static void testRequiredString_MissingKey_Throws() {
        try {
            ActionConfigUtils.getRequiredString(new Map<String, Object>(), 'name');
            System.assert(false, 'Should throw for missing key');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
        }
    }

    @IsTest
    static void testRequiredString_NullValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => null };
        try {
            ActionConfigUtils.getRequiredString(params, 'name');
            System.assert(false, 'Should throw for null value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
        }
    }

    // ========== getOptionalString ==========

    @IsTest
    static void testOptionalString_MissingAndCoercion() {
        Map<String, Object> params = new Map<String, Object>{ 'blank' => '   ', 'num' => 42 };

        System.assertEquals(null, ActionConfigUtils.getOptionalString(null, 'missing'), 'Null params should return null');
        System.assertEquals(null, ActionConfigUtils.getOptionalString(new Map<String, Object>(), 'missing'), 'Missing key should return null');
        System.assertEquals('   ', ActionConfigUtils.getOptionalString(params, 'blank'), 'Blank value should be returned as-is');
        System.assertEquals('42', ActionConfigUtils.getOptionalString(params, 'num'), 'Non-string values should be coerced to string');
    }

    @IsTest
    static void testOptionalString_NullValue_ReturnsNull() {
        Map<String, Object> params = new Map<String, Object>{ 'key' => null };
        System.assertEquals(null, ActionConfigUtils.getOptionalString(params, 'key'), 'Null value should return null');
    }

    // ========== getRequiredBoolean ==========

    @IsTest
    static void testRequiredBoolean_ValidStringTrue_ReturnsTrue() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => 'true' };
        System.assertEquals(true, ActionConfigUtils.getRequiredBoolean(params, 'flag'));
    }

    @IsTest
    static void testRequiredBoolean_ValidBooleanFalse_ReturnsFalse() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => false };
        System.assertEquals(false, ActionConfigUtils.getRequiredBoolean(params, 'flag'));
    }

    @IsTest
    static void testRequiredBoolean_NullParams_Throws() {
        try {
            ActionConfigUtils.getRequiredBoolean(null, 'flag');
            System.assert(false, 'Should throw for null params');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
        }
    }

    @IsTest
    static void testRequiredBoolean_MissingKey_Throws() {
        try {
            ActionConfigUtils.getRequiredBoolean(new Map<String, Object>(), 'flag');
            System.assert(false, 'Should throw for missing key');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('flag'), 'Message should mention the key');
        }
    }

    @IsTest
    static void testRequiredBoolean_NullValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => null };
        try {
            ActionConfigUtils.getRequiredBoolean(params, 'flag');
            System.assert(false, 'Should throw for null value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
        }
    }

    @IsTest
    static void testRequiredBoolean_InvalidStringValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => 'maybe' };
        try {
            ActionConfigUtils.getRequiredBoolean(params, 'flag');
            System.assert(false, 'Should throw for non-boolean string');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid value'), 'Should indicate invalid value');
        }
    }

    // ========== getOptionalBoolean ==========

    @IsTest
    static void testOptionalBoolean_NullParams_ReturnsDefault() {
        System.assertEquals(true, ActionConfigUtils.getOptionalBoolean(null, 'flag', true), 'Null params should return default');
    }

    @IsTest
    static void testOptionalBoolean_MissingKey_ReturnsDefault() {
        System.assertEquals(false, ActionConfigUtils.getOptionalBoolean(new Map<String, Object>(), 'flag', false), 'Missing key should return default');
    }

    @IsTest
    static void testOptionalBoolean_NullValue_ReturnsDefault() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => null };
        System.assertEquals(true, ActionConfigUtils.getOptionalBoolean(params, 'flag', true), 'Null value should return default');
    }

    @IsTest
    static void testOptionalBoolean_InvalidValue_ReturnsDefault() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => 'maybe' };
        System.assertEquals(true, ActionConfigUtils.getOptionalBoolean(params, 'flag', true), 'Invalid value should return default');
    }

    @IsTest
    static void testOptionalBoolean_ValidValue_ReturnsBoolean() {
        Map<String, Object> params = new Map<String, Object>{ 'flag' => 'false' };
        System.assertEquals(false, ActionConfigUtils.getOptionalBoolean(params, 'flag', true), 'Valid value should override default');
    }

    // ========== getRequiredId ==========

    @IsTest
    static void testRequiredId_ValidId_ReturnsId() {
        Account account = new Account(Name = 'Test');
        insert account;

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => account.Id };
        Id result = ActionConfigUtils.getRequiredId(params, 'recordId', Schema.Account.SObjectType);
        System.assertEquals(account.Id, result);
    }

    @IsTest
    static void testRequiredId_NullParams_Throws() {
        try {
            ActionConfigUtils.getRequiredId(null, 'recordId', null);
            System.assert(false, 'Should throw for null params');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
            System.assert(e.getMessage().contains('Salesforce ID'), 'Should mention ID type');
        }
    }

    @IsTest
    static void testRequiredId_MissingKey_Throws() {
        try {
            ActionConfigUtils.getRequiredId(new Map<String, Object>(), 'recordId', null);
            System.assert(false, 'Should throw for missing key');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('recordId'), 'Message should mention the key');
        }
    }

    @IsTest
    static void testRequiredId_NullValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => null };
        try {
            ActionConfigUtils.getRequiredId(params, 'recordId', null);
            System.assert(false, 'Should throw for null value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'), 'Should indicate missing');
        }
    }

    @IsTest
    static void testRequiredId_InvalidFormat_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => 'not-a-valid-id' };
        try {
            ActionConfigUtils.getRequiredId(params, 'recordId', null);
            System.assert(false, 'Should throw for invalid ID format');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid value'), 'Should indicate invalid value');
        }
    }

    @IsTest
    static void testRequiredId_TypeMismatch_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => UserInfo.getUserId() };
        try {
            ActionConfigUtils.getRequiredId(params, 'recordId', Schema.Account.SObjectType);
            System.assert(false, 'Should throw for type mismatch');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid object type'), 'Should mention type mismatch');
            System.assert(e.getMessage().contains('Account'), 'Should mention required type');
        }
    }

    @IsTest
    static void testRequiredId_NoObjectTypeCheck_ReturnsAnyId() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => UserInfo.getUserId() };
        Id result = ActionConfigUtils.getRequiredId(params, 'recordId', null);
        System.assertEquals(UserInfo.getUserId(), result, 'Without type check, any valid ID should be accepted');
    }

    // ========== getOptionalId ==========

    @IsTest
    static void testOptionalId_NullParams_ReturnsNull() {
        System.assertEquals(null, ActionConfigUtils.getOptionalId(null, 'recordId', null), 'Null params should return null');
    }

    @IsTest
    static void testOptionalId_MissingKey_ReturnsNull() {
        System.assertEquals(null, ActionConfigUtils.getOptionalId(new Map<String, Object>(), 'recordId', null), 'Missing key should return null');
    }

    @IsTest
    static void testOptionalId_NullValue_ReturnsNull() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => null };
        System.assertEquals(null, ActionConfigUtils.getOptionalId(params, 'recordId', null), 'Null value should return null');
    }

    @IsTest
    static void testOptionalId_InvalidFormat_ReturnsNull() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => 'not-an-id' };
        Id result = ActionConfigUtils.getOptionalId(params, 'recordId', null);
        System.assertEquals(null, result, 'Invalid format should return null');
    }

    @IsTest
    static void testOptionalId_TypeMismatch_ReturnsNull() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => UserInfo.getUserId() };
        Id result = ActionConfigUtils.getOptionalId(params, 'recordId', Schema.Account.SObjectType);
        System.assertEquals(null, result, 'Type mismatch should return null');
    }

    @IsTest
    static void testOptionalId_ValidId_ReturnsId() {
        Account account = new Account(Name = 'Test');
        insert account;

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => account.Id };
        Id result = ActionConfigUtils.getOptionalId(params, 'recordId', Schema.Account.SObjectType);
        System.assertEquals(account.Id, result, 'Valid ID with matching type should return the ID');
    }

    @IsTest
    static void testOptionalId_ValidIdNoTypeCheck_ReturnsId() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => UserInfo.getUserId() };
        Id result = ActionConfigUtils.getOptionalId(params, 'recordId', null);
        System.assertEquals(UserInfo.getUserId(), result, 'Without type check, valid ID should be returned');
    }

    // ========== getOptionalInteger ==========

    @IsTest
    static void testOptionalInteger_NullParams_ReturnsDefault() {
        System.assertEquals(10, ActionConfigUtils.getOptionalInteger(null, 'count', 10), 'Null params should return default');
    }

    @IsTest
    static void testOptionalInteger_MissingKey_ReturnsDefault() {
        System.assertEquals(5, ActionConfigUtils.getOptionalInteger(new Map<String, Object>(), 'count', 5), 'Missing key should return default');
    }

    @IsTest
    static void testOptionalInteger_NullValue_ReturnsDefault() {
        Map<String, Object> params = new Map<String, Object>{ 'count' => null };
        System.assertEquals(7, ActionConfigUtils.getOptionalInteger(params, 'count', 7), 'Null value should return default');
    }

    @IsTest
    static void testOptionalInteger_InvalidValue_ReturnsDefault() {
        Map<String, Object> params = new Map<String, Object>{ 'count' => 'not-a-number' };
        System.assertEquals(3, ActionConfigUtils.getOptionalInteger(params, 'count', 3), 'Invalid value should return default');
    }

    @IsTest
    static void testOptionalInteger_ValidStringNumber_ReturnsInteger() {
        Map<String, Object> params = new Map<String, Object>{ 'count' => '42' };
        System.assertEquals(42, ActionConfigUtils.getOptionalInteger(params, 'count', 0), 'String number should be coerced');
    }

    @IsTest
    static void testOptionalInteger_ValidInteger_ReturnsValue() {
        Map<String, Object> params = new Map<String, Object>{ 'count' => 99 };
        System.assertEquals(99, ActionConfigUtils.getOptionalInteger(params, 'count', 0), 'Integer value should be returned');
    }

    // ========== getRequiredStringList ==========

    @IsTest
    static void testRequiredStringList_ListOfObjects_CoercesToStrings() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<Object>{ 1, 'two', null, true } };
        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'items', false);
        System.assertEquals(3, result.size(), 'Should coerce non-nulls and skip nulls');
        System.assertEquals('1', result[0]);
        System.assertEquals('two', result[1]);
        System.assertEquals('true', result[2]);
    }

    @IsTest
    static void testRequiredStringList_SingleString_WrapsInList() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => 'solo' };
        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'items', false);
        System.assertEquals(1, result.size());
        System.assertEquals('solo', result[0]);
    }

    @IsTest
    static void testRequiredStringList_NullParams_Throws() {
        try {
            ActionConfigUtils.getRequiredStringList(null, 'items', false);
            System.assert(false, 'Should throw for null params');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'));
        }
    }

    @IsTest
    static void testRequiredStringList_MissingKey_Throws() {
        try {
            ActionConfigUtils.getRequiredStringList(new Map<String, Object>(), 'items', false);
            System.assert(false, 'Should throw for missing key');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('items'));
        }
    }

    @IsTest
    static void testRequiredStringList_NullValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => null };
        try {
            ActionConfigUtils.getRequiredStringList(params, 'items', false);
            System.assert(false, 'Should throw for null value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'));
        }
    }

    @IsTest
    static void testRequiredStringList_InvalidType_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new Map<String, Object>{ 'x' => 'y' } };
        try {
            ActionConfigUtils.getRequiredStringList(params, 'items', false);
            System.assert(false, 'Should throw for invalid type');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid type') || e.getMessage().contains('Expected List<String>'));
        }
    }

    @IsTest
    static void testRequiredStringList_EmptyWithRequireNonEmpty_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<Object>() };
        try {
            ActionConfigUtils.getRequiredStringList(params, 'items', true);
            System.assert(false, 'Should throw for empty list with requireNonEmpty');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be empty'), 'Should mention non-empty requirement');
        }
    }

    @IsTest
    static void testRequiredStringList_AllNullItems_RequireNonEmpty_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<Object>{ null, null } };
        try {
            ActionConfigUtils.getRequiredStringList(params, 'items', true);
            System.assert(false, 'Should throw when all items are null and requireNonEmpty');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be empty'));
        }
    }

    @IsTest
    static void testRequiredStringList_EmptyWithoutRequireNonEmpty_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<Object>() };
        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'items', false);
        System.assertEquals(0, result.size(), 'Should return empty list when not requiring non-empty');
    }

    // ========== getOptionalStringList ==========

    @IsTest
    static void testOptionalStringList_NullParams_ReturnsEmpty() {
        List<String> result = ActionConfigUtils.getOptionalStringList(null, 'items');
        System.assertEquals(0, result.size(), 'Null params should return empty list');
    }

    @IsTest
    static void testOptionalStringList_MissingKey_ReturnsEmpty() {
        List<String> result = ActionConfigUtils.getOptionalStringList(new Map<String, Object>(), 'items');
        System.assertEquals(0, result.size(), 'Missing key should return empty list');
    }

    @IsTest
    static void testOptionalStringList_NullValue_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => null };
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'items');
        System.assertEquals(0, result.size(), 'Null value should return empty list');
    }

    @IsTest
    static void testOptionalStringList_ListOfObjects_CoercesAndSkipsNull() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<Object>{ 'alpha', 2, null } };
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'items');
        System.assertEquals(2, result.size(), 'Should skip nulls');
        System.assertEquals('alpha', result[0]);
        System.assertEquals('2', result[1]);
    }

    @IsTest
    static void testOptionalStringList_ListOfStrings_ReturnedAsIs() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => new List<String>{ 'x', 'y' } };
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'items');
        System.assertEquals(2, result.size());
    }

    @IsTest
    static void testOptionalStringList_SingleString_WrapsInList() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => 'solo' };
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'items');
        System.assertEquals(1, result.size());
        System.assertEquals('solo', result[0]);
    }

    @IsTest
    static void testOptionalStringList_UnexpectedType_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'items' => 42 };
        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'items');
        System.assertEquals(0, result.size(), 'Unexpected type should return empty list');
    }

    // ========== getRequiredMap ==========

    @IsTest
    static void testRequiredMap_ValidMap_ReturnsMap() {
        Map<String, Object> mapData = new Map<String, Object>{ 'k' => 'v' };
        Map<String, Object> params = new Map<String, Object>{ 'data' => mapData };

        Map<String, Object> result = ActionConfigUtils.getRequiredMap(params, 'data', false);
        System.assertEquals('v', result.get('k'));
    }

    @IsTest
    static void testRequiredMap_NullParams_Throws() {
        try {
            ActionConfigUtils.getRequiredMap(null, 'data', false);
            System.assert(false, 'Should throw for null params');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'));
        }
    }

    @IsTest
    static void testRequiredMap_MissingKey_Throws() {
        try {
            ActionConfigUtils.getRequiredMap(new Map<String, Object>(), 'data', false);
            System.assert(false, 'Should throw for missing key');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('data'));
        }
    }

    @IsTest
    static void testRequiredMap_NullValue_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => null };
        try {
            ActionConfigUtils.getRequiredMap(params, 'data', false);
            System.assert(false, 'Should throw for null value');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Missing required parameter'));
        }
    }

    @IsTest
    static void testRequiredMap_NonMapType_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => 'not a map' };
        try {
            ActionConfigUtils.getRequiredMap(params, 'data', false);
            System.assert(false, 'Should throw for non-map type');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('Invalid type') || e.getMessage().contains('Expected Map'));
        }
    }

    @IsTest
    static void testRequiredMap_EmptyWithRequireNonEmpty_Throws() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => new Map<String, Object>() };
        try {
            ActionConfigUtils.getRequiredMap(params, 'data', true);
            System.assert(false, 'Should throw for empty map with requireNonEmpty');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be empty'));
        }
    }

    @IsTest
    static void testRequiredMap_EmptyWithoutRequireNonEmpty_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => new Map<String, Object>() };
        Map<String, Object> result = ActionConfigUtils.getRequiredMap(params, 'data', false);
        System.assertEquals(0, result.size(), 'Should return empty map when not requiring non-empty');
    }

    // ========== getOptionalMap ==========

    @IsTest
    static void testOptionalMap_NullParams_ReturnsEmpty() {
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(null, 'data');
        System.assertEquals(0, result.size(), 'Null params should return empty map');
    }

    @IsTest
    static void testOptionalMap_MissingKey_ReturnsEmpty() {
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(new Map<String, Object>(), 'data');
        System.assertEquals(0, result.size(), 'Missing key should return empty map');
    }

    @IsTest
    static void testOptionalMap_NullValue_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => null };
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'data');
        System.assertEquals(0, result.size(), 'Null value should return empty map');
    }

    @IsTest
    static void testOptionalMap_InvalidType_ReturnsEmpty() {
        Map<String, Object> params = new Map<String, Object>{ 'data' => 'not a map' };
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'data');
        System.assertEquals(0, result.size(), 'Invalid type should return empty map');
    }

    @IsTest
    static void testOptionalMap_ValidMap_ReturnsMap() {
        Map<String, Object> mapData = new Map<String, Object>{ 'key' => 'val' };
        Map<String, Object> params = new Map<String, Object>{ 'data' => mapData };
        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'data');
        System.assertEquals('val', result.get('key'));
    }
}
