/**
 * @description Tests for StructuredTextContextFormatter implementation and context formatter metadata mapping
 */
@IsTest
private class StructuredTextContextFormatterTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test data
        Account account = TestFactory.newAccount().withName('Test Account').withDescription('Test account for structured text formatting').save();

        TestFactory.newContact().withName('John', 'Doe').withEmail('john.doe@test.com').withAccount(account.Id).save();
    }

    // ===================================================================================
    // BASIC FORMATTING TESTS
    // ===================================================================================

    @IsTest
    static void testStructuredTextFormatter_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        IContextFormatter formatter = new StructuredTextContextFormatter();

        // When: Formatting context
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should contain structured text
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('METADATA'));
        System.assert(formatted.contains('Format: Structured Text'));
        System.assert(formatted.contains('## Accounts'));
        System.assert(formatted.contains('Test Account'));
        System.assert(formatted.contains('END OF CONTEXT DATA'));
    }

    // ===================================================================================
    // CHILD RELATIONSHIP TESTS
    // ===================================================================================

    @IsTest
    static void testStructuredTextFormatter_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        IContextFormatter formatter = new StructuredTextContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should include child relationship data
        System.assert(formatted.contains('Contacts'));
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('john.doe@test.com'));
    }

    // ===================================================================================
    // PARENT RELATIONSHIP TESTS
    // ===================================================================================

    @IsTest
    static void testStructuredTextFormatter_WithParentRelationshipFields() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        IContextFormatter formatter = new StructuredTextContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ');
        Test.stopTest();

        // Then: Should include relationship field data
        System.assert(formatted.contains('Account → Account Name:'));
        System.assert(formatted.contains('Test Account'));
    }

    // ===================================================================================
    // EDGE CASE TESTS
    // ===================================================================================

    @IsTest
    static void testStructuredTextFormatter_WithNullRecords() {
        // Given: Null records
        IContextFormatter formatter = new StructuredTextContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(null, '[TEST] ');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('METADATA'));
        System.assert(formatted.contains('No records to format'));
    }

    @IsTest
    static void testStructuredTextFormatter_WithEmptyList() {
        // Given: Empty list
        IContextFormatter formatter = new StructuredTextContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(new List<SObject>(), '[TEST] ');
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('METADATA'));
        System.assert(formatted.contains('No records to format'));
    }
}
