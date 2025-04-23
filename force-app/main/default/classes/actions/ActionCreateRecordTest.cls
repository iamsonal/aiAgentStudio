/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Test class for the ActionCreateRecord standard action implementation.
 *              Verifies functionality using the standard Account object, including success,
 *              config errors, argument errors, permission checks, and DML failures.
 * @see ActionCreateRecord
 * @see IAgentAction
 * @see FrameworkUtils
 */
@isTest
private class ActionCreateRecordTest {
    private static final String ACCOUNT_API_NAME = 'Account';

    @TestSetup
    static void makeData() {
        Account parentAccount = new Account(Name = 'Parent Test Account');
        insert parentAccount;
    }

    private static String buildConfigJson(String objectApiName, Map<String, Object> defaultValues) {
        Map<String, Object> configMap = new Map<String, Object>();
        if (String.isNotBlank(objectApiName)) {
            configMap.put('objectApiName', objectApiName);
        }
        if (defaultValues != null && !defaultValues.isEmpty()) {
            configMap.put('defaultFieldValues', defaultValues);
        }
        return JSON.serialize(configMap);
    }

    private static ActionResult executeAction(String configJson, String argsJson) {
        ActionCreateRecord action = new ActionCreateRecord();
        ActionContext mockContext = new ActionContext(null, UserInfo.getUserId(), null, null, null, null);
        return action.execute(configJson, argsJson, mockContext);
    }

    @isTest
    static void testSuccess_BasicCreate() {
        String accountName = 'Test Account ' + System.currentTimeMillis();
        String accountNumber = 'ACC123';
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
        Map<String, Object> argsMap = new Map<String, Object>{
            'Name' => accountName,
            'AccountNumber' => accountNumber,
            'Description' => 'Basic success test'
        };
        String argsJson = JSON.serialize(argsMap);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Action should succeed. Details: ' + result.internalDetails);
        System.assertEquals(null, result.errorCode, 'Error code should be null.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Id newRecordId = Id.valueOf((String) outputMap.get('recordId'));

        Account created = [SELECT Id, Name, AccountNumber, Description FROM Account WHERE Id = :newRecordId];
        System.assertEquals(accountName, created.Name);
        System.assertEquals(accountNumber, created.AccountNumber);
        System.assertEquals('Basic success test', created.Description);
    }

    @isTest
    static void testSuccess_WithDefaultValues() {
        String accountName = 'Default Value Test ' + System.currentTimeMillis();
        String defaultPhone = '555-1212';
        String providedDesc = 'Provided by LLM';
        Map<String, Object> defaults = new Map<String, Object>{
            'Phone' => defaultPhone,
            'Description' => 'Default Description'
        };
        String configJson = buildConfigJson(ACCOUNT_API_NAME, defaults);
        Map<String, Object> argsMap = new Map<String, Object>{ 'Name' => accountName, 'Description' => providedDesc };
        String argsJson = JSON.serialize(argsMap);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Action should succeed with defaults. Details: ' + result.internalDetails);
        Id newRecordId = Id.valueOf((String) ((Map<String, Object>) result.outputForLlm).get('recordId'));

        Account created = [SELECT Id, Name, Phone, Description FROM Account WHERE Id = :newRecordId];
        System.assertEquals(accountName, created.Name);
        System.assertEquals(defaultPhone, created.Phone);
        System.assertEquals(providedDesc, created.Description);
    }

    @isTest
    static void testSuccess_DiverseStandardFieldTypes() {
        Account parent = [SELECT Id FROM Account WHERE Name = 'Parent Test Account' LIMIT 1];
        String accountName = 'Diverse Std Type Test ' + System.currentTimeMillis();
        Map<String, Object> argsMap = new Map<String, Object>{
            'Name' => accountName,
            'AnnualRevenue' => 500000,
            'Sic' => '8080',
            'Rating' => 'Hot',
            'Ownership' => 'Private',
            'Phone' => '999-888-7777',
            'ParentId' => parent.Id
        };
        String argsJson = JSON.serialize(argsMap);
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(
            result.isSuccess,
            'Action should succeed with diverse standard types. Details: ' + result.internalDetails
        );
        Id newRecordId = Id.valueOf((String) ((Map<String, Object>) result.outputForLlm).get('recordId'));

        Account created = [
            SELECT Id, Name, AnnualRevenue, Sic, Rating, Ownership, Phone, ParentId
            FROM Account
            WHERE Id = :newRecordId
        ];
        System.assertEquals(accountName, created.Name);
        System.assertEquals(500000, created.AnnualRevenue);
        System.assertEquals('8080', created.Sic);
        System.assertEquals('Hot', created.Rating);
        System.assertEquals('Private', created.Ownership);
        System.assertEquals('999-888-7777', created.Phone);
        System.assertEquals(parent.Id, created.ParentId);
    }

    @isTest
    static void testFailure_Config_MalformedJson() {
        String configJson = '{"o';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }
    @isTest
    static void testFailure_Config_MissingObjectApiName() {
        String configJson = '{}';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }
    @isTest
    static void testFailure_Config_InvalidObjectApiName() {
        String configJson = '{"objectApiName": "Bad__c"}';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }

    @isTest
    static void testFailure_Args_MalformedJson() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
        String argsJson = '{"N';
        ActionResult result = executeAction(configJson, argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_BlankJsonAndNoDefaults() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
        String argsJson = '';
        ActionResult result = executeAction(configJson, argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_EmptyMapAndNoDefaults() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
        String argsJson = '{}';
        ActionResult result = executeAction(configJson, argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }

    @isTest
    static void testFailure_Args_InvalidDataType() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);

        Map<String, Object> argsMap = new Map<String, Object>{
            'Name' => 'Type Error Test',
            'AnnualRevenue' => 'IsNotANumber'
        };
        String argsJson = JSON.serialize(argsMap);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result != null, 'Result should not be null, action should handle coercion failure.');
        System.assert(!result.isSuccess, 'Action should fail with invalid data type for coercion.');
        System.assertEquals(FrameworkUtils.ERR_CODE_INPUT_VALIDATION_TYPE, result.errorCode);
        System.assert(result.internalDetails.contains('Invalid data format provided'));
        System.assert(result.internalDetails.contains('AnnualRevenue'));
        System.assert(
            result.internalDetails.contains('Invalid numeric format for field AnnualRevenue: IsNotANumber'),
            'Ensure specific coercion error message is included.'
        );

        List<Account> accs = [SELECT Id FROM Account WHERE Name = 'Type Error Test'];
        System.assertEquals(0, accs.size(), 'No account should have been created.');
    }

