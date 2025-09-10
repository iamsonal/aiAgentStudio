/**
 * @description Comprehensive test class for SystemPromptBuilder, SObjectContextFormatter, and PromptInjectionGuard.
 * Tests all major functionality including prompt composition, context formatting, and security features.
 */
@IsTest
private class SystemPromptBuilderTest {
    // Test data setup
    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetupData setup = TestFactory.createFullAgentSetup();

        // Insert LLM Configuration
        insert setup.llmConfig;

        // Link and insert Agent Definition
        setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
        setup.agentDefinition.IdentityPrompt__c = 'You are a helpful AI assistant.';
        setup.agentDefinition.InstructionsPrompt__c = 'Follow user instructions carefully.';
        setup.agentDefinition.ExamplesPrompt__c = 'Example: User asks for help, you provide assistance.';
        setup.agentDefinition.PromptFooter__c = 'Always be helpful and accurate.';
        setup.agentDefinition.ContextFormatStrategy__c = 'Structured Text';
        setup.agentDefinition.EnableReasoningMode__c = false;
        setup.agentDefinition.MemoryStrategy__c = 'Buffer Window';
        insert setup.agentDefinition;

        // Create test session
        ChatSession__c session = TestFactory.createChatSession(setup.agentDefinition.Id, UserInfo.getUserId());
        insert session;

        // Create test messages
        List<ChatMessage__c> messages = TestFactory.createChatMessages(session.Id, 2);
        insert messages;

        // Create test Account for context
        Account testAccount = new Account(Name = 'Test Account', Description = 'This is a test account for context formatting');
        insert testAccount;

