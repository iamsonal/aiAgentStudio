/**
 * @description Tests for SystemPromptBuilder using TestFactory utilities
 */
@IsTest
private class SystemPromptBuilderTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test data for context
        Account account = TestFactory.newAccount()
            .withName('Test Account')
            .withDescription('Test account for context')
            .save();

        TestFactory.newContact()
            .withName('John', 'Doe')
            .withEmail('john.doe@test.com')
            .withAccount(account.Id)
            .save();
    }

    // ===================================================================================
    // BASIC PROMPT BUILDING TESTS
    // ===================================================================================

    @IsTest
    static void testBuildBasicPrompt_ContainsAllSections() {
        // Given: Agent definition
        AIAgentDefinition__c agent = [
            SELECT Id, IdentityPrompt__c, InstructionsPrompt__c, ExamplesPrompt__c,
                   PromptFooter__c, ContextFormatStrategy__c,
                   MemoryStrategy__c, DeveloperName__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        agent.MemoryStrategy__c = 'Summary Buffer';
        agent.IdentityPrompt__c = 'You are a helpful AI assistant.';
        agent.InstructionsPrompt__c = 'Follow these instructions carefully.';
        agent.ExamplesPrompt__c = 'Example: User asks for help, you provide assistance.';
        update agent;

        AgentExecution__c session = [SELECT Id, ConversationSummary__c FROM AgentExecution__c LIMIT 1];
        session.ConversationSummary__c = 'Test summary';
        update session;

        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        // When: Building prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String prompt = builder.build(
            session.Id,
            agent,
            llmConfig,
            null,
            1,
            UserInfo.getUserId()
        );
        Test.stopTest();

        // Then: Should contain all sections
        System.assert(prompt.contains('# System Context'));
        System.assert(prompt.contains('# Identity'));
        System.assert(prompt.contains('# Instructions'));
        System.assert(prompt.contains('# Examples'));
        System.assert(prompt.contains('# Context'));
    }

    @IsTest
    static void testBuildPrompt_WithSummaryBuffer_IncludesSummary() {
        // Given: Agent with summary buffer
        AIAgentDefinition__c agent = [
            SELECT Id, MemoryStrategy__c, IdentityPrompt__c, InstructionsPrompt__c, PromptFooter__c,
                   ContextFormatStrategy__c, DeveloperName__c, ExamplesPrompt__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        agent.MemoryStrategy__c = 'Summary Buffer';
        update agent;

        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        session.ConversationSummary__c = 'Previous conversation summary';
        update session;

        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        // When: Building prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());
        Test.stopTest();

        // Then: Should include summary
        System.assert(prompt.contains('CONVERSATION_SUMMARY'));
        System.assert(prompt.contains('Previous conversation summary'));
    }

    @IsTest
    static void testBuildPrompt_WithNullOptionalFields_HandlesGracefully() {
        // Given: Agent with null optional fields
        AIAgentDefinition__c agent = [
            SELECT Id, IdentityPrompt__c, InstructionsPrompt__c, ExamplesPrompt__c,
                   PromptFooter__c, ContextFormatStrategy__c, MemoryStrategy__c, DeveloperName__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        agent.IdentityPrompt__c = null;
        agent.ExamplesPrompt__c = null;
        agent.PromptFooter__c = null;
        update agent;

        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        // When: Building prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());
        Test.stopTest();

        // Then: Should still build prompt
        System.assert(String.isNotBlank(prompt));
        System.assert(prompt.contains('# System Context'));
    }

    // ===================================================================================
    // CONTEXT FORMATTING TESTS
    // ===================================================================================

    @IsTest
    static void testFormatContext_StructuredText_FormatsCorrectly() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];

        // When: Formatting
        Test.startTest();
        String formatted = SystemPromptBuilder.getContextFormatter('StructuredText', '[TEST] ')
            .formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should be structured text
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('## Accounts'));
        System.assert(formatted.contains('Test Account'));
    }

    @IsTest
    static void testFormatContext_XML_FormatsCorrectly() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name FROM Account LIMIT 1];

        // When: Formatting
        Test.startTest();
        String formatted = SystemPromptBuilder.getContextFormatter('XML', '[TEST] ')
            .formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should be XML
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('<object_group'));
        System.assert(formatted.contains('<record>'));
        System.assert(formatted.contains('Test Account'));
    }

    @IsTest
    static void testFormatContext_JSON_FormatsCorrectly() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name FROM Account LIMIT 1];

        // When: Formatting
        Test.startTest();
        String formatted = SystemPromptBuilder.getContextFormatter('JSON', '[TEST] ')
            .formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should be valid JSON
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('"objectInfo"'));
        System.assert(formatted.contains('"records"'));

        // Verify valid JSON
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson);
    }

    @IsTest
    static void testFormatContext_WithChildRelationships_IncludesChildren() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName FROM Contacts)
            FROM Account
            LIMIT 1
        ];

        // When: Formatting
        Test.startTest();
        String formatted = SystemPromptBuilder.getContextFormatter('StructuredText', '[TEST] ')
            .formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should include child relationships
        System.assert(formatted.contains('Contacts'));
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
    }

    @IsTest
    static void testFormatContext_WithRelationshipFields_IncludesRelated() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name
            FROM Contact
            LIMIT 1
        ];

        // When: Formatting
        Test.startTest();
        String formatted = SystemPromptBuilder.getContextFormatter('StructuredText', '[TEST] ')
            .formatContext(contacts, '[TEST] ');
        Test.stopTest();

        // Then: Should include relationship data
        System.assert(formatted.contains('Account → Account Name:'));
        System.assert(formatted.contains('Test Account'));
    }

    // ===================================================================================
    // TEMPORAL CONTEXT TESTS
    // ===================================================================================

    @IsTest
    static void testPrompt_IncludesTemporalContext() {
        // Given: Agent and session
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c, IdentityPrompt__c, InstructionsPrompt__c, ContextFormatStrategy__c,
                   MemoryStrategy__c, ExamplesPrompt__c, PromptFooter__c
            FROM AIAgentDefinition__c
            LIMIT 1
        ];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        LLMConfiguration__c llmConfig = [SELECT Id FROM LLMConfiguration__c LIMIT 1];

        // When: Building prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String prompt = builder.build(session.Id, agent, llmConfig, null, 1, UserInfo.getUserId());
        Test.stopTest();

        // Then: Should include temporal context
        System.assert(prompt.contains('Current Date:'));
        System.assert(prompt.contains('Current Day:'));
        System.assert(prompt.contains('Current Time'));
        System.assert(prompt.contains('User Timezone:'));
    }

    // ===================================================================================
    // HELPER METHOD TESTS
    // ===================================================================================

    @IsTest
    static void testTruncateContextSection_ShortText_NoTruncation() {
        // Given: Short text
        SystemPromptBuilder builder = new SystemPromptBuilder();
        String shortText = 'This is a short text';

        // When: Truncating
        Test.startTest();
        String result = builder.truncateContextSection(shortText, 100);
        Test.stopTest();

        // Then: Should not truncate
        System.assertEquals(shortText, result);
    }

    @IsTest
    static void testTruncateContextSection_LongText_Truncates() {
        // Given: Long text
        SystemPromptBuilder builder = new SystemPromptBuilder();
        String longText = '';
        for (Integer i = 0; i < 100; i++) {
            longText += 'This is a very long line ' + i + '\n';
        }

        // When: Truncating to small size
        Test.startTest();
        String result = builder.truncateContextSection(longText, 50);
        Test.stopTest();

        // Then: Should truncate
        System.assert(result.length() < longText.length());
        System.assert(result.contains('[Context truncated...]'));
    }

    @IsTest
    static void testBuildStructuredContextPrompt_NoContext_ReturnsEmpty() {
        // Given: Session with no structured context
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // When: Building structured context prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String result = builder.buildStructuredContextPrompt(session.Id, 1, false);
        Test.stopTest();

        // Then: Should return empty
        System.assertEquals('', result);
    }

    @IsTest
    static void testBuildStructuredContextPrompt_WithItems_BuildsSections() {
        // Given: Session with context ledger items
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        // Create context ledger items with different types
        List<ContextLedgerItem__c> ledgerItems = new List<ContextLedgerItem__c>{
            new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = account.Id,
                RecordType__c = 'Account',
                ContextType__c = 'IMPLICIT_PRIMARY',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 1,
                AccessCount__c = 1,
                RelevanceScore__c = 100.0
            ),
            new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = '003TestRecord001',
                RecordType__c = 'Contact',
                ContextType__c = 'ACTION_GENERATED',
                Status__c = 'ACTIVE',
                TurnAdded__c = 5,
                LastAccessedTurn__c = 8,
                AccessCount__c = 3,
                RelevanceScore__c = 85.0
            )
        };
        insert ledgerItems;

        // When: Building structured context prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String result = builder.buildStructuredContextPrompt(session.Id, 10, false);
        Test.stopTest();

        // Then: Should build sections with formatted items
        System.assert(String.isNotBlank(result), 'Should return non-empty result');
        System.assert(result.contains('## Current Primary Context'), 'Should contain primary section header');
        System.assert(result.contains('Account:'), 'Should contain account info');
        System.assert(result.contains('Contact:'), 'Should contain contact info');
    }

    @IsTest
    static void testBuildStructuredContextPrompt_WithMetadata_IncludesMetadata() {
        // Given: Session with context ledger items that have metadata
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        ContextLedgerItem__c item = new ContextLedgerItem__c(
            AgentExecution__c = session.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ContextType__c = 'USER_MENTIONED',
            Status__c = 'ACTIVE',
            TurnAdded__c = 1,
            LastAccessedTurn__c = 1,
            AccessCount__c = 1,
            RelevanceScore__c = 100.0,
            Metadata__c = '{"importance":"high","reason":"user requested"}'
        );
        insert item;

        // When: Building structured context prompt with metadata
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String result = builder.buildStructuredContextPrompt(session.Id, 1, true);
        Test.stopTest();

        // Then: Should include metadata
        System.assert(String.isNotBlank(result), 'Should return non-empty result');
        System.assert(result.contains('Account:'), 'Should contain account info');
        System.assert(result.contains('Explicitly mentioned by user'), 'Should contain context type explanation');
    }

    @IsTest
    static void testBuildStructuredContextPrompt_ExceedsLimit_TruncatesCriticalSections() {
        // Given: Session with many context items that will exceed MAX_CONTEXT_CHARS (8000)
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        List<ContextLedgerItem__c> ledgerItems = new List<ContextLedgerItem__c>();

        // Create many primary context items to exceed the limit
        for (Integer i = 0; i < 50; i++) {
            ledgerItems.add(new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = '001TestRecord' + String.valueOf(i).leftPad(3, '0'),
                RecordType__c = 'Account',
                ContextType__c = 'IMPLICIT_PRIMARY',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 1,
                AccessCount__c = 1,
                RelevanceScore__c = 100.0,
                SourceRecordId__c = account.Id,
                ChildRecordIds__c = '["003Child' + i + '","003Child' + (i+1) + '"]',
                Metadata__c = '{"field' + i + '":"value' + i + '","description":"This is a long description for item ' + i + ' to help increase the total character count"}'
            ));
        }

        // Add recent context items
        for (Integer i = 50; i < 100; i++) {
            ledgerItems.add(new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = '001TestRecord' + String.valueOf(i).leftPad(3, '0'),
                RecordType__c = 'Contact',
                ContextType__c = 'ACTION_GENERATED',
                Status__c = 'ACTIVE',
                TurnAdded__c = 8,
                LastAccessedTurn__c = 9,
                AccessCount__c = 2,
                RelevanceScore__c = 80.0,
                SourceRecordId__c = account.Id,
                ChildRecordIds__c = '["004Related' + i + '","004Related' + (i+1) + '","004Related' + (i+2) + '"]'
            ));
        }

        // Add related context items
        for (Integer i = 100; i < 120; i++) {
            ledgerItems.add(new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = '001TestRecord' + String.valueOf(i).leftPad(3, '0'),
                RecordType__c = 'Opportunity',
                ContextType__c = 'RELATED_RECORD',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 5,
                AccessCount__c = 1,
                RelevanceScore__c = 60.0
            ));
        }

        // Add background context items
        for (Integer i = 120; i < 140; i++) {
            ledgerItems.add(new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = '001TestRecord' + String.valueOf(i).leftPad(3, '0'),
                RecordType__c = 'Case',
                ContextType__c = 'BACKGROUND_CONTEXT',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 2,
                AccessCount__c = 1,
                RelevanceScore__c = 40.0
            ));
        }

        insert ledgerItems;

        // When: Building structured context prompt
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String result = builder.buildStructuredContextPrompt(session.Id, 10, true);
        Test.stopTest();

        // Then: Should handle limit gracefully
        System.assert(String.isNotBlank(result), 'Should return non-empty result');
        System.assert(result.length() <= 8500, 'Should respect MAX_CONTEXT_CHARS limit (with some buffer for truncation indicator)');

        // Should contain primary section (critical section - truncated, not skipped)
        System.assert(result.contains('## Current Primary Context'), 'Should contain primary section');

        // May or may not contain all sections depending on truncation
        // But should have attempted to include critical sections first
        if (result.contains('[Context truncated...]')) {
            System.debug('Context was truncated as expected due to size limits');
        }
    }

    @IsTest
    static void testBuildContextPromptSection_FormatsItemsCorrectly() {
        // Given: Mock context items
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        // Create a ledger item to build a real ContextItem from
        ContextLedgerItem__c ledgerItem = new ContextLedgerItem__c(
            AgentExecution__c = session.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ContextType__c = 'SEARCH_RESULT',
            Status__c = 'ACTIVE',
            TurnAdded__c = 5,
            LastAccessedTurn__c = 8,
            AccessCount__c = 3,
            RelevanceScore__c = 85.0,
            SourceRecordId__c = '001SourceRecord',
            ChildRecordIds__c = '["003Child1","003Child2"]',
            Metadata__c = '{"matchScore":0.95,"searchQuery":"test query"}'
        );
        insert ledgerItem;

        // Query it back to get all fields including system fields
        ledgerItem = [SELECT Id, RecordId__c, RecordType__c, ContextType__c, Status__c,
                      TurnAdded__c, LastAccessedTurn__c, AccessCount__c, RelevanceScore__c,
                      SourceRecordId__c, ChildRecordIds__c, Metadata__c, OriginalContextType__c,
                      LastDataRefreshTime__c, LastModifiedDate
                      FROM ContextLedgerItem__c WHERE Id = :ledgerItem.Id];

        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(ledgerItem);
        List<ContextManagerService.ContextItem> items = new List<ContextManagerService.ContextItem>{ item };

        // When: Building context prompt section
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String section = builder.buildContextPromptSection('primary', items, 10, false);
        Test.stopTest();

        // Then: Should format section correctly
        System.assert(String.isNotBlank(section), 'Should return formatted section');
        System.assert(section.contains('## Current Primary Context'), 'Should contain section header');
        System.assert(section.contains('Account:'), 'Should contain record type');
        System.assert(section.contains('Found via search'), 'Should contain context type explanation');
        System.assert(section.contains('Related to: 001SourceRecord'), 'Should contain source relationship');
        System.assert(section.contains('Has related:'), 'Should contain child relationships');
    }

    @IsTest
    static void testFormatContextItem_WithMetadata_FormatsAllParts() {
        // Given: Context item with full metadata
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        ContextLedgerItem__c ledgerItem = new ContextLedgerItem__c(
            AgentExecution__c = session.Id,
            RecordId__c = account.Id,
            RecordType__c = 'Account',
            ContextType__c = 'PINNED',
            Status__c = 'ACTIVE',
            TurnAdded__c = 1,
            LastAccessedTurn__c = 8, // Changed from 5 to 8 so (10-8=2) gives "2 turns ago"
            AccessCount__c = 10,
            RelevanceScore__c = 100.0,
            Metadata__c = '{"priority":"high","notes":"Important account"}'
        );
        insert ledgerItem;

        // Query it back
        ledgerItem = [SELECT Id, RecordId__c, RecordType__c, ContextType__c, Status__c,
                      TurnAdded__c, LastAccessedTurn__c, AccessCount__c, RelevanceScore__c,
                      SourceRecordId__c, ChildRecordIds__c, Metadata__c, OriginalContextType__c,
                      LastDataRefreshTime__c, LastModifiedDate
                      FROM ContextLedgerItem__c WHERE Id = :ledgerItem.Id];

        ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(ledgerItem);

        // When: Formatting with metadata (current turn = 10, last accessed = 8, so 2 turns ago)
        SystemPromptBuilder builder = new SystemPromptBuilder();
        Test.startTest();
        String formatted = builder.formatContextItem(item, 10, true);
        Test.stopTest();

        // Then: Should include all parts
        System.assert(String.isNotBlank(formatted), 'Should return formatted item');
        System.assert(formatted.contains('Account:'), 'Should contain record type');
        System.assert(formatted.contains('Pinned by user'), 'Should contain context explanation');
        System.assert(formatted.contains('2 turns ago'), 'Should contain temporal label');
    }

    @IsTest
    static void testGetContextTypeExplanation_AllTypes_ReturnsCorrectExplanations() {
        // Given: Session for creating items
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];
        SystemPromptBuilder builder = new SystemPromptBuilder();

        // Test all context types
        Map<String, String> typeToExpectedExplanation = new Map<String, String>{
            'IMPLICIT_PRIMARY' => 'User is currently viewing this record',
            'ACTION_GENERATED' => 'Created by you in a previous turn',
            'USER_MENTIONED' => 'Explicitly mentioned by user',
            'SEARCH_RESULT' => 'Found via search',
            'PINNED' => 'Pinned by user for reference',
            'RELATED_RECORD' => 'Related to other context records'
        };

        Test.startTest();
        for (String contextType : typeToExpectedExplanation.keySet()) {
            // Create ledger item for each type
            ContextLedgerItem__c ledgerItem = new ContextLedgerItem__c(
                AgentExecution__c = session.Id,
                RecordId__c = account.Id,
                RecordType__c = 'Account',
                ContextType__c = contextType,
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 1,
                AccessCount__c = 1,
                RelevanceScore__c = 100.0
            );
            insert ledgerItem;

            // Query it back and create ContextItem
            ledgerItem = [SELECT Id, RecordId__c, RecordType__c, ContextType__c, Status__c,
                          TurnAdded__c, LastAccessedTurn__c, AccessCount__c, RelevanceScore__c,
                          SourceRecordId__c, ChildRecordIds__c, Metadata__c, OriginalContextType__c,
                          LastDataRefreshTime__c, LastModifiedDate
                          FROM ContextLedgerItem__c WHERE Id = :ledgerItem.Id];

            ContextManagerService.ContextItem item = new ContextManagerService.ContextItem(ledgerItem);

            // When: Getting explanation
            String explanation = builder.getContextTypeExplanation(item);

            // Then: Should match expected
            System.assertEquals(typeToExpectedExplanation.get(contextType), explanation,
                               'Explanation for ' + contextType + ' should match');

            // Clean up for next iteration
            delete ledgerItem;
        }
        Test.stopTest();
    }
}
