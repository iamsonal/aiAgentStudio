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
private class StandardQueryRecordsToolTest {
    @IsTest
    static void readsSelectedAndParentFieldsWithAModelValue() {
        Account parent = new Account(Name = 'Parent Co');
        insert parent;
        insert new Contact(LastName = 'Lee', AccountId = parent.Id);

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool()
            .execute(request(config('SELECT LastName, Account.Name FROM Contact WHERE LastName = :lastName LIMIT 5'), '{"lastName":"Lee"}', null));

        System.assertEquals(true, response.isSuccess);
        Contact returned = (Contact) response.recordSets.get('Contact')[0];
        System.assertEquals('Lee', returned.LastName);
        System.assertEquals('Parent Co', returned.Account.Name);
        System.assertEquals(parent.Id, returned.Account.Id, 'The platform returns the parent Id, so Core can check access to the parent.');
    }

    @IsTest
    static void aSensitiveParentValueIsTokenizedBeforeTheModelSeesIt() {
        Contact customer = new Contact(LastName = 'Customer', Email = 'pat.customer@example.com');
        insert customer;
        insert new Case(Subject = 'Parent email', ContactId = customer.Id);
        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool()
            .execute(request(config('SELECT Subject, Contact.Email FROM Case WHERE Subject = :subject LIMIT 5'), '{"subject":"Parent email"}', null));
        Id runId = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition()).runId;

        String serialized = TrustService.protectRecordSets(TrustService.openForAuthorizedTransition(runId), response.recordSets);

