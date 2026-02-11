/**
 * @description Tests for Utils class covering schema and security utilities
 */
@IsTest
private class UtilsTest {
    // ===== Schema Utilities Tests =====

    @IsTest
    static void testGetSObjectType_ValidObjectName_ReturnsType() {
        Test.startTest();
        SObjectType accountType = Utils.getSObjectType('Account');
        Test.stopTest();

        System.assertNotEquals(null, accountType, 'Should return valid SObjectType for Account');
        System.assertEquals('Account', accountType.getDescribe().getName(), 'Should return Account SObjectType');
    }

    @IsTest
    static void testGetSObjectType_CaseInsensitive_ReturnsType() {
        Test.startTest();
        SObjectType accountType1 = Utils.getSObjectType('Account');
        SObjectType accountType2 = Utils.getSObjectType('ACCOUNT');
        SObjectType accountType3 = Utils.getSObjectType('account');
        Test.stopTest();

        System.assertEquals(accountType1, accountType2, 'Should handle case-insensitive lookup');
        System.assertEquals(accountType1, accountType3, 'Should handle case-insensitive lookup');
    }

    @IsTest
    static void testGetSObjectType_Caching_ReturnsSameInstance() {
        // Clear cache
        Utils.sObjectTypeCache.clear();

        Test.startTest();
        SObjectType firstCall = Utils.getSObjectType('Account');
        SObjectType secondCall = Utils.getSObjectType('Account');
        Test.stopTest();

        System.assertEquals(1, Utils.sObjectTypeCache.size(), 'Should cache the result');
        System.assertEquals(firstCall, secondCall, 'Should return cached instance');
    }

    @IsTest
    static void testGetSObjectType_BlankApiName_ReturnsNull() {
        Test.startTest();
        SObjectType result1 = Utils.getSObjectType('');
        SObjectType result2 = Utils.getSObjectType(null);
        Test.stopTest();

        System.assertEquals(null, result1, 'Should return null for blank API name');
        System.assertEquals(null, result2, 'Should return null for null API name');
    }

    @IsTest
    static void testGetSObjectType_InvalidObjectName_ReturnsNull() {
        Test.startTest();
        SObjectType result = Utils.getSObjectType('NonExistentObject__c');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for invalid object name');
    }

    @IsTest
    static void testGetObjectFields_ValidObject_ReturnsFields() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Map<String, SObjectField> fields = Utils.getObjectFields(accountType);
        Test.stopTest();

