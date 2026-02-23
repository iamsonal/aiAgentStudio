/**
 * @description Tests for ContextFormattingService formatting options.
 */
@IsTest
private class ContextFormattingServiceTest {
    @IsTest
    static void testFormatContext_ExcludesIdFields() {
        Account account = new Account(Name = 'Format Account');
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withExcludeIdFields(true).withMetadata(true);

        String output = service.formatContext(new List<SObject>{ account }, '[test]', 'JSON', options);
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(output);

        // The formatter wraps single object type in a metadata structure
        Map<String, Object> meta = (Map<String, Object>) parsed.get('_meta');
        List<Object> records = (List<Object>) parsed.get('records');
        Map<String, Object> record = (Map<String, Object>) records[0];

        System.assertEquals(false, record.containsKey('Id'), 'Id field should be excluded');
        System.assertEquals('Format Account', record.get('Account Name'), 'Name should be included with field label');
    }

    @IsTest
    static void testFormatContext_DefaultsToJsonMetadata() {
        Account account = new Account(Name = 'Meta Account');
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        String output = service.formatContext(new List<SObject>{ account }, '[test]', null);

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(output);
        System.assert(parsed.containsKey('_meta'), 'Default JSON output should include metadata');
    }

    @IsTest
    static void testFormatContext_TruncatesWhenOverMaxChars() {
        Account account = new Account(Name = 'Truncate Account', Description = String.valueOf('x').repeat(1000));
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withMaxChars(200);

        String output = service.formatContext(new List<SObject>{ account }, '[test]', 'JSON', options);

        System.assert(output.contains('[truncated]'), 'Output should include truncation marker');
    }

    @IsTest
    static void testFormatContext_AppliesPiiMasking() {
        Contact contact = new Contact(LastName = 'Masked', Birthdate = Date.newInstance(1990, 1, 1));
        insert contact;

        PIIMaskingService maskingService = new PIIMaskingService(PIIMaskingService.MODE_SCHEMA_ONLY, null, null, null);
        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withPIIMasking(maskingService);

        String output = service.formatContext(new List<SObject>{ contact }, '[test]', 'JSON', options);

        System.assert(!output.contains('1990-01-01'), 'Birthdate should be masked');
        System.assert(output.contains('[FIELD_BIRTHDATE:'), 'Masked token should be present');
    }

    @IsTest
    static void testFormatContext_SmallMaxChars_NonJsonAddsMarker() {
        Account account = new Account(Name = 'Small Max', Description = String.valueOf('x').repeat(200));
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withMaxChars(40);

        String output = service.formatContext(new List<SObject>{ account }, '[test]', 'TEXT', options);
        System.assert(output.contains('[truncated due to size limit]'), 'Small max chars should include truncation marker');
    }

    @IsTest
    static void testFormatContext_TruncateWithoutNewlines_Safe() {
        Account account = new Account(Name = 'No Newlines', Description = String.valueOf('a').repeat(800));
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withMaxChars(120);

        String output = service.formatContext(new List<SObject>{ account }, '[test]', 'JSON', options);
        System.assert(output.contains('[truncated]'), 'Output should include truncation marker for JSON');
    }

    @IsTest
    static void testFormatContext_TruncateWithNewlines_Safe() {
        String longText = String.valueOf('line1\nline2\nline3\nline4\nline5\n').repeat(40);
        Account account = new Account(Name = 'With Newlines', Description = longText);
        insert account;

        ContextFormattingService service = new ContextFormattingService();
        ContextFormattingService.FormattingOptions options = new ContextFormattingService.FormattingOptions().withMaxChars(180);

        String output = service.formatContext(new List<SObject>{ account }, '[test]', 'JSON', options);
        System.assert(output.contains('[truncated]'), 'Output should include truncation marker');
    }

    @IsTest
    static void testFormatContext_JsonIncludesChildRelationships() {
        Account account = new Account(Name = 'Parent Account');
        insert account;
        Contact contact = new Contact(LastName = 'Child Contact', AccountId = account.Id);
        insert contact;

        Account accountWithChildren = [
            SELECT Id, Name, (SELECT Id, LastName FROM Contacts)
            FROM Account
            WHERE Id = :account.Id
            LIMIT 1
        ];

        ContextFormattingService service = new ContextFormattingService();
        String output = service.formatContext(new List<SObject>{ accountWithChildren }, '[test]', 'JSON');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(output);
        List<Object> records = (List<Object>) parsed.get('records');
        Map<String, Object> record = (Map<String, Object>) records[0];
        Map<String, Object> children = (Map<String, Object>) record.get('_children');

        System.assert(children.containsKey('Contacts'), 'JSON should include Contacts child relationship');
        List<Object> contactList = (List<Object>) children.get('Contacts');
        Map<String, Object> child = (Map<String, Object>) contactList[0];
        System.assertEquals('Child Contact', child.get('Last Name'), 'Child record fields should be included');
    }

    @IsTest
    static void testFormatContext_YamlIncludesChildRelationships() {
        Account account = new Account(Name = 'Yaml Parent');
        insert account;
        Contact contact = new Contact(LastName = 'Yaml Child', AccountId = account.Id);
        insert contact;

        Account accountWithChildren = [
            SELECT Id, Name, (SELECT Id, LastName FROM Contacts)
            FROM Account
            WHERE Id = :account.Id
            LIMIT 1
        ];

        ContextFormattingService service = new ContextFormattingService();
        String output = service.formatContext(new List<SObject>{ accountWithChildren }, '[test]', 'YAML');

        System.assert(output.contains('Contacts:'), 'YAML should include Contacts child relationship');
        System.assert(output.contains('Last Name: Yaml Child'), 'YAML should include child field values');
    }

    @IsTest
    static void testFormatContext_JsonIncludesRelatedFields() {
        Account account = new Account(Name = 'Related Account');
        insert account;
        Case testCase = new Case(Subject = 'Related Case', AccountId = account.Id);
        insert testCase;

        Case caseWithAccount = [
            SELECT Id, Subject, Account.Name
            FROM Case
            WHERE Id = :testCase.Id
            LIMIT 1
        ];

        ContextFormattingService service = new ContextFormattingService();
        String output = service.formatContext(new List<SObject>{ caseWithAccount }, '[test]', 'JSON');

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(output);
        List<Object> records = (List<Object>) parsed.get('records');
        Map<String, Object> record = (Map<String, Object>) records[0];

        System.assertEquals('Related Case', record.get('Subject'), 'Case subject should be present');
        System.assertEquals('Related Account', record.get('Account.Account Name'), 'Related account fields should be flattened');
    }

    @IsTest
    static void testFormatContext_YamlIncludesRelatedFields() {
        Account account = new Account(Name = 'Yaml Related Account');
        insert account;
        Case testCase = new Case(Subject = 'Yaml Related Case', AccountId = account.Id);
        insert testCase;

        Case caseWithAccount = [
            SELECT Id, Subject, Account.Name
            FROM Case
            WHERE Id = :testCase.Id
            LIMIT 1
        ];

        ContextFormattingService service = new ContextFormattingService();
        String output = service.formatContext(new List<SObject>{ caseWithAccount }, '[test]', 'YAML');

        System.assert(output.contains('Subject: Yaml Related Case'), 'YAML should include Case subject');
        System.assert(output.contains('Account.Account Name: Yaml Related Account'), 'YAML should include related account fields');
    }
}
