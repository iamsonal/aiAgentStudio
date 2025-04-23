/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Test class for the ActionUpdateRecord standard action implementation.
 *              Verifies functionality using the standard Account object, including
 *              successful updates, data coercion, permission checks, and DML failures.
 * @see ActionUpdateRecord
 * @see IAgentAction
 * @see FrameworkUtils
 */
@isTest
private class ActionUpdateRecordTest {
    private static final String ACCOUNT_API_NAME = 'Account';

    @TestSetup
    static void makeData() {
        Account accToUpdate = new Account(
            Name = 'Update Target Account',
            Phone = '111-0000',
            Rating = 'Cold',
            Description = 'Initial Description'
        );
        insert accToUpdate;

        Account accForRequiredFieldTest = new Account(Name = 'Update Required Field Test');
        insert accForRequiredFieldTest;
    }

    private static String buildArgsJson(Id recordId, Map<String, Object> fieldsToUpdate) {
        Map<String, Object> argsMap = new Map<String, Object>();
        if (fieldsToUpdate != null) {
            argsMap.putAll(fieldsToUpdate);
        }
        argsMap.put('recordId', recordId);
        return JSON.serialize(argsMap);
    }

    private static ActionResult executeAction(String argsJson) {
        ActionUpdateRecord action = new ActionUpdateRecord();
        ActionContext mockContext = new ActionContext(null, UserInfo.getUserId(), null, null, null, null);

        return action.execute(null, argsJson, mockContext);
    }

    @isTest
    static void testSuccess_BasicUpdate() {
        Account target = [SELECT Id, Phone FROM Account WHERE Name = 'Update Target Account' LIMIT 1];
        String newPhone = '111-9999';
        Map<String, Object> updates = new Map<String, Object>{ 'Phone' => newPhone };
        String argsJson = buildArgsJson(target.Id, updates);

        Test.startTest();
        ActionResult result = executeAction(argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Action should succeed. Details: ' + result.internalDetails);
        System.assertEquals(null, result.errorCode);
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        System.assertEquals(target.Id, Id.valueOf((String) outputMap.get('recordId')));

        Account updated = [SELECT Id, Phone FROM Account WHERE Id = :target.Id];
        System.assertEquals(newPhone, updated.Phone, 'Phone field was not updated.');
    }

    @isTest
    static void testSuccess_UpdateMultipleFields() {
        Account target = [SELECT Id, Rating, Description FROM Account WHERE Name = 'Update Target Account' LIMIT 1];
        String newRating = 'Warm';
        String newDesc = 'Updated via testSuccess_UpdateMultipleFields';
        Map<String, Object> updates = new Map<String, Object>{ 'Rating' => newRating, 'Description' => newDesc };
        String argsJson = buildArgsJson(target.Id, updates);

        Test.startTest();
        ActionResult result = executeAction(argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Update multiple fields should succeed.');
        Account updated = [SELECT Id, Rating, Description FROM Account WHERE Id = :target.Id];
        System.assertEquals(newRating, updated.Rating, 'Rating field was not updated.');
        System.assertEquals(newDesc, updated.Description, 'Description field was not updated.');
    }

    @isTest
    static void testSuccess_UpdateWithCoercion() {
        Account target = [
            SELECT Id, AnnualRevenue, NumberOfEmployees
            FROM Account
            WHERE Name = 'Update Target Account'
            LIMIT 1
        ];
        Map<String, Object> updates = new Map<String, Object>{
            'AnnualRevenue' => '67890.50',
            'NumberOfEmployees' => '42'
        };
        String argsJson = buildArgsJson(target.Id, updates);

        Test.startTest();
        ActionResult result = executeAction(argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Update with coercion should succeed.');
        Account updated = [SELECT Id, AnnualRevenue, NumberOfEmployees FROM Account WHERE Id = :target.Id];
        System.assertEquals(67890.50, updated.AnnualRevenue);
        System.assertEquals(42, updated.NumberOfEmployees);
    }

    @isTest
    static void testFailure_Args_MalformedJson() {
        String argsJson = '{"rec';
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_BlankJson() {
        String argsJson = '';
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_EmptyMap() {
        String argsJson = '{}';
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_MissingRecordId() {
        String argsJson = '{"Name": "New Name"}';
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(result.internalDetails.contains('"recordId"'));
    }
    @isTest
    static void testFailure_Args_InvalidRecordIdFormat() {
        String argsJson = '{"recordId": "12345", "Name": "New"}';
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }
    @isTest
    static void testFailure_Args_NoFieldsToUpdate() {
        Account target = [SELECT Id FROM Account LIMIT 1];
        String argsJson = buildArgsJson(target.Id, null);
        ActionResult result = executeAction(argsJson);
        System.assert(!result.isSuccess);
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(result.internalDetails.contains('No fields provided to update'));
    }

    @isTest
    static void testFailure_Args_InvalidDataTypeForCoercion() {
        Account target = [SELECT Id, NumberOfEmployees FROM Account WHERE Name = 'Update Target Account' LIMIT 1];
        Map<String, Object> updates = new Map<String, Object>{ 'NumberOfEmployees' => 'many' };
        String argsJson = buildArgsJson(target.Id, updates);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(argsJson);
        Test.stopTest();

        System.assert(result != null, 'Result should not be null');
        System.assert(!result.isSuccess, 'Should fail due to invalid data type for coercion.');
        System.assert(result.internalDetails.contains('NumberOfEmployees'));
    }

    @isTest
    static void testFailure_DML_RequiredFieldViolationOnUpdate() {
        Account target = [SELECT Id, Name FROM Account WHERE Name = 'Update Required Field Test' LIMIT 1];
        Map<String, Object> updates = new Map<String, Object>{ 'Name' => null };
        String argsJson = buildArgsJson(target.Id, updates);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(argsJson);
        Test.stopTest();

        System.assert(result != null && !result.isSuccess, 'Action should fail trying to nullify a required field.');
        System.assertEquals('DML_ERROR', result.errorCode);

        System.assert(
            result.internalDetails.contains('REQUIRED_FIELD_MISSING') ||
            result.internalDetails.contains('Required fields are missing'),
            'Error code/msg expected.'
        );
        System.assert(
            result.internalDetails.contains('[Name]') || result.internalDetails.contains('[Account Name]'),
            'Field name expected in error.'
        );

        Account after = [SELECT Id, Name FROM Account WHERE Id = :target.Id];
        System.assertEquals('Update Required Field Test', after.Name, 'Name should not have been nulled.');
    }

    @isTest
    static void testFailure_DML_RecordLocked() {
        Account target = [SELECT Id FROM Account WHERE Name = 'Update Target Account' FOR UPDATE];
        Map<String, Object> updates = new Map<String, Object>{ 'Phone' => '888-LOCK' };
        String argsJson = buildArgsJson(target.Id, updates);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(argsJson);
        Test.stopTest();

        if (!result.isSuccess) {
            System.assertEquals(
                'RECORD_LOCKED',
                result.errorCode,
                'Expected RECORD_LOCKED if DML failed due to locking.'
            );
            System.assert(result.internalDetails.contains('unable to lock row'), 'Check for standard locking message.');
        } else {
            Account updated = [SELECT Phone FROM Account WHERE Id = :target.Id];
            System.assertEquals('888-LOCK', updated.Phone);
        }
    }
}