        System.assertNotEquals(null, fields, 'Should return map of fields');
        System.assert(fields.size() > 0, 'Should return non-empty field map');
        System.assert(fields.containsKey('name'), 'Should contain Name field (lowercase)');
        System.assert(fields.containsKey('id'), 'Should contain Id field (lowercase)');
    }

    @IsTest
    static void testGetObjectFields_NullSObjectType_ReturnsEmptyMap() {
        Test.startTest();
        Map<String, SObjectField> fields = Utils.getObjectFields(null);
        Test.stopTest();

        System.assertNotEquals(null, fields, 'Should return non-null map');
        System.assertEquals(0, fields.size(), 'Should return empty map for null SObjectType');
    }

    @IsTest
    static void testGetObjectFields_Caching_ReturnsSameMap() {
        Utils.fieldDescribeCache.clear();
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Map<String, SObjectField> firstCall = Utils.getObjectFields(accountType);
        Map<String, SObjectField> secondCall = Utils.getObjectFields(accountType);
        Test.stopTest();

        System.assertEquals(firstCall, secondCall, 'Should return cached field map');
        System.assertEquals(1, Utils.fieldDescribeCache.size(), 'Should cache result');
    }

    @IsTest
    static void testGetFieldToken_ValidField_ReturnsToken() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        SObjectField nameField = Utils.getFieldToken(accountType, 'Name');
        Test.stopTest();

        System.assertNotEquals(null, nameField, 'Should return valid field token');
        System.assertEquals('Name', nameField.getDescribe().getName(), 'Should return Name field token');
    }

    @IsTest
    static void testGetFieldToken_CaseInsensitive_ReturnsToken() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        SObjectField field1 = Utils.getFieldToken(accountType, 'Name');
        SObjectField field2 = Utils.getFieldToken(accountType, 'NAME');
        SObjectField field3 = Utils.getFieldToken(accountType, 'name');
        Test.stopTest();

        System.assertEquals(field1, field2, 'Should handle case-insensitive field lookup');
        System.assertEquals(field1, field3, 'Should handle case-insensitive field lookup');
    }

    @IsTest
    static void testGetFieldToken_NullParameters_ReturnsNull() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        SObjectField result1 = Utils.getFieldToken(null, 'Name');
        SObjectField result2 = Utils.getFieldToken(accountType, null);
        SObjectField result3 = Utils.getFieldToken(accountType, '');
        Test.stopTest();

        System.assertEquals(null, result1, 'Should return null for null SObjectType');
        System.assertEquals(null, result2, 'Should return null for null field name');
        System.assertEquals(null, result3, 'Should return null for blank field name');
    }

    @IsTest
    static void testGetFieldToken_InvalidFieldName_ReturnsNull() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        SObjectField result = Utils.getFieldToken(accountType, 'NonExistentField__c');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for invalid field name');
    }

    @IsTest
    static void testGetDescribe_ValidObject_ReturnsDescribe() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        DescribeSObjectResult describe = Utils.getDescribe(accountType);
        Test.stopTest();

        System.assertNotEquals(null, describe, 'Should return valid describe result');
        System.assertEquals('Account', describe.getName(), 'Should return Account describe');
    }

    @IsTest
    static void testGetDescribe_NullSObjectType_ReturnsNull() {
        Test.startTest();
        DescribeSObjectResult result = Utils.getDescribe(null);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null SObjectType');
    }

    @IsTest
    static void testGetDescribe_Caching_ReturnsSameDescribe() {
        Utils.describeCache.clear();
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        DescribeSObjectResult firstCall = Utils.getDescribe(accountType);
        DescribeSObjectResult secondCall = Utils.getDescribe(accountType);
        Test.stopTest();

        System.assertEquals(firstCall, secondCall, 'Should return cached describe result');
        System.assertEquals(1, Utils.describeCache.size(), 'Should cache result');
    }

    // ===== Security Utilities Tests =====

    @IsTest
    static void testCheckObjectPermission_ReadableObject_Succeeds() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkObjectPermission(accountType, AccessType.READABLE);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown, 'Should not throw exception for readable object');
    }

    @IsTest
    static void testCheckObjectPermission_NullSObjectType_ThrowsException() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkObjectPermission(null, AccessType.READABLE);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('cannot be null'), 'Should indicate null SObjectType');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw exception for null SObjectType');
    }

    @IsTest
    static void testCheckObjectPermission_NullAccessType_ThrowsException() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkObjectPermission(accountType, null);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('AccessType cannot be null'), 'Should indicate null AccessType');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw exception for null AccessType');
    }

    @IsTest
    static void testCheckObjectPermission_CreatableAccess_ValidatesCorrectly() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        try {
            Utils.checkObjectPermission(accountType, AccessType.CREATABLE);
            System.assert(true, 'Should validate CREATABLE access');
        } catch (Utils.ActionSecurityException e) {
            // Expected if user doesn't have create permission
            System.assert(e.getMessage().contains('CREATE'), 'Should mention CREATE permission');
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckObjectPermission_UpdatableAccess_ValidatesCorrectly() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        try {
            Utils.checkObjectPermission(accountType, AccessType.UPDATABLE);
            System.assert(true, 'Should validate UPDATABLE access');
        } catch (Utils.ActionSecurityException e) {
            // Expected if user doesn't have update permission
            System.assert(e.getMessage().contains('UPDATE'), 'Should mention UPDATE permission');
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckFieldPermission_ReadableField_Succeeds() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkFieldPermission(fieldDescribe, AccessType.READABLE);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
        }
        Test.stopTest();

        System.assertEquals(false, exceptionThrown, 'Should not throw exception for readable field');
    }

    @IsTest
    static void testCheckFieldPermission_NullDescribeFieldResult_ThrowsException() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkFieldPermission(null, AccessType.READABLE);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('cannot be null'), 'Should indicate null DescribeFieldResult');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw exception for null DescribeFieldResult');
    }

    @IsTest
    static void testCheckFieldPermission_NullAccessType_ThrowsException() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            Utils.checkFieldPermission(fieldDescribe, null);
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Invalid AccessType'), 'Should indicate invalid AccessType');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw exception for null AccessType');
    }

    @IsTest
    static void testCheckFieldPermission_CreatableField_ValidatesCorrectly() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        try {
            Utils.checkFieldPermission(fieldDescribe, AccessType.CREATABLE);
            System.assert(true, 'Should validate CREATABLE field access');
        } catch (Utils.ActionSecurityException e) {
            // Expected if user doesn't have create permission on field
            System.assert(e.getMessage().contains('Permission denied'), 'Should indicate permission denied');
        }
        Test.stopTest();
    }

    @IsTest
    static void testCheckFieldPermission_UpdatableField_ValidatesCorrectly() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        try {
            Utils.checkFieldPermission(fieldDescribe, AccessType.UPDATABLE);
            System.assert(true, 'Should validate UPDATABLE field access');
        } catch (Utils.ActionSecurityException e) {
            // Expected if user doesn't have update permission on field
            System.assert(e.getMessage().contains('Permission denied'), 'Should indicate permission denied');
        }
        Test.stopTest();
    }

    @IsTest
    static void testHasFieldPermission_WithDescribeFieldResult_ReturnsBoolean() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        Boolean readable = Utils.hasFieldPermission(fieldDescribe, AccessType.READABLE);
        Boolean creatable = Utils.hasFieldPermission(fieldDescribe, AccessType.CREATABLE);
        Boolean updatable = Utils.hasFieldPermission(fieldDescribe, AccessType.UPDATABLE);
        Test.stopTest();

        System.assertNotEquals(null, readable, 'Should return boolean for readable check');
        System.assertNotEquals(null, creatable, 'Should return boolean for creatable check');
        System.assertNotEquals(null, updatable, 'Should return boolean for updatable check');
    }

    @IsTest
    static void testHasFieldPermission_NullDescribeFieldResult_ReturnsFalse() {
        Test.startTest();
        Boolean result = Utils.hasFieldPermission((Schema.DescribeFieldResult) null, AccessType.READABLE);
        Test.stopTest();

        System.assertEquals(false, result, 'Should return false for null DescribeFieldResult');
    }

    @IsTest
    static void testHasFieldPermission_InvalidAccessType_ReturnsFalse() {
        Schema.DescribeFieldResult fieldDescribe = Schema.Account.Name.getDescribe();

        Test.startTest();
        Boolean result = Utils.hasFieldPermission(fieldDescribe, null);
        Test.stopTest();

        System.assertEquals(false, result, 'Should return false for invalid AccessType');
    }

    @IsTest
    static void testHasFieldPermission_WithSObjectTypeAndFieldName_ReturnsBoolean() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Boolean result = Utils.hasFieldPermission(accountType, 'Name', AccessType.READABLE);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return boolean result');
    }

    @IsTest
    static void testHasFieldPermission_InvalidFieldName_ReturnsFalse() {
        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        Boolean result = Utils.hasFieldPermission(accountType, 'NonExistentField__c', AccessType.READABLE);
        Test.stopTest();

        System.assertEquals(false, result, 'Should return false for non-existent field');
    }

    @IsTest
    static void testHasFieldPermission_NullParameters_ReturnsFalse() {
        Test.startTest();
        Boolean result1 = Utils.hasFieldPermission(null, 'Name', AccessType.READABLE);
        Boolean result2 = Utils.hasFieldPermission(Schema.Account.SObjectType, null, AccessType.READABLE);
        Test.stopTest();

        System.assertEquals(false, result1, 'Should return false for null SObjectType');
        System.assertEquals(false, result2, 'Should return false for null field name');
    }

    @IsTest
    static void testActionSecurityException_CanBeThrown() {
        Test.startTest();
        Boolean exceptionThrown = false;
        try {
            throw new Utils.ActionSecurityException('Test security exception');
        } catch (Utils.ActionSecurityException e) {
            exceptionThrown = true;
            System.assertEquals('Test security exception', e.getMessage(), 'Should preserve exception message');
        }
        Test.stopTest();

        System.assert(exceptionThrown, 'Should throw ActionSecurityException');
    }

    @IsTest
    static void testMultipleCachesWorkIndependently() {
        Utils.sObjectTypeCache.clear();
        Utils.fieldDescribeCache.clear();
        Utils.describeCache.clear();

        SObjectType accountType = Schema.Account.SObjectType;

        Test.startTest();
        // Populate all caches
        SObjectType type1 = Utils.getSObjectType('Account');
        Map<String, SObjectField> fields = Utils.getObjectFields(accountType);
        DescribeSObjectResult describe = Utils.getDescribe(accountType);
        Test.stopTest();

        System.assertEquals(1, Utils.sObjectTypeCache.size(), 'SObjectType cache should have 1 entry');
        System.assertEquals(1, Utils.fieldDescribeCache.size(), 'Field cache should have 1 entry');
        System.assertEquals(1, Utils.describeCache.size(), 'Describe cache should have 1 entry');
    }
}
