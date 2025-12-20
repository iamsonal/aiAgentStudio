/**
 * @description Comprehensive tests for ContextFormattingService
 * Tests all format strategies: JSON, XML, and Structured Text
 */
@IsTest
private class ContextFormattingServiceTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test data
        Account account = TestFactory.newAccount().withName('Test Account').withDescription('Test account for formatting').save();

        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@test.com').withAccount(account.Id).save();
    }

    // ===================================================================================
    // JSON FORMAT TESTS
    // ===================================================================================

    @IsTest
    static void testJsonFormatting_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting as JSON
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should contain valid JSON
        System.assert(String.isNotBlank(formatted), 'Formatted result should not be blank');
        System.assert(formatted.contains('"metadata"'), 'Should contain metadata');
        System.assert(formatted.contains('"format" : "JSON"'), 'Should specify JSON format');
        System.assert(formatted.contains('"records"'), 'Should contain records');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');

        // Verify valid JSON
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson, 'Should be valid JSON');
        System.assert(parsedJson.containsKey('metadata'), 'Should have metadata key');
    }

    @IsTest
    static void testJsonFormatting_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should include child relationship JSON structure
        System.assert(formatted.contains('"childRelationships"'), 'Should have childRelationships');
        System.assert(formatted.contains('"Contacts"'), 'Should have Contacts');
        System.assert(formatted.contains('John'), 'Should contain first name');
        System.assert(formatted.contains('Doe'), 'Should contain last name');
        System.assert(formatted.contains('john.doe@test.com'), 'Should contain email');

        // Verify structure
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        List<Object> records = (List<Object>) parsedJson.get('records');
        System.assertNotEquals(null, records, 'Should have records');

        Map<String, Object> firstRecord = (Map<String, Object>) records[0];
        Map<String, Object> childRels = (Map<String, Object>) firstRecord.get('childRelationships');
        System.assertNotEquals(null, childRels, 'Should have childRelationships');
        System.assert(childRels.containsKey('Contacts'), 'Should have Contacts key');
    }

    @IsTest
    static void testJsonFormatting_WithParentRelationships() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should include parent relationship data
        System.assert(formatted.contains('John'), 'Should contain first name');
        System.assert(formatted.contains('Doe'), 'Should contain last name');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');

        // Verify valid JSON
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson, 'Should be valid JSON');
    }

    @IsTest
    static void testJsonFormatting_WithNullRecords() {
        // Given: Null records
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(null, '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(formatted.contains('"metadata"'), 'Should contain metadata');
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson, 'Should be valid JSON');
    }

    @IsTest
    static void testJsonFormatting_WithEmptyList() {
        // Given: Empty list
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(new List<SObject>(), '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('"metadata"'), 'Should contain metadata');
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson, 'Should be valid JSON');
    }

    // ===================================================================================
    // XML FORMAT TESTS
    // ===================================================================================

    @IsTest
    static void testXmlFormatting_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting as XML
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'XML');
        Test.stopTest();

        // Then: Should contain XML structure
        System.assert(String.isNotBlank(formatted), 'Formatted result should not be blank');
        System.assert(formatted.contains('<context_data'), 'Should have context_data root');
        System.assert(formatted.contains('format="XML"'), 'Should specify XML format');
        System.assert(formatted.contains('<metadata>'), 'Should have metadata');
        System.assert(formatted.contains('<record>'), 'Should have record elements');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
    }

    @IsTest
    static void testXmlFormatting_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'XML');
        Test.stopTest();

        // Then: Should include child relationship XML structure
        System.assert(formatted.contains('<child_relationship'), 'Should have child_relationship element');
        System.assert(formatted.contains('name="Contacts"'), 'Should have Contacts name');
        System.assert(formatted.contains('object_type="Contact"'), 'Should have Contact type');
        System.assert(formatted.contains('<child_record'), 'Should have child_record element');
        System.assert(formatted.contains('John'), 'Should contain first name');
        System.assert(formatted.contains('Doe'), 'Should contain last name');
    }

    @IsTest
    static void testXmlFormatting_WithParentRelationships() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ', 'XML');
        Test.stopTest();

        // Then: Should include parent relationship data
        System.assert(formatted.contains('<record'), 'Should have record elements');
        System.assert(formatted.contains('John'), 'Should contain first name');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
    }

    @IsTest
    static void testXmlFormatting_WithNullRecords() {
        // Given: Null records
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(null, '[TEST] ', 'XML');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(formatted.contains('<context_data'), 'Should have context_data');
        System.assert(formatted.contains('<metadata>'), 'Should have metadata');
    }

    @IsTest
    static void testXmlFormatting_WithEmptyList() {
        // Given: Empty list
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(new List<SObject>(), '[TEST] ', 'XML');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('<context_data'), 'Should have context_data');
        System.assert(formatted.contains('<metadata>'), 'Should have metadata');
    }

    // ===================================================================================
    // STRUCTURED TEXT FORMAT TESTS
    // ===================================================================================

    @IsTest
    static void testStructuredTextFormatting_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting as Structured Text
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'Structured Text');
        Test.stopTest();

        // Then: Should contain structured text
        System.assert(String.isNotBlank(formatted), 'Formatted result should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA header');
        System.assert(formatted.contains('Format: Structured Text'), 'Should specify format');
        System.assert(formatted.contains('## Accounts'), 'Should have Accounts header');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
        System.assert(formatted.contains('END OF CONTEXT DATA'), 'Should have end marker');
    }

    @IsTest
    static void testStructuredTextFormatting_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'Structured Text');
        Test.stopTest();

        // Then: Should include child relationship data
        System.assert(formatted.contains('Contacts'), 'Should mention Contacts');
        System.assert(formatted.contains('John'), 'Should contain first name');
        System.assert(formatted.contains('Doe'), 'Should contain last name');
        System.assert(formatted.contains('john.doe@test.com'), 'Should contain email');
    }

    @IsTest
    static void testStructuredTextFormatting_WithParentRelationships() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ', 'Structured Text');
        Test.stopTest();

        // Then: Should include relationship field data
        System.assert(formatted.contains('Account → Account Name:'), 'Should have parent relationship');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
    }

    @IsTest
    static void testStructuredTextFormatting_WithNullRecords() {
        // Given: Null records
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(null, '[TEST] ', 'Structured Text');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA');
        System.assert(formatted.contains('No records to format'), 'Should have message');
    }

    @IsTest
    static void testStructuredTextFormatting_WithEmptyList() {
        // Given: Empty list
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(new List<SObject>(), '[TEST] ', 'Structured Text');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA');
        System.assert(formatted.contains('No records to format'), 'Should have message');
    }

    // ===================================================================================
    // INTERFACE COMPATIBILITY TESTS
    // ===================================================================================

    @IsTest
    static void testDefaultFormat_WithBlankStrategy() {
        // Given: Test accounts and formatter
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Calling with blank format (should default to Structured Text)
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', '');
        Test.stopTest();

        // Then: Should default to Structured Text
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA header');
        System.assert(formatted.contains('Format: Structured Text'), 'Should use Structured Text');
        System.assert(formatted.contains('Test Account'), 'Should contain data');
    }

    @IsTest
    static void testUnknownFormat_DefaultsToStructuredText() {
        // Given: Test accounts and unknown format
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Using unknown format
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', 'UnknownFormat');
        Test.stopTest();

        // Then: Should default to Structured Text
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA header');
        System.assert(formatted.contains('Format: Structured Text'), 'Should use Structured Text');
    }

    @IsTest
    static void testBlankFormat_DefaultsToStructuredText() {
        // Given: Test accounts and blank format
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        ContextFormattingService formatter = new ContextFormattingService();

        // When: Using blank format
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ', '');
        Test.stopTest();

        // Then: Should default to Structured Text
        System.assert(String.isNotBlank(formatted), 'Should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should have METADATA header');
        System.assert(formatted.contains('Format: Structured Text'), 'Should use Structured Text');
    }

    // ===================================================================================
    // MULTI-OBJECT TYPE TESTS
    // ===================================================================================

    @IsTest
    static void testJsonFormatting_MultipleObjectTypes() {
        // Given: Multiple record types
        Account acc = [SELECT Id FROM Account LIMIT 1];
        TestFactory.newContact().withName('Jane', 'Smith').withEmail('jane.smith@test.com').withAccount(acc.Id).save();

        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Id = :acc.Id];
        List<Contact> contacts = [SELECT Id, FirstName, LastName FROM Contact WHERE AccountId = :acc.Id];

        List<SObject> mixedRecords = new List<SObject>();
        mixedRecords.addAll(accounts);
        mixedRecords.addAll(contacts);

        ContextFormattingService formatter = new ContextFormattingService();

        // When: Formatting mixed types as JSON
        Test.startTest();
        String formatted = formatter.formatContext(mixedRecords, '[TEST] ', 'JSON');
        Test.stopTest();

        // Then: Should handle both object types
        System.assert(formatted.contains('Test Account'), 'Should contain account');
        System.assert(formatted.contains('John'), 'Should contain first contact');
        System.assert(formatted.contains('Jane'), 'Should contain second contact');

        // Verify it's valid JSON array
        List<Object> parsedArray = (List<Object>) JSON.deserializeUntyped(formatted);
        System.assertEquals(2, parsedArray.size(), 'Should have 2 object groups');
    }
}
