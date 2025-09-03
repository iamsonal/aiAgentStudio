@IsTest
private class ActionGetRecordsTest {
    @TestSetup
    static void makeData() {
        // Create LLM Configuration
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        // Create Agent Definition
        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        // Create Agent Capabilities
        List<AgentCapability__c> caps = TestFactory.createStandardCapabilities(agent.Id);
        insert caps;

        // Create Chat Session
        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;

        // Create test accounts
        List<Account> accounts = new List<Account>();
        accounts.add(new Account(Name = 'Test Account 1', Industry = 'Technology'));
        accounts.add(new Account(Name = 'Test Account 2', Industry = 'Finance'));
        accounts.add(new Account(Name = 'Another Company', Industry = 'Healthcare'));
        insert accounts;

        // Create test contacts
        List<Contact> contacts = new List<Contact>();
        contacts.add(new Contact(FirstName = 'John', LastName = 'Smith', Email = 'john.smith@test.com', AccountId = accounts[0].Id));
        contacts.add(new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane.doe@test.com', AccountId = accounts[1].Id));
        contacts.add(new Contact(FirstName = 'Bob', LastName = 'Johnson', Email = 'bob.johnson@test.com'));
        insert contacts;
    }

    @IsTest
    static void executeAction_success_basicQuery() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}';
        String argumentsJson = '{}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('Account', (String) dataMap.get('objectApiName'));
        System.assertEquals(3, (Integer) dataMap.get('count'));
        System.assertEquals(3, ((List<Object>) dataMap.get('records')).size());
        System.assertEquals(false, (Boolean) dataMap.get('truncated'));
        System.assert(((String) outputMap.get('messageForUser')).contains('Found and showing all 3 Account'));
    }

    @IsTest
    static void executeAction_success_withFilters() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Contact", "defaultFields": ["Id", "Name", "Email"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"filters": {"LastName": "Smith"}}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        List<Object> rawRecords = (List<Object>) dataMap.get('records');
        List<SObject> records = (List<SObject>) JSON.deserialize(JSON.serialize(rawRecords), List<SObject>.class);

        System.assertEquals('Contact', (String) dataMap.get('objectApiName'));
        System.assertEquals(1, (Integer) dataMap.get('count'));
        System.assertEquals(1, records.size());
        System.assertEquals('John Smith', records[0].get('Name'));
    }

    @IsTest
    static void executeAction_success_withAdditionalFields() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"additionalFields": ["Industry"]}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        List<Object> rawRecords = (List<Object>) dataMap.get('records');
        List<SObject> records = (List<SObject>) JSON.deserialize(JSON.serialize(rawRecords), List<SObject>.class);

        System.assertEquals(3, records.size());
        // Verify that Industry field is included in results
        System.assertNotEquals(null, records[0].get('Industry'));
    }

    @IsTest
    static void executeAction_success_withLimitAndOrderBy() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"limit": 2, "orderBy": "Name ASC"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        List<Object> rawRecords = (List<Object>) dataMap.get('records');
        List<SObject> records = (List<SObject>) JSON.deserialize(JSON.serialize(rawRecords), List<SObject>.class);

        System.assertEquals(2, records.size());
        // Verify ordering - "Another Company" should come first alphabetically
        System.assertEquals('Another Company', records[0].get('Name'));
    }

    @IsTest
    static void executeAction_success_truncatedResults() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 2}';
        String argumentsJson = '{}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals(3, (Integer) dataMap.get('count')); // Total found
        System.assertEquals(2, ((List<Object>) dataMap.get('records')).size()); // Returned to LLM
        System.assertEquals(true, (Boolean) dataMap.get('truncated'));
        System.assert(((String) outputMap.get('messageForUser')).contains('Found 3 Account record(s). Showing the first 2'));
    }

    @IsTest
    static void executeAction_success_noResults() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Contact", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"filters": {"LastName": "NonExistentName"}}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals(0, (Integer) dataMap.get('count'));
        System.assertEquals(0, ((List<Object>) dataMap.get('records')).size());
        System.assertEquals('No Contact records found matching the criteria.', (String) outputMap.get('messageForUser'));
    }

    @IsTest
    static void executeAction_failure_invalidConfiguration() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"invalidKey": "value"}'; // Missing objectApiName
        String argumentsJson = '{}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('objectApiName'));
    }

    @IsTest
    static void executeAction_failure_invalidObjectApiName() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "InvalidObject__c", "defaultFields": ["Id"], "maxReturnToLLM": 10}';
        String argumentsJson = '{}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('Invalid SObject API Name'));
    }

    @IsTest
    static void executeAction_failure_blankObjectApiName() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "", "defaultFields": ["Id"], "maxReturnToLLM": 10}';
        String argumentsJson = '{}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('cannot be blank'));
    }

    @IsTest
    static void validateAndCoerceLimit_success_integerLimit() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"limit": 5}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        List<Object> records = (List<Object>) dataMap.get('records');

        // There are 3 accounts total, so a limit of 5 should return all 3.
        System.assertEquals(3, records.size());
    }

    @IsTest
    static void validateAndCoerceLimit_success_stringLimit() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"limit": "2"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        List<Object> records = (List<Object>) dataMap.get('records');

        // Verify string limit was parsed correctly
        System.assertEquals(2, records.size());
    }

    @IsTest
    static void validateAndCoerceLimit_failure_invalidString() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id"], "maxReturnToLLM": 10}';
        String argumentsJson = '{"limit": "invalid"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('Invalid Integer format'));
    }

    @IsTest
    static void queryResult_constructor_success() {
        List<Account> testAccounts = [SELECT Id, Name FROM Account LIMIT 2];

        Test.startTest();
        ActionGetRecords.QueryResult result = new ActionGetRecords.QueryResult(testAccounts, 5, 'Account', 'Test message');
        Test.stopTest();

        System.assertEquals(testAccounts, result.records);
        System.assertEquals(5, result.count);
        System.assertEquals('Account', result.objectApiName);
        System.assertEquals('Test message', result.message);
        System.assertEquals(true, result.truncated); // 2 returned, 5 total
        System.assertEquals(5, (Integer) result.metadata.get('totalFound'));
        System.assertEquals(2, (Integer) result.metadata.get('returned'));
        System.assertEquals(true, (Boolean) result.metadata.get('hasMore'));
        System.assertEquals('Account', (String) result.metadata.get('objectType'));
    }

    // Helper method to create mock ActionContext
    private static ActionContext createMockActionContext() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentCapability__c capability = [SELECT Id FROM AgentCapability__c LIMIT 1];

        return new ActionContext(
            session.Id, // chatSessionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            null, // relatedRecordId
            agent.Id, // agentDefinitionId
            capability.Id, // agentCapabilityId
            'ActionGetRecords', // implementationDetail
            'test-turn-' +
            System.currentTimeMillis(), // turnIdentifier
            1 // currentTurnCount
        );
    }
}
