/**
 * @description Tests for ActionGetRecordDetails behavior.
 */
@IsTest
private class ActionGetRecordDetailsTest {
    @TestSetup
    static void setupTestData() {
        TestFactory.newAccount().withName('Tech Innovations Inc').withIndustry('Technology').withRevenue(5000000.00).save();
        TestFactory.newAccount().withName('Tech Solutions Ltd').withIndustry('Technology').withRevenue(3000000.00).save();
        TestFactory.newAccount().withName('Finance Solutions Corp').withIndustry('Finance').save();

        Account techAccount = [SELECT Id FROM Account WHERE Name = 'Tech Innovations Inc' LIMIT 1];
        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@techinnovations.com').withAccount(techAccount.Id).save();

        insert new Case(Subject = 'Test Case 1', Status = 'New', Origin = 'Web', Priority = 'Medium');
    }

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-get-001', 1, 'Function');
    }

    // ========== SUCCESS - ID LOOKUP ==========

    @IsTest
    static void testGetContactById_ReturnsAllFields() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testContact.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should retrieve contact successfully');
        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('Contact', response.get('objectType'));
        System.assertEquals('Id', response.get('matchedBy'));

        Map<String, Object> record = (Map<String, Object>) response.get('record');
        System.assertEquals('John', record.get('FirstName'));
        System.assertEquals('Doe', record.get('LastName'));
        System.assertEquals('john.doe@techinnovations.com', record.get('Email'));
    }

    @IsTest
    static void testGetAccountById_ReturnsNumericFields() {
        Account testAccount = [SELECT Id FROM Account WHERE Name = 'Tech Innovations Inc' LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry', 'AnnualRevenue' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess);
        Map<String, Object> record = (Map<String, Object>) ((Map<String, Object>) result.data).get('record');
        System.assertEquals('Tech Innovations Inc', record.get('Name'));
        System.assertEquals(5000000.00, record.get('AnnualRevenue'));
    }

    // ========== SUCCESS - ALTERNATE IDENTIFIERS ==========

    @IsTest
    static void testGetCaseByCaseNumber_Success() {
        Case testCase = [SELECT Id, CaseNumber FROM Case WHERE Subject = 'Test Case 1' LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Case', 'defaultFields' => new List<String>{ 'Id', 'CaseNumber', 'Subject', 'Status' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'CaseNumber' => testCase.CaseNumber };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should retrieve case by CaseNumber');
        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('CaseNumber', response.get('matchedBy'));

        Map<String, Object> record = (Map<String, Object>) response.get('record');
        System.assertEquals('Test Case 1', record.get('Subject'));
    }

    @IsTest
    static void testGetContactByEmail_Success() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Email' => 'john.doe@techinnovations.com' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should retrieve contact by Email');
        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('Email', response.get('matchedBy'));
    }

    @IsTest
    static void testMultipleMatches_ReturnsFirstWithWarning() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Industry' => 'Technology' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed but with warning');
        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertNotEquals(null, response.get('multipleMatchesWarning'), 'Should include multiple matches warning');
    }

    @IsTest
    static void testRelationshipFields_Success() {
        Contact testContact = [SELECT Id FROM Contact WHERE FirstName = 'John' LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Contact',
                'defaultFields' => new List<String>{ 'Id', 'FirstName', 'Account.Name', 'Account.Industry' }
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testContact.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed with relationship fields');
        Map<String, Object> record = (Map<String, Object>) ((Map<String, Object>) result.data).get('record');
        System.assertNotEquals(null, record.get('Account'), 'Should include Account relationship');
    }

    // ========== FAILURE SCENARIOS ==========

    @IsTest
    static void testMissingObjectApiName_ReturnsConfigError() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"defaultFields": ["Id", "Name"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => '001000000000000' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
    }

    @IsTest
    static void testInvalidObjectApiName_ReturnsConfigError() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "NonExistentObject__c", "defaultFields": ["Id"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => '001000000000000' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
    }

    @IsTest
    static void testMissingFieldSelection_ReturnsConfigError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Account"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
    }

    @IsTest
    static void testBothFieldSetAndDefaultFields_ReturnsConfigError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'fieldSetName' => 'SomeFieldSet', 'defaultFields' => new List<String>{ 'Id', 'Name' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
    }

    @IsTest
    static void testMissingIdentifier_ReturnsValidationError() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Contact", "defaultFields": ["Id", "FirstName"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testMultipleIdentifiers_ReturnsValidationError() {
        Contact testContact = [SELECT Id, Email FROM Contact LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Contact", "defaultFields": ["Id", "Email"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testContact.Id, 'Email' => testContact.Email };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testRecordNotFound_ReturnsNotFoundError() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Contact", "defaultFields": ["Id", "FirstName"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => '003000000000000AAA' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, result.errorCode);
    }

    @IsTest
    static void testInvalidFieldSet_ReturnsValidationError() {
        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Account", "variant": "fieldset", "fieldSetName": "NonExistent_FieldSet"}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }

    @IsTest
    static void testUnknownIdentifierField_ReturnsValidationError() {
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        action.parseActionConfiguration('{"objectApiName": "Account", "defaultFields": ["Id", "Name"]}', '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'UnknownField' => 'value' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assert(!result.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
    }
}
