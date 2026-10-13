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

@IsTest(SeeAllData=false)
private class TrustServiceTest {
    @IsTest
    static void protectsSupportedValuesAndRejectsFalsePositives() {
        Id runId = startRun('safe input').runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        System.assert(TrustService.passesIban('GB82 WEST 1234 5698 7654 32'), 'Known IBAN must pass checksum validation.');
        String protectedContent = TrustService.protect(
            context,
            'Email alice@example.com; phone +1 (415) 555-2671; card 4111 1111 1111 1111; SSN 123-45-6789; IBAN GB82 WEST 1234 5698 7654 32.'
        );
        TrustService.save(context);

        System.assert(!protectedContent.contains('alice@example.com'));
        System.assert(!protectedContent.contains('4111 1111 1111 1111'));
        Set<String> categories = new Set<String>();
        for (AgentTrustToken__c mapping : [SELECT Category__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE]) {
            categories.add(mapping.Category__c);
        }
        System.assertEquals(new Set<String>{ 'Email', 'Phone', 'Payment Card', 'US SSN', 'IBAN' }, categories);

        context = TrustService.open(runId);
        String unchanged = TrustService.protect(
            context,
            'Invalid card 4111 1111 1111 1112, Luhn-valid order 1000000000000008, and ordinary number 1234567890.'
        );
        System.assert(unchanged.contains('4111 1111 1111 1112'));
        System.assert(unchanged.contains('1000000000000008'), 'A Luhn-valid number without a card-network prefix is not a card.');
        System.assert(unchanged.contains('1234567890'));
        System.assertEquals(0, context.pendingTokens.size());

        String amex = TrustService.protect(context, 'Amex 3782 822463 10005.');
        System.assert(!amex.contains('3782 822463 10005'));
        System.assertEquals(1, context.pendingTokens.size());
    }

    @IsTest
    static void findsBareSsnOnlyNextToItsName() {
        Id runId = startRun('safe input').runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String protectedContent = TrustService.protect(context, 'SSN: 123456789. Social security number 234567890. Martin 345678901, order 456789012.');
        System.assert(!protectedContent.contains('123456789') && !protectedContent.contains('234567890'), protectedContent);
        System.assert(protectedContent.contains('345678901') && protectedContent.contains('456789012'), 'Other nine-digit numbers are left alone.');
    }

    @IsTest
    static void orgDataStopsReleasingAValueTheModelAlsoWrote() {
        Id runId = startRun('safe input').runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String written = TrustService.protect(context, 'Write to bob@example.com', true);
        TrustService.save(context);
        System.assertEquals(true, [SELECT ModelAuthored__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE].ModelAuthored__c);
        context = TrustService.open(runId);
        String fromRecord = TrustService.protect(context, 'The record says bob@example.com');
        TrustService.save(context);
        AgentTrustToken__c mapping = [SELECT Token__c, ModelAuthored__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE];
        System.assert(written.contains(mapping.Token__c) && fromRecord.contains(mapping.Token__c), 'The same value keeps one token.');
        System.assertEquals(false, mapping.ModelAuthored__c, 'Only tools allowed its category may receive a value that org data holds.');
    }

