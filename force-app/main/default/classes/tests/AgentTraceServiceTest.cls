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
private class AgentTraceServiceTest {
    private static final String TRACE_OPERATOR_ALIAS = 'traceop';

    @TestSetup
    static void createTraceOperator() {
        Profile profile = [
            SELECT Id
            FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator'
            LIMIT 1
        ];
        String unique = String.valueOf(System.now().getTime());
        User operator = new User(
            Alias = TRACE_OPERATOR_ALIAS,
            Email = unique + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Trace Operator',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = unique + '@example.com'
        );
        insert operator;
        PermissionSet operatorPermissionSet = [SELECT Id FROM PermissionSet WHERE Name = 'AgentKernelOperator' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = operator.Id, PermissionSetId = operatorPermissionSet.Id);
    }

    @IsTest
    static void eventPagesHaveNoGapsOrDuplicates() {
        AgentKernelModels.StartResult started = completedRun();
        Integer expectedCount = [SELECT COUNT() FROM AgentEvent__c WHERE AgentRun__c = :started.runId];
        AgentKernelModels.EventPageRequest request = new AgentKernelModels.EventPageRequest();
        request.runId = started.runId;
        request.limitSize = 1;
        Set<Id> seen = new Set<Id>();
        Decimal previousSequence;
        AgentKernelModels.EventPage page;

        do {
            page = AgentTraceService.getEventPage(request);
            for (AgentKernelModels.EventRecord eventRecord : page.events) {
                System.assert(seen.add(eventRecord.id), 'An event must not appear in more than one page.');
                if (previousSequence != null) {
                    System.assert(eventRecord.sequence > previousSequence, 'Event sequences must increase monotonically.');
                }
                previousSequence = eventRecord.sequence;
            }
            request.afterSequence = page.nextSequence;
            request.afterId = page.nextId;
        } while (page.hasMore);

        System.assertEquals(expectedCount, seen.size(), 'Paging must return every event exactly once.');
    }

    @IsTest
    static void commandPagesHandleCreatedDateTiesWithoutGapsOrDuplicates() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        insertCommands(started.runId, 24);
        Integer expectedCount = [SELECT COUNT() FROM AgentCommand__c WHERE AgentRun__c = :started.runId];
        AgentKernelModels.CommandPageRequest request = new AgentKernelModels.CommandPageRequest();
        request.runId = started.runId;
        request.limitSize = 4;
        Set<Id> seen = new Set<Id>();
        Datetime previousCreatedDate;
        Id previousId;
        AgentKernelModels.CommandPage page;

        do {
            page = AgentTraceService.getCommandPage(request);
            for (AgentKernelModels.CommandRecord command : page.commands) {
                System.assert(seen.add(command.id), 'A command must not appear in more than one page.');
                if (previousCreatedDate != null) {
                    System.assert(
                        command.createdAt > previousCreatedDate || (command.createdAt == previousCreatedDate && command.id > previousId),
                        'The compound command keyset must increase monotonically.'
                    );
                }
                previousCreatedDate = command.createdAt;
                previousId = command.id;
            }
            request.afterCreatedDate = page.nextCreatedDate;
            request.afterId = page.nextId;
        } while (page.hasMore);

