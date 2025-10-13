/**
 * @description Tests for context formatter implementations using TestFactory utilities
 */
@IsTest
private class ContextFormatterTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test data
        Account account = TestFactory.newAccount()
            .withName('Test Account')
            .withDescription('Test account for context formatting')
            .save();

        TestFactory.newContact()
            .withName('John', 'Doe')
            .withEmail('john.doe@test.com')
            .withAccount(account.Id)
            .save();
    }

    // ===================================================================================
    // XML FORMATTER TESTS
    // ===================================================================================

    @IsTest
    static void testXmlContextFormatter_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        IContextFormatter formatter = new XmlContextFormatter();

        // When: Formatting context
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should contain XML structure
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('<context_data'));
        System.assert(formatted.contains('format="XML"'));
        System.assert(formatted.contains('<metadata>'));
        System.assert(formatted.contains('<record>'));
        System.assert(formatted.contains('Test Account'));
    }

    // ===================================================================================
    // JSON FORMATTER TESTS
    // ===================================================================================

    @IsTest
    static void testJsonContextFormatter_BasicFormatting() {
        // Given: Test accounts
        List<Account> accounts = [SELECT Id, Name, Description FROM Account LIMIT 1];
        IContextFormatter formatter = new JsonContextFormatter();

        // When: Formatting context
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should contain valid JSON
        System.assert(String.isNotBlank(formatted));
        System.assert(formatted.contains('"metadata"'));
        System.assert(formatted.contains('"format" : "JSON"'));
        System.assert(formatted.contains('"records"'));
        System.assert(formatted.contains('Test Account'));

        // Verify valid JSON
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson);
        System.assert(parsedJson.containsKey('metadata'));
    }

    // ===================================================================================
    // STRUCTURED TEXT FORMATTER TESTS
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
    // FACTORY TESTS
    // ===================================================================================

    @IsTest
    static void testContextFormatterFactory_CreatesCorrectFormatters() {
        // Test: XML formatter
        IContextFormatter xmlFormatter = ContextFormatterFactory.createFormatter('XML');
        System.assert(xmlFormatter instanceof XmlContextFormatter);

        // Test: JSON formatter
        IContextFormatter jsonFormatter = ContextFormatterFactory.createFormatter('JSON');
        System.assert(jsonFormatter instanceof JsonContextFormatter);

        // Test: StructuredText formatter
        IContextFormatter textFormatter = ContextFormatterFactory.createFormatter('StructuredText');
        System.assert(textFormatter instanceof StructuredTextContextFormatter);

        // Test: Default (null)
        IContextFormatter defaultFormatter = ContextFormatterFactory.createFormatter(null);
        System.assert(defaultFormatter instanceof StructuredTextContextFormatter);

        // Test: Unknown strategy
        IContextFormatter unknownFormatter = ContextFormatterFactory.createFormatter('Unknown');
        System.assert(unknownFormatter instanceof StructuredTextContextFormatter);
    }

    // ===================================================================================
    // RELATIONSHIP TESTS - STRUCTURED TEXT
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
    // RELATIONSHIP TESTS - XML
    // ===================================================================================

    @IsTest
    static void testXmlFormatter_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        IContextFormatter formatter = new XmlContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should include child relationship XML structure
        System.assert(formatted.contains('<child_relationship'));
        System.assert(formatted.contains('name="Contacts"'));
        System.assert(formatted.contains('object_type="Contact"'));
        System.assert(formatted.contains('<child_record'));
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('john.doe@test.com'));
    }

    @IsTest
    static void testXmlFormatter_WithEmptyChildRelationship() {
        // Given: Account with no contacts
        Account acc = TestFactory.newAccount()
            .withName('Account Without Contacts')
            .save();

        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName FROM Contacts)
            FROM Account
            WHERE Id = :acc.Id
        ];
        IContextFormatter formatter = new XmlContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should not include child relationships (empty)
        System.assert(formatted.contains('<record'));
        System.assert(formatted.contains('Account Without Contacts'));
    }

    // ===================================================================================
    // RELATIONSHIP TESTS - JSON
    // ===================================================================================

    @IsTest
    static void testJsonFormatter_WithChildRelationships() {
        // Given: Account with contacts
        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            LIMIT 1
        ];
        IContextFormatter formatter = new JsonContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should include child relationship JSON structure
        System.assert(formatted.contains('"childRelationships"'));
        System.assert(formatted.contains('"Contacts"'));
        System.assert(formatted.contains('"relationshipName" : "Contacts"'));
        System.assert(formatted.contains('"childObjectType" : "Contact"'));
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('john.doe@test.com'));

        // Verify valid JSON
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        System.assertNotEquals(null, parsedJson);

        List<Object> records = (List<Object>) parsedJson.get('records');
        System.assertNotEquals(null, records);
        System.assertEquals(1, records.size());

        Map<String, Object> firstRecord = (Map<String, Object>) records[0];
        Map<String, Object> childRelationships = (Map<String, Object>) firstRecord.get('childRelationships');
        System.assertNotEquals(null, childRelationships, 'Should have childRelationships');
        System.assert(childRelationships.containsKey('Contacts'), 'Should have Contacts relationship');

        // Verify nested structure
        Map<String, Object> contactsRelationship = (Map<String, Object>) childRelationships.get('Contacts');
        System.assertNotEquals(null, contactsRelationship, 'Should have Contacts relationship object');

        Map<String, Object> relationshipInfo = (Map<String, Object>) contactsRelationship.get('relationshipInfo');
        System.assertNotEquals(null, relationshipInfo, 'Should have relationshipInfo');
        System.assertEquals('Contacts', relationshipInfo.get('relationshipName'));
        System.assertEquals('Contact', relationshipInfo.get('childObjectType'));
    }

    @IsTest
    static void testJsonFormatter_WithMultipleChildRecords() {
        // Given: Account with multiple contacts
        Account acc = [SELECT Id FROM Account LIMIT 1];
        TestFactory.newContact()
            .withName('Jane', 'Smith')
            .withEmail('jane.smith@test.com')
            .withAccount(acc.Id)
            .save();

        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName, Email FROM Contacts ORDER BY FirstName)
            FROM Account
            WHERE Id = :acc.Id
        ];

        IContextFormatter formatter = new JsonContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should include all child records
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Jane'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('Smith'));

        // Verify child records array
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        List<Object> records = (List<Object>) parsedJson.get('records');
        Map<String, Object> firstRecord = (Map<String, Object>) records[0];
        Map<String, Object> childRelationships = (Map<String, Object>) firstRecord.get('childRelationships');
        System.assertNotEquals(null, childRelationships, 'Should have childRelationships map');

        Map<String, Object> contactsRelationship = (Map<String, Object>) childRelationships.get('Contacts');
        System.assertNotEquals(null, contactsRelationship, 'Should have Contacts relationship');

        // Verify relationshipInfo
        Map<String, Object> relationshipInfo = (Map<String, Object>) contactsRelationship.get('relationshipInfo');
        System.assertNotEquals(null, relationshipInfo, 'Should have relationshipInfo');
        System.assertEquals(2, relationshipInfo.get('recordCount'), 'Should report 2 records');

        List<Object> contactRecords = (List<Object>) contactsRelationship.get('records');
        System.assertNotEquals(null, contactRecords, 'Should have contact records array');
        System.assertEquals(2, contactRecords.size(), 'Should have 2 contact records');
    }

    @IsTest
    static void testJsonFormatter_WithEmptyChildRelationship() {
        // Given: Account with no contacts
        Account acc = TestFactory.newAccount()
            .withName('Account Without Contacts JSON')
            .save();

        List<Account> accounts = [
            SELECT Id, Name, (SELECT Id, FirstName, LastName FROM Contacts)
            FROM Account
            WHERE Id = :acc.Id
        ];
        IContextFormatter formatter = new JsonContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(accounts, '[TEST] ');
        Test.stopTest();

        // Then: Should not include empty child relationships
        System.assert(formatted.contains('"records"'));
        System.assert(formatted.contains('Account Without Contacts JSON'));

        // Verify JSON structure
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        List<Object> records = (List<Object>) parsedJson.get('records');
        Map<String, Object> firstRecord = (Map<String, Object>) records[0];

        // Empty child relationships should not be included or should be empty
        if (firstRecord.containsKey('childRelationships')) {
            Map<String, Object> childRels = (Map<String, Object>) firstRecord.get('childRelationships');
            System.assert(childRels == null || childRels.isEmpty() || !childRels.containsKey('Contacts'),
                         'Empty child relationships should not be included');
        }
    }

    // ===================================================================================
    // PARENT RELATIONSHIP TESTS - ALL FORMATTERS
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

    @IsTest
    static void testXmlFormatter_WithParentRelationshipFields() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        IContextFormatter formatter = new XmlContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ');
        Test.stopTest();

        // Then: Should include parent relationship data in XML
        System.assert(formatted.contains('<record'));
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('Test Account'));
    }

    @IsTest
    static void testJsonFormatter_WithParentRelationshipFields() {
        // Given: Contact with account relationship
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Account.Name, Account.Description
            FROM Contact
            LIMIT 1
        ];
        IContextFormatter formatter = new JsonContextFormatter();

        // When: Formatting
        Test.startTest();
        String formatted = formatter.formatContext(contacts, '[TEST] ');
        Test.stopTest();

        // Then: Should include parent relationship data in JSON
        System.assert(formatted.contains('John'));
        System.assert(formatted.contains('Doe'));
        System.assert(formatted.contains('Test Account'));

        // Verify valid JSON structure
        Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
        List<Object> records = (List<Object>) parsedJson.get('records');
        System.assertNotEquals(null, records);
        System.assertEquals(1, records.size());
    }

    // ===================================================================================
    // EDGE CASE TESTS
    // ===================================================================================

    @IsTest
    static void testFormatContext_EmptyList() {
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

    @IsTest
    static void testFormatContext_NullRecords() {
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
    static void testErrorHandling_AllFormatters() {
        // Test: JSON formatter with null
        IContextFormatter jsonFormatter = new JsonContextFormatter();
        String jsonResult = jsonFormatter.formatContext(null, '[TEST] ');
        System.assert(jsonResult.contains('"metadata"'));

        // Test: XML formatter with null
        IContextFormatter xmlFormatter = new XmlContextFormatter();
        String xmlResult = xmlFormatter.formatContext(null, '[TEST] ');
        System.assert(xmlResult.contains('<context_data'));
        System.assert(xmlResult.contains('<metadata>'));

        // Test: Structured text formatter with null
        IContextFormatter textFormatter = new StructuredTextContextFormatter();
        String textResult = textFormatter.formatContext(null, '[TEST] ');
        System.assert(textResult.contains('METADATA'));
        System.assert(textResult.contains('No records to format'));
    }
}
