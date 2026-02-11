/**
 * @description Tests for ActionCreateRecord behavior.
 */
@IsTest
private class ActionCreateRecordTest {
    @TestSetup
    static void setupTestData() {
        TestFactory.newAccount().withName('Test Account 1').withIndustry('Technology').save();
    }

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-create-001', 1, 'Function');
    }

    // ========== SUCCESS SCENARIOS ==========

    @IsTest
    static void testExecute_CreatesRecordAndReturnsResult() {
        ActionCreateRecord action = new ActionCreateRecord();

        String configJson = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Account' });
        String argsJson = JSON.serialize(new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'Acme Create' } });

        ActionOutcome outcome = action.execute(configJson, argsJson, buildContext());

        System.assertEquals(true, outcome.isSuccess, 'Create record should succeed');
        ActionCreateRecord.CreateResult result = (ActionCreateRecord.CreateResult) outcome.data;
        System.assertNotEquals(null, result.recordId, 'Should return created record Id');

        Account created = [SELECT Name FROM Account WHERE Id = :result.recordId LIMIT 1];
        System.assertEquals('Acme Create', created.Name, 'Record should be created with provided name');
    }

    @IsTest
    static void testCreateContact_WithAllFields_VerifiesDbState() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Contact"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{
                'FirstName' => 'John',
                'LastName' => 'Doe',
                'Email' => 'john.doe@example.com',
                'AccountId' => testAccount.Id
            }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should create contact successfully');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertEquals(4, createResult.fieldsSet.size(), 'Should set 4 fields');

        Contact created = [SELECT FirstName, LastName, Email, AccountId FROM Contact WHERE Id = :createResult.recordId];
        System.assertEquals('John', created.FirstName);
        System.assertEquals('Doe', created.LastName);
        System.assertEquals('john.doe@example.com', created.Email);
        System.assertEquals(testAccount.Id, created.AccountId);
    }

    @IsTest
    static void testCreateAccount_WithDefaults_AppliesDefaultValues() {
        ActionCreateRecord action = new ActionCreateRecord();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Account',
                'defaultFieldValues' => new Map<String, Object>{ 'Type' => 'Customer - Direct', 'Industry' => 'Technology' }
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'New Tech Corp' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should create account successfully');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT Name, Type, Industry FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('New Tech Corp', created.Name);
        System.assertEquals('Customer - Direct', created.Type, 'Should apply default Type');
        System.assertEquals('Technology', created.Industry, 'Should apply default Industry');
    }

    @IsTest
    static void testCreateAccount_UserValueOverridesDefault() {
        ActionCreateRecord action = new ActionCreateRecord();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFieldValues' => new Map<String, Object>{ 'Type' => 'Customer - Direct' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Partner Corp', 'Type' => 'Technology Partner' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess);
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT Type FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Technology Partner', created.Type, 'User value should override default');
    }

    @IsTest
    static void testTypeCoercion_StringToNumber_CoercesCorrectly() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Big Corp', 'NumberOfEmployees' => '500', 'AnnualRevenue' => '10000000.50' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed with type coercion');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals(500, created.NumberOfEmployees, 'Should coerce to Integer');
        System.assertEquals(10000000.50, created.AnnualRevenue, 'Should coerce to Decimal');
    }

    @IsTest
    static void testDirectParamsWithoutRecordDataWrapper_UseFallback() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Name' => 'Direct Params Account', 'Industry' => 'Technology' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should create record with direct params (fallback)');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        Account created = [SELECT Name, Industry FROM Account WHERE Id = :createResult.recordId];
        System.assertEquals('Direct Params Account', created.Name);
        System.assertEquals('Technology', created.Industry);
    }

    @IsTest
    static void testCreateCase_IncludesRecordNameInResult() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Case"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Subject' => 'Test Case', 'Status' => 'New', 'Origin' => 'Web' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should create case: ' + result.errorMessage);
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertNotEquals(null, createResult.recordName, 'Should return record name (Case Number)');
        System.assertEquals('Case Number', createResult.recordNameLabel, 'Should return correct field label');
    }

    // ========== RECORDTYPE VALIDATION ==========

    @IsTest
    static void testRecordTypeValidation_InvalidIdFormat_Failure() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Test', 'RecordTypeId' => 'invalid-id-format' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with invalid RecordType format');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testRecordTypeValidation_NonRecordTypeId_Failure() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'Test', 'RecordTypeId' => testAccount.Id } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with non-RecordType ID');
        System.assert(result.errorMessage.contains('not a RecordType ID'), 'Error should mention wrong ID type');
    }

    @IsTest
    static void testRecordTypeValidation_NonExistent_Failure() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Test', 'RecordTypeId' => '012000000000001AAA' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with non-existent RecordType');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ========== FAILURE SCENARIOS ==========

    @IsTest
    static void testExecute_NoFieldData_ReturnsValidationError() {
        ActionCreateRecord action = new ActionCreateRecord();
        String configJson = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Account' });

        ActionOutcome outcome = action.execute(configJson, '{"recordData":{}}', buildContext());

        System.assertEquals(false, outcome.isSuccess, 'Empty field data should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testExecute_MissingObjectApiName_ReturnsValidationError() {
        ActionCreateRecord action = new ActionCreateRecord();

        ActionOutcome outcome = action.execute('{"defaultFieldValues":{}}', '{"recordData":{"Name":"Acme"}}', buildContext());

        System.assertEquals(false, outcome.isSuccess, 'Missing objectApiName should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testMissingRequiredField_ReturnsDmlError() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Contact"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'FirstName' => 'John' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail without required field');
        System.assert(result.errorMessage.contains('Failed to create Contact'), 'Should indicate creation failure');
    }

    @IsTest
    static void testInvalidFieldName_FiltersAndSucceeds() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Valid Name', 'NonExistentField__c' => 'Invalid Value' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed by filtering invalid field');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertEquals(false, createResult.fieldsSet.contains('NonExistentField__c'), 'Should not include invalid field');
    }

    @IsTest
    static void testStringTooLong_ReturnsTypeCoercionError() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        String longName = '';
        for (Integer i = 0; i < 30; i++) {
            longName += '0123456789';
        }

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => longName } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with string too long');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ========== CONFIGURATION PARSING ==========

    @IsTest
    static void testParseConfig_InvalidObjectApiName_ThrowsException() {
        ActionCreateRecord action = new ActionCreateRecord();
        try {
            action.parseActionConfiguration('{"objectApiName": "NonExistentObject__c"}', '[TEST] ');
            System.assert(false, 'Should throw exception for invalid object');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid SObject'), 'Should indicate invalid object');
        }
    }

    @IsTest
    static void testParseConfig_EmptyConfigJson_ThrowsException() {
        ActionCreateRecord action = new ActionCreateRecord();
        try {
            action.parseActionConfiguration('', '[TEST] ');
            System.assert(false, 'Should throw exception for empty config');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Configuration JSON is required'), 'Should mention config required');
        }
    }

    @IsTest
    static void testParseConfig_MalformedJson_ThrowsException() {
        ActionCreateRecord action = new ActionCreateRecord();
        try {
            action.parseActionConfiguration('{invalid json}', '[TEST] ');
            System.assert(false, 'Should throw exception for malformed JSON');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid configuration JSON'), 'Should mention invalid JSON');
        }
    }

    // ========== FLS COVERAGE ==========

    @IsTest
    static void testAllFieldsFilteredByFLS_ReturnsPermissionDenied() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'FakeField1__c' => 'Value1', 'FakeField2__c' => 'Value2' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'All fields filtered should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, result.errorCode, 'Should return permission denied');
        System.assert(result.errorMessage.contains('No creatable fields'), 'Should mention no creatable fields');
    }

    // ========== NAME FIELD CACHE ==========

    @IsTest
    static void testNameFieldCache_NullCacheHit_SucceedsWithoutRecordName() {
        // Pre-populate cache with null entry for 'account' to simulate an object with no name field
        ActionCreateRecord.nameFieldInfoCache.put('account', null);

        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'Cache Null Hit' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should still create record successfully');
        ActionCreateRecord.CreateResult createResult = (ActionCreateRecord.CreateResult) result.data;
        System.assertEquals(null, createResult.recordName, 'Record name should be null when cache entry is null');
    }

    @IsTest
    static void testNameFieldCache_SecondCreate_HitsCacheAndPopulatesName() {
        ActionCreateRecord action1 = new ActionCreateRecord();
        action1.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        ActionOutcome result1 = action1.executeAction(new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'First Account' } });
        System.assert(result1.isSuccess, 'First create should succeed');

        // Second create reuses the static name field cache
        ActionCreateRecord action2 = new ActionCreateRecord();
        action2.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        ActionOutcome result2 = action2.executeAction(new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'Second Account' } });
        System.assert(result2.isSuccess, 'Second create should succeed');

        ActionCreateRecord.CreateResult cr1 = (ActionCreateRecord.CreateResult) result1.data;
        ActionCreateRecord.CreateResult cr2 = (ActionCreateRecord.CreateResult) result2.data;
        System.assertEquals('First Account', cr1.recordName, 'First record name should be populated');
        System.assertEquals('Second Account', cr2.recordName, 'Second record name should be populated from cache');
    }

    // ========== INACTIVE RECORDTYPE ==========

    @IsTest
    static void testInactiveRecordType_ReturnsValidationError() {
        ActionCreateRecord action = new ActionCreateRecord();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        // Use JSON.deserialize to create an in-memory RecordType with IsActive = false
        RecordType mockRT = (RecordType) JSON.deserialize(
            '{"attributes":{"type":"RecordType"},"DeveloperName":"Test_Inactive","Name":"Test Inactive","IsActive":false}',
            RecordType.class
        );
        ActionCreateRecord.mockRecordTypeQueryResult = new List<RecordType>{ mockRT };

        Map<String, Object> params = new Map<String, Object>{
            'recordData' => new Map<String, Object>{ 'Name' => 'Test', 'RecordTypeId' => '012000000000001AAA' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Inactive RecordType should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(result.errorMessage.contains('not active'), 'Should mention inactive RecordType');

        ActionCreateRecord.mockRecordTypeQueryResult = null;
    }
}
