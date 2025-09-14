/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Test class for context formatter implementations.
 */
@IsTest
private class ContextFormatterTest {
    @TestSetup
    static void makeData() {
        // Create test account
        Account testAccount = new Account(Name = 'Test Account', Description = 'This is a test account for context formatting');
        insert testAccount;

        // Create test contact
        Contact testContact = new Contact(FirstName = 'John', LastName = 'Doe', Email = 'john.doe@test.com', AccountId = testAccount.Id);
        insert testContact;
    }

    @IsTest
    static void testXmlContextFormatter() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account WHERE Name = 'Test Account' LIMIT 1];

        System.debug('Test accounts: ' + accounts);
        System.debug('Account count: ' + accounts.size());

        IContextFormatter formatter = new XmlContextFormatter();
        String formatted = formatter.formatContext(accounts, '[TEST] ');

        System.debug('XML Formatted Output: ' + formatted);
        System.debug('XML Formatted Output Length: ' + formatted.length());

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('<context_data'), 'Should contain XML root element with metadata');
        System.assert(formatted.contains('format="XML"'), 'Should contain format attribute');
        System.assert(formatted.contains('<metadata>'), 'Should contain metadata section');
        System.assert(formatted.contains('<object_group'), 'Should contain XML object group');
        System.assert(formatted.contains('<record>'), 'Should contain XML record tags');
        System.assert(formatted.contains('<field'), 'Should contain XML field tags');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
    }

    @IsTest
    static void testJsonContextFormatter() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account WHERE Name = 'Test Account' LIMIT 1];

        System.debug('Test accounts: ' + accounts);
        System.debug('Account count: ' + accounts.size());

        IContextFormatter formatter = new JsonContextFormatter();
        String formatted = formatter.formatContext(accounts, '[TEST] ');

        System.debug('JSON Formatted Output: ' + formatted);
        System.debug('JSON Formatted Output Length: ' + formatted.length());

        System.assert(String.isNotBlank(formatted), 'Formatted JSON context should not be blank');
        System.assert(formatted.contains('"metadata"'), 'Should contain metadata section');
        System.assert(formatted.contains('"format" : "JSON"'), 'Should contain format information');
        System.assert(formatted.contains('"objectInfo"'), 'Should contain objectInfo section');
        System.assert(formatted.contains('"records"'), 'Should contain records array');
        System.assert(formatted.contains('"fields"'), 'Should contain fields section');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');

        // Verify it's valid JSON
        try {
            Map<String, Object> parsedJson = (Map<String, Object>) JSON.deserializeUntyped(formatted);
            System.assertNotEquals(null, parsedJson, 'Should be valid JSON');

            // Check for metadata
            System.assert(parsedJson.containsKey('metadata'), 'Should contain metadata key');
            Map<String, Object> metadata = (Map<String, Object>) parsedJson.get('metadata');
            System.assert(metadata.containsKey('format'), 'Metadata should contain format');
            System.assertEquals('JSON', metadata.get('format'), 'Format should be JSON');
        } catch (Exception e) {
            System.assert(false, 'JSON should be valid and parseable: ' + e.getMessage());
        }
    }

    @IsTest
    static void testStructuredTextContextFormatter() {
        // Get test records
        List<Account> accounts = [SELECT Id, Name, Description FROM Account WHERE Name = 'Test Account' LIMIT 1];

        System.debug('Test accounts: ' + accounts);
        System.debug('Account count: ' + accounts.size());

        IContextFormatter formatter = new StructuredTextContextFormatter();
        String formatted = formatter.formatContext(accounts, '[TEST] ');

        System.debug('Structured Text Formatted Output: ' + formatted);
        System.debug('Structured Text Formatted Output Length: ' + formatted.length());

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('METADATA'), 'Should contain metadata section');
        System.assert(formatted.contains('Format: Structured Text'), 'Should contain format information');
        System.assert(formatted.contains('## Accounts'), 'Should contain object group header');
        System.assert(formatted.contains('Test Account'), 'Should contain account name');
        System.assert(formatted.contains('Description:'), 'Should contain non-primary field labels');
        System.assert(formatted.contains('END OF CONTEXT DATA'), 'Should contain end of data marker');
    }

    @IsTest
    static void testContextFormatterFactory() {
        // Test XML formatter creation
        IContextFormatter xmlFormatter = ContextFormatterFactory.createFormatter('XML');
        System.assert(xmlFormatter instanceof XmlContextFormatter, 'Should create XmlContextFormatter for XML strategy');

        // Test JSON formatter creation
        IContextFormatter jsonFormatter = ContextFormatterFactory.createFormatter('JSON');
        System.assert(jsonFormatter instanceof JsonContextFormatter, 'Should create JsonContextFormatter for JSON strategy');

        // Test StructuredText formatter creation
        IContextFormatter textFormatter = ContextFormatterFactory.createFormatter('StructuredText');
        System.assert(
            textFormatter instanceof StructuredTextContextFormatter,
            'Should create StructuredTextContextFormatter for StructuredText strategy'
        );

        // Test default formatter creation
        IContextFormatter defaultFormatter = ContextFormatterFactory.createFormatter(null);
        System.assert(defaultFormatter instanceof StructuredTextContextFormatter, 'Should create StructuredTextContextFormatter for null strategy');

        IContextFormatter defaultFormatter2 = ContextFormatterFactory.createFormatter('Unknown');
        System.assert(
            defaultFormatter2 instanceof StructuredTextContextFormatter,
            'Should create StructuredTextContextFormatter for unknown strategy'
        );
    }

    @IsTest
    static void testFormatContextWithChildRelationships() {
        // Get account with contacts
        List<Account> accounts = [
            SELECT Id, Name, Description, (SELECT Id, FirstName, LastName, Email FROM Contacts)
            FROM Account
            WHERE Name = 'Test Account'
            LIMIT 1
        ];

        System.debug('Test accounts with children: ' + accounts);
        System.debug('Account count: ' + accounts.size());
        if (!accounts.isEmpty()) {
            System.debug('Contacts count: ' + accounts[0].Contacts.size());
        }

        IContextFormatter formatter = new StructuredTextContextFormatter();
        String formatted = formatter.formatContext(accounts, '[TEST] ');

        System.debug('Child Relationship Formatted Output: ' + formatted);
        System.debug('Child Relationship Formatted Output Length: ' + formatted.length());

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('Contacts'), 'Should contain child relationship');
        System.assert(formatted.contains('John'), 'Should contain contact first name');
        System.assert(formatted.contains('Doe'), 'Should contain contact last name');
    }

    @IsTest
    static void testFormatContextWithRelationshipFields() {
        // Create test data with relationship fields
        List<Contact> contacts = [
            SELECT Id, FirstName, LastName, Email, Account.Name
            FROM Contact
            WHERE Account.Name = 'Test Account'
            LIMIT 1
        ];

        System.debug('Test contacts with relationships: ' + contacts);
        System.debug('Contact count: ' + contacts.size());

        IContextFormatter formatter = new StructuredTextContextFormatter();
        String formatted = formatter.formatContext(contacts, '[TEST] ');

        System.debug('Relationship Fields Formatted Output: ' + formatted);
        System.debug('Relationship Fields Formatted Output Length: ' + formatted.length());

        System.assert(String.isNotBlank(formatted), 'Formatted context should not be blank');
        System.assert(formatted.contains('Account → Account Name:'), 'Should contain relationship field label');
        System.assert(formatted.contains('Test Account'), 'Should contain related account name');
    }

    @IsTest
    static void testFormatContextEmptyList() {
        IContextFormatter formatter = new StructuredTextContextFormatter();
        String formatted = formatter.formatContext(new List<SObject>(), '[TEST] ');

        System.assert(String.isNotBlank(formatted), 'Empty list should return metadata with message');
        System.assert(formatted.contains('METADATA'), 'Should contain metadata section');
        System.assert(formatted.contains('No records to format'), 'Should contain no records message');
    }

    @IsTest
    static void testFormatContextWithNullRecords() {
        IContextFormatter formatter = new StructuredTextContextFormatter();
        String formatted = formatter.formatContext(null, '[TEST] ');

        System.assert(String.isNotBlank(formatted), 'Null records should return metadata with message');
        System.assert(formatted.contains('METADATA'), 'Should contain metadata section');
        System.assert(formatted.contains('No records to format'), 'Should contain no records message');
    }

    @IsTest
    static void testErrorHandlingInFormatters() {
        // Test JSON formatter error handling
        IContextFormatter jsonFormatter = new JsonContextFormatter();
        String jsonErrorResult = jsonFormatter.formatContext(null, '[TEST] ');

        System.assert(String.isNotBlank(jsonErrorResult), 'JSON formatter should return result even with null input');
        System.assert(jsonErrorResult.contains('"metadata"'), 'JSON error result should contain metadata');

        // Test XML formatter error handling
        IContextFormatter xmlFormatter = new XmlContextFormatter();
        String xmlErrorResult = xmlFormatter.formatContext(null, '[TEST] ');

        System.assert(String.isNotBlank(xmlErrorResult), 'XML formatter should return result even with null input');
        System.assert(xmlErrorResult.contains('<context_data'), 'XML error result should contain root element');
        System.assert(xmlErrorResult.contains('<metadata>'), 'XML error result should contain metadata');

        // Test Structured Text formatter error handling
        IContextFormatter textFormatter = new StructuredTextContextFormatter();
        String textErrorResult = textFormatter.formatContext(null, '[TEST] ');

        System.assert(String.isNotBlank(textErrorResult), 'Structured Text formatter should return result even with null input');
        System.assert(textErrorResult.contains('METADATA'), 'Structured Text error result should contain metadata');
        System.assert(textErrorResult.contains('No records to format'), 'Structured Text error result should contain message');
    }
}