    @isTest
    static void testSuccess_Permission_SomeFieldsDenied() {
        ActionResult actionResult = null;
        String accountName = 'Partial FLS ' + System.currentTimeMillis();

        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator' LIMIT 1];
        User restrictedUser = new User(
            ProfileId = p.Id,
            LastName = 'SomeFLS',
            Alias = 'somef',
            Email = 'somefls@test.com',
            UserName = 'somefls@test.aiagentfw.com' + System.currentTimeMillis(),
            LocaleSidKey = 'en_US',
            LanguageLocaleKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            TimeZoneSidKey = 'America/Los_Angeles',
            IsActive = true
        );
        insert restrictedUser;

        System.runAs(restrictedUser) {
            Test.startTest();
            String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
            Map<String, Object> argsMap = new Map<String, Object>{ 'Name' => accountName, 'AccountNumber' => 'DENIED' };
            String argsJson = JSON.serialize(argsMap);
            actionResult = executeAction(configJson, argsJson);
            Test.stopTest();
        }

        System.assert(actionResult != null, 'Action Result should not be null.');
        System.assert(
            actionResult.isSuccess,
            'Action should succeed if DML with *permitted* fields works. Details: ' + actionResult.internalDetails
        );
        System.assertEquals(null, actionResult.errorCode);
        Id newRecordId = Id.valueOf((String) ((Map<String, Object>) actionResult.outputForLlm).get('recordId'));

        Account created = [SELECT Id, Name, AccountNumber FROM Account WHERE Id = :newRecordId];
        System.assertEquals(accountName, created.Name, 'Name field (permitted) should be set.');

        if (Schema.sObjectType.Account.fields.AccountNumber.isCreateable() == false) {
            System.assertEquals(
                null,
                created.AccountNumber,
                'AccountNumber should be null if runAs user LACKS FLS create access'
            );
        } else {
            System.assertEquals(
                'DENIED',
                created.AccountNumber,
                'AccountNumber was unexpectedly set. Check Profile/PermSet FLS for the test user.'
            );
        }
    }

    @isTest
    static void testFailure_DML_RequiredFieldMissing() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, null);
        Map<String, Object> argsMap = new Map<String, Object>{ 'Phone' => '111-222-3333' };
        String argsJson = JSON.serialize(argsMap);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Action should fail due to missing required field.');
        System.assertEquals('DML_ERROR', result.errorCode);
        System.assert(result.internalDetails.contains('REQUIRED_FIELD_MISSING'));

        System.assert(
            result.internalDetails.contains('Required fields are missing: [Name]') ||
            result.internalDetails.contains('[Account Name]'),
            'Details should list Name as missing field.'
        );

        List<Account> created = [SELECT Id FROM Account WHERE Phone = '111-222-3333'];
        System.assertEquals(0, created.size());
    }
}
