/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Comprehensive test class for ActionConfigUtils. Tests all required and optional parameter extraction
 * methods with various valid inputs, edge cases, type mismatches, and error scenarios.
 *
 * Coverage:
 *   - String extraction (required/optional)
 *   - Id extraction with optional type validation (required/optional)
 *   - Boolean extraction (required/optional)
 *   - List<String> extraction with optional non-empty validation (required/optional)
 *   - Map<String, Object> extraction with optional non-empty validation (required/optional)
 *   - Integer extraction (optional)
 *   - Null/missing parameter handling
 *   - Type coercion and validation error handling
 */
@IsTest
private class ActionConfigUtilsTest {
    // ============================================================================
    // --- Test Data Setup ---
    // ============================================================================

    @TestSetup
    static void makeData() {
        // Create test data that can be used for ID validation
        Account testAccount = new Account(Name = 'Test Account');
        insert testAccount;
    }

    // ============================================================================
    // --- getRequiredString Tests ---
    // ============================================================================

    @IsTest
    static void testGetRequiredString_Success() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => 'John Doe' };

        String result = ActionConfigUtils.getRequiredString(params, 'name');

        Assert.areEqual('John Doe', result, 'Should return the string value');
    }

    @IsTest
    static void testGetRequiredString_MissingKey() {
        Map<String, Object> params = new Map<String, Object>();

        try {
            ActionConfigUtils.getRequiredString(params, 'name');
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_NullValue() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => null };

        try {
            ActionConfigUtils.getRequiredString(params, 'name');
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredString_BlankValue() {
        Map<String, Object> params = new Map<String, Object>{ 'name' => '   ' };

        try {
            ActionConfigUtils.getRequiredString(params, 'name');
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('cannot be blank'), 'Should indicate blank value');
        }
    }

    @IsTest
    static void testGetRequiredString_NumericValue() {
        Map<String, Object> params = new Map<String, Object>{ 'age' => 25 };

        String result = ActionConfigUtils.getRequiredString(params, 'age');

        Assert.areEqual('25', result, 'Should coerce numeric to string');
    }

    // ============================================================================
    // --- getOptionalString Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalString_Success() {
        Map<String, Object> params = new Map<String, Object>{ 'description' => 'Test description' };

        String result = ActionConfigUtils.getOptionalString(params, 'description');

        Assert.areEqual('Test description', result, 'Should return the string value');
    }

    @IsTest
    static void testGetOptionalString_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        String result = ActionConfigUtils.getOptionalString(params, 'description');

        Assert.isNull(result, 'Should return null for missing key');
    }

    @IsTest
    static void testGetOptionalString_NullValue() {
        Map<String, Object> params = new Map<String, Object>{ 'description' => null };

        String result = ActionConfigUtils.getOptionalString(params, 'description');

        Assert.isNull(result, 'Should return null for null value');
    }

    @IsTest
    static void testGetOptionalString_BlankValue() {
        Map<String, Object> params = new Map<String, Object>{ 'description' => '' };

        String result = ActionConfigUtils.getOptionalString(params, 'description');

        Assert.areEqual('', result, 'Should return blank string (caller decides if valid)');
    }

    // ============================================================================
    // --- getRequiredId Tests ---
    // ============================================================================

    @IsTest
    static void testGetRequiredId_Success() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'accountId' => acc.Id };

        Id result = ActionConfigUtils.getRequiredId(params, 'accountId', null);

        Assert.areEqual(acc.Id, result, 'Should return the ID value');
    }

    @IsTest
    static void testGetRequiredId_WithTypeValidation_Success() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'accountId' => acc.Id };

        Id result = ActionConfigUtils.getRequiredId(params, 'accountId', Account.SObjectType);

        Assert.areEqual(acc.Id, result, 'Should return the ID when type matches');
    }

    @IsTest
    static void testGetRequiredId_WithTypeValidation_TypeMismatch() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'contactId' => acc.Id };

        try {
            ActionConfigUtils.getRequiredId(params, 'contactId', Contact.SObjectType);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Invalid object type'), 'Should indicate type mismatch');
        }
    }

    @IsTest
    static void testGetRequiredId_MissingKey() {
        Map<String, Object> params = new Map<String, Object>();

        try {
            ActionConfigUtils.getRequiredId(params, 'recordId', null);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredId_InvalidFormat() {
        Map<String, Object> params = new Map<String, Object>{ 'recordId' => 'not-an-id' };

        try {
            ActionConfigUtils.getRequiredId(params, 'recordId', null);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Invalid value'), 'Should indicate invalid format');
        }
    }

    @IsTest
    static void testGetRequiredId_StringIdFormat() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'accountId' => String.valueOf(acc.Id) };

        Id result = ActionConfigUtils.getRequiredId(params, 'accountId', Account.SObjectType);

        Assert.areEqual(acc.Id, result, 'Should parse string ID format');
    }

    // ============================================================================
    // --- getOptionalId Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalId_Success() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'accountId' => acc.Id };

        Id result = ActionConfigUtils.getOptionalId(params, 'accountId', null);

        Assert.areEqual(acc.Id, result, 'Should return the ID value');
    }

    @IsTest
    static void testGetOptionalId_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        Id result = ActionConfigUtils.getOptionalId(params, 'accountId', null);

        Assert.isNull(result, 'Should return null for missing key');
    }

    @IsTest
    static void testGetOptionalId_InvalidFormat() {
        Map<String, Object> params = new Map<String, Object>{ 'accountId' => 'invalid-id' };

        Id result = ActionConfigUtils.getOptionalId(params, 'accountId', null);

        Assert.isNull(result, 'Should return null for invalid format');
    }

    @IsTest
    static void testGetOptionalId_TypeMismatch() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'contactId' => acc.Id };

        Id result = ActionConfigUtils.getOptionalId(params, 'contactId', Contact.SObjectType);

        Assert.isNull(result, 'Should return null for type mismatch');
    }

    // ============================================================================
    // --- getRequiredBoolean Tests ---
    // ============================================================================

    @IsTest
    static void testGetRequiredBoolean_TrueValue() {
        Map<String, Object> params = new Map<String, Object>{ 'isActive' => true };

        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'isActive');

        Assert.isTrue(result, 'Should return true');
    }

    @IsTest
    static void testGetRequiredBoolean_FalseValue() {
        Map<String, Object> params = new Map<String, Object>{ 'isActive' => false };

        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'isActive');

        Assert.isFalse(result, 'Should return false');
    }

    @IsTest
    static void testGetRequiredBoolean_StringTrue() {
        Map<String, Object> params = new Map<String, Object>{ 'isActive' => 'true' };

        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'isActive');

        Assert.isTrue(result, 'Should parse string "true"');
    }

    @IsTest
    static void testGetRequiredBoolean_StringFalse() {
        Map<String, Object> params = new Map<String, Object>{ 'isActive' => 'false' };

        Boolean result = ActionConfigUtils.getRequiredBoolean(params, 'isActive');

        Assert.isFalse(result, 'Should parse string "false"');
    }

    @IsTest
    static void testGetRequiredBoolean_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        try {
            ActionConfigUtils.getRequiredBoolean(params, 'isActive');
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredBoolean_InvalidValue() {
        Map<String, Object> params = new Map<String, Object>{ 'isActive' => 'maybe' };

        try {
            ActionConfigUtils.getRequiredBoolean(params, 'isActive');
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Invalid value'), 'Should indicate invalid value');
        }
    }

    // ============================================================================
    // --- getOptionalBoolean Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalBoolean_Success() {
        Map<String, Object> params = new Map<String, Object>{ 'includeDetails' => true };

        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'includeDetails', false);

        Assert.isTrue(result, 'Should return the boolean value');
    }

    @IsTest
    static void testGetOptionalBoolean_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'includeDetails', true);

        Assert.isTrue(result, 'Should return default value for missing key');
    }

    @IsTest
    static void testGetOptionalBoolean_InvalidValue() {
        Map<String, Object> params = new Map<String, Object>{ 'includeDetails' => 'invalid' };

        Boolean result = ActionConfigUtils.getOptionalBoolean(params, 'includeDetails', false);

        Assert.isFalse(result, 'Should return default value for invalid value');
    }

    // ============================================================================
    // --- getRequiredStringList Tests ---
    // ============================================================================

    @IsTest
    static void testGetRequiredStringList_Success() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<String>{ 'Name', 'Email', 'Phone' }
        };

        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'fields', false);

        Assert.areEqual(3, result.size(), 'Should return list with 3 items');
        Assert.areEqual('Name', result[0], 'Should contain correct values');
    }

    @IsTest
    static void testGetRequiredStringList_ObjectList() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<Object>{ 'Name', 'Email', 123 }
        };

        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'fields', false);

        Assert.areEqual(3, result.size(), 'Should convert Object list to String list');
        Assert.areEqual('123', result[2], 'Should convert numbers to strings');
    }

    @IsTest
    static void testGetRequiredStringList_SingleString() {
        Map<String, Object> params = new Map<String, Object>{ 'fields' => 'Name' };

        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'fields', false);

        Assert.areEqual(1, result.size(), 'Should wrap single string in list');
        Assert.areEqual('Name', result[0], 'Should contain the string value');
    }

    @IsTest
    static void testGetRequiredStringList_RequireNonEmpty_Success() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<String>{ 'Name' }
        };

        List<String> result = ActionConfigUtils.getRequiredStringList(params, 'fields', true);

        Assert.areEqual(1, result.size(), 'Should return non-empty list');
    }

    @IsTest
    static void testGetRequiredStringList_RequireNonEmpty_Empty() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<String>()
        };

        try {
            ActionConfigUtils.getRequiredStringList(params, 'fields', true);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('cannot be empty'), 'Should indicate empty list');
        }
    }

    @IsTest
    static void testGetRequiredStringList_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        try {
            ActionConfigUtils.getRequiredStringList(params, 'fields', false);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredStringList_InvalidType() {
        Map<String, Object> params = new Map<String, Object>{ 'fields' => 123 };

        try {
            ActionConfigUtils.getRequiredStringList(params, 'fields', false);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Invalid type'), 'Should indicate invalid type');
        }
    }

    // ============================================================================
    // --- getOptionalStringList Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalStringList_Success() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<String>{ 'Name', 'Email' }
        };

        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'fields');

        Assert.areEqual(2, result.size(), 'Should return list with 2 items');
    }

    @IsTest
    static void testGetOptionalStringList_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'fields');

        Assert.isNotNull(result, 'Should return empty list');
        Assert.areEqual(0, result.size(), 'Should be empty');
    }

    @IsTest
    static void testGetOptionalStringList_InvalidType() {
        Map<String, Object> params = new Map<String, Object>{ 'fields' => 123 };

        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'fields');

        Assert.isNotNull(result, 'Should return empty list');
        Assert.areEqual(0, result.size(), 'Should be empty for invalid type');
    }

    @IsTest
    static void testGetOptionalStringList_ObjectList() {
        Map<String, Object> params = new Map<String, Object>{
            'fields' => new List<Object>{ 'Name', 123, null, 'Email' }
        };

        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'fields');

        Assert.areEqual(3, result.size(), 'Should skip null values');
        Assert.areEqual('123', result[1], 'Should convert numbers to strings');
    }

    @IsTest
    static void testGetOptionalStringList_SingleString() {
        Map<String, Object> params = new Map<String, Object>{ 'field' => 'Name' };

        List<String> result = ActionConfigUtils.getOptionalStringList(params, 'field');

        Assert.areEqual(1, result.size(), 'Should wrap single string in list');
    }

    // ============================================================================
    // --- getRequiredMap Tests ---
    // ============================================================================

    @IsTest
    static void testGetRequiredMap_Success() {
        Map<String, Object> innerMap = new Map<String, Object>{ 'Name' => 'John', 'Email' => 'john@test.com' };
        Map<String, Object> params = new Map<String, Object>{ 'filters' => innerMap };

        Map<String, Object> result = ActionConfigUtils.getRequiredMap(params, 'filters', false);

        Assert.areEqual(2, result.size(), 'Should return map with 2 items');
        Assert.areEqual('John', result.get('Name'), 'Should contain correct values');
    }

    @IsTest
    static void testGetRequiredMap_RequireNonEmpty_Success() {
        Map<String, Object> innerMap = new Map<String, Object>{ 'Name' => 'John' };
        Map<String, Object> params = new Map<String, Object>{ 'filters' => innerMap };

        Map<String, Object> result = ActionConfigUtils.getRequiredMap(params, 'filters', true);

        Assert.areEqual(1, result.size(), 'Should return non-empty map');
    }

    @IsTest
    static void testGetRequiredMap_RequireNonEmpty_Empty() {
        Map<String, Object> innerMap = new Map<String, Object>();
        Map<String, Object> params = new Map<String, Object>{ 'filters' => innerMap };

        try {
            ActionConfigUtils.getRequiredMap(params, 'filters', true);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('cannot be empty'), 'Should indicate empty map');
        }
    }

    @IsTest
    static void testGetRequiredMap_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        try {
            ActionConfigUtils.getRequiredMap(params, 'filters', false);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }

    @IsTest
    static void testGetRequiredMap_InvalidType() {
        Map<String, Object> params = new Map<String, Object>{ 'filters' => 'not-a-map' };

        try {
            ActionConfigUtils.getRequiredMap(params, 'filters', false);
            Assert.fail('Should have thrown ArgumentValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Invalid type'), 'Should indicate invalid type');
        }
    }

    // ============================================================================
    // --- getOptionalMap Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalMap_Success() {
        Map<String, Object> innerMap = new Map<String, Object>{ 'Name' => 'John' };
        Map<String, Object> params = new Map<String, Object>{ 'metadata' => innerMap };

        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'metadata');

        Assert.areEqual(1, result.size(), 'Should return the map');
        Assert.areEqual('John', result.get('Name'), 'Should contain correct value');
    }

    @IsTest
    static void testGetOptionalMap_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'metadata');

        Assert.isNotNull(result, 'Should return empty map');
        Assert.areEqual(0, result.size(), 'Should be empty');
    }

    @IsTest
    static void testGetOptionalMap_InvalidType() {
        Map<String, Object> params = new Map<String, Object>{ 'metadata' => 'not-a-map' };

        Map<String, Object> result = ActionConfigUtils.getOptionalMap(params, 'metadata');

        Assert.isNotNull(result, 'Should return empty map');
        Assert.areEqual(0, result.size(), 'Should be empty for invalid type');
    }

    // ============================================================================
    // --- getOptionalInteger Tests ---
    // ============================================================================

    @IsTest
    static void testGetOptionalInteger_Success() {
        Map<String, Object> params = new Map<String, Object>{ 'limit' => 100 };

        Integer result = ActionConfigUtils.getOptionalInteger(params, 'limit', 10);

        Assert.areEqual(100, result, 'Should return the integer value');
    }

    @IsTest
    static void testGetOptionalInteger_StringNumber() {
        Map<String, Object> params = new Map<String, Object>{ 'limit' => '50' };

        Integer result = ActionConfigUtils.getOptionalInteger(params, 'limit', 10);

        Assert.areEqual(50, result, 'Should parse string number');
    }

    @IsTest
    static void testGetOptionalInteger_Missing() {
        Map<String, Object> params = new Map<String, Object>();

        Integer result = ActionConfigUtils.getOptionalInteger(params, 'limit', 25);

        Assert.areEqual(25, result, 'Should return default value');
    }

    @IsTest
    static void testGetOptionalInteger_InvalidValue() {
        Map<String, Object> params = new Map<String, Object>{ 'limit' => 'invalid' };

        Integer result = ActionConfigUtils.getOptionalInteger(params, 'limit', 10);

        Assert.areEqual(10, result, 'Should return default value for invalid input');
    }

    @IsTest
    static void testGetOptionalInteger_NullValue() {
        Map<String, Object> params = new Map<String, Object>{ 'limit' => null };

        Integer result = ActionConfigUtils.getOptionalInteger(params, 'limit', 10);

        Assert.areEqual(10, result, 'Should return default value for null');
    }

    // ============================================================================
    // --- Edge Cases and Null Handling ---
    // ============================================================================

    @IsTest
    static void testNullParamsMap() {
        // Test that all methods handle null params map gracefully
        Assert.isNull(ActionConfigUtils.getOptionalString(null, 'key'), 'Optional string should return null');
        Assert.isNotNull(ActionConfigUtils.getOptionalStringList(null, 'key'), 'Optional list should return empty list');
        Assert.isNotNull(ActionConfigUtils.getOptionalMap(null, 'key'), 'Optional map should return empty map');
        Assert.areEqual(10, ActionConfigUtils.getOptionalInteger(null, 'key', 10), 'Optional integer should return default');
        Assert.areEqual(true, ActionConfigUtils.getOptionalBoolean(null, 'key', true), 'Optional boolean should return default');
        Assert.isNull(ActionConfigUtils.getOptionalId(null, 'key', null), 'Optional ID should return null');
    }

    @IsTest
    static void testNullParamsMap_Required() {
        // Test that required methods throw exceptions for null params map
        try {
            ActionConfigUtils.getRequiredString(null, 'key');
            Assert.fail('Should have thrown exception');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            Assert.isTrue(e.getMessage().contains('Missing required parameter'), 'Should indicate missing parameter');
        }
    }
}

