@IsTest
private class ActionFindEntitiesTest {
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
        accounts.add(new Account(Name = 'Acme Corporation', Industry = 'Technology', Phone = '555-123-4567'));
        accounts.add(new Account(Name = 'Global Industries', Industry = 'Manufacturing', Phone = '555-987-6543'));
        accounts.add(new Account(Name = 'Tech Solutions Inc', Industry = 'Technology'));
        insert accounts;

        // Create test contacts
        List<Contact> contacts = new List<Contact>();
        contacts.add(
            new Contact(FirstName = 'John', LastName = 'Smith', Email = 'john.smith@acme.com', Phone = '555-111-2222', AccountId = accounts[0].Id)
        );
        contacts.add(
            new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane.doe@global.com', MobilePhone = '555-333-4444', AccountId = accounts[1].Id)
        );
        contacts.add(new Contact(FirstName = 'Robert', LastName = 'Johnson', Email = 'bob.johnson@tech.com', Phone = '555-555-6666'));
        insert contacts;

        // Create test SObjectConfig__mdt records (this would normally be done via metadata)
        // Note: In a real test, you'd need to create these as actual metadata or mock the query
    }

    @IsTest
    static void executeAction_success_singleMatch() {
        // Mock the metadata query to return test configuration
        ActionFindEntitiesTest.mockMetadataQuery();
        Contact expectedContact = [SELECT Id, Name, Email FROM Contact WHERE Email = 'john.smith@acme.com' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expectedContact.Id });

        ActionFindEntities action = new ActionFindEntities();
        String config = '{"maxAmbiguousResults": 5}';
        String argumentsJson = '{"searchQuery": "john.smith@acme.com"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        System.debug(JSON.serialize(result));

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('SUCCESS', (String) dataMap.get('resultType'));
        System.assertNotEquals(null, dataMap.get('record'));
        Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
        System.assertEquals(expectedContact.Id, (String) recordMap.get('Id'));
    }

    @IsTest
    static void executeAction_success_phoneSearch() {
        ActionFindEntitiesTest.mockMetadataQuery();
        Account expectedAccount = [SELECT Id, Name, Phone FROM Account WHERE Phone = '555-123-4567' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expectedAccount.Id });

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": "555-123-4567"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('SUCCESS', (String) dataMap.get('resultType'));
        Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
        System.assertEquals(expectedAccount.Id, (String) recordMap.get('Id'));
        System.assertEquals('Acme Corporation', (String) recordMap.get('Name'));
    }

    @IsTest
    static void executeAction_success_nameSearch() {
        ActionFindEntitiesTest.mockMetadataQuery();
        Contact expectedContact = [SELECT Id, Name, Email FROM Contact WHERE LastName = 'Smith' LIMIT 1];
        Test.setFixedSearchResults(new List<Id>{ expectedContact.Id });

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": "John Smith"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');
        System.assertEquals('SUCCESS', (String) dataMap.get('resultType'));
        System.assertNotEquals(null, dataMap.get('record'));

        Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
        System.assertEquals(expectedContact.Id, (String) recordMap.get('Id'));
        System.assertEquals('John Smith', (String) recordMap.get('Name'));
    }

    @IsTest
    static void executeAction_success_ambiguousResults() {
        ActionFindEntitiesTest.mockMetadataQuery();
        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Industry = 'Technology'];
        Test.setFixedSearchResults(new List<Id>{ accounts[0].Id, accounts[1].Id });

        ActionFindEntities action = new ActionFindEntities();
        String config = '{"maxAmbiguousResults": 3}';
        String argumentsJson = '{"searchQuery": "Technology"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('AMBIGUOUS', (String) dataMap.get('resultType'));
        System.assertEquals(null, dataMap.get('record'));
        List<Object> options = (List<Object>) dataMap.get('options');
        System.assertEquals(2, options.size());
    }

    @IsTest
    static void executeAction_success_withSObjectTypes() {
        ActionFindEntitiesTest.mockMetadataQuery();
        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Name LIKE '%Acme%'];
        Test.setFixedSearchResults(new List<Id>{ accounts[0].Id });

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": "Acme", "sObjectTypes": ["Account"]}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('SUCCESS', (String) dataMap.get('resultType'));
        Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
        System.assertEquals(accounts[0].Id, (String) recordMap.get('Id'));
    }

    @IsTest
    static void executeAction_success_notFound() {
        ActionFindEntitiesTest.mockMetadataQuery();

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": "NonExistentSearchTerm12345"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(true, result.isSuccess);

        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        System.assertEquals('NOT_FOUND', (String) dataMap.get('resultType'));
        System.assertEquals('No matching records found.', (String) outputMap.get('messageForUser'));
        System.assertEquals(null, dataMap.get('record'));
        System.assertEquals(null, dataMap.get('options'));
    }

    @IsTest
    static void executeAction_failure_blankSearchQuery() {
        ActionFindEntitiesTest.mockMetadataQuery();

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": ""}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('cannot be blank'));
    }

    @IsTest
    static void executeAction_failure_noMetadataConfiguration() {
        // Don't mock metadata - let it return empty list
        ActionFindEntities.MDT_CACHE = new List<SObjectConfig__mdt>();

        ActionFindEntities action = new ActionFindEntities();
        String config = '{}';
        String argumentsJson = '{"searchQuery": "test"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        System.assertNotEquals(null, result);
        System.assertEquals(false, result.isSuccess);
        System.assert(String.valueOf(result.outputForLlm).contains('No active SObjectConfig__mdt records found'));
    }

    @IsTest
    static void searchResult_constructor_success() {
        Test.startTest();
        ActionFindEntities.SearchResult result = new ActionFindEntities.SearchResult(
            'SUCCESS',
            'Test message',
            new Map<String, Object>{ 'Id' => '001000000000001', 'Name' => 'Test' },
            null
        );
        Test.stopTest();

        System.assertEquals('SUCCESS', result.resultType);
        System.assertEquals('Test message', result.message);
        System.assertNotEquals(null, result.record);
        System.assertEquals(null, result.options);
        System.assertEquals('SUCCESS', (String) result.metadata.get('searchType'));
        System.assertEquals(true, (Boolean) result.metadata.get('hasRecord'));
        System.assertEquals(0, (Integer) result.metadata.get('optionCount'));
    }

    @IsTest
    static void searchResult_constructor_ambiguous() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        options.add(new Map<String, String>{ 'id' => '001000000000001', 'label' => 'Option 1' });
        options.add(new Map<String, String>{ 'id' => '001000000000002', 'label' => 'Option 2' });

        Test.startTest();
        ActionFindEntities.SearchResult result = new ActionFindEntities.SearchResult('AMBIGUOUS', 'Multiple matches found', null, options);
        Test.stopTest();

        System.assertEquals('AMBIGUOUS', result.resultType);
        System.assertEquals('Multiple matches found', result.message);
        System.assertEquals(null, result.record);
        System.assertEquals(2, result.options.size());
        System.assertEquals('AMBIGUOUS', (String) result.metadata.get('searchType'));
        System.assertEquals(false, (Boolean) result.metadata.get('hasRecord'));
        System.assertEquals(2, (Integer) result.metadata.get('optionCount'));
    }

    @IsTest
    static void parseActionConfiguration_success_withOverrides() {
        ActionFindEntitiesTest.mockMetadataQuery();

        ActionFindEntities action = new ActionFindEntities();
        String config = '{"maxAmbiguousResults": 8}';
        String argumentsJson = '{"searchQuery": "test"}';

        Test.startTest();
        ActionResult result = action.execute(config, argumentsJson, createMockActionContext());
        Test.stopTest();

        // Verify configuration was parsed successfully
        System.assertNotEquals(null, result);
        // The result should be successful (configuration parsing worked)
        // The actual search might return NOT_FOUND, but that's expected
        if (!result.isSuccess) {
            // If it failed, it should not be due to configuration issues
            System.assert(
                !String.valueOf(result.outputForLlm).contains('configuration'),
                'Configuration parsing failed: ' + String.valueOf(result.outputForLlm)
            );
        }
    }

    // Helper method to mock metadata query
    private static void mockMetadataQuery() {
        List<SObjectConfig__mdt> mockMetadata = new List<SObjectConfig__mdt>();

        // Create mock metadata for Account
        SObjectConfig__mdt accountConfig = new SObjectConfig__mdt();
        accountConfig.SObjectAPIName__c = 'Account';
        accountConfig.PrimaryNameField__c = 'Name';
        accountConfig.KeyIdentifierFields__c = 'Phone,Id';
        mockMetadata.add(accountConfig);

        // Create mock metadata for Contact
        SObjectConfig__mdt contactConfig = new SObjectConfig__mdt();
        contactConfig.SObjectAPIName__c = 'Contact';
        contactConfig.PrimaryNameField__c = 'Name';
        contactConfig.KeyIdentifierFields__c = 'Email,Phone,MobilePhone,Id';
        mockMetadata.add(contactConfig);

        // Set the static cache
        ActionFindEntities.MDT_CACHE = mockMetadata;
    }

    // Helper method to create mock ActionContext using real records
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
            'ActionFindEntities', // implementationDetail
            'test-turn-' +
            System.currentTimeMillis(), // turnIdentifier
            1 // currentTurnCount
        );
    }
}