        // Create test Contact
        Contact testContact = new Contact(FirstName = 'John', LastName = 'Doe', Email = 'john.doe@test.com', AccountId = testAccount.Id);
        insert testContact;
    }

    // Helper method to create test context data
    private static void createTestContextData(Id sessionId) {
        // Create some test context records that the services can work with
        // This will be used by the actual services during testing
    }

    // SystemPromptBuilder Tests

    @IsTest
    static void testBuildBasicPrompt() {
        // Get test data
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        agent.MemoryStrategy__c = 'Summary Buffer';
        update agent;
        session.ConversationSummary__c = 'This is a test summary to ensure the context section is generated.';
        update session;

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(
            session.Id,
            agent,
            llmConfig,
            null, // no page record
            1, // current turn
            UserInfo.getUserId()
        );

        Test.stopTest();

        // Verify prompt structure
        System.assert(prompt.contains('# System Context'), 'Should contain system context section');
        System.assert(prompt.contains('# Identity'), 'Should contain identity section');
        System.assert(prompt.contains('# Instructions'), 'Should contain instructions section');
        System.assert(prompt.contains('# Examples'), 'Should contain examples section');
        System.assert(prompt.contains('# Context'), 'Should contain context section');
        System.assert(prompt.contains(agent.PromptFooter__c), 'Should contain footer');
    }

    @IsTest
    static void testBuildPromptWithReasoningMode() {
        // Get test data and enable reasoning mode
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        agent.EnableReasoningMode__c = true;
        update agent;

        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());

        Test.stopTest();

        // Verify reasoning mode instructions are included
        System.assert(prompt.contains('CRITICAL BEHAVIOR RULE: REASONING MODE'), 'Should contain reasoning mode instructions');
        System.assert(prompt.contains('tool_calls'), 'Should mention tool_calls in reasoning instructions');
    }

    @IsTest
    static void testBuildPromptWithSummaryBuffer() {
        // Get test data and set summary buffer strategy
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        agent.MemoryStrategy__c = 'Summary Buffer';
        update agent;

        // Add conversation summary to session
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];
        session.ConversationSummary__c = 'Previous conversation summary for testing';
        update session;

        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());

        Test.stopTest();

        // Verify conversation summary is included
        System.assert(prompt.contains('CONVERSATION_SUMMARY'), 'Should contain conversation summary section');
        System.assert(prompt.contains('Previous conversation summary'), 'Should contain the actual summary');
    }

    @IsTest
    static void testBuildPromptWithPageRecord() {
        // Get test data
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];
        Account testAccount = [SELECT Id FROM Account LIMIT 1];

        agent.MemoryStrategy__c = 'Summary Buffer';
        update agent;
        session.ConversationSummary__c = 'This is a test summary to ensure the context section is generated.';
        update session;

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(
            session.Id,
            agent,
            llmConfig,
            testAccount.Id, // Pass page record ID
            1,
            UserInfo.getUserId()
        );

        Test.stopTest();

        // Verify prompt was built successfully
        System.assert(String.isNotBlank(prompt), 'Prompt should not be blank');
        System.assert(prompt.contains('# Context'), 'Should contain context section');
    }

    @IsTest
    static void testBuildContextSummary() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String summary = builder.buildContextSummary(session.Id, 1);

        Test.stopTest();

        System.assert(String.isNotBlank(summary), 'Context summary should not be blank');
        System.assert(
            summary.contains('No context available') || summary.contains('Context:'),
            'Should contain context information or no context message'
        );
    }

    @IsTest
    static void testGetHighlightedContext() {
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        List<ContextManagerService.ContextItem> highlighted = builder.getHighlightedContext(session.Id, 1);

        Test.stopTest();

        System.assertNotEquals(null, highlighted, 'Highlighted context should not be null');
    }

    // SObjectContextFormatter Tests

    @IsTest
    static void testFormatContextStructuredText() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'StructuredText', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('## Accounts'), 'Should contain object group header');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
        System.assert(formatted.contains('Description:'), 'Should contain non-primary field labels');
    }

    @IsTest
    static void testFormatContextXML() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description, Owner.Name, Owner.Email FROM Account LIMIT 1];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'XML', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('<object_group'), 'Should contain XML object group');
        System.assert(formatted.contains('<record>'), 'Should contain XML record tags');
        System.assert(formatted.contains('<field'), 'Should contain XML field tags');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
        // Should contain relationship field data
        System.assert(formatted.contains('Owner'), 'Should contain owner relationship data');
    }

    @IsTest
    static void testFormatContextWithChildRelationships() {
        // Get account with contacts
        List<Account> accounts = [
            SELECT Id, Name, Description, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'StructuredText', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('Contacts'), 'Should contain child relationship');
        System.assert(formatted.contains('John'), 'Should contain contact first name');
        System.assert(formatted.contains('Doe'), 'Should contain contact last name');
    }

    @IsTest
    static void testFormatContextWithChildRelationshipsXML() {
        // Get account with contacts in XML format - this will trigger formatChildRelationshipAsXml
        List<Account> accounts = [
            SELECT Id, Name, Description, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'XML', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('<child_relationship'), 'Should contain child relationship XML');
        System.assert(formatted.contains('<child_record>'), 'Should contain child record XML tags');
        System.assert(formatted.contains('John'), 'Should contain contact first name in XML');
        System.assert(formatted.contains('Doe'), 'Should contain contact last name in XML');
        System.assert(formatted.contains('Contacts'), 'Should contain relationship name in XML');
    }

    @IsTest
    static void testFormatContextEmptyList() {
        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(new List<SObject>(), 'StructuredText', '[TEST] ');

        Test.stopTest();

        System.assertEquals('', formatted, 'Empty list should return empty string');
    }

    @IsTest
    static void testFormatContextWithRelationshipFields() {
        // Create test data with relationship fields to trigger extractRelatedFields
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Email, Account.Name, Account.Owner.Name
            FROM Contact
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(contacts, 'StructuredText', '[TEST] ');

        Test.stopTest();

        System.debug(formatted);

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('Account → Account Name:'), 'Should contain relationship field label');
        System.assert(formatted.contains('Test Account'), 'Should contain related account name');
        System.assert(formatted.contains('Account → Owner → Full Name:'), 'Should contain nested relationship data');
    }

    @IsTest
    static void testFormatContextWithRelationshipFieldsXML() {
        // Test relationship fields in XML format to ensure extractRelatedFields is called
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Email, Account.Name, Account.Owner.Name
            FROM Contact
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(contacts, 'XML', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('<field'), 'Should contain XML field tags');
        System.assert(formatted.contains('Test Account'), 'Should contain related account name');
        // This should trigger extractRelatedFields for nested relationship traversal
        System.assert(formatted.contains('Account Name') || formatted.contains('Owner'), 'Should contain relationship field data in XML');
    }

    @IsTest
    static void testFormatContextJSON() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'JSON', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted JSON context should not be blank');
        System.assert(formatted.contains('"objectInfo"'), 'Should contain objectInfo section');
        System.assert(formatted.contains('"records"'), 'Should contain records array');
        System.assert(formatted.contains('"fields"'), 'Should contain fields section');
        System.assert(formatted.contains('"objectType"'), 'Should contain object type');
        System.assert(formatted.contains('"objectLabel"'), 'Should contain object label');
        System.assert(formatted.contains('"recordCount"'), 'Should contain record count');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');

        // Verify it's valid JSON
        try {
            Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
            System.assertNotEquals(null, parsedJson, 'Should be valid JSON');
            System.assert(parsedJson.containsKey('objectInfo'), 'Should have objectInfo in parsed JSON');
            System.assert(parsedJson.containsKey('records'), 'Should have records in parsed JSON');
        } catch (Exception e) {
            System.assert(false, 'JSON should be valid and parseable: ' + e.getMessage());
        }
    }

    @IsTest
    static void testFormatContextJSONWithChildRelationships() {
        // Get account with contacts
        List<Account> accounts = [
            SELECT Id, Name, Description, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'JSON', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted JSON context should not be blank');
        System.assert(formatted.contains('"childRelationships"'), 'Should contain child relationships section');
        System.assert(formatted.contains('"relationshipInfo"'), 'Should contain relationship info');
        System.assert(formatted.contains('"relationshipName"'), 'Should contain relationship name');
        System.assert(formatted.contains('"childObjectType"'), 'Should contain child object type');
        System.assert(formatted.contains('"childObjectLabel"'), 'Should contain child object label');
        System.assert(formatted.contains('John'), 'Should contain contact first name');
        System.assert(formatted.contains('Doe'), 'Should contain contact last name');

        // Verify it's valid JSON with proper structure
        try {
            Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
            List<Object> records = (List<Object>) parsedJson.get('records');
            System.assert(!records.isEmpty(), 'Should have records in JSON');

            Map<String, Object> firstRecord = (Map<String, Object>) records[0];
            if (firstRecord.containsKey('childRelationships')) {
                Map<String, Object> childRels = (Map<String, Object>) firstRecord.get('childRelationships');
                System.assert(!childRels.isEmpty(), 'Should have child relationships data');
            }
        } catch (Exception e) {
            System.assert(false, 'JSON with child relationships should be valid: ' + e.getMessage());
        }
    }

    @IsTest
    static void testFormatContextJSONWithRelationshipFields() {
        // Create test data with relationship fields
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Email, Account.Name, Account.Owner.Name
            FROM Contact
            LIMIT 1
        ];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(contacts, 'JSON', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted), 'Formatted JSON context should not be blank');
        System.assert(formatted.contains('Account → Account Name'), 'Should contain relationship field path');
        System.assert(formatted.contains('Test Account'), 'Should contain related account name');

        // Verify it's valid JSON
        try {
            Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
            List<Object> records = (List<Object>) parsedJson.get('records');
            System.assert(!records.isEmpty(), 'Should have records in JSON');

            Map<String, Object> firstRecord = (Map<String, Object>) records[0];
            Map<String, Object> fields = (Map<String, Object>) firstRecord.get('fields');
            System.assert(!fields.isEmpty(), 'Should have fields data in JSON');
        } catch (Exception e) {
            System.assert(false, 'JSON with relationship fields should be valid: ' + e.getMessage());
        }
    }

    @IsTest
    static void testFormatContextJSONDataTypes() {
        // Test that JSON formatting preserves appropriate data types
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];

        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(accounts, 'JSON', '[TEST] ');

        Test.stopTest();

        // Verify JSON structure preserves data types appropriately
        try {
            Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
            Map<String, Object> objectInfo = (Map<String, Object>) parsedJson.get('objectInfo');

            // Check that recordCount is a number, not a string
            Object recordCount = objectInfo.get('recordCount');
            System.assertEquals(1, recordCount, 'Record count should be 1');

            // Verify records structure
            List<Object> records = (List<Object>) parsedJson.get('records');
            System.assertEquals(1, records.size(), 'Should have exactly one record');

            Map<String, Object> firstRecord = (Map<String, Object>) records[0];
            System.assert(firstRecord.containsKey('fields'), 'Record should have fields section');
        } catch (Exception e) {
            System.assert(false, 'JSON should maintain proper data types: ' + e.getMessage());
        }
    }

    @IsTest
    static void testFormatContextJSONEmpty() {
        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(new List<SObject>(), 'JSON', '[TEST] ');

        Test.stopTest();

        System.assertEquals('', formatted, 'Empty list should return empty string for JSON format');
    }

    // Edge case and error handling tests

    @IsTest
    static void testBuildPromptWithNullValues() {
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];

        // Clear optional fields
        agent.IdentityPrompt__c = null;
        agent.ExamplesPrompt__c = null;
        agent.PromptFooter__c = null;
        update agent;

        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());

        Test.stopTest();

        System.assert(String.isNotBlank(prompt), 'Should still build prompt with null optional fields');
        System.assert(prompt.contains('# System Context'), 'Should contain system context');
    }

    @IsTest
    static void testFormatContextWithNullRecords() {
        Test.startTest();

        String formatted = SObjectContextFormatter.formatContext(null, 'StructuredText', '[TEST] ');

        Test.stopTest();

        System.assertEquals('', formatted, 'Null records should return empty string');
    }

    @IsTest
    static void testSObjectContextFormatterSchemaCaching() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];

        Test.startTest();

        // First call should populate cache
        String formatted1 = SObjectContextFormatter.formatContext(accounts, 'StructuredText', '[TEST] ');

        // Second call should use cached schema info
        String formatted2 = SObjectContextFormatter.formatContext(accounts, 'XML', '[TEST] ');

        Test.stopTest();

        System.assert(String.isNotBlank(formatted1), 'First formatted result should not be blank');
        System.assert(String.isNotBlank(formatted2), 'Second formatted result should not be blank');
        System.assert(formatted1.contains('## Accounts'), 'First should be structured text format');
        System.assert(formatted2.contains('<object_group'), 'Second should be XML format');
    }

    @IsTest
    static void testSystemPromptBuilderTemporalContext() {
        // Test that temporal context includes user timezone information
        AIAgentDefinition__c agent = [
            SELECT
                Id,
                DeveloperName__c,
                IdentityPrompt__c,
                InstructionsPrompt__c,
                ExamplesPrompt__c,
                PromptFooter__c,
                ContextFormatStrategy__c,
                EnableReasoningMode__c,
                MemoryStrategy__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];
        ChatSession__c session = [SELECT Id FROM ChatSession__c LIMIT 1];

        Test.startTest();

        SystemPromptBuilder builder = new SystemPromptBuilder();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());

        Test.stopTest();

        // Verify temporal context is included
        System.assert(prompt.contains('Current Date:'), 'Should contain current date');
        System.assert(prompt.contains('Current Day:'), 'Should contain current day');
        System.assert(prompt.contains('Current Time'), 'Should contain current time');
        System.assert(prompt.contains('User Timezone:'), 'Should contain user timezone');
    }
}
