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
        AgentExecution__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
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
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;

        System.assertEquals('Account', queryResult.objectApiName);
        System.assertEquals(3, queryResult.count);
        System.assertEquals(3, queryResult.records.size());
        System.assertEquals(false, queryResult.truncated);
        System.assert(queryResult.message.contains('Found and showing all 3 Account'));
    }

    @IsTest
    static void executeAction_success_withFilters() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Contact", "defaultFields": ["Id", "FirstName", "LastName", "Email"], "maxReturnToLLM": 10}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'filters' => new Map<String, Object>{ 'LastName' => 'Smith' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        List<SObject> records = queryResult.records;

        System.assertEquals('Contact', queryResult.objectApiName);
        System.assertEquals(1, queryResult.count);
        System.assertEquals(1, records.size());

        // Check individual field values
        System.assertEquals('John', records[0].get('FirstName'));
        System.assertEquals('Smith', records[0].get('LastName'));
    }

    @IsTest
    static void executeAction_success_withLimitAndOrderBy() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'limit' => 2, 'orderBy' => 'Name ASC' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;
        List<SObject> records = queryResult.records;

        System.assertEquals(2, records.size());
        // Verify ordering - "Another Company" should come first alphabetically
        System.assertEquals('Another Company', records[0].get('Name'));
    }

    @IsTest
    static void executeAction_success_truncatedResults() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Account", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 2}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>();

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;

        System.assertEquals(3, queryResult.count); // Total found
        System.assertEquals(2, queryResult.records.size()); // Returned to LLM
        System.assertEquals(true, queryResult.truncated);
        System.assert(queryResult.message.contains('Found 3 Account record(s). Showing the first 2'));
    }

    @IsTest
    static void executeAction_success_noResults() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "Contact", "defaultFields": ["Id", "FirstName", "LastName"], "maxReturnToLLM": 10}';
        action.parseActionConfiguration(config, '[TEST] ');

        Map<String, Object> params = new Map<String, Object>{ 'filters' => new Map<String, Object>{ 'LastName' => 'NonExistentName' } };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        ActionGetRecords.QueryResult queryResult = (ActionGetRecords.QueryResult) result.data;

        System.assertEquals(0, queryResult.count);
        System.assertEquals(0, queryResult.records.size());
        System.assertEquals('No Contact records found matching the criteria.', queryResult.message);
    }

    @IsTest
    static void executeAction_failure_invalidConfiguration() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"invalidKey": "value"}'; // Missing objectApiName

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown ValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('objectApiName'));
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_failure_invalidObjectApiName() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "InvalidObject__c", "defaultFields": ["Id"], "maxReturnToLLM": 10}';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown ValidationException');
        } catch (BaseAgentAction.ValidationException e) {
            System.assert(e.getMessage().contains('Invalid SObject API Name'));
        }
        Test.stopTest();
    }

    @IsTest
    static void executeAction_failure_blankObjectApiName() {
        ActionGetRecords action = new ActionGetRecords();
        String config = '{"objectApiName": "", "defaultFields": ["Id"], "maxReturnToLLM": 10}';

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown ValidationException');
        } catch (ActionConfigUtils.ArgumentValidationException e) {
            System.assert(e.getMessage().contains('cannot be blank'));
        }
        Test.stopTest();
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
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentCapability__c capability = [SELECT Id FROM AgentCapability__c WHERE StandardActionType__c = 'GetRecords' LIMIT 1];

        return new ActionContext(
            session.Id, // executionId
            UserInfo.getUserId(), // originalUserId
            UserInfo.getUserId(), // executionUserId
            null, // relatedRecordId
            agent.Id, // agentDefinitionId
            capability.Id, // agentCapabilityId
            'ActionGetRecords', // implementationDetail
            'test-turn-' +
            System.currentTimeMillis(), // turnIdentifier
            1, // currentTurnCount
            'Conversational' // executionType
        );
    }
}
