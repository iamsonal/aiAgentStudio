/**
 * @description Tests for ActionUpdateRecord behavior.
 */
@IsTest
private class ActionUpdateRecordTest {
    @TestSetup
    static void setupTestData() {
        TestFactory.newAccount().withName('Test Account 1').withIndustry('Technology').save();
        Account acc = [SELECT Id FROM Account WHERE Name = 'Test Account 1' LIMIT 1];
        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@test.com').withAccount(acc.Id).save();
    }

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-update-001', 1, 'Function');
    }

    // ========== SUCCESS SCENARIOS ==========

    @IsTest
    static void testExecute_UpdatesRecordAndReturnsResult() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();

        String configJson = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Account' });
        String argsJson = JSON.serialize(
            new Map<String, Object>{ 'recordId' => account.Id, 'recordData' => new Map<String, Object>{ 'Name' => 'After Update' } }
        );

        ActionOutcome outcome = action.execute(configJson, argsJson, buildContext());

        System.assertEquals(true, outcome.isSuccess, 'Update should succeed');
        ActionUpdateRecord.UpdateResult result = (ActionUpdateRecord.UpdateResult) outcome.data;
        System.assertEquals(String.valueOf(account.Id), result.recordId, 'Should return updated record Id');

        Account refreshed = [SELECT Name FROM Account WHERE Id = :account.Id LIMIT 1];
        System.assertEquals('After Update', refreshed.Name, 'Record should be updated');
    }

    @IsTest
    static void testUpdateContact_MultipleFields_VerifiesDbState() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'recordData' => new Map<String, Object>{ 'FirstName' => 'Johnny', 'Email' => 'johnny.doe@test.com' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should update successfully');
        ActionUpdateRecord.UpdateResult updateResult = (ActionUpdateRecord.UpdateResult) result.data;
        System.assertEquals(2, updateResult.updatedFields.size(), 'Should update 2 fields');

        Contact updated = [SELECT FirstName, LastName, Email FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals('Johnny', updated.FirstName, 'FirstName should be updated');
        System.assertEquals('Doe', updated.LastName, 'LastName should remain unchanged');
        System.assertEquals('johnny.doe@test.com', updated.Email, 'Email should be updated');
    }

    @IsTest
    static void testTypeCoercion_StringToNumber_CoercesCorrectly() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'recordData' => new Map<String, Object>{ 'NumberOfEmployees' => '250', 'AnnualRevenue' => '2500000.75' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess);
        Account updated = [SELECT NumberOfEmployees, AnnualRevenue FROM Account WHERE Id = :testAccount.Id];
        System.assertEquals(250, updated.NumberOfEmployees);
        System.assertEquals(2500000.75, updated.AnnualRevenue);
    }

    @IsTest
    static void testDefaultFieldValues_MergesWithAiValues() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration(
            '{"objectApiName": "Contact", "defaultFieldValues": {"LastName": "DefaultLastName", "Email": "default@test.com"}}',
            '[TEST] '
        );

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'recordData' => new Map<String, Object>{ 'FirstName' => 'UpdatedJohn' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should update successfully: ' + result.errorMessage);
        Contact updated = [SELECT FirstName, LastName, Email FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals('UpdatedJohn', updated.FirstName, 'AI-provided value should be used');
        System.assertEquals('DefaultLastName', updated.LastName, 'Default value should be applied');
        System.assertEquals('default@test.com', updated.Email, 'Default value should be applied');
    }

    @IsTest
    static void testAiOverridesDefaults_PrecedenceCorrect() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{"defaultFieldValues": {"Email": "default@test.com"}}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'recordData' => new Map<String, Object>{ 'Email' => 'ai-provided@test.com' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess);
        Contact updated = [SELECT Email FROM Contact WHERE Id = :testContact.Id];
        System.assertEquals('ai-provided@test.com', updated.Email, 'AI value should override default');
    }

    @IsTest
    static void testObjectApiNameMatch_CaseInsensitive_Succeeds() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{"objectApiName": "account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testAccount.Id,
            'recordData' => new Map<String, Object>{ 'Name' => 'Case Insensitive Update' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed with case-insensitive match');
    }

    // ========== FAILURE SCENARIOS ==========

    @IsTest
    static void testExecute_ObjectApiNameMismatch_ReturnsValidationError() {
        Account account = [SELECT Id FROM Account LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();

        String configJson = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Case' });
        String argsJson = JSON.serialize(
            new Map<String, Object>{ 'recordId' => account.Id, 'recordData' => new Map<String, Object>{ 'Name' => 'Should Fail' } }
        );

        ActionOutcome outcome = action.execute(configJson, argsJson, buildContext());

        System.assertEquals(false, outcome.isSuccess, 'Object mismatch should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testMissingRecordId_ReturnsValidationError() {
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordData' => new Map<String, Object>{ 'Name' => 'No Id' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assert(result.errorMessage.contains('Missing required parameter: "recordId"'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testInvalidRecordId_ReturnsValidationError() {
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => 'invalid-id-format', 'recordData' => new Map<String, Object>{ 'Name' => 'Test' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assert(result.errorMessage.contains('Invalid ID format'));
    }

    @IsTest
    static void testEmptyRecordData_ReturnsValidationError() {
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => testContact.Id, 'recordData' => new Map<String, Object>() };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with empty recordData');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testOnlyInvalidFields_ReturnsPermissionDenied() {
        Contact testContact = [SELECT Id FROM Contact LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => testContact.Id,
            'recordData' => new Map<String, Object>{ 'NonExistentField__c' => 'Value1', 'AnotherFakeField__c' => 'Value2' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail when all fields are filtered out');
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, result.errorCode);
    }

    @IsTest
    static void testNonExistentRecord_ReturnsDmlError() {
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'recordId' => '003000000000000',
            'recordData' => new Map<String, Object>{ 'FirstName' => 'Test' }
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail for non-existent record');
        System.assert(result.errorMessage.contains('Failed to update record'), 'Should mention update failure');
    }

    @IsTest
    static void testStringTooLong_ReturnsTypeCoercionError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{}', '[TEST] ');

        String longName = '';
        for (Integer i = 0; i < 30; i++) {
            longName += '0123456789';
        }

        Map<String, Object> params = new Map<String, Object>{ 'recordId' => testAccount.Id, 'recordData' => new Map<String, Object>{ 'Name' => longName } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with string too long');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    // ========== CONFIGURATION PARSING ==========

    @IsTest
    static void testParseConfig_NullConfig_UsesDefaults() {
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration(null, '[TEST] ');
        System.assert(true, 'Should handle null config gracefully');
    }

    @IsTest
    static void testParseConfig_MalformedJson_UsesDefaults() {
        ActionUpdateRecord action = new ActionUpdateRecord();
        action.parseActionConfiguration('{invalid json}', '[TEST] ');
        System.assert(true, 'Should handle malformed JSON gracefully');
    }
}
