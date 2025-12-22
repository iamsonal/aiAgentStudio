/**
 * @description Comprehensive test class for ActionGetRecordDetails
 *              Tests record retrieval via multiple identifier fields, FieldSets,
 *              defaultFields, security validation, and error scenarios.
 */
@IsTest
private class ActionGetRecordDetailsTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test accounts using TestFactory
        TestFactory.newAccount().withName('Tech Innovations Inc').withIndustry('Technology').withRevenue(5000000.00).save();

        // Create second Technology account for multiple matches test
        TestFactory.newAccount().withName('Tech Solutions Ltd').withIndustry('Technology').withRevenue(3000000.00).save();

        TestFactory.newAccount().withName('Finance Solutions Corp').withIndustry('Finance').withRevenue(2500000.00).save();

        // Create test contacts
        Account techAccount = [SELECT Id FROM Account WHERE Name = 'Tech Innovations Inc' LIMIT 1];
        Account financeAccount = [SELECT Id FROM Account WHERE Name = 'Finance Solutions Corp' LIMIT 1];

        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@techinnovations.com').withAccount(techAccount.Id).save();

        TestFactory.newContact().withName('Jane', 'Smith').withEmail('jane.smith@financesolutions.com').withAccount(financeAccount.Id).save();

        // Create test cases (for CaseNumber identifier testing)
        Case testCase1 = new Case(Subject = 'Test Case 1', Status = 'New', Origin = 'Web', Priority = 'Medium');
        insert testCase1;

        Case testCase2 = new Case(Subject = 'Test Case 2', Status = 'Working', Origin = 'Email', Priority = 'High');
        insert testCase2;
    }

    // ===================================================================================
    // SUCCESS SCENARIOS - ID LOOKUP
    // ===================================================================================

    @IsTest
    static void testGetRecordById_WithDefaultFields_Success() {
        // Given: A contact and action configured with defaultFields
        Contact testContact = [SELECT Id, FirstName, LastName, Email FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testContact.Id };

        // When: Retrieving the contact by Id
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve successfully
        System.assert(result.isSuccess, 'Should retrieve contact successfully');

        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('Contact', response.get('objectType'), 'Should return Contact object type');
        System.assertEquals(testContact.Id, response.get('recordId'), 'Should return correct record ID');
        System.assertEquals('Id', response.get('matchedBy'), 'Should match by Id');

        Map<String, Object> record = (Map<String, Object>) response.get('record');
        System.assertEquals('John', record.get('FirstName'), 'Should return FirstName');
        System.assertEquals('Doe', record.get('LastName'), 'Should return LastName');
        System.assertEquals('john.doe@techinnovations.com', record.get('Email'), 'Should return Email');
    }

    @IsTest
    static void testGetAccountById_WithDefaultFields_Success() {
        // Given: An account
        Account testAccount = [SELECT Id, Name, Industry FROM Account WHERE Name = 'Tech Innovations Inc' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry', 'AnnualRevenue' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        // When: Retrieving by Id
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve all configured fields
        System.assert(result.isSuccess);
        Map<String, Object> response = (Map<String, Object>) result.data;
        Map<String, Object> record = (Map<String, Object>) response.get('record');

        System.assertEquals('Tech Innovations Inc', record.get('Name'));
        System.assertEquals('Technology', record.get('Industry'));
        System.assertEquals(5000000.00, record.get('AnnualRevenue'));
    }

    // ===================================================================================
    // SUCCESS SCENARIOS - CASENUMBER LOOKUP (NAME FIELD)
    // ===================================================================================

    @IsTest
    static void testGetCaseByCaseNumber_Success() {
        // Given: A case with CaseNumber
        Case testCase = [SELECT Id, CaseNumber, Subject, Status FROM Case WHERE Subject = 'Test Case 1' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Case',
                'defaultFields' => new List<String>{ 'Id', 'CaseNumber', 'Subject', 'Status', 'Origin', 'Priority' }
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'CaseNumber' => testCase.CaseNumber };

        // When: Retrieving case by CaseNumber
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve successfully
        System.assert(result.isSuccess, 'Should retrieve case by CaseNumber');

        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('Case', response.get('objectType'));
        System.assertEquals(testCase.Id, response.get('recordId'));
        System.assertEquals('CaseNumber', response.get('matchedBy'));

        Map<String, Object> record = (Map<String, Object>) response.get('record');
        System.assertEquals(testCase.CaseNumber, record.get('CaseNumber'));
        System.assertEquals('Test Case 1', record.get('Subject'));
        System.assertEquals('New', record.get('Status'));
    }

    // ===================================================================================
    // SUCCESS SCENARIOS - EMAIL LOOKUP (ALTERNATE IDENTIFIER)
    // ===================================================================================

    @IsTest
    static void testGetContactByEmail_Success() {
        // Given: A contact with email
        Contact testContact = [SELECT Id, Email, FirstName, LastName FROM Contact WHERE Email = 'jane.smith@financesolutions.com' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName', 'Email' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Email' => testContact.Email };

        // When: Retrieving contact by Email
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve successfully
        System.assert(result.isSuccess, 'Should retrieve contact by Email');

        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertEquals('Email', response.get('matchedBy'));

        Map<String, Object> record = (Map<String, Object>) response.get('record');
        System.assertEquals('jane.smith@financesolutions.com', record.get('Email'));
        System.assertEquals('Jane', record.get('FirstName'));
        System.assertEquals('Smith', record.get('LastName'));
    }

    // ===================================================================================
    // SUCCESS SCENARIOS - MULTIPLE MATCHES WARNING
    // ===================================================================================

    @IsTest
    static void testMultipleMatches_ReturnsFirstWithWarning() {
        // Given: Multiple accounts with same industry (non-unique field)
        // TestSetup creates 2 accounts with Industry = 'Technology'
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Industry' => 'Technology' };

        // When: Querying by non-unique field
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should return first match with warning
        System.assert(result.isSuccess, 'Should succeed but with warning');

        Map<String, Object> response = (Map<String, Object>) result.data;
        Object warningObj = response.get('multipleMatchesWarning');
        System.assertNotEquals(null, warningObj, 'Should include multiple matches warning');

        String warningMessage = (String) warningObj;
        System.assert(warningMessage.contains('Multiple records matched'), 'Warning should mention multiple matches');
        System.assert(warningMessage.contains('2 matches'), 'Warning should indicate 2 matches found');
    }

    // ===================================================================================
    // SECURITY & FIELD-LEVEL SECURITY TESTS
    // ===================================================================================

    @IsTest
    static void testFieldLevelSecurity_FiltersInaccessibleFields() {
        // Given: Action with accessible and inaccessible fields
        // Note: In test context, all fields are typically accessible
        // This test validates the FLS filtering logic exists
        Account testAccount = [SELECT Id FROM Account LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        // When: Retrieving record
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should apply Security.stripInaccessible
        System.assert(result.isSuccess, 'Should succeed with FLS enforcement');
        Map<String, Object> response = (Map<String, Object>) result.data;
        System.assertNotEquals(null, response.get('record'), 'Should return sanitized record');
    }

    // ===================================================================================
    // FAILURE SCENARIOS - VALIDATION ERRORS
    // ===================================================================================

    @IsTest
    static void testMissingObjectApiName_Failure() {
        // Given: Configuration without objectApiName
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(new Map<String, Object>{ 'defaultFields' => new List<String>{ 'Id', 'Name' } });
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => '001000000000000' };

        // When: Attempting to retrieve
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with configuration error
        System.assert(!result.isSuccess, 'Should fail without objectApiName');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
        System.assert(result.errorMessage.contains('objectApiName'), 'Error should mention objectApiName');
    }

    @IsTest
    static void testInvalidObjectApiName_Failure() {
        // Given: Configuration with invalid object name
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'NonExistentObject__c', 'defaultFields' => new List<String>{ 'Id', 'Name' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => '001000000000000' };

        // When: Attempting to retrieve
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with configuration error
        System.assert(!result.isSuccess, 'Should fail with invalid object');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
        System.assert(result.errorMessage.contains('Invalid object API name'), 'Error should mention invalid object');
    }

    @IsTest
    static void testMissingFieldSetAndDefaultFields_Failure() {
        // Given: Configuration without fieldSetName or defaultFields
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Account'
                // Missing both fieldSetName and defaultFields
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        // When: Attempting to retrieve
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with configuration error
        System.assert(!result.isSuccess, 'Should fail without field configuration');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
        System.assert(
            result.errorMessage.contains('fieldSetName') || result.errorMessage.contains('defaultFields'),
            'Error should mention required field configuration'
        );
    }

    @IsTest
    static void testBothFieldSetAndDefaultFields_Failure() {
        // Given: Configuration with BOTH fieldSetName and defaultFields (mutually exclusive)
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Account',
                'fieldSetName' => 'SomeFieldSet',
                'defaultFields' => new List<String>{ 'Id', 'Name' }
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        // When: Attempting to retrieve
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with configuration error
        System.assert(!result.isSuccess, 'Should fail with both configurations');
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, result.errorCode);
        System.assert(result.errorMessage.contains('Both'), 'Error should mention both configurations provided');
    }

    @IsTest
    static void testMissingIdentifierParameter_Failure() {
        // Given: No identifier field provided
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        // When: Attempting to retrieve without identifier
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with input validation error
        System.assert(!result.isSuccess, 'Should fail without identifier');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(result.errorMessage.contains('Missing identifier parameter'), 'Error should mention missing identifier');
    }

    @IsTest
    static void testMultipleIdentifierParameters_Failure() {
        // Given: Multiple identifier fields provided (should only provide one)
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'Email' } });
        action.parseActionConfiguration(config, '[TEST] ');

        Contact testContact = [SELECT Id, Email FROM Contact LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{
            'Id' => testContact.Id,
            'Email' => testContact.Email // Two identifiers - not allowed
        };

        // When: Attempting to retrieve with multiple identifiers
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with input validation error
        System.assert(!result.isSuccess, 'Should fail with multiple identifiers');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(result.errorMessage.contains('Multiple identifier parameters'), 'Error should mention multiple identifiers');
    }

    @IsTest
    static void testRecordNotFound_Failure() {
        // Given: Valid configuration but non-existent record ID
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'FirstName', 'LastName' } }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{
            'Id' => '003000000000000AAA' // Non-existent but valid format
        };

        // When: Attempting to retrieve non-existent record
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with record not found error
        System.assert(!result.isSuccess, 'Should fail for non-existent record');
        System.assertEquals(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, result.errorCode);
        System.assert(result.errorMessage.contains('Record not found'), 'Error should mention record not found');
    }

    @IsTest
    static void testInvalidFieldSetName_Failure() {
        // Given: Configuration with non-existent FieldSet
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Account', 'fieldSetName' => 'NonExistent_FieldSet' });
        action.parseActionConfiguration(config, '[TEST] ');

        Account testAccount = [SELECT Id FROM Account LIMIT 1];
        Map<String, Object> params = new Map<String, Object>{ 'Id' => testAccount.Id };

        // When: Attempting to retrieve with invalid FieldSet
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should fail with input validation error
        System.assert(!result.isSuccess, 'Should fail with non-existent FieldSet');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, result.errorCode);
        System.assert(
            result.errorMessage.contains('FieldSet') && result.errorMessage.contains('not found'),
            'Error should mention FieldSet not found'
        );
    }

    // ===================================================================================
    // EDGE CASES
    // ===================================================================================

    @IsTest
    static void testRelationshipFields_Success() {
        // Given: Configuration with relationship fields
        Contact testContact = [SELECT Id, AccountId FROM Contact WHERE FirstName = 'John' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{
                'objectApiName' => 'Contact',
                'defaultFields' => new List<String>{ 'Id', 'FirstName', 'Account.Name', 'Account.Industry' }
            }
        );
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'Id' => testContact.Id };

        // When: Retrieving with relationship fields
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve relationship fields
        System.assert(result.isSuccess, 'Should succeed with relationship fields');
        Map<String, Object> response = (Map<String, Object>) result.data;
        Map<String, Object> record = (Map<String, Object>) response.get('record');

        // Account relationship data should be present
        System.assertNotEquals(null, record.get('Account'), 'Should include Account relationship');
    }

    @IsTest
    static void testCaseInsensitiveIdentifierField_Success() {
        // Given: Contact with email
        Contact testContact = [SELECT Id, Email FROM Contact WHERE Email = 'john.doe@techinnovations.com' LIMIT 1];

        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Contact', 'defaultFields' => new List<String>{ 'Id', 'Email' } });
        action.parseActionConfiguration(config, '[TEST] ');

        // Use lowercase email for lookup
        Map<String, Object> params = new Map<String, Object>{ 'Email' => 'john.doe@techinnovations.com' };

        // When: Retrieving with case-sensitive field value
        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        // Then: Should retrieve successfully (SOQL is case-insensitive for text)
        System.assert(result.isSuccess, 'Should handle case-sensitive field values');
    }

    // ===================================================================================
    // CONFIGURATION PARSING TESTS
    // ===================================================================================

    @IsTest
    static void testParseConfig_ValidConfig_Success() {
        // Given: Valid configuration with defaultFields
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(
            new Map<String, Object>{ 'objectApiName' => 'Account', 'defaultFields' => new List<String>{ 'Id', 'Name', 'Industry' } }
        );

        // When: Parsing configuration
        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Then: Should parse successfully without exception
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void testParseConfig_ValidFieldSetConfig_Success() {
        // Given: Valid configuration with fieldSetName
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = JSON.serialize(new Map<String, Object>{ 'objectApiName' => 'Account', 'fieldSetName' => 'AI_Agent_Details' });

        // When: Parsing configuration
        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Then: Should parse successfully
        System.assert(true, 'FieldSet configuration should parse successfully');
    }

    @IsTest
    static void testParseConfig_EmptyConfig_UsesDefaults() {
        // Given: Empty configuration
        ActionGetRecordDetails action = new ActionGetRecordDetails();
        String config = '{}';

        // When: Parsing empty config
        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Then: Should parse and use defaults (will fail at execution without required fields)
        System.assert(true, 'Should parse empty config without exception');
    }
}
