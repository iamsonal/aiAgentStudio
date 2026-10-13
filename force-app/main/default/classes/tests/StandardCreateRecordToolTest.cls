/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

@IsTest
private class StandardCreateRecordToolTest {
    private static AgentKernelModels.ToolRequest request(String config, String input) {
        AgentKernelModels.ToolRequest toolRequest = new AgentKernelModels.ToolRequest();
        toolRequest.toolName = 'standard_create';
        toolRequest.input = input;
        toolRequest.implementationConfiguration = config;
        return toolRequest;
    }

    @IsTest
    static void createsAccountFromFlatInput() {
        AgentKernelModels.ToolResponse response = new StandardCreateRecordTool()
            .execute(request(accountConfig('"Name","Industry"'), '{"recordData":{"Name":"ToolAuthoring Test Acme","Industry":"Technology"}}'));

        System.assertEquals(true, response.isSuccess);
        Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(response.output);
        System.assert(!String.isBlank((String) output.get('id')), 'Create must return the new record id.');
        List<Account> created = [SELECT Id, Industry FROM Account WHERE Id = :(Id) output.get('id') LIMIT 1];
        System.assertEquals(1, created.size());
        System.assertEquals('Technology', created[0].Industry);
    }

    @IsTest
    static void appliesOperatorDefaultFieldsWithoutExposingThemToInput() {
        AgentKernelModels.ToolResponse response = new StandardCreateRecordTool()
            .execute(
                request(
                    '{"objectApiName":"Account","fields":["Name"],"defaultFieldValues":{"Description":"Created by AI Agent"}}',
                    '{"recordData":{"Name":"Configured defaults account"}}'
                )
            );

        Id recordId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(response.output)).get('id');
        System.assertEquals('Created by AI Agent', [SELECT Description FROM Account WHERE Id = :recordId].Description);
    }

    @IsTest
    static void fixedFieldValuesTieNewRecordsToTheRunsRecord() {
        Account anchor = new Account(Name = 'Run record');
        insert anchor;
        String config = '{"objectApiName":"Contact","fields":["LastName"],"defaultFieldValues":{"AccountId":":anchorId"}}';
        AgentKernelModels.ToolRequest call = request(config, '{"recordData":{"LastName":"Child"}}');
        call.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), anchor.Id, null);

        Id recordId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(new StandardCreateRecordTool().execute(call).output)).get('id');
        System.assertEquals(anchor.Id, [SELECT AccountId FROM Contact WHERE Id = :recordId].AccountId);

        Contact wrongType = new Contact(LastName = 'Not an account');
        insert wrongType;
        call.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), wrongType.Id, null);
        Boolean refused = false;
        try {
            new StandardCreateRecordTool().execute(call);
        } catch (AgentKernelException.PermanentException expected) {
            refused = expected.getMessage().contains('AccountId cannot point to the run\'s record, which is a Contact');
        }
        System.assert(refused, 'A run record of the wrong type is refused before any write.');
    }

    @IsTest
    static void rejectsModelOverrideOfOperatorDefaultField() {
        assertPermanent(
            '{"objectApiName":"Account","fields":["Name"],"defaultFieldValues":{"Description":"Created by AI Agent"}}',
            '{"recordData":{"Name":"Configured defaults account","Description":"Model override"}}',
            'operator-managed default field'
        );
    }

    @IsTest
    static void rejectsMissingConfiguration() {
        assertPermanent(null, '{"recordData":{"Name":"Acme"}}', 'implementation configuration');
        assertPermanent('{}', '{"recordData":{"Name":"Acme"}}', 'objectApiName');
    }

    @IsTest
    static void rejectsUnknownObjectFieldAndEmptyInput() {
        assertPermanent('{"objectApiName":"Nope__c"}', '{"recordData":{"Name":"Acme"}}', 'Unknown object');
        assertPermanent(accountConfig('"Name"'), '{"recordData":{"Nope__c":"x"}}', 'may not set Nope__c');
        assertPermanent(accountConfig('"Name"'), '{"recordData":{}}', 'at least one field');
        assertPermanent(accountConfig('"Name"'), 'not-json', 'must be a JSON object');
    }

    @IsTest
    static void rejectsNonWritableField() {
        assertPermanent(accountConfig('"CreatedDate"'), '{"recordData":{"CreatedDate":"2026-01-01"}}', 'cannot be set on create');
    }

    @IsTest
    static void theFieldListIsTheOnlyGrantEvenWithAHandwrittenSchema() {
        String schemaOnly = '{"objectApiName":"Account"}';
        assertPermanent(schemaOnly, '{"recordData":{"Name":"Acme"}}', 'List the fields the agent may set in fields');
        AgentKernelModels.ToolConfiguration configuration = new AgentKernelModels.ToolConfiguration();
        configuration.implementationConfiguration = schemaOnly;
        configuration.inputSchema = '{"type":"object","properties":{"recordData":{"type":"object","properties":{"Name":{"type":"string"}}}}}';
        System.assert(String.join(new StandardCreateRecordTool().validateConfiguration(configuration), ' ').contains('List the fields'));
        assertPermanent(accountConfig('"Name"'), '{"recordData":{"Name":"Acme","Industry":"Technology"}}', 'may not set Industry');
    }

    @IsTest
    static void rejectsWrongTypeRecordTypeAndGuidesRequiredFields() {
        Account existing = new Account(Name = 'Existing Account');
        insert existing;

        assertInvalidRecordType(existing.Id);
        assertPermanent(accountConfig('"Industry"'), '{"recordData":{"Industry":"Technology"}}', 'Supply all required fields');
    }

    @IsTest
    static void coercesReferenceIdsAndRejectsInvalidReferenceValues() {
        System.assertEquals(UserInfo.getUserId(), StandardToolSupport.coerceValue(Schema.DisplayType.REFERENCE, UserInfo.getUserId(), 'OwnerId'));
        Boolean rejected = false;
        try {
            StandardToolSupport.coerceValue(Schema.DisplayType.REFERENCE, 'not-an-id', 'OwnerId');
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains('valid Salesforce record ID');
        }
        System.assert(rejected, 'Reference fields must reject malformed IDs before DML.');
    }

    @IsTest
    static void coercesIsoDatetimesWithTheirTimeZone() {
        System.assertEquals(
            Datetime.newInstanceGmt(2026, 10, 1, 15, 30, 0),
            StandardToolSupport.coerceValue(Schema.DisplayType.DATETIME, '2026-10-01T15:30:00Z', 'NextStep__c')
        );
        System.assertEquals(
            Datetime.newInstanceGmt(2026, 10, 1, 10, 0, 0),
            StandardToolSupport.coerceValue(Schema.DisplayType.DATETIME, '2026-10-01T15:30:00+05:30', 'NextStep__c'),
            'The offset the model wrote is kept, whatever the service user\'s time zone.'
        );
        Boolean rejected = false;
        try {
            StandardToolSupport.coerceValue(Schema.DisplayType.DATETIME, 'tomorrow', 'NextStep__c');
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains('ISO-8601');
        }
        System.assert(rejected);
    }

    @IsTest
    static void coreAndOptionalPackageRecordsAreNeverTargets() {
        for (String name : new List<String>{ 'AgentRun__c', 'AgentRun__Share', 'AgentApproval__History', 'AgentLifecycleEvent__e', 'AgentChannelRoute__c' }) {
            System.assert(StandardToolSupport.isCoreObject(name), name);
        }
        System.assert(!StandardToolSupport.isCoreObject('Account'));
        System.assert(!StandardToolSupport.isCoreObject('AccountShare'));
    }

    @IsTest
    static void refusesARecordTypeThatIsNotAnActiveRecordTypeOfTheObject() {
        for (String name : new List<String>{ 'NoSuchRecordType', 'Master' }) {
            String config = '{"objectApiName":"Account","fields":["Name"],"recordTypeDeveloperName":"' + name + '"}';
            assertPermanent(config, '{"recordData":{"Name":"Acme"}}', 'is not an active record type of Account');
            System.assert(
                String.join(new StandardCreateRecordTool().validateConfiguration(configuration(config)), ' ').contains('Choose an active record type'),
                'Save must refuse ' + name + ' before the agent runs.'
            );
        }
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = 'Acme'], 'A refused record type creates nothing.');
    }

    @IsTest
    static void theRecordTypeHasOneOwner() {
        String withDefault = '{"objectApiName":"Account","fields":["Name"],"recordTypeDeveloperName":"Any","defaultFieldValues":{"RecordTypeId":"012000000000000AAA"}}';
        String agentChooses = '{"objectApiName":"Account","fields":["Name","RecordTypeId"],"recordTypeDeveloperName":"Any"}';
        assertPermanent(withDefault, '{"recordData":{"Name":"Acme"}}', 'not both');
        assertPermanent(agentChooses, '{"recordData":{"Name":"Acme"}}', 'Remove RecordTypeId from fields');
        System.assert(String.join(new StandardCreateRecordTool().validateConfiguration(configuration(agentChooses)), ' ').contains('Remove RecordTypeId'));
    }

    @IsTest
    static void aRecordTypeLimitsPicklistsToItsValues() {
        Schema.RecordTypeInfo recordType = Account.SObjectType.getDescribe().getRecordTypeInfosByDeveloperName().get('Master');
        Schema.DescribeFieldResult industry = Account.Industry.getDescribe();
        StandardToolSchemas.recordTypeValues.put(
            'account|' + String.valueOf(recordType.getRecordTypeId()),
            new Map<String, List<String>>{ 'industry' => new List<String>{ 'Technology' } }
        );

        System.assertEquals(new List<String>{ 'Technology' }, StandardToolSchemas.picklistValues(Account.SObjectType, recordType, industry));
        System.assert(
            StandardToolSchemas.picklistValues(Account.SObjectType, null, industry).size() > 1,
            'Without a record type, every active value is offered.'
        );
        System.assertEquals(
            StandardToolSchemas.picklistValues(Account.SObjectType, null, Account.Rating.getDescribe()),
            StandardToolSchemas.picklistValues(Account.SObjectType, recordType, Account.Rating.getDescribe()),
            'A field the record type read leaves out keeps every active value.'
        );
    }

    @IsTest
    static void checksFixedFieldValuesWhenTheAdminSaves() {
        Map<String, String> refused = new Map<String, String>{
            '{"objectApiName":"Account","fields":["Name"],"defaultFieldValues":{"NumberOfEmployees":"many"}}' => 'NumberOfEmployees requires a whole number',
            '{"objectApiName":"Task","fields":["Subject"],"defaultFieldValues":{"ActivityDate":"next week"}}' => 'ActivityDate requires an ISO-8601 date',
            '{"objectApiName":"Task","fields":["Description"],"defaultFieldValues":{"Subject":":endOfMonth"}}' => ':endOfMonth cannot go in Subject',
            '{"objectApiName":"Task","fields":["Subject"],"defaultFieldValues":{"ActivityDate":":today+3x"}}' => 'd (days), w (weeks)',
            '{"objectApiName":"Account","fields":["Name"],"defaultFieldValues":{"CreatedDate":"2026-01-01T00:00:00Z"}}' => 'cannot set CreatedDate',
            '{"objectApiName":"Account","fields":["Name","Description"],"defaultFieldValues":{"Description":"Fixed"}}' => 'Description is both a Fixed Field Value and a field the agent may set'
        };
        for (String config : refused.keySet()) {
            String problems = String.join(new StandardCreateRecordTool().validateConfiguration(configuration(config)), ' ');
            System.assert(problems.contains(refused.get(config)), 'Expected "' + refused.get(config) + '" but got: ' + problems);
        }
        String good = '{"objectApiName":"Task","fields":["Subject"],"defaultFieldValues":{"ActivityDate":":endOfMonth+1m","Priority":"High","IsReminderSet":true}}';
        System.assertEquals(new List<String>(), new StandardCreateRecordTool().validateConfiguration(configuration(good)));
    }

    @IsTest
    static void fillsInARelativeDateOnEachCall() {
        String config = '{"objectApiName":"Task","fields":["Subject"],"defaultFieldValues":{"ActivityDate":":today+3d"}}';
        Id recordId = (Id) ((Map<String, Object>) JSON.deserializeUntyped(
                new StandardCreateRecordTool().execute(request(config, '{"recordData":{"Subject":"Follow up"}}')).output
            ))
            .get('id');
        System.assertEquals(Date.today().addDays(3), [SELECT ActivityDate FROM Task WHERE Id = :recordId].ActivityDate);
    }

    private static AgentKernelModels.ToolConfiguration configuration(String implementationConfiguration) {
        AgentKernelModels.ToolConfiguration built = new AgentKernelModels.ToolConfiguration();
        built.implementationConfiguration = implementationConfiguration;
        return built;
    }

    private static String accountConfig(String quotedFields) {
        return '{"objectApiName":"Account","fields":[' + quotedFields + ']}';
    }

    private static void assertInvalidRecordType(Id value) {
        Boolean rejected = false;
        try {
            StandardToolSupport.assertActiveRecordType(Account.SObjectType, value, 'RecordTypeId');
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains('requires a record type ID');
        }
        System.assert(rejected, 'RecordTypeId must reject IDs for other SObject types.');
    }

    private static void assertPermanent(String config, String input, String expectedFragment) {
        Boolean rejected = false;
        try {
            new StandardCreateRecordTool().execute(request(config, input));
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains(expectedFragment);
        }
        System.assert(rejected, 'Expected permanent rejection containing: ' + expectedFragment);
    }
}
