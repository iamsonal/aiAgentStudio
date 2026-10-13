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
private class PlutoRunStoryControllerTest {
    @IsTest
    static void storyCarriesTheRunItsStepsAndItsEventsWithoutStepPayloads() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 4);
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c tool = AgentKernelTestFactory.insertToolCommand(started.runId, started.revision, 'get_case', AgentKernelModels.COMMAND_STATUS_PENDING);

        Integer queriesBefore = Limits.getQueries();
        PlutoRunStoryController.Story story = PlutoRunStoryController.getStory(started.runId);
        Integer queries = Limits.getQueries() - queriesBefore;

        Assert.areEqual(started.runId, story.run.Id, 'The story is about the requested run.');
        Assert.areEqual(5, story.run.AgentDefinition__r.MaxModelCalls__c, 'The agent\'s budget comes with the run.');
        Assert.areEqual(2, story.commands.size(), 'The first model step and the tool step are listed.');
        Assert.isTrue(new Map<Id, AgentCommand__c>(story.commands).containsKey(tool.Id), 'The tool step is listed.');
        Assert.isFalse(story.commands[0].getPopulatedFieldsAsMap().containsKey('Input__c'), 'Step payloads load only when opened.');
        Assert.isFalse(story.events.isEmpty(), 'Run events are included.');
        Assert.isFalse(story.truncated, 'A short run is shown whole.');
        Assert.isTrue(queries <= 6, 'The story loads in a fixed number of queries, not one per step: ' + queries);
    }

    @IsTest
    static void storyKeepsOnlyThePayloadsThatExplainTheRun() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.insertRecords(
            new List<SObject>{
                new AgentEvent__c(
                    AgentRun__c = started.runId,
                    Sequence__c = 900,
                    EventType__c = 'Run Rescued',
                    OccurredAt__c = System.now(),
                    Payload__c = '{"mode":"rearm_failed","pausedErrorCode":"BUDGET_EXCEEDED","actorId":"' + UserInfo.getUserId() + '"}'
                ),
                new AgentEvent__c(
                    AgentRun__c = started.runId,
                    Sequence__c = 899,
                    EventType__c = 'Run Paused',
                    OccurredAt__c = System.now(),
                    Payload__c = '{"inputTokens":751,"errorCode":"BUDGET_EXCEEDED","budget":{"exceeded":"model","modelCalls":4,"maxModelCalls":4}}'
                ),
                new AgentEvent__c(
                    AgentRun__c = started.runId,
                    Sequence__c = 901,
                    EventType__c = 'Tool Requested',
                    OccurredAt__c = System.now(),
                    Payload__c = '{"inputTokens":539}'
                )
            }
        );

        PlutoRunStoryController.Story story = PlutoRunStoryController.getStory(started.runId);
        List<AgentEvent__c> events = story.events;

        Map<String, AgentEvent__c> byType = new Map<String, AgentEvent__c>();
        for (AgentEvent__c event : events) {
            byType.put(event.EventType__c, event);
        }
        Assert.isTrue(byType.get('Run Rescued').Payload__c.contains('BUDGET_EXCEEDED'), 'A rescue keeps the reason it recovered from.');
        Assert.isNull(byType.get('Tool Requested').Payload__c, 'Model telemetry on other events is not sent to the page.');
        Map<String, Object> pause = (Map<String, Object>) JSON.deserializeUntyped(byType.get('Run Paused').Payload__c);
        Assert.areEqual(new Set<String>{ 'errorCode', 'budget' }, pause.keySet(), 'A pause keeps only the facts that explain it.');
        Assert.areEqual(UserInfo.getName(), story.userNames.get(UserInfo.getUserId()), 'The page names the operator who rescued the run.');
    }

    @IsTest
    static void storyLoadsPayloadsOnlyForTheNewestExplainingEvents() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        String oversized = '{"mode":"rearm_failed","note":"' + ''.leftPad(120000, 'x') + '"}';
        List<AgentEvent__c> rescues = new List<AgentEvent__c>();
        for (Integer index = 0; index < PlutoRunStoryController.MAX_PAYLOAD_EVENTS + 5; index++) {
            rescues.add(
                new AgentEvent__c(
                    AgentRun__c = started.runId,
                    Sequence__c = 1000 + index,
                    EventType__c = 'Run Rescued',
                    OccurredAt__c = System.now(),
                    Payload__c = index >= PlutoRunStoryController.MAX_PAYLOAD_EVENTS ? oversized : '{"mode":"rearm_failed","rescue":' + index + '}'
                )
            );
        }
        AgentKernelTestFactory.insertRecords(rescues);

        Integer queriesBefore = Limits.getQueries();
        PlutoRunStoryController.Story story = PlutoRunStoryController.getStory(started.runId);
        Integer queries = Limits.getQueries() - queriesBefore;

        Map<Decimal, AgentEvent__c> bySequence = new Map<Decimal, AgentEvent__c>();
        for (AgentEvent__c event : story.events) {
            bySequence.put(event.Sequence__c, event);
        }
        Assert.isNull(bySequence.get(1000 + PlutoRunStoryController.MAX_PAYLOAD_EVENTS).Payload__c, 'An oversized payload is left out.');
        Assert.isTrue(bySequence.get(1005).Payload__c.contains('"rescue":5'), 'The newest explaining events keep their payloads.');
        Assert.isNull(bySequence.get(1004).Payload__c, 'Older explaining events show only their summary.');
        Assert.isTrue(queries <= 11, 'Payloads load in a few bounded queries after the event list: ' + queries);
    }

    @IsTest
    static void storyNamesTheToolsAModelStepAskedForWhenNoToolStepFollowed() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = AgentKernelTestFactory.getCommand(started.commandId);
        model.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        model.LeaseToken__c = 'story-lease';
        model.LeaseExpiresAt__c = System.now().addMinutes(5);
        model.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(model);
        model.Status__c = 'Succeeded';
        AgentKernelTestFactory.updateRecord(model);
        AgentKernelTestFactory.insertRecord(
            new AgentInvocation__c(
                AgentRun__c = started.runId,
                AgentCommand__c = model.Id,
                InvocationKey__c = model.OperationKey__c + ':1',
                OperationKey__c = model.OperationKey__c,
                AttemptNumber__c = 1,
                CommandRevision__c = started.revision,
                InvocationType__c = 'Model',
                Outcome__c = 'Succeeded',
                PayloadProtectionMode__c = 'Redacted',
                StartedAt__c = System.now(),
                CompletedAt__c = System.now(),
                Response__c = '{"isFinal":false,"toolCalls":[{"toolName":"simulate_escalation_notification","toolInput":"{}"}]}'
            )
        );

        PlutoRunStoryController.Story story = PlutoRunStoryController.getStory(started.runId);

        Assert.areEqual(
            new List<String>{ 'simulate_escalation_notification' },
            story.requestedTools.get(model.Id),
            'A model step whose tool never ran is named by what the model asked for.'
        );
    }

    @IsTest
    static void stepDetailLoadsOneStepsInputAndOutput() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c tool = AgentKernelTestFactory.insertToolCommand(started.runId, started.revision, 'get_case', AgentKernelModels.COMMAND_STATUS_PENDING);

        PlutoRunStoryController.StepDetail detail = PlutoRunStoryController.getStepDetail(tool.Id);

        Assert.areEqual('{}', detail.input, 'The step\'s input is returned.');
        Assert.isFalse(detail.payloadHidden, 'An admin can read step payloads.');
        Assert.isNotNull(detail.attempts, 'Attempts are listed, even when there are none yet.');
    }

    @IsTest
    static void stepDetailCarriesEvidence() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c tool = AgentKernelTestFactory.insertToolCommand(started.runId, started.revision, 'get_case', AgentKernelModels.COMMAND_STATUS_PENDING);
        AgentKernelTestFactory.insertRecord(
            new AgentInvocation__c(
                AgentRun__c = started.runId,
                AgentCommand__c = tool.Id,
                InvocationKey__c = tool.OperationKey__c + ':1',
                OperationKey__c = tool.OperationKey__c,
                AttemptNumber__c = 1,
                CommandRevision__c = started.revision,
                InvocationType__c = 'Tool',
                Outcome__c = 'Succeeded',
                PayloadProtectionMode__c = 'Redacted',
                StartedAt__c = System.now(),
                CompletedAt__c = System.now(),
                Request__c = '{"toolName":"get_case","principal":{"resolvedPrincipalUserId":"' + UserInfo.getUserId() + '"}}',
                Response__c = '{"isSuccess":true}'
            )
        );

        PlutoRunStoryController.StepDetail detail = PlutoRunStoryController.getStepDetail(tool.Id);

        Assert.areEqual(1, detail.evidence.size(), 'The attempt carries its evidence.');
        Assert.isTrue(detail.evidence[0].Request__c.contains('get_case'), 'The stored request is returned.');
        Assert.isFalse(detail.evidenceHidden, 'An admin can read evidence.');
    }

    @IsTest
    static void modelStepDetailNamesTheAgentsToolsSoThePageCanLinkToThem() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'get_case', '{"type":"object","properties":{},"additionalProperties":false}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = [SELECT Id FROM AgentCommand__c WHERE AgentRun__c = :started.runId AND CommandType__c = 'Model' LIMIT 1];
        AgentCommand__c toolStep = AgentKernelTestFactory.insertToolCommand(
            started.runId,
            started.revision,
            'get_case',
            AgentKernelModels.COMMAND_STATUS_PENDING
        );

        Assert.areEqual(
            tool.Id,
            PlutoRunStoryController.getStepDetail(model.Id).toolIds.get('get_case'),
            'A model step links each offered tool to its record.'
        );
        Assert.isNull(PlutoRunStoryController.getStepDetail(toolStep.Id).toolIds, 'A tool step offers no tools, so it skips the lookup.');
    }

    @IsTest
    static void stepDetailIsRefusedToSomeoneWithoutAgentCoreAccess() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentCommand__c model = [SELECT Id FROM AgentCommand__c WHERE AgentRun__c = :started.runId AND CommandType__c = 'Model' LIMIT 1];

        User outsider = new User(
            Alias = 'plutost',
            Email = 'pluto-story-outsider@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'No Agent Access',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'pluto-story-outsider-' + Crypto.getRandomInteger() + '@example.com'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert outsider;
        }

        System.runAs(outsider) {
            try {
                PlutoRunStoryController.getStepDetail(model.Id);
                Assert.fail('Someone without Agent Core access sees no step, and so no tools.');
            } catch (AuraHandledException expected) {
                Assert.isFalse(String.isBlank(expected.getMessage()), 'The refusal says what happened.');
            }
        }
    }

    @IsTest
    static void wrongRecordsAreRefusedWithAReadableMessage() {
        try {
            PlutoRunStoryController.getStory(UserInfo.getUserId());
            Assert.fail('Only Agent Runs have a story.');
        } catch (AuraHandledException expected) {
            Assert.isTrue(expected.getMessage().contains('Agent Run'), expected.getMessage());
        }
        try {
            PlutoRunStoryController.getStepDetail(UserInfo.getUserId());
            Assert.fail('Only steps have details.');
        } catch (AuraHandledException expected) {
            Assert.isTrue(expected.getMessage().contains('step'), expected.getMessage());
        }
    }
}