        System.assertEquals(expectedCount, seen.size(), 'Paging must return every command exactly once.');
    }

    @IsTest
    static void invocationPagesHaveNoGapsOrDuplicates() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        for (Integer attempt = 1; attempt <= 5; attempt++) {
            recordInvocation(started, definition, attempt);
        }
        AgentKernelModels.InvocationPageRequest request = new AgentKernelModels.InvocationPageRequest();
        request.runId = started.runId;
        request.limitSize = 2;
        Set<Id> seen = new Set<Id>();
        AgentKernelModels.InvocationPage page;

        do {
            page = AgentTraceService.getInvocationPage(request);
            for (AgentKernelModels.InvocationRecord invocation : page.invocations) {
                System.assert(seen.add(invocation.id), 'An invocation must not appear in more than one page.');
            }
            request.afterCreatedDate = page.nextCreatedDate;
            request.afterId = page.nextId;
        } while (page.hasMore);

        System.assertEquals(5, seen.size(), 'Paging must return every invocation exactly once.');
    }

    @IsTest
    static void invocationsShowTheirTransactionOnlyToRunReaders() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        recordInvocation(started, definition, 1);
        recordInvocation(started, definition, 2);
        User operator = [SELECT Id FROM User WHERE Alias = :TRACE_OPERATOR_ALIAS LIMIT 1];
        insert new AgentRun__Share(
            ParentId = started.runId,
            UserOrGroupId = operator.Id,
            AccessLevel = 'Read',
            RowCause = Schema.AgentRun__Share.RowCause.Manual
        );
        User outsider = new User(
            Alias = 'traceout',
            Email = 'trace-outsider-' + String.valueOf(System.now().getTime()) + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Trace Outsider',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT ProfileId FROM User WHERE Id = :operator.Id]
            .ProfileId,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'trace-outsider-' + String.valueOf(System.now().getTime()) + '@example.com'
        );
        insert outsider;
        AgentKernelModels.InvocationPageRequest pageRequest = new AgentKernelModels.InvocationPageRequest();
        pageRequest.runId = started.runId;

        System.runAs(operator) {
            List<AgentKernelModels.InvocationRecord> invocations = AgentTraceService.getInvocationPage(pageRequest).invocations;
            System.assertEquals(2, invocations.size());
            System.assertEquals(InvocationEvidenceService.TRANSACTION_ID, invocations[0].transactionId, 'Each attempt records the transaction that ran it.');
            System.assertEquals(invocations[0].transactionId, invocations[1].transactionId, 'Attempts recorded in one transaction share its ID.');
        }
        System.runAs(outsider) {
            try {
                AgentTraceService.getInvocationPage(pageRequest);
                System.assert(false, 'A user without Pluto access must not read invocation transactions.');
            } catch (AgentKernelException.NotFoundException expected) {
                System.assert(expected.getMessage().contains('not found'));
            }
        }
    }

    @IsTest
    static void hiddenPayloadFieldsUseTheDefaultPageLimit() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        insertCommands(started.runId, 200);
        User operator = [SELECT Id FROM User WHERE Alias = :TRACE_OPERATOR_ALIAS LIMIT 1];
        insert new AgentRun__Share(
            ParentId = started.runId,
            UserOrGroupId = operator.Id,
            AccessLevel = 'Read',
            RowCause = Schema.AgentRun__Share.RowCause.Manual
        );
        AgentKernelModels.CommandPageRequest defaultRequest = new AgentKernelModels.CommandPageRequest();
        defaultRequest.runId = started.runId;
        AgentKernelModels.CommandPageRequest oversizedRequest = new AgentKernelModels.CommandPageRequest();
        oversizedRequest.runId = started.runId;
        oversizedRequest.limitSize = 1000;

        System.runAs(operator) {
            AgentKernelModels.CommandPage defaultPage = AgentTraceService.getCommandPage(defaultRequest);
            System.assertEquals(50, defaultPage.commands.size(), 'Callers without payload FLS should receive the default non-payload page size.');
            System.assertEquals(true, defaultPage.hasMore);

            AgentKernelModels.CommandPage cappedPage = AgentTraceService.getCommandPage(oversizedRequest);
            System.assertEquals(200, cappedPage.commands.size(), 'The non-payload page limit must still cap oversized requests.');
            System.assertEquals(true, cappedPage.hasMore);
        }
    }

    private static AgentKernelModels.StartResult completedRun() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.succeed(started.runId, started.commandId, started.revision, started.operationKey, '{"done":true}')
        );
        return started;
    }

    private static void insertCommands(Id runId, Integer count) {
        List<AgentCommand__c> commands = new List<AgentCommand__c>();
        for (Integer index = 0; index < count; index++) {
            commands.add(
                new AgentCommand__c(
                    AgentRun__c = runId,
                    CommandType__c = AgentKernelModels.COMMAND_TYPE_MODEL,
                    Status__c = AgentKernelModels.COMMAND_STATUS_PENDING,
                    ExpectedRunRevision__c = index + 10,
                    OperationKey__c = 'trace-test-' + index,
                    DispatchToken__c = 'trace-dispatch-' + index
                )
            );
        }
        AgentKernelTestFactory.insertRecords(commands);
    }

    private static void recordInvocation(AgentKernelModels.StartResult started, AgentDefinition__c definition, Integer attempt) {
        InvocationEvidenceService.Capture capture = new InvocationEvidenceService.Capture();
        capture.runId = started.runId;
        capture.commandId = started.commandId;
        capture.commandRevision = started.revision;
        capture.attemptNumber = attempt;
        capture.invocationType = 'Model';
        capture.outcome = 'Succeeded';
        capture.operationKey = started.operationKey;
        capture.startedAt = System.now();
        capture.requestJson = '{"attempt":' + attempt + '}';
        capture.responseJson = '{"result":"ok"}';

        InvocationEvidenceService.record(capture);
    }
}
