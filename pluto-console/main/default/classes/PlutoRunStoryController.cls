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

/**
 * Read-only story of one Agent Run for the plutoRunStory component.
 *
 * UI aid only. Every query runs in user mode, so sharing and field access
 * fail closed, and a field the viewer cannot read is left out rather than
 * failing the page. The story carries no step payloads; getStepDetail loads
 * one step's input and output when the viewer opens it. No DML here.
 */
public with sharing class PlutoRunStoryController {
    @TestVisible
    private static final Integer MAX_COMMANDS = 500;
    private static final Integer MAX_INVOCATIONS = 1000;
    private static final Integer MAX_APPROVALS = 200;
    @TestVisible
    private static final Integer MAX_EVENTS = 1000;
    private static final Integer MAX_EVENT_PAYLOAD = 2000;
    @TestVisible
    private static final Integer MAX_PAYLOAD_EVENTS = 20;
    /** Payload rows read per query, so heap holds at most this many full payloads at once. */
    private static final Integer PAYLOAD_FETCH_SIZE = 5;
    private static final Integer MAX_RUN_PAYLOAD = 20000;
    /** Model and tool evidence is up to three 131,072-character fields per attempt, so only the latest attempts carry it. */
    private static final Integer MAX_EVIDENCE_ATTEMPTS = 3;
    /** Model steps whose requested tools never ran are rare; each reads one evidence field of up to 131,072 characters. */
    private static final Integer MAX_UNRUN_REQUESTS = 5;
    /** Only these events explain the story; model telemetry on the others is not shown. */
    private static final Set<String> EVENT_PAYLOAD_TYPES = new Set<String>{ 'Run Rescued', 'Run Waiting', 'Run Resumed' };
    /** A pause event also carries model telemetry; only the facts that explain the pause are sent. */
    private static final Set<String> PAUSE_FACTS = new Set<String>{ 'errorCode', 'budget', 'actorId' };

    public class Story {
        @AuraEnabled
        public AgentRun__c run { get; set; }
        @AuraEnabled
        public String anchorName { get; set; }
        @AuraEnabled
        public List<AgentCommand__c> commands { get; set; }
        @AuraEnabled
        public List<AgentInvocation__c> invocations { get; set; }
        @AuraEnabled
        public List<AgentApproval__c> approvals { get; set; }
        @AuraEnabled
        public List<AgentEvent__c> events { get; set; }
        /** True when the run has more steps or events than one story shows. */
        @AuraEnabled
        public Boolean truncated { get; set; }
        /** Names of the operators and deciders the events name, keyed by Id. */
        @AuraEnabled
        public Map<Id, String> userNames { get; set; }
        /**
         * The tools a model step asked for when no tool step followed it, such as
         * when Core paused before the tool ran, keyed by the model step's Id.
         * Absent when the viewer cannot read evidence.
         */
        @AuraEnabled
        public Map<Id, List<String>> requestedTools { get; set; }
    }

    public class StepDetail {
        @AuraEnabled
        public String input { get; set; }
        @AuraEnabled
        public String output { get; set; }
        @AuraEnabled
        public Boolean payloadHidden { get; set; }
        @AuraEnabled
        public Datetime payloadPurgedAt { get; set; }
        @AuraEnabled
        public List<AgentInvocation__c> attempts { get; set; }
        /** The latest attempts' model or tool request, response, and provider evidence. */
        @AuraEnabled
        public List<AgentInvocation__c> evidence { get; set; }
        /** True when the viewer lacks Agent Kernel Sensitive Data, which guards evidence. */
        @AuraEnabled
        public Boolean evidenceHidden { get; set; }
        /** For a model step, the agent's tools keyed by the name the model saw, so the page can link to each. */
        @AuraEnabled
        public Map<String, Id> toolIds { get; set; }
    }

    @AuraEnabled
    public static Story getStory(Id runId) {
        try {
            requireRun(runId);
            Story story = new Story();
            story.run = loadRun(runId);
            story.anchorName = anchorName(story.run.AnchorRecordId__c);
            story.commands = (List<AgentCommand__c>) query(
                AgentCommand__c.SObjectType,
                new List<String>{
                    'Sequence__c',
                    'CommandType__c',
                    'Status__c',
                    'ToolName__c',
                    'OperationKey__c',
                    'AttemptNumber__c',
                    'InputSource__c',
                    'AnswerTurn__c',
                    'BatchKey__c',
                    'BatchOrdinal__c',
                    'BatchSize__c',
                    'ErrorCode__c',
                    'ErrorMessage__c',
                    'Rationale__c',
                    'DurationMs__c',
                    'TotalTokens__c',
                    'PayloadPurgedAt__c',
                    'CreatedDate',
                    'LastModifiedDate'
                },
                'AgentRun__c = :recordId ORDER BY Sequence__c ASC, Id ASC',
                runId,
                MAX_COMMANDS + 1
            );
            story.invocations = (List<AgentInvocation__c>) query(
                AgentInvocation__c.SObjectType,
                new List<String>{
                    'AgentCommand__c',
                    'InvocationType__c',
                    'Outcome__c',
                    'AttemptNumber__c',
                    'StartedAt__c',
                    'CompletedAt__c',
                    'DurationMs__c',
                    'InputTokens__c',
                    'OutputTokens__c',
                    'TotalTokens__c',
                    'EstimatedCostUSD__c',
                    'ModelIdentifier__c',
                    'ErrorCode__c'
                },
                'AgentRun__c = :recordId ORDER BY CreatedDate ASC, Id ASC',
                runId,
                MAX_INVOCATIONS
            );
            story.approvals = (List<AgentApproval__c>) query(
                AgentApproval__c.SObjectType,
                new List<String>{
                    'Name',
                    'AgentCommand__c',
                    'Status__c',
                    'ApproverType__c',
                    'ToolName__c',
                    'Owner.Name',
                    'RequestedBy__r.Name',
                    'DecidedBy__r.Name',
                    'RelayedBy__r.Name',
                    'Reason__c',
                    'DecisionComment__c',
                    'ExpiresAt__c',
                    'ClosedAt__c',
                    'CreatedDate'
                },
                'AgentRun__c = :recordId ORDER BY CreatedDate ASC, Id ASC',
                runId,
                MAX_APPROVALS
            );
            story.events = (List<AgentEvent__c>) query(
                AgentEvent__c.SObjectType,
                new List<String>{ 'Sequence__c', 'EventType__c', 'CommandKey__c', 'OccurredAt__c', 'Summary__c' },
                'AgentRun__c = :recordId ORDER BY Sequence__c ASC, Id ASC',
                runId,
                MAX_EVENTS + 1
            );
            story.truncated = story.commands.size() > MAX_COMMANDS || story.events.size() > MAX_EVENTS;
            if (story.commands.size() > MAX_COMMANDS) {
                story.commands.remove(MAX_COMMANDS);
            }
            if (story.events.size() > MAX_EVENTS) {
                story.events.remove(MAX_EVENTS);
            }
            attachEventPayloads(story.events);
            story.userNames = actorNames(story.events);
            story.requestedTools = unrunRequests(story.run, story.commands);
            return story;
        } catch (AuraHandledException known) {
            throw known;
        } catch (Exception failure) {
            throw friendly(failure, 'The run could not be loaded.');
        }
    }

    /** One step's input, output, and attempt errors, loaded when the viewer opens the step. */
    @AuraEnabled
    public static StepDetail getStepDetail(Id commandId) {
        try {
            if (commandId == null || commandId.getSObjectType() != AgentCommand__c.SObjectType) {
                throw handled('Choose a step to open.');
            }
            List<AgentCommand__c> commands = (List<AgentCommand__c>) query(
                AgentCommand__c.SObjectType,
                new List<String>{ 'Input__c', 'Output__c', 'PayloadPurgedAt__c', 'CommandType__c', 'AgentRun__r.AgentDefinition__c' },
                'Id = :recordId',
                commandId,
                1
            );
            if (commands.isEmpty()) {
                throw handled('This step is no longer available.');
            }
            AgentCommand__c command = commands[0];
            Map<String, Object> fields = command.getPopulatedFieldsAsMap();
            StepDetail detail = new StepDetail();
            detail.payloadHidden = !readable(AgentCommand__c.SObjectType, 'Input__c') || !readable(AgentCommand__c.SObjectType, 'Output__c');
            detail.input = (String) fields.get('Input__c');
            detail.output = (String) fields.get('Output__c');
            detail.payloadPurgedAt = (Datetime) fields.get('PayloadPurgedAt__c');
            detail.attempts = (List<AgentInvocation__c>) query(
                AgentInvocation__c.SObjectType,
                new List<String>{
                    'AttemptNumber__c',
                    'InvocationType__c',
                    'Outcome__c',
                    'StartedAt__c',
                    'DurationMs__c',
                    'ErrorCode__c',
                    'ErrorMessage__c',
                    'ProviderRequestId__c',
                    'ModelIdentifier__c',
                    'InputTokens__c',
                    'OutputTokens__c',
                    'TotalTokens__c',
                    'EstimatedCostUSD__c',
                    'CpuTimeMs__c',
                    'SoqlQueries__c',
                    'DmlStatements__c',
                    'TransactionId__c',
                    'PayloadProtectionMode__c',
                    'PayloadPurgedAt__c'
                },
                'AgentCommand__c = :recordId ORDER BY AttemptNumber__c ASC, CreatedDate ASC',
                commandId,
                50
            );
            detail.evidenceHidden = !readable(AgentInvocation__c.SObjectType, 'Request__c') || !readable(AgentInvocation__c.SObjectType, 'Response__c');
            detail.evidence = (List<AgentInvocation__c>) query(
                AgentInvocation__c.SObjectType,
                new List<String>{ 'AttemptNumber__c', 'Request__c', 'Response__c', 'NativeEvidence__c', 'EvidenceMetadata__c' },
                'AgentCommand__c = :recordId ORDER BY AttemptNumber__c DESC, CreatedDate DESC',
                commandId,
                MAX_EVIDENCE_ATTEMPTS
            );
            if (fields.get('CommandType__c') == 'Model' && fields.containsKey('AgentRun__r')) {
                detail.toolIds = toolIds(command.AgentRun__r.AgentDefinition__c);
            }
            return detail;
        } catch (AuraHandledException known) {
            throw known;
        } catch (Exception failure) {
            throw friendly(failure, 'This step could not be loaded.');
        }
    }

    /**
     * A model step names the tools it chose through the steps that follow it.
     * When none follows, only the model's recorded reply says what it asked for.
     */
    private static Map<Id, List<String>> unrunRequests(AgentRun__c run, List<AgentCommand__c> commands) {
        Map<Id, List<String>> requested = new Map<Id, List<String>>();
        List<Id> candidates = new List<Id>();
        for (Integer index = commands.size() - 1; index >= 0 && candidates.size() < MAX_UNRUN_REQUESTS; index--) {
            // A field the viewer cannot read was left out of the query, so it is read from the populated map.
            Map<String, Object> fields = commands[index].getPopulatedFieldsAsMap();
            Boolean isLast = index == commands.size() - 1;
            Boolean toolFollows = !isLast && commands[index + 1].getPopulatedFieldsAsMap().get('CommandType__c') == 'Tool';
            Boolean finalAnswer = isLast && run.getPopulatedFieldsAsMap().get('Status__c') == 'Succeeded';
            if (
                fields.get('CommandType__c') == 'Model' &&
                fields.get('Status__c') == 'Succeeded' &&
                fields.get('AnswerTurn__c') != true &&
                !toolFollows &&
                !finalAnswer
            ) {
                candidates.add(commands[index].Id);
            }
        }
        if (candidates.isEmpty() || !readable(AgentInvocation__c.SObjectType, 'Response__c')) {
            return requested;
        }
        List<AgentInvocation__c> replies = (List<AgentInvocation__c>) query(
            AgentInvocation__c.SObjectType,
            new List<String>{ 'AgentCommand__c', 'Response__c' },
            'AgentCommand__c IN :recordId AND InvocationType__c = \'Model\' AND Outcome__c = \'Succeeded\' ORDER BY AttemptNumber__c DESC, CreatedDate DESC',
            candidates,
            MAX_UNRUN_REQUESTS * 2
        );
        for (AgentInvocation__c reply : replies) {
            if (requested.containsKey(reply.AgentCommand__c) || reply.Response__c == null) {
                continue;
            }
            List<String> names = toolNames(reply.Response__c);
            if (!names.isEmpty()) {
                requested.put(reply.AgentCommand__c, names);
            }
        }
        return requested;
    }

    /** Inactive tools are included: an older step may have offered one that was switched off since. */
    private static Map<String, Id> toolIds(Id agentId) {
        Map<String, Id> ids = new Map<String, Id>();
        if (agentId == null || !AgentTool__c.SObjectType.getDescribe().isAccessible() || !readable(AgentTool__c.SObjectType, 'DeveloperName__c')) {
            return ids;
        }
        for (
            AgentTool__c tool : (List<AgentTool__c>) query(
                AgentTool__c.SObjectType,
                new List<String>{ 'DeveloperName__c' },
                'AgentDefinition__c = :recordId',
                agentId,
                200
            )
        ) {
            ids.put(tool.DeveloperName__c, tool.Id);
        }
        return ids;
    }

    private static List<String> toolNames(String response) {
        List<String> names = new List<String>();
        try {
            Object calls = ((Map<String, Object>) JSON.deserializeUntyped(response)).get('toolCalls');
            if (calls instanceof List<Object>) {
                for (Object call : (List<Object>) calls) {
                    Object name = call instanceof Map<String, Object> ? ((Map<String, Object>) call).get('toolName') : null;
                    if (name instanceof String) {
                        names.add((String) name);
                    }
                }
            }
        } catch (Exception unreadable) {
            // A truncated or tokenized reply cannot be read; the step keeps its general title.
            names.clear();
        }
        return names;
    }

    /** Rescue and resume events name the person who acted; the page shows their names. */
    private static Map<Id, String> actorNames(List<AgentEvent__c> events) {
        Set<Id> userIds = new Set<Id>();
        for (AgentEvent__c event : events) {
            Object payload = event.getPopulatedFieldsAsMap().get('Payload__c');
            if (payload == null) {
                continue;
            }
            try {
                Object actor = ((Map<String, Object>) JSON.deserializeUntyped((String) payload)).get('actorId');
                if (actor instanceof String && ((String) actor).startsWith('005')) {
                    userIds.add(Id.valueOf((String) actor));
                }
            } catch (Exception unreadable) {
                continue;
            }
        }
        return userNames(userIds);
    }

    private static Map<Id, String> userNames(Set<Id> userIds) {
        Map<Id, String> names = new Map<Id, String>();
        if (userIds.isEmpty()) {
            return names;
        }
        for (User person : [SELECT Id, Name FROM User WHERE Id IN :userIds WITH USER_MODE]) {
            names.put(person.Id, person.Name);
        }
        return names;
    }

    private static void requireRun(Id runId) {
        if (runId == null || runId.getSObjectType() != AgentRun__c.SObjectType) {
            throw handled('Open this component on an Agent Run.');
        }
        if (!AgentRun__c.SObjectType.getDescribe().isAccessible()) {
            throw handled('You do not have access to Agent Runs.');
        }
    }

    private static AgentRun__c loadRun(Id runId) {
        List<AgentRun__c> runs = (List<AgentRun__c>) query(
            AgentRun__c.SObjectType,
            new List<String>{
                'Name',
                'Status__c',
                'AgentDefinition__c',
                'AgentDefinition__r.Name',
                'AgentDefinition__r.MaxModelCalls__c',
                'AgentDefinition__r.MaxToolCalls__c',
                'AgentDefinition__r.MaxTotalTokens__c',
                'ReplyModelCallBase__c',
                'ReplyToolCallBase__c',
                'ReplyTokenBase__c',
                'AnchorRecordId__c',
                'ParentRun__c',
                'ParentRun__r.Name',
                'InitiatingUser__c',
                'InitiatingUser__r.Name',
                'ExecutionIdentity__c',
                'ExecutionIdentity__r.PrincipalUser__r.Name',
                'InvocationEntryPoint__c',
                'CurrentCommand__c',
                'WaitingCommand__c',
                'WaitingReason__c',
                'WaitExpiresAt__c',
                'ErrorCode__c',
                'ErrorMessage__c',
                'ModelCallCount__c',
                'ToolCallCount__c',
                'TotalTokenCount__c',
                'UnmeteredModelAttempts__c',
                'StartedAt__c',
                'LastActivityAt__c',
                'CompletedAt__c',
                'Input__c',
                'Output__c',
                'CreatedDate'
            },
            'Id = :recordId',
            runId,
            1
        );
        if (runs.isEmpty()) {
            throw handled('This run does not exist or is not shared with you.');
        }
        AgentRun__c run = runs[0];
        Map<String, Object> fields = run.getPopulatedFieldsAsMap();
        if (fields.containsKey('Input__c') && run.Input__c != null) {
            run.Input__c = run.Input__c.left(MAX_RUN_PAYLOAD);
        }
        if (fields.containsKey('Output__c') && run.Output__c != null) {
            run.Output__c = run.Output__c.left(MAX_RUN_PAYLOAD);
        }
        return run;
    }

    /** The anchor's display name, when the viewer can read it; otherwise the Id is shown. */
    private static String anchorName(String anchorId) {
        if (String.isBlank(anchorId)) {
            return null;
        }
        try {
            Id recordId = Id.valueOf(anchorId);
            Schema.DescribeSObjectResult describe = recordId.getSObjectType().getDescribe();
            if (!describe.isAccessible()) {
                return null;
            }
            String nameField;
            for (Schema.SObjectField field : describe.fields.getMap().values()) {
                Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
                if (fieldDescribe.isNameField() && fieldDescribe.isAccessible()) {
                    nameField = fieldDescribe.getName();
                    break;
                }
            }
            if (nameField == null) {
                return null;
            }
            List<SObject> records = Database.queryWithBinds(
                'SELECT ' + nameField + ' FROM ' + describe.getName() + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => recordId },
                AccessLevel.USER_MODE
            );
            return records.isEmpty() ? null : String.valueOf(records[0].get(nameField));
        } catch (Exception unreadable) {
            return null;
        }
    }

    /**
     * Queries the fields the viewer can read, in user mode. Relationship paths
     * are kept only when the lookup is readable; the related object's sharing
     * then decides whether its name appears.
     */
    private static List<SObject> query(Schema.SObjectType type, List<String> fields, String condition, Object binding, Integer limitSize) {
        List<String> selected = new List<String>{ 'Id' };
        for (String field : fields) {
            if (readablePath(type, field)) {
                selected.add(field);
            }
        }
        return Database.queryWithBinds(
            'SELECT ' + String.join(selected, ',') + ' FROM ' + type.getDescribe().getName() + ' WHERE ' + condition + ' LIMIT ' + limitSize,
            new Map<String, Object>{ 'recordId' => binding },
            AccessLevel.USER_MODE
        );
    }

    private static Boolean readablePath(Schema.SObjectType type, String path) {
        if (!path.contains('.')) {
            return readable(type, path);
        }
        String relationship = path.substringBefore('.');
        String lookup = relationship.endsWith('__r') ? relationship.removeEnd('__r') + '__c' : relationship + 'Id';
        Schema.SObjectField field = type.getDescribe().fields.getMap().get(lookup.toLowerCase());
        if (field == null || !field.getDescribe().isAccessible()) {
            return false;
        }
        // Each hop must be readable, so a path through a hidden lookup is left out.
        for (Schema.SObjectType target : field.getDescribe().getReferenceTo()) {
            if (!target.getDescribe().isAccessible() || !readablePath(target, path.substringAfter('.'))) {
                return false;
            }
        }
        return true;
    }

    private static Boolean readable(Schema.SObjectType type, String fieldName) {
        Schema.SObjectField field = type.getDescribe().fields.getMap().get(fieldName.toLowerCase());
        return field != null && field.getDescribe().isAccessible();
    }

    private static String pauseFacts(String payload) {
        try {
            Object parsed = JSON.deserializeUntyped(payload);
            if (!(parsed instanceof Map<String, Object>)) {
                return null;
            }
            Map<String, Object> facts = new Map<String, Object>();
            for (String key : PAUSE_FACTS) {
                if (((Map<String, Object>) parsed).containsKey(key)) {
                    facts.put(key, ((Map<String, Object>) parsed).get(key));
                }
            }
            return facts.isEmpty() ? null : JSON.serialize(facts);
        } catch (JSONException unreadable) {
            return null;
        }
    }

    /**
     * Event payloads can each hold 131,072 characters, so the story never
     * loads them with the event list. Only the newest events that explain the
     * run (pauses, rescues, waits, and resumes) get theirs, a few rows per
     * query, each trimmed before the next is read. Older ones show their summary.
     */
    private static void attachEventPayloads(List<AgentEvent__c> events) {
        if (!readable(AgentEvent__c.SObjectType, 'Payload__c')) {
            return;
        }
        Map<Id, AgentEvent__c> explaining = new Map<Id, AgentEvent__c>();
        for (Integer index = events.size() - 1; index >= 0; index--) {
            AgentEvent__c event = events[index];
            event.Payload__c = null;
            Object eventType = event.getPopulatedFieldsAsMap().get('EventType__c');
            if (explaining.size() < MAX_PAYLOAD_EVENTS && (eventType == 'Run Paused' || EVENT_PAYLOAD_TYPES.contains((String) eventType))) {
                explaining.put(event.Id, event);
            }
        }
        List<Id> pending = new List<Id>(explaining.keySet());
        for (Integer offset = 0; offset < pending.size(); offset += PAYLOAD_FETCH_SIZE) {
            List<Id> chunk = new List<Id>();
            for (Integer index = offset; index < Math.min(pending.size(), offset + PAYLOAD_FETCH_SIZE); index++) {
                chunk.add(pending[index]);
            }
            for (
                AgentEvent__c loaded : (List<AgentEvent__c>) query(
                    AgentEvent__c.SObjectType,
                    new List<String>{ 'Payload__c' },
                    'Id IN :recordId',
                    chunk,
                    chunk.size()
                )
            ) {
                AgentEvent__c event = explaining.get(loaded.Id);
                event.Payload__c = storyPayload(event.EventType__c, loaded.Payload__c);
            }
        }
    }

    private static String storyPayload(String eventType, String payload) {
        if (payload == null) {
            return null;
        }
        if (eventType == 'Run Paused') {
            return pauseFacts(payload);
        }
        return payload.length() > MAX_EVENT_PAYLOAD ? null : payload;
    }

    private static AuraHandledException friendly(Exception failure, String fallback) {
        return handled(
            failure instanceof QueryException || failure instanceof System.NoAccessException
                ? 'You do not have access to part of this run. Ask an admin for Agent Core read access.'
                : fallback
        );
    }

    /** setMessage keeps the text readable to Apex callers and tests as well as the page. */
    private static AuraHandledException handled(String message) {
        AuraHandledException failure = new AuraHandledException(message);
        failure.setMessage(message);
        return failure;
    }
}