    @IsTest
    static void reusesTokensAndResolvesOnlyAllowedCategories() {
        AuthorizedToolFixture fixture = authorizedToolRun('safe input', TrustService.CATEGORY_EMAIL);
        Id runId = fixture.started.runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String first = TrustService.protect(context, 'alice@example.com');
        String second = TrustService.protect(context, 'Send to alice@example.com');
        TrustService.save(context);

        AgentTrustToken__c mapping = [
            SELECT Token__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :runId AND Category__c = 'Email'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assertEquals(mapping.Token__c, first);
        System.assert(second.contains(mapping.Token__c));
        System.assertEquals('alice@example.com', TrustService.resolveForTool(runId, fixture.command.Id, fixture.command.LeaseToken__c, first));
        System.assertEquals(
            '{"subject":"hello"}',
            TrustService.resolveForTool(runId, fixture.command.Id, fixture.command.LeaseToken__c, '{"subject":"hello"}'),
            'Core must never inject an absent protected value.'
        );
    }

    @IsTest
    static void rejectsForgedAndCrossRunTokens() {
        Id firstRunId = startRun('alice@example.com').runId;
        Id secondRunId = startRun('safe input').runId;
        String firstRunToken = [
            SELECT Token__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :firstRunId
            WITH SYSTEM_MODE
            LIMIT 1
        ]
        .Token__c;

        for (String invalidValue : new List<String>{ firstRunToken, '{{EMAIL_999_aaaaaaaa}}' }) {
            try {
                TrustService.validateTokens(secondRunId, invalidValue);
                System.assert(false, 'Unknown and cross-run tokens must fail closed.');
            } catch (TrustService.TokenUseException expected) {
                System.assertEquals(TrustService.TOKEN_INVALID, expected.code);
                System.assert(expected.getMessage().contains('unknown'));
            }
        }
    }

    @IsTest
    static void purgesOnlyThroughAuthorizedServicePath() {
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
        System.runAs(AgentKernelTestFactory.self()) {
            Id runId = startRun('alice@example.com').runId;
            AgentTrustToken__c mapping = [
                SELECT Id, OriginalValue__c, PurgedAt__c
                FROM AgentTrustToken__c
                WHERE AgentRun__c = :runId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            try {
                mapping.OriginalValue__c = null;
                mapping.PurgedAt__c = System.now();
                Database.update(mapping, AccessLevel.SYSTEM_MODE);
                System.assert(false, 'Direct token mutation must be rejected.');
            } catch (DmlException expected) {
                System.assert(expected.getMessage().contains('immutable'));
            }

            TrustService.purgeBounded(new Set<Id>{ runId }, 2000);
            mapping = [SELECT OriginalValue__c, PurgedAt__c FROM AgentTrustToken__c WHERE Id = :mapping.Id WITH SYSTEM_MODE];
            System.assertEquals(null, mapping.OriginalValue__c);
            System.assertNotEquals(null, mapping.PurgedAt__c);
        }
    }

    @IsTest
    static void tokenCheckQueriesOnlyForPlaceholdersAndRefusesOutsiders() {
        Id runId = startRun('alice@example.com').runId;
        String token = [SELECT Token__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE LIMIT 1].Token__c;

        Integer queriesBefore = Limits.getQueries();
        TrustService.validateTokens(runId, '{"subject":"no placeholders here"}');
        System.assertEquals(queriesBefore, Limits.getQueries(), 'Content without placeholders needs no authorization query.');
        TrustService.validateTokens(runId, '{"to":"' + token + '"}');

        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                TrustService.validateTokens(runId, '{"to":"' + token + '"}');
                System.assert(false, 'A user who does not run this agent must not check its tokens.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('not authorized'));
            }
        }
    }

    @IsTest
    static void finalOutputResolutionIsTemporaryAndPermissionGated() {
        AgentKernelModels.StartResult started = startRun('safe input');
        Id runId = started.runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String protectedOutput = TrustService.protect(context, '{"result":"alice@example.com"}');
        TrustService.save(context);

        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.TRUST_RESOLVER });
        System.runAs(AgentKernelTestFactory.self()) {
            try {
                TrustService.resolveFinalOutput(runId);
                System.assert(false, 'A running run has no resolvable final output.');
            } catch (AgentKernelException.InvalidTransitionException expected) {
                System.assert(expected.getMessage().contains('succeeded'));
            }
        }
        AgentKernelTestFactory.applyOutcome(AgentKernelModels.succeed(runId, started.commandId, started.revision, started.operationKey, protectedOutput));

