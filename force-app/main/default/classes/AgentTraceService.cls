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

/** Sharing-aware, bounded projections of run evidence. */
@SuppressWarnings('PMD.ApexSOQLInjection') // Dynamic projections contain only hard-coded fields filtered by describe access.
global inherited sharing class AgentTraceService {
    private static final Integer EVENT_PAYLOAD_PAGE_LIMIT = 20;
    private static final Integer COMMAND_PAYLOAD_PAGE_LIMIT = 10;
    private static final Integer INVOCATION_PAYLOAD_PAGE_LIMIT = 5;

    global static AgentKernelModels.RunRecord getRun(Id runId) {
        return AgentRunService.getRun(runId);
    }

    global static AgentKernelModels.EventPage getEventPage(AgentKernelModels.EventPageRequest request) {
        requireRequest(request == null ? null : request.runId);
        validateCursorPair(request.afterSequence, request.afterId, 'Event');
        Id runId = request.runId;
        Decimal afterSequence = request.afterSequence;
        Id afterId = request.afterId;
        validateEventCursor(runId, afterSequence, afterId);
        List<String> fields = AgentRunService.accessibleFields(
            AgentEvent__c.SObjectType,
            new List<String>{
                'AgentRun__c',
                'Sequence__c',
                'EventType__c',
                'CommandKey__c',
                'OccurredAt__c',
                'Summary__c',
                'Payload__c',
                'PayloadHash__c',
                'PayloadProtectionMode__c',
                'OriginalPayloadLength__c',
                'PayloadTruncated__c',
                'PayloadRedacted__c'
            }
        );
        Integer safeLimit = safeLimit(request.limitSize, fields, new Set<String>{ 'Payload__c' }, EVENT_PAYLOAD_PAGE_LIMIT);
        Integer queryLimit = safeLimit + 1;
        String cursorClause = afterSequence == null ? '' : ' AND (Sequence__c > :afterSequence OR (Sequence__c = :afterSequence AND Id > :afterId))';
        List<AgentEvent__c> records = (List<AgentEvent__c>) Database.query(
            'SELECT ' +
                String.join(fields, ',') +
                ' FROM AgentEvent__c WHERE AgentRun__c = :runId' +
                cursorClause +
                ' ORDER BY Sequence__c ASC, Id ASC LIMIT :queryLimit',
            AccessLevel.USER_MODE
        );
        AgentKernelModels.EventPage page = new AgentKernelModels.EventPage();
        page.hasMore = records.size() > safeLimit;
        for (Integer index = 0; index < Math.min(safeLimit, records.size()); index++) {
            AgentEvent__c record = records[index];
            AgentKernelModels.EventRecord eventRecord = toEventRecord(record);
            page.events.add(eventRecord);
            page.nextSequence = eventRecord.sequence;
            page.nextId = eventRecord.id;
        }
        return page;
    }

    global static AgentKernelModels.CommandPage getCommandPage(AgentKernelModels.CommandPageRequest request) {
        requireRequest(request == null ? null : request.runId);
        validateCursorPair(request.afterCreatedDate, request.afterId, 'Command');
        Id runId = request.runId;
        Datetime afterCreatedDate = request.afterCreatedDate;
        Id afterId = request.afterId;
        validateCommandCursor(runId, afterCreatedDate, afterId);
        List<String> fields = AgentRunService.accessibleFields(
            AgentCommand__c.SObjectType,
            new List<String>{
                'AgentRun__c',
                'CommandType__c',
                'Status__c',
                'ExpectedRunRevision__c',
                'OperationKey__c',
                'AttemptNumber__c',
                'LeaseExpiresAt__c',
                'AvailableAt__c',
                'Input__c',
                'Output__c',
                'InputHash__c',
                'OutputHash__c',
                'PayloadPurgedAt__c',
                'ToolName__c',
                'BatchKey__c',
                'BatchOrdinal__c',
                'BatchSize__c',
                'ErrorCode__c',
                'ErrorMessage__c',
                'Rationale__c',
                'ProviderRequestId__c',
                'ProviderToolCallId__c',
                'DurationMs__c',
                'InputTokens__c',
                'OutputTokens__c',
                'TotalTokens__c',
                'ExternalReference__c',
                'CreatedDate'
            }
        );
        // Error messages are bounded to 1,000 characters and readable by operators; only payloads shrink the page.
        Integer safeLimit = safeLimit(request.limitSize, fields, new Set<String>{ 'Input__c', 'Output__c' }, COMMAND_PAYLOAD_PAGE_LIMIT);
        Integer queryLimit = safeLimit + 1;
        String cursorClause = afterCreatedDate == null ? '' : ' AND (CreatedDate > :afterCreatedDate OR (CreatedDate = :afterCreatedDate AND Id > :afterId))';
        List<AgentCommand__c> records = (List<AgentCommand__c>) Database.query(
            'SELECT ' +
                String.join(fields, ',') +
                ' FROM AgentCommand__c WHERE AgentRun__c = :runId' +
                cursorClause +
                ' ORDER BY CreatedDate ASC, Id ASC LIMIT :queryLimit',
            AccessLevel.USER_MODE
        );
        AgentKernelModels.CommandPage page = new AgentKernelModels.CommandPage();
        page.hasMore = records.size() > safeLimit;
        for (Integer index = 0; index < Math.min(safeLimit, records.size()); index++) {
            AgentCommand__c record = records[index];
            AgentKernelModels.CommandRecord commandRecord = toCommandRecord(record);
            page.commands.add(commandRecord);
            page.nextCreatedDate = commandRecord.createdAt;
            page.nextId = commandRecord.id;
        }
        return page;
    }

    /**
     * Returns one immutable row per completed model or tool invocation attempt.
     * Raw evidence fields are omitted unless the caller has additive sensitive
     * payload field access.
     */
    global static AgentKernelModels.InvocationPage getInvocationPage(AgentKernelModels.InvocationPageRequest request) {
        requireRequest(request == null ? null : request.runId);
        validateCursorPair(request.afterCreatedDate, request.afterId, 'Invocation');
        Id runId = request.runId;
        Datetime afterCreatedDate = request.afterCreatedDate;
        Id afterId = request.afterId;
        validateInvocationCursor(runId, afterCreatedDate, afterId);
        List<String> fields = AgentRunService.accessibleFields(
            AgentInvocation__c.SObjectType,
            new List<String>{
                'AgentRun__c',
                'AgentCommand__c',
                'InvocationKey__c',
                'AttemptNumber__c',
                'CommandRevision__c',
                'InvocationType__c',
                'Outcome__c',
                'OperationKey__c',
                'ProviderToolCallId__c',
                'StartedAt__c',
                'CompletedAt__c',
                'DurationMs__c',
                'InputTokens__c',
                'OutputTokens__c',
                'TotalTokens__c',
                'Model__c',
                'ModelAdapterClass__c',
                'ModelIdentifier__c',
                'EstimatedCostUSD__c',
                'AppliedInputPricePerMillion__c',
                'AppliedOutputPricePerMillion__c',
                'ProviderRequestId__c',
                'TransactionId__c',
                'ExternalReference__c',
                'ErrorCode__c',
                'ErrorMessage__c',
                'Request__c',
                'Response__c',
                'NativeEvidence__c',
                'RequestHash__c',
                'ResponseHash__c',
                'NativeEvidenceHash__c',
                'PayloadProtectionMode__c',
                'EvidenceMetadata__c',
                'PayloadPurgedAt__c',
                'CreatedDate'
            }
        );
        Integer safeLimit = safeLimit(
            request.limitSize,
            fields,
            new Set<String>{ 'Request__c', 'Response__c', 'NativeEvidence__c', 'ErrorMessage__c' },
            INVOCATION_PAYLOAD_PAGE_LIMIT
        );
        Integer queryLimit = safeLimit + 1;
        String cursorClause = afterCreatedDate == null ? '' : ' AND (CreatedDate > :afterCreatedDate OR (CreatedDate = :afterCreatedDate AND Id > :afterId))';
        List<AgentInvocation__c> records = (List<AgentInvocation__c>) Database.query(
            'SELECT ' +
                String.join(fields, ',') +
                ' FROM AgentInvocation__c WHERE AgentRun__c = :runId' +
                cursorClause +
                ' ORDER BY CreatedDate ASC, Id ASC LIMIT :queryLimit',
            AccessLevel.USER_MODE
        );
        AgentKernelModels.InvocationPage page = new AgentKernelModels.InvocationPage();
        page.hasMore = records.size() > safeLimit;
        for (Integer index = 0; index < Math.min(safeLimit, records.size()); index++) {
            AgentInvocation__c record = records[index];
            AgentKernelModels.InvocationRecord invocationRecord = toInvocationRecord(record);
            page.invocations.add(invocationRecord);
            page.nextCreatedDate = invocationRecord.createdAt;
            page.nextId = invocationRecord.id;
        }
        return page;
    }

    private static AgentKernelModels.EventRecord toEventRecord(AgentEvent__c source) {
        AgentKernelModels.EventRecord result = new AgentKernelModels.EventRecord();
        result.id = source.Id;
        result.runId = (Id) value(source, 'AgentRun__c');
        result.sequence = (Decimal) value(source, 'Sequence__c');
        result.eventType = (String) value(source, 'EventType__c');
        result.commandKey = (String) value(source, 'CommandKey__c');
        result.occurredAt = (Datetime) value(source, 'OccurredAt__c');
        result.summary = (String) value(source, 'Summary__c');
        result.payload = (String) value(source, 'Payload__c');
        result.payloadHash = (String) value(source, 'PayloadHash__c');
        result.payloadProtectionMode = (String) value(source, 'PayloadProtectionMode__c');
        result.originalPayloadLength = (Decimal) value(source, 'OriginalPayloadLength__c');
        result.payloadTruncated = (Boolean) value(source, 'PayloadTruncated__c');
        result.payloadRedacted = (Boolean) value(source, 'PayloadRedacted__c');
        return result;
    }

    private static AgentKernelModels.CommandRecord toCommandRecord(AgentCommand__c source) {
        AgentKernelModels.CommandRecord result = new AgentKernelModels.CommandRecord();
        result.id = source.Id;
        result.runId = (Id) value(source, 'AgentRun__c');
        result.commandType = (String) value(source, 'CommandType__c');
        result.status = (String) value(source, 'Status__c');
        result.expectedRunRevision = (Decimal) value(source, 'ExpectedRunRevision__c');
        result.operationKey = (String) value(source, 'OperationKey__c');
        result.attemptNumber = (Decimal) value(source, 'AttemptNumber__c');
        result.leaseExpiresAt = (Datetime) value(source, 'LeaseExpiresAt__c');
        result.availableAt = (Datetime) value(source, 'AvailableAt__c');
        result.input = (String) value(source, 'Input__c');
        result.output = (String) value(source, 'Output__c');
        result.inputHash = (String) value(source, 'InputHash__c');
        result.outputHash = (String) value(source, 'OutputHash__c');
        result.payloadPurgedAt = (Datetime) value(source, 'PayloadPurgedAt__c');
        result.toolName = (String) value(source, 'ToolName__c');
        result.batchKey = (String) value(source, 'BatchKey__c');
        result.batchOrdinal = (Decimal) value(source, 'BatchOrdinal__c');
        result.batchSize = (Decimal) value(source, 'BatchSize__c');
        result.errorCode = (String) value(source, 'ErrorCode__c');
        result.errorMessage = (String) value(source, 'ErrorMessage__c');
        result.rationale = (String) value(source, 'Rationale__c');
        result.providerRequestId = (String) value(source, 'ProviderRequestId__c');
        result.providerToolCallId = (String) value(source, 'ProviderToolCallId__c');
        result.durationMilliseconds = (Decimal) value(source, 'DurationMs__c');
        result.inputTokens = (Decimal) value(source, 'InputTokens__c');
        result.outputTokens = (Decimal) value(source, 'OutputTokens__c');
        result.totalTokens = (Decimal) value(source, 'TotalTokens__c');
        result.externalReference = (String) value(source, 'ExternalReference__c');
        result.createdAt = (Datetime) value(source, 'CreatedDate');
        return result;
    }

    private static AgentKernelModels.InvocationRecord toInvocationRecord(AgentInvocation__c source) {
        AgentKernelModels.InvocationRecord result = new AgentKernelModels.InvocationRecord();
        result.id = source.Id;
        result.runId = (Id) value(source, 'AgentRun__c');
        result.commandId = (Id) value(source, 'AgentCommand__c');
        result.invocationKey = (String) value(source, 'InvocationKey__c');
        result.attemptNumber = (Decimal) value(source, 'AttemptNumber__c');
        result.commandRevision = (Decimal) value(source, 'CommandRevision__c');
        result.invocationType = (String) value(source, 'InvocationType__c');
        result.outcome = (String) value(source, 'Outcome__c');
        result.operationKey = (String) value(source, 'OperationKey__c');
        result.providerToolCallId = (String) value(source, 'ProviderToolCallId__c');
        result.startedAt = (Datetime) value(source, 'StartedAt__c');
        result.completedAt = (Datetime) value(source, 'CompletedAt__c');
        result.durationMilliseconds = (Decimal) value(source, 'DurationMs__c');
        result.inputTokens = (Decimal) value(source, 'InputTokens__c');
        result.outputTokens = (Decimal) value(source, 'OutputTokens__c');
        result.totalTokens = (Decimal) value(source, 'TotalTokens__c');
        result.model = (String) value(source, 'Model__c');
        result.modelAdapterClass = (String) value(source, 'ModelAdapterClass__c');
        result.modelIdentifier = (String) value(source, 'ModelIdentifier__c');
        result.estimatedCostUsd = (Decimal) value(source, 'EstimatedCostUSD__c');
        result.appliedInputPricePerMillion = (Decimal) value(source, 'AppliedInputPricePerMillion__c');
        result.appliedOutputPricePerMillion = (Decimal) value(source, 'AppliedOutputPricePerMillion__c');
        result.providerRequestId = (String) value(source, 'ProviderRequestId__c');
        result.transactionId = (String) value(source, 'TransactionId__c');
        result.externalReference = (String) value(source, 'ExternalReference__c');
        result.errorCode = (String) value(source, 'ErrorCode__c');
        result.errorMessage = (String) value(source, 'ErrorMessage__c');
        result.request = (String) value(source, 'Request__c');
        result.response = (String) value(source, 'Response__c');
        result.nativeEvidence = (String) value(source, 'NativeEvidence__c');
        result.requestHash = (String) value(source, 'RequestHash__c');
        result.responseHash = (String) value(source, 'ResponseHash__c');
        result.nativeEvidenceHash = (String) value(source, 'NativeEvidenceHash__c');
        result.payloadProtectionMode = (String) value(source, 'PayloadProtectionMode__c');
        result.evidenceMetadata = (String) value(source, 'EvidenceMetadata__c');
        result.payloadPurgedAt = (Datetime) value(source, 'PayloadPurgedAt__c');
        result.createdAt = (Datetime) value(source, 'CreatedDate');
        return result;
    }

    private static Object value(SObject source, String fieldName) {
        return AgentRunService.fieldValue(source, fieldName);
    }

    private static void requireRequest(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.InvalidTransitionException('Trace query run ID is required.');
        }
        AgentKernelAccessGuard.assertRunReadable(runId);
    }

    private static Integer safeLimit(Integer requestedLimit) {
        return Math.max(1, Math.min(200, requestedLimit == null ? 50 : requestedLimit));
    }

    private static Integer safeLimit(Integer requestedLimit, List<String> projectedFields, Set<String> payloadFields, Integer payloadLimit) {
        Integer result = safeLimit(requestedLimit);
        for (String fieldName : payloadFields) {
            if (projectedFields.contains(fieldName)) {
                return Math.min(result, payloadLimit);
            }
        }
        return result;
    }

    private static void validateCursorPair(Object firstKey, Id afterId, String sourceName) {
        if ((firstKey == null) != (afterId == null)) {
            throw new AgentKernelException.InvalidTransitionException(sourceName + ' trace cursor is incomplete.');
        }
        if (firstKey instanceof Decimal && (Decimal) firstKey < 0) {
            throw new AgentKernelException.InvalidTransitionException('Event trace cursor cannot be negative.');
        }
    }

    private static void validateEventCursor(Id runId, Decimal sequence, Id afterId) {
        if (afterId == null) {
            return;
        }
        List<AgentEvent__c> rows = [
            SELECT AgentRun__c, Sequence__c
            FROM AgentEvent__c
            WHERE Id = :afterId AND AgentRun__c = :runId AND Sequence__c = :sequence
            WITH USER_MODE
            LIMIT 1
        ];
        requireOwnedCursor(!rows.isEmpty(), 'Event');
    }

    private static void validateCommandCursor(Id runId, Datetime createdAt, Id afterId) {
        if (afterId == null) {
            return;
        }
        List<AgentCommand__c> rows = [
            SELECT Id
            FROM AgentCommand__c
            WHERE Id = :afterId AND AgentRun__c = :runId AND CreatedDate = :createdAt
            WITH USER_MODE
            LIMIT 1
        ];
        requireOwnedCursor(!rows.isEmpty(), 'Command');
    }

    private static void validateInvocationCursor(Id runId, Datetime createdAt, Id afterId) {
        if (afterId == null) {
            return;
        }
        List<AgentInvocation__c> rows = [
            SELECT Id
            FROM AgentInvocation__c
            WHERE Id = :afterId AND AgentRun__c = :runId AND CreatedDate = :createdAt
            WITH USER_MODE
            LIMIT 1
        ];
        requireOwnedCursor(!rows.isEmpty(), 'Invocation');
    }

    private static void requireOwnedCursor(Boolean valid, String sourceName) {
        if (!valid) {
            throw new AgentKernelException.InvalidTransitionException(sourceName + ' trace cursor does not belong to this run.');
        }
    }
}