        System.assert(serialized.contains('Parent email'), serialized);
        System.assert(!serialized.contains('pat.customer@example.com'), serialized);
        System.assert(TrustService.containsToken(serialized), serialized);
    }

    @IsTest
    static void readsListBindsSemiJoinsAndDateLiterals() {
        Account banking = new Account(Name = 'Bank', Industry = 'Banking');
        Account other = new Account(Name = 'Farm', Industry = 'Agriculture');
        insert new List<Account>{ banking, other };
        insert new Contact(LastName = 'Ng', AccountId = banking.Id);

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool()
            .execute(
                request(
                    config(
                        'SELECT Name FROM Account WHERE Industry IN :industries AND CreatedDate = LAST_N_DAYS:30 AND Id IN (SELECT AccountId FROM Contact WHERE LastName != null) ORDER BY Name ASC NULLS LAST LIMIT 10'
                    ),
                    '{"industries":["Banking","Agriculture"]}',
                    null
                )
            );

        System.assertEquals(1, response.recordSets.get('Account').size(), 'Only the account with a contact matches.');
        System.assertEquals(banking.Id, response.recordSets.get('Account')[0].Id);
    }

    @IsTest
    static void coercesEachBindToItsFieldType() {
        insert new Account(Name = 'Typed', NumberOfEmployees = 25, AnnualRevenue = 1000.5);
        insert new Contact(LastName = 'Typed', HasOptedOutOfEmail = true);

        AgentKernelModels.ToolResponse accounts = new StandardQueryRecordsTool()
            .execute(
                request(
                    config('SELECT Name FROM Account WHERE NumberOfEmployees = :size AND AnnualRevenue >= :revenue AND CreatedDate < :before LIMIT 5'),
                    JSON.serialize(new Map<String, Object>{ 'size' => 25, 'revenue' => 1000, 'before' => System.now().addDays(1) }),
                    null
                )
            );
        AgentKernelModels.ToolResponse contacts = new StandardQueryRecordsTool()
            .execute(request(config('SELECT LastName FROM Contact WHERE HasOptedOutOfEmail = :optedOut LIMIT 5'), '{"optedOut":true}', null));

        System.assertEquals(1, accounts.recordSets.get('Account').size());
        System.assertEquals(1, contacts.recordSets.get('Contact').size());
    }

    @IsTest
    static void aValueThatLooksLikeSoqlIsOnlyAValue() {
        insert new Account(Name = 'Real');

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool()
            .execute(request(config('SELECT Name FROM Account WHERE Name = :name LIMIT 5'), '{"name":"x\' OR Name != \'"}', null));

        System.assertEquals(0, response.recordSets.get('Account').size());
    }

    @IsTest
    static void anchorIdIsTheRunsRecordAndNeverAModelInput() {
        Account account = new Account(Name = 'Anchor');
        insert account;
        insert new Case(Subject = 'Anchored case', AccountId = account.Id);
        String scoped = config('SELECT Subject FROM Case WHERE AccountId = :anchorId LIMIT 5');

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool().execute(request(scoped, '{}', account.Id));
        System.assertEquals('Anchored case', ((Case) response.recordSets.get('Case')[0]).Subject);

        assertExecuteRefused(scoped, '{"anchorId":"' + account.Id + '"}', account.Id, 'accepts: no inputs');
        assertExecuteRefused(scoped, '{}', null, 'not started on a record');
        Contact contact = new Contact(LastName = 'Wrong anchor');
        insert contact;
        assertExecuteRefused(scoped, '{}', contact.Id, 'cannot hold the run\'s record, which is a Contact');
    }

    @IsTest
    static void aLiteralContainingKeywordsIsNotRead() {
        Account account = new Account(Name = 'Smith OR LIMIT 5');
        insert account;
        String query = config('SELECT Name FROM Account WHERE Name = \'Smith OR LIMIT 5\' AND Id = :anchorId LIMIT 1');

        System.assertEquals(true, StandardQueryRecordsTool.scopedToAnchor(query), 'The OR inside the quotes is text, not a condition.');
        System.assertEquals(1, new StandardQueryRecordsTool().execute(request(query, null, account.Id)).recordSets.get('Account').size());
    }

    @IsTest
    static void scopedToAnchorOnlyWhenEveryRecordRelatesToTheRunsRecord() {
        System.assertEquals(
            true,
            StandardQueryRecordsTool.scopedToAnchor(config('SELECT Subject FROM Case WHERE AccountId = :anchorId AND Status = :status LIMIT 5'))
        );
        System.assertEquals(
            false,
            StandardQueryRecordsTool.scopedToAnchor(config('SELECT Subject FROM Case WHERE AccountId = :anchorId OR Status = :status LIMIT 5'))
        );
        System.assertEquals(false, StandardQueryRecordsTool.scopedToAnchor(config('SELECT Subject FROM Case WHERE NOT AccountId = :anchorId LIMIT 5')));
        System.assertEquals(false, StandardQueryRecordsTool.scopedToAnchor(config('SELECT Subject FROM Case WHERE AccountId != :anchorId LIMIT 5')));
        System.assertEquals(
            false,
            StandardQueryRecordsTool.scopedToAnchor(
                config('SELECT Name FROM Account WHERE Id IN (SELECT AccountId FROM Case WHERE AccountId = :anchorId) LIMIT 5')
            )
        );
        System.assertEquals(false, StandardQueryRecordsTool.scopedToAnchor(config('SELECT Subject FROM Case WHERE Status = :status LIMIT 5')));
        System.assertEquals(false, StandardQueryRecordsTool.scopedToAnchor('{not json'));
    }

    @IsTest
    static void runValuesAreFilledByCoreAndNeverModelInputs() {
        Account account = new Account(Name = 'Mine today', OwnerId = UserInfo.getUserId());
        insert account;
        String mine = config('SELECT Name FROM Account WHERE OwnerId = :initiatingUserId AND CreatedDate <= :now LIMIT 5');

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool().execute(request(mine, '{}', null));
        System.assertEquals('Mine today', ((Account) response.recordSets.get('Account')[0]).Name);
        assertExecuteRefused(mine, '{"initiatingUserId":"005000000000000AAA"}', null, 'accepts: no inputs');
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(ToolAuthoringService.previewSchema('QueryRecords', mine));
        System.assertEquals(new Set<String>(), ((Map<String, Object>) schema.get('properties')).keySet(), 'Run values are never model inputs.');
    }

    @IsTest
    static void saveRefusesWhatCoreCannotProtectWithTheFix() {
        Map<String, String> expectedByQuery = new Map<String, String>{
            'SELECT COUNT() FROM Account LIMIT 1' => 'Run Report',
            'SELECT MAX(AnnualRevenue) FROM Account LIMIT 1' => 'Run Report',
            'SELECT CALENDAR_YEAR(CreatedDate) FROM Account' => 'toLabel(), FORMAT(), and convertCurrency()',
            'SELECT FORMAT(AnnualRevenue) revenue FROM Account' => 'without aliases',
            'SELECT Industry FROM Account GROUP BY Industry LIMIT 1' => 'GROUP BY',
            'SELECT Name, (SELECT LastName FROM Nope) FROM Account' => 'not a child relationship of Account',
            'SELECT Name FROM Account WITH SYSTEM_MODE' => 'Remove WITH SYSTEM_MODE',
            'SELECT Name FROM Account WITH SOMETHING' => 'WITH takes only DATA CATEGORY',
            'SELECT Name FROM Account WITH SECURITY_ENFORCED' => 'Remove WITH SECURITY_ENFORCED',
            'SELECT Name FROM Account WITH USER_MODE' => 'Remove WITH USER_MODE',
            'SELECT Name FROM Account LIMIT 1 FOR UPDATE' => 'only reads',
            'SELECT Name FROM Account LIMIT :anchorId' => 'filled in by Core',
            'SELECT Name FROM Account WHERE Name = :size LIMIT :size' => 'separate bind',
            'SELECT Name FROM AgentRun__c LIMIT 1' => 'Agent Core',
            'SELECT Name FROM Account WHERE Id IN (SELECT AnchorRecordId__c FROM AgentRun__c) LIMIT 1' => 'Agent Core',
            'SELECT What.Owner.Name FROM Task' => 'Use TYPEOF What',
            'SELECT TYPEOF What WHEN Nope THEN Name END FROM Task' => 'not an object What can point to',
            'SELECT Name FROM Account WHERE Id IN :anchorId LIMIT 1' => 'Compare it with =',
            'SELECT Name FROM Account WHERE Name = :anchorId LIMIT 1' => 'Compare it with =',
            'SELECT Name FROM Account WHERE Name = :initiatingUserId LIMIT 1' => 'lookup field that can point to a user',
            'SELECT Name FROM Account WHERE OwnerId IN :principalUserId LIMIT 1' => 'is one value',
            'SELECT Name FROM Account WHERE CreatedDate = :today LIMIT 1' => 'only in a Date field',
            'SELECT Name FROM Account LIMIT :today' => 'filled in by Core',
            'SELECT Name FROM Account WHERE Name = :value OR NumberOfEmployees = :value LIMIT 1' => 'different types',
            'SELECT Name FROM Account WHERE :name = Name LIMIT 1' => 'Compare :name to a field',
            'SELECT Missing__c FROM Account LIMIT 1' => 'does not exist on Account',
            'SELECT Parent.Missing__c FROM Account LIMIT 1' => 'does not exist on Account',
            'SELECT Name label FROM Account LIMIT 1' => 'without aliases',
            'SELECT :name FROM Account LIMIT 1' => 'only in WHERE',
            'SELECT Name FROM Account a LIMIT 1' => 'no alias',
            'SELECT Name FROM Account WHERE Name = \'open LIMIT 1' => 'never closed',
            'SELECT Name FROM Account WHERE (Name = :name LIMIT 1' => 'never closed',
            'SELECT Name FROM Account WHERE Name = LIMIT 1' => 'does not run',
            'FROM Account LIMIT 1' => 'start with SELECT'
        };
        for (String query : expectedByQuery.keySet()) {
            List<String> problems = new StandardQueryRecordsTool().validateConfiguration(configuration(config(query)));
            System.assertEquals(1, problems.size(), 'Expected a refusal for: ' + query);
            System.assert(problems[0].contains(expectedByQuery.get(query)), query + ' => ' + problems[0]);
        }
        List<String> extra = new StandardQueryRecordsTool()
            .validateConfiguration(configuration('{"query":"SELECT Name FROM Account LIMIT 1","objectApiName":"Account"}'));
        System.assert(extra[0].contains('takes only "query"'), extra[0]);
    }

    @IsTest
    static void saveCompilesQueriesWithEveryKindOfBind() {
        List<String> problems = new StandardQueryRecordsTool()
            .validateConfiguration(
                configuration(
                    config(
                        'SELECT Name, Owner.Email FROM Account WHERE Id IN :ids AND NumberOfEmployees IN :sizes AND CreatedDate < :before AND Industry = :industry AND Name LIKE :name AND ParentId = :anchorId ORDER BY CreatedDate DESC LIMIT 5 OFFSET 5'
                    )
                )
            );
        System.assertEquals(new List<String>(), problems);
    }

    @IsTest
    static void saveCompilesFunctionsTypeofManyObjectLookupsAndCountBinds() {
        for (
            String query : new List<String>{
                'SELECT toLabel(Industry), FORMAT(AnnualRevenue), FORMAT(CreatedDate) FROM Account',
                'SELECT Subject, What.Name FROM Task WHERE What.Name = :name',
                'SELECT Subject, TYPEOF What WHEN Account THEN Name, Phone WHEN Opportunity THEN Amount ELSE Name END FROM Task',
                'SELECT Name FROM Account LIMIT :count OFFSET :skip'
            }
        ) {
            System.assertEquals(new List<String>(), new StandardQueryRecordsTool().validateConfiguration(configuration(config(query))), query);
        }
    }

    @IsTest
    static void readsChildRecordsAndProtectsThemLikeParentRecords() {
        Account parent = new Account(Name = 'With children');
        insert parent;
        insert new Contact(LastName = 'Child', Email = 'child.contact@example.com', AccountId = parent.Id);
        String query = config('SELECT Name, (SELECT LastName, Email FROM Contacts) FROM Account WHERE Name = :name');

        AgentKernelModels.ToolResponse response = new StandardQueryRecordsTool().execute(request(query, '{"name":"With children"}', null));
        Id runId = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition()).runId;
        String serialized = TrustService.protectRecordSets(TrustService.openForAuthorizedTransition(runId), response.recordSets);

        System.assert(serialized.contains('Child'), serialized);
        System.assert(!serialized.contains('child.contact@example.com'), 'A sensitive child value is tokenized: ' + serialized);
    }

    @IsTest
    static void runsWithoutLimitAndWithBindsInSubqueriesLimitAndOffset() {
        Account banking = new Account(Name = 'Bank');
        Account other = new Account(Name = 'Farm');
        insert new List<Account>{ banking, other };
        insert new Contact(LastName = 'Ng', AccountId = banking.Id);

        AgentKernelModels.ToolResponse filtered = new StandardQueryRecordsTool()
            .execute(
                request(config('SELECT Name FROM Account WHERE Id IN (SELECT AccountId FROM Contact WHERE LastName = :lastName)'), '{"lastName":"Ng"}', null)
            );
        System.assertEquals(1, filtered.recordSets.get('Account').size());
        System.assertEquals(banking.Id, filtered.recordSets.get('Account')[0].Id);

        String paged = config('SELECT Name FROM Account ORDER BY Name LIMIT :count OFFSET :skip');
        AgentKernelModels.ToolResponse page = new StandardQueryRecordsTool().execute(request(paged, '{"count":1,"skip":1}', null));
        System.assertEquals(1, page.recordSets.get('Account').size());
        System.assertEquals(other.Id, page.recordSets.get('Account')[0].Id, 'Bank is skipped, Farm is next.');
        assertExecuteRefused(paged, '{"count":0,"skip":0}', null, 'at least 1');
        assertExecuteRefused(paged, '{"count":1.5,"skip":0}', null, 'whole number');

        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(ToolAuthoringService.previewSchema('QueryRecords', paged));
        Map<String, Object> count = (Map<String, Object>) ((Map<String, Object>) schema.get('properties')).get('count');
        System.assertEquals('integer', count.get('type'));
        System.assertEquals(1, count.get('minimum'));
    }

    @IsTest
    static void modelInputMustMatchTheBinds() {
        String query = config('SELECT Name FROM Account WHERE Industry IN :industries AND Name LIKE :name LIMIT 5');
        assertExecuteRefused(query, '{"industries":["Banking"],"name":"%a%","fields":["Description"]}', null, 'accepts: industries, name');
        assertExecuteRefused(query, '{"industries":["Banking"]}', null, 'must include name');
        assertExecuteRefused(query, '{"industries":[],"name":"a"}', null, 'list of 1 through 50');
        assertExecuteRefused(query, '{"industries":"Banking","name":"a"}', null, 'list of 1 through 50');
    }

    @IsTest
    static void someoneWithoutAccessIsRefused() {
        insert new Account(Name = 'Hidden');
        User noAccess = new User(
            Alias = 'noqry',
            Email = 'query-records-no-access@example.com',
            Username = 'query-records-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'No Access',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert noAccess;
        }

        System.runAs(noAccess) {
            assertExecuteRefused(config('SELECT Name FROM Account WHERE Name = :name LIMIT 5'), '{"name":"Hidden"}', null, 'could not run as the run user');
        }
    }

    @IsTest
    static void derivesOneRequiredInputPerBind() {
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(
            ToolAuthoringService.previewSchema(
                'QueryRecords',
                config('SELECT Subject FROM Case WHERE AccountId = :anchorId AND Status IN :statuses AND Subject LIKE :subject LIMIT 5')
            )
        );
        Map<String, Object> properties = (Map<String, Object>) schema.get('properties');

        System.assertEquals(new Set<String>{ 'statuses', 'subject' }, properties.keySet(), 'The run\'s record is never a model input.');
        System.assertEquals(new List<Object>{ 'statuses', 'subject' }, schema.get('required'));
        System.assertEquals(false, schema.get('additionalProperties'));
        Map<String, Object> statuses = (Map<String, Object>) properties.get('statuses');
        System.assertEquals('array', statuses.get('type'));
        System.assert(((Map<String, Object>) statuses.get('items')).containsKey('enum'), 'Picklist values come from the field: ' + JSON.serialize(statuses));
        System.assert(String.valueOf(((Map<String, Object>) properties.get('subject')).get('description')).contains('%'));
    }

    private static String config(String query) {
        return JSON.serialize(new Map<String, Object>{ 'query' => query });
    }

    private static AgentKernelModels.ToolConfiguration configuration(String implementationConfiguration) {
        AgentKernelModels.ToolConfiguration value = new AgentKernelModels.ToolConfiguration();
        value.implementationConfiguration = implementationConfiguration;
        return value;
    }

    private static AgentKernelModels.ToolRequest request(String config, String input, Id anchorId) {
        AgentKernelModels.ToolRequest value = new AgentKernelModels.ToolRequest();
        value.implementationConfiguration = config;
        value.input = input;
        value.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), anchorId, null);
        return value;
    }

    private static void assertExecuteRefused(String config, String input, Id anchorId, String expected) {
        try {
            new StandardQueryRecordsTool().execute(request(config, input, anchorId));
            System.assert(false, 'Expected a refusal containing: ' + expected);
        } catch (AgentKernelException.PermanentException refused) {
            System.assert(refused.getMessage().contains(expected), refused.getMessage());
        }
    }
}