        System.runAs(AgentKernelTestFactory.userWith(new List<String>())) {
            try {
                TrustService.resolveFinalOutput(runId);
                System.assert(false, 'Resolution permission must be required.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('permission'));
            }
        }

        String resolved;
        System.runAs(AgentKernelTestFactory.self()) {
            resolved = TrustService.resolveFinalOutput(runId);
        }
        System.assertEquals('{"result":"alice@example.com"}', resolved);
        System.assertEquals(protectedOutput, [SELECT Output__c FROM AgentRun__c WHERE Id = :runId WITH SYSTEM_MODE].Output__c);
        AgentEvent__c auditEvent = [
            SELECT EventType__c, Payload__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :runId AND EventType__c = 'Trust Output Resolved'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assertEquals('Trust Output Resolved', auditEvent.EventType__c);
        System.assert(!String.valueOf(auditEvent.Payload__c).contains('alice@example.com'));
    }

    @IsTest
    static void runResultActionResolvesManyRunsWithFixedQueriesAndOneAuditWrite() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<Id> runIds = new List<Id>();
        for (Integer index = 0; index < 5; index++) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, 'safe input');
            TrustService.ProtectionContext context = TrustService.open(started.runId);
            String protectedOutput = TrustService.protect(context, '{"result":"person' + index + '@example.com"}');
            TrustService.save(context);
            AgentKernelTestFactory.applyOutcome(
                AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, protectedOutput)
            );
            runIds.add(started.runId);
        }
        AgentKernelModels.StartResult running = AgentKernelTestFactory.start(definition.Id, 'still running');
        List<AgentRunResultAction.Request> requests = new List<AgentRunResultAction.Request>();
        for (Id runId : runIds) {
            AgentRunResultAction.Request request = new AgentRunResultAction.Request();
            request.runId = runId;
            requests.add(request);
        }
        AgentRunResultAction.Request runningRequest = new AgentRunResultAction.Request();
        runningRequest.runId = running.runId;
        requests.add(runningRequest);

        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.TRUST_RESOLVER });
        System.runAs(AgentKernelTestFactory.self()) {
            Integer queriesBefore = Limits.getQueries();
            Integer dmlBefore = Limits.getDmlStatements();
            List<AgentRunResultAction.Result> results = AgentRunResultAction.getResult(requests);
            Integer queriesUsed = Limits.getQueries() - queriesBefore;
            Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;

            for (Integer index = 0; index < 5; index++) {
                System.assertEquals(AgentKernelModels.RUN_STATUS_SUCCEEDED, results[index].status);
                System.assertEquals('{"result":"person' + index + '@example.com"}', results[index].output);
            }
            System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, results[5].status);
            System.assertEquals(null, results[5].output, 'A running run has no answer yet.');
            System.assert(queriesUsed <= 10, 'Queries must not grow with the number of runs: ' + queriesUsed);
            System.assertEquals(2, dmlUsed, 'All audit events are inserted together and all runs updated together.');
        }
        System.assertEquals(
            5,
            [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c IN :runIds AND EventType__c = :AgentKernelModels.EVENT_TRUST_OUTPUT_RESOLVED WITH SYSTEM_MODE],
            'Each resolved answer is audited on its run.'
        );
    }

    @IsTest
    static void modelTokenReachesOnlyAnAllowedToolInPlaintext() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestTool.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        tool.AllowedSensitiveDataCategories__c = 'Email';
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"email":"alice@example.com"}');
        String token = [
            SELECT Token__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :started.runId AND Category__c = 'Email'
            WITH SYSTEM_MODE
            LIMIT 1
        ]
        .Token__c;
        KernelTestModelProvider.toolInput = '{"value":"' + token + '"}';

        AgentCommand__c modelCommand = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, modelCommand.Id, modelCommand.ExpectedRunRevision__c, modelCommand.OperationKey__c, modelCommand.LeaseToken__c)
            .execute(null);
        AgentCommand__c toolCommand = leaseCurrent(started.runId);
        System.assert(toolCommand.Input__c.contains(token));
        System.assert(!toolCommand.Input__c.contains('alice@example.com'));

        new ToolCommandQueueable(started.runId, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);
        System.assertEquals('{"value":"alice@example.com"}', KernelTestTool.lastRequest.input);
        System.assert(![SELECT Input__c FROM AgentCommand__c WHERE Id = :toolCommand.Id WITH SYSTEM_MODE].Input__c.contains('alice@example.com'));
    }

    @IsTest
    static void disallowedModelTokenNeverReachesToolImplementation() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestTool.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"email":"alice@example.com"}');
        String token = [
            SELECT Token__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :started.runId AND Category__c = 'Email'
            WITH SYSTEM_MODE
            LIMIT 1
        ]
        .Token__c;
        KernelTestModelProvider.toolInput = '{"value":"' + token + '"}';

        AgentCommand__c modelCommand = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, modelCommand.Id, modelCommand.ExpectedRunRevision__c, modelCommand.OperationKey__c, modelCommand.LeaseToken__c)
            .execute(null);
        AgentCommand__c toolCommand = leaseCurrent(started.runId);
        new ToolCommandQueueable(started.runId, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);

        System.assertEquals(0, KernelTestTool.invocationCount);
        AgentCommand__c deniedCall = AgentKernelTestFactory.getCommand(toolCommand.Id);
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_FAILED, deniedCall.Status__c, 'The model learns the tool may not receive the value.');
        System.assertEquals(TrustService.TOKEN_CATEGORY_DENIED, deniedCall.ErrorCode__c);
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, run.Status__c, 'A disallowed token is model feedback, not an operator pause.');
    }

    @IsTest
    static void tokensAreShortCategoryLabeledAndRunScoped() {
        Id runId = startRun('{"email":"alice@example.com","phone":"+1 415 555 0100"}').runId;
        List<AgentTrustToken__c> mappings = [
            SELECT Token__c, Category__c, ModelAuthored__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :runId
            WITH SYSTEM_MODE
            ORDER BY Token__c
        ];
        System.assertEquals(2, mappings.size());
        for (AgentTrustToken__c mapping : mappings) {
            System.assert(TrustService.containsToken(mapping.Token__c), mapping.Token__c);
            System.assert(mapping.Token__c.length() < 30, 'Tokens stay short enough for the model to copy.');
            System.assertEquals(false, mapping.ModelAuthored__c);
        }
        System.assert(mappings[0].Token__c.startsWith('{{EMAIL_'));
        System.assert(mappings[1].Token__c.startsWith('{{PHONE_'));
    }

    @IsTest
    static void modelAuthoredValuesReachToolsWithoutCategoryAllowance() {
        // This test drives each tool worker itself; InlineToolExecutionTest covers tools that run in the model's job.
        InPlaceToolRunner.headroomChecksForTest = 0;
        KernelTestModelProvider.mode = 'toolThenFinal';
        KernelTestModelProvider.invocationCount = 0;
        KernelTestTool.invocationCount = 0;
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.createTool(
            definition.Id,
            'test_tool',
            '{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":false}'
        );
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, 'Call the support desk.');
        // The model wrote this number itself; it never saw it from org data.
        KernelTestModelProvider.toolInput = '{"value":"+1 415 555 0199"}';

        AgentCommand__c modelCommand = leaseCurrent(started.runId);
        new ModelCommandQueueable(started.runId, modelCommand.Id, modelCommand.ExpectedRunRevision__c, modelCommand.OperationKey__c, modelCommand.LeaseToken__c)
            .execute(null);
        AgentCommand__c toolCommand = leaseCurrent(started.runId);
        System.assert(TrustService.containsToken(toolCommand.Input__c), 'Evidence still stores the value as a token.');
        AgentTrustToken__c mapping = [
            SELECT ModelAuthored__c, Category__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :started.runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assertEquals(true, mapping.ModelAuthored__c);
        System.assertEquals(TrustService.CATEGORY_PHONE, mapping.Category__c);
        new ToolCommandQueueable(started.runId, toolCommand.Id, toolCommand.ExpectedRunRevision__c, toolCommand.OperationKey__c, toolCommand.LeaseToken__c)
            .execute(null);

        System.assertEquals(1, KernelTestTool.invocationCount, 'A tool without Phone allowed still receives a number the model wrote.');
        System.assert(KernelTestTool.lastRequest.input.contains('+1 415 555 0199'));
    }

    @IsTest
    static void startNeverPersistsRawSensitiveInput() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"email":"alice@example.com"}');
        AgentRun__c run = [SELECT Input__c, StartRequestHash__c FROM AgentRun__c WHERE Id = :started.runId WITH SYSTEM_MODE];
        System.assert(!run.Input__c.contains('alice@example.com'));
        System.assert(TrustService.containsToken(run.Input__c));
        for (AgentEvent__c eventRecord : [SELECT Payload__c FROM AgentEvent__c WHERE AgentRun__c = :started.runId WITH SYSTEM_MODE]) {
            System.assert(eventRecord.Payload__c == null || !eventRecord.Payload__c.contains('alice@example.com'));
        }
        System.assertEquals(1, [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :started.runId WITH SYSTEM_MODE]);
    }

    @IsTest
    static void protectsSalesforceClassifiedFieldsAndResolvesOnlyForAllowedTools() {
        String classifiedValue = repeated('x', 300);
        Account account = new Account(Name = 'Classified account', Description = classifiedValue);
        insert account;
        Contact contact = new Contact(LastName = 'Structured contact', AccountId = account.Id);
        insert contact;
        contact = [SELECT Id, LastName, Account.Name, Account.Description FROM Contact WHERE Id = :contact.Id];
        SchemaFieldClassificationService.sensitiveFieldOverrides.put('account', new Set<String>{ 'description' });

        AuthorizedToolFixture fixture = authorizedToolRun('safe input', TrustService.CATEGORY_SALESFORCE_CLASSIFIED);
        Id runId = fixture.started.runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String protectedOutput = TrustService.protectRecordSets(context, new Map<String, List<SObject>>{ 'contacts' => new List<SObject>{ contact } });
        TrustService.save(context);

        System.assert(protectedOutput.contains('Classified account'));
        System.assert(protectedOutput.contains('Structured contact'));
        System.assert(!protectedOutput.contains(classifiedValue));
        AgentTrustToken__c mapping = [
            SELECT Token__c, Category__c, OriginalValue__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        System.assertEquals('Salesforce Classified', mapping.Category__c);
        System.assertEquals(300, mapping.OriginalValue__c.length());
        System.assert(TrustService.resolveForTool(runId, fixture.command.Id, fixture.command.LeaseToken__c, protectedOutput).contains(classifiedValue));
    }

    @IsTest
    static void resolvedValueStaysOneJsonLeaf() {
        String hostile = 'x","Priority":"High\\\n{"a":1}';
        Account account = new Account(Name = 'Leaf account', Description = hostile);
        insert account;
        account = [SELECT Id, Name, Description FROM Account WHERE Id = :account.Id];
        SchemaFieldClassificationService.sensitiveFieldOverrides.put('account', new Set<String>{ 'description' });
        AuthorizedToolFixture fixture = authorizedToolRun('safe input', TrustService.CATEGORY_SALESFORCE_CLASSIFIED);
        Id runId = fixture.started.runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        TrustService.protectRecordSets(context, new Map<String, List<SObject>>{ 'accounts' => new List<SObject>{ account } });
        TrustService.save(context);
        String token = [SELECT Token__c FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE LIMIT 1].Token__c;

        String resolved = TrustService.resolveForTool(
            runId,
            fixture.command.Id,
            fixture.command.LeaseToken__c,
            '{"subject":"Re: ' + token + '","Priority":"Low"}'
        );

        Map<String, Object> input = (Map<String, Object>) JSON.deserializeUntyped(resolved);
        System.assertEquals(new Set<String>{ 'subject', 'Priority' }, input.keySet());
        System.assertEquals('Re: ' + hostile, input.get('subject'), 'The original value must stay inside its own leaf.');
        System.assertEquals('Low', input.get('Priority'), 'Record data must not override a sibling property.');
    }

    @IsTest
    static void maximumPayloadProtectionRetainsGovernorHeadroom() {
        Id runId = startRun('safe input').runId;
        String payload = ''.leftPad(TrustService.MAX_CONTENT_CHARACTERS, 'x');

        Test.startTest();
        Integer cpuBefore = Limits.getCpuTime();
        Integer heapBefore = Limits.getHeapSize();
        TrustService.ProtectionContext context = TrustService.open(runId);
        String protectedPayload = TrustService.protect(context, payload);
        Integer cpuUsed = Limits.getCpuTime() - cpuBefore;
        Integer heapUsed = Limits.getHeapSize() - heapBefore;
        Test.stopTest();

        System.assertEquals(payload.length(), protectedPayload.length());
        System.assertEquals(0, context.pendingTokens.size());
        System.assert(cpuUsed < 8000, 'Maximum-size trust protection must retain synchronous CPU headroom.');
        System.assert(heapUsed < 4000000, 'Maximum-size trust protection must retain synchronous heap headroom.');
    }

    @IsTest
    static void structuredRecordBoundsApplyWhenTrustIsDisabled() {
        List<SObject> records = new List<SObject>();
        for (Integer index = 0; index <= 200; index++) {
            records.add(new Account(Name = 'Structured account ' + index));
        }
        try {
            TrustService.serializeRecordSets(new Map<String, List<SObject>>{ 'accounts' => records });
            System.assert(false, 'Trust-disabled structured output must retain the Core record bound.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('200-record limit'));
        }
    }

    @IsTest
    static void manyDistinctTrustTokensRoundTripInOnePass() {
        List<String> values = new List<String>();
        for (Integer index = 0; index < 100; index++) {
            values.add('person' + index + '@example.com');
        }
        String payload = String.join(values, ',');
        AuthorizedToolFixture fixture = authorizedToolRun('safe input', TrustService.CATEGORY_EMAIL);
        Id runId = fixture.started.runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        Integer existingTokenCount = context.tokensByValue.size();

        String protectedPayload = TrustService.protect(context, payload);
        TrustService.save(context);

        System.assert(context.tokensByValue.size() >= existingTokenCount + 100, 'Each distinct email must produce a trust mapping.');
        System.assertEquals(payload, TrustService.resolveForTool(runId, fixture.command.Id, fixture.command.LeaseToken__c, protectedPayload));
    }

    private static String repeated(String value, Integer count) {
        String result = '';
        for (Integer index = 0; index < count; index++) {
            result += value;
        }
        return result;
    }

    private static AgentKernelModels.StartResult startRun(String input) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        return AgentKernelTestFactory.start(definition.Id, input);
    }

    private class AuthorizedToolFixture {
        AgentKernelModels.StartResult started;
        AgentCommand__c command;
    }

    private static AuthorizedToolFixture authorizedToolRun(String input, String allowedCategory) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(
            definition.Id,
            'authorized_trust_tool',
            '{"type":"object","properties":{},"additionalProperties":false}'
        );
        tool.AllowedSensitiveDataCategories__c = allowedCategory;
        AgentKernelTestFactory.updateRecord(tool);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, input);
        AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            tool.DeveloperName__c,
            AgentKernelModels.COMMAND_STATUS_LEASED
        );
        command.LeaseToken__c = 'authorized-trust-lease-' + command.Id;
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        AgentKernelTestFactory.updateRecord(command);
        AgentKernelTestFactory.replaceCurrentCommand(started, command);
        AuthorizedToolFixture fixture = new AuthorizedToolFixture();
        fixture.started = started;
        fixture.command = AgentKernelTestFactory.getCommand(command.Id);
        return fixture;
    }

    private static AgentCommand__c leaseCurrent(Id runId) {
        AgentRun__c run = AgentKernelTestFactory.getRun(runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        CommandLeaseService.Result result = CommandLeaseService.tryLease(
            run.Id,
            command.Id,
            run.Revision__c,
            command.OperationKey__c,
            command.DispatchToken__c
        );
        System.assertEquals(CommandLeaseService.Outcome.Leased, result.outcome);
        return AgentKernelTestFactory.getCommand(command.Id);
    }

    @IsTest
    static void maximumSizeContentIsScannedInSafePieces() {
        Id runId = startRun('safe input').runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        String line = 'Order line 000123 quantity 42 shipped from warehouse B\n';
        String content =
            line.repeat(Integer.valueOf((TrustService.MAX_CONTENT_CHARACTERS - 200) / line.length())) +
            'Contact alice@example.com about card 4111 1111 1111 1111.';
        System.assert(content.length() <= TrustService.MAX_CONTENT_CHARACTERS);
        System.assert(TrustService.detectionChunks(content).size() > 1, 'Long content is scanned in pieces.');
        System.assertEquals(content, String.join(TrustService.detectionChunks(content), ''), 'Pieces join back to the content.');

        String protectedContent = TrustService.protect(context, content);

        System.assert(!protectedContent.contains('alice@example.com'));
        System.assert(!protectedContent.contains('4111 1111 1111 1111'));
        System.assertEquals(2, context.pendingTokens.size());
    }

    @IsTest
    static void jsonIsCutOnlyBetweenMembers() {
        String json = JSON.serialize(new Map<String, Object>{ 'rows' => new List<Object>{ 'a'.repeat(9000), 'b'.repeat(9000) } });
        for (String piece : TrustService.detectionChunks(json)) {
            System.assert(piece.endsWith(',') || piece == TrustService.detectionChunks(json)[TrustService.detectionChunks(json).size() - 1], piece.right(20));
        }
    }

    @IsTest
    static void detectionFailureWithholdsTheContent() {
        Id runId = startRun('safe input').runId;
        TrustService.ProtectionContext context = TrustService.open(runId);
        TrustService.failDetectionForTest = true;

        String result = TrustService.protect(context, 'Email alice@example.com about the refund.');

        System.assert(!result.contains('alice@example.com'), 'Nothing is stored or sent as written.');
        Map<String, Object> marker = (Map<String, Object>) JSON.deserializeUntyped(result);
        System.assertEquals(true, marker.get('contentWithheld'));
        System.assertEquals('System.StringException', marker.get('errorType'));
    }
}
