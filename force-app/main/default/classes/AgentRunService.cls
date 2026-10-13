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

/** Sharing-aware entry points for starting and controlling runs. */
global inherited sharing class AgentRunService {
    private static final Integer MAX_RUNS_PER_READ = 200;

    global static AgentKernelModels.StartResult start(AgentKernelModels.StartRequest request) {
        return startFromEntryPoint(request, AgentKernelModels.INVOCATION_APEX);
    }

    public static AgentKernelModels.StartResult startFromEntryPoint(AgentKernelModels.StartRequest request, String invocationEntryPoint) {
        AgentKernelModels.StartResult result = persistStart(request, invocationEntryPoint, true);
        if (result.deduplicated != true) {
            CommandDispatcher.dispatch(result.commandId);
        }
        return result;
    }

    /**
     * Persists a run without dispatching it, for bulk callers that dispatch
     * many runs together. A command left undispatched is picked up by
     * scheduled recovery.
     */
    public static AgentKernelModels.StartResult startWithoutDispatch(AgentKernelModels.StartRequest request, String invocationEntryPoint) {
        return persistStart(request, invocationEntryPoint, false);
    }

    private static AgentKernelModels.StartResult persistStart(
        AgentKernelModels.StartRequest request,
        String invocationEntryPoint,
        Boolean requireDispatchCapacity
    ) {
        if (request == null) {
            throw new AgentKernelException.InvalidTransitionException('Start request is required.');
        }
        Boolean hasDefinitionId = request.definitionId != null;
        Boolean hasDeveloperName = !String.isBlank(request.developerName);
        if (hasDefinitionId == hasDeveloperName) {
            throw new AgentKernelException.InvalidTransitionException('Specify exactly one definition ID or developer name.');
        }
        AgentDefinition__c definition = hasDefinitionId
            ? AgentConfigService.getActiveDefinition(request.definitionId)
            : AgentConfigService.getActiveDefinition(request.developerName);
        String deduplicationKey = AgentRunDeduplicationService.deduplicationKey(definition.Id, request.externalCorrelationKey);
        String requestHash = startRequestHash(deduplicationKey, definition.Id, request, invocationEntryPoint, definition.ExecutionIdentity__c);
        AgentKernelModels.StartResult existing = AgentRunDeduplicationService.findVisibleExisting(deduplicationKey, requestHash);
        if (existing != null) {
            return existing;
        }
        if (requireDispatchCapacity) {
            CommandDispatcher.assertCapacityForNewRun(definition);
        }
        try {
            return AgentKernel.startRun(definition, request, invocationEntryPoint);
        } catch (AgentKernelException.PersistenceException insertFailure) {
            // A concurrent start with the same correlation key won the unique key.
            existing = AgentRunDeduplicationService.findVisibleExisting(deduplicationKey, requestHash);
            if (existing != null) {
                return existing;
            }
            if (deduplicationKey != null && insertFailure.statusCode == 'DUPLICATE_VALUE') {
                throw new AgentKernelException.NotFoundException('The requested definition or correlated run was not found or is inaccessible.');
            }
            throw insertFailure;
        }
    }

    private static String startRequestHash(
        String deduplicationKey,
        Id definitionId,
        AgentKernelModels.StartRequest request,
        String invocationEntryPoint,
        Id executionIdentityId
    ) {
        return deduplicationKey == null
            ? null
            : AgentRunDeduplicationService.requestHash(
                  definitionId,
                  request.anchorRecordId,
                  request.parentRunId,
                  request.input,
                  invocationEntryPoint,
                  executionIdentityId
              );
    }

    global static void cancel(Id runId, Decimal expectedRevision, String reason) {
        requireRunId(runId);
        AgentKernel.cancel(runId, expectedRevision, reason);
    }

    global static Id resume(AgentKernelModels.ResumeRequest request) {
        if (request == null) {
            throw new AgentKernelException.InvalidTransitionException('Resume request is required.');
        }
        requireRunId(request.runId);
        Id commandId = AgentKernel.resume(request.runId, request.expectedRunRevision, request.payload);
        // Null when the reply was kept but the run paused on a spent model budget.
        if (commandId != null) {
            CommandDispatcher.dispatch(commandId);
        }
        return commandId;
    }

    /**
     * Resumes a tool's wait for outside input with the resume key the tool
     * received in ToolRequest.resumeKey. For an outside system's callback: the
     * key is the authority, so the caller needs no Run Control and no revision.
     * The payload must match the wait's resume schema.
     */
    global static Id resumeWait(String resumeKey, String payload) {
        if (String.isBlank(resumeKey)) {
            throw new AgentKernelException.InvalidTransitionException('A resume key is required.');
        }
        Id commandId = AgentKernel.resumeWithKey(resumeKey.trim(), payload);
        if (commandId != null) {
            CommandDispatcher.dispatch(commandId);
        }
        return commandId;
    }

    global static void pause(Id runId, Decimal expectedRevision, String reason) {
        requireRunId(runId);
        AgentKernel.pause(runId, expectedRevision, reason);
    }

    global static Id rescue(AgentKernelModels.RescueRequest request) {
        if (request == null) {
            throw new AgentKernelException.InvalidTransitionException('Rescue request is required.');
        }
        requireRunId(request.runId);
        Id commandId = AgentKernel.rescue(request);
        CommandDispatcher.dispatch(commandId);
        return commandId;
    }

    /**
     * Records an approver's decision on an Agent Approval. The caller is the
     * approver, or an approval channel with Agent Kernel Approval Relay that
     * names the approver in deciderId. Approval continues the waiting tool;
     * rejection continues to the model; neither cancels the run.
     */
    global static Id decideApproval(AgentKernelModels.ApprovalDecision decision) {
        Id commandId = AgentKernel.decideApproval(decision);
        if (commandId != null) {
            CommandDispatcher.dispatch(commandId);
        }
        return commandId;
    }

    /** Returns a pending approval's tool input with trust tokens resolved, for a user who could decide it; audited. */
    global static String resolveApprovalInput(Id approvalId) {
        return AgentApprovalService.resolveInput(approvalId);
    }

    global static AgentKernelModels.ReconciliationResult reconcileUnknownOutcome(AgentKernelModels.ReconciliationRequest request) {
        if (request == null) {
            throw new AgentKernelException.InvalidTransitionException('Reconciliation request is required.');
        }
        requireRunId(request.runId);
        AgentKernelModels.ReconciliationResult result = AgentKernel.reconcileUnknownOutcome(request);
        if (result.dispatchedCommandId != null) {
            CommandDispatcher.dispatch(result.dispatchedCommandId);
        }
        return result;
    }

    /**
     * Settles the run's one Unknown tool call, reading its command, operation
     * key, and revision itself, for no-code operators. decision is
     * ConfirmSucceeded, ConfirmFailed, or Retry.
     */
    public static AgentKernelModels.ReconciliationResult reconcileCurrentUnknown(
        Id runId,
        String decision,
        String reason,
        String confirmedOutput,
        String failureMessage,
        Boolean safeToRetry,
        Boolean pauseRun
    ) {
        requireRunId(runId);
        List<AgentCommand__c> unknown = [
            SELECT Id, OperationKey__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId AND Status__c = :AgentKernelModels.COMMAND_STATUS_UNKNOWN
            WITH USER_MODE
            LIMIT 1
        ];
        if (unknown.isEmpty()) {
            throw new AgentKernelException.InvalidTransitionException('This run has no tool call waiting for reconciliation.');
        }
        AgentKernelModels.ReconciliationDecision parsed;
        try {
            parsed = AgentKernelModels.ReconciliationDecision.valueOf(decision);
        } catch (Exception invalid) {
            parsed = null;
        }
        if (parsed == null) {
            throw new AgentKernelException.InvalidTransitionException('Decision must be ConfirmSucceeded, ConfirmFailed, or Retry.');
        }
        AgentKernelModels.ReconciliationRequest request = new AgentKernelModels.ReconciliationRequest();
        request.runId = runId;
        request.commandId = unknown[0].Id;
        request.operationKey = unknown[0].OperationKey__c;
        request.expectedRunRevision = getRun(runId).revision;
        request.decision = parsed;
        request.reason = reason;
        request.confirmedOutput = confirmedOutput;
        request.errorMessage = failureMessage;
        request.safeToRetryAttested = safeToRetry == true;
        request.pauseRun = pauseRun == true;
        return reconcileUnknownOutcome(request);
    }

    global static AgentKernelModels.RunRecord getRun(Id runId) {
        return toRunRecord(getRunRecord(runId));
    }

    /**
     * Up to 200 caller-visible runs in one query, keyed by run Id. Runs the
     * caller cannot see are absent from the result.
     */
    global static Map<Id, AgentKernelModels.RunRecord> getRuns(Set<Id> runIds) {
        Map<Id, AgentKernelModels.RunRecord> result = new Map<Id, AgentKernelModels.RunRecord>();
        if (runIds == null || runIds.isEmpty()) {
            return result;
        }
        if (runIds.size() > MAX_RUNS_PER_READ) {
            throw new AgentKernelException.InvalidTransitionException('Read at most ' + MAX_RUNS_PER_READ + ' runs at once.');
        }
        for (AgentRun__c run : queryRuns(runIds)) {
            result.put(run.Id, toRunRecord(run));
        }
        return result;
    }

    /** The kernel checks the caller can see the run before any transition, with an Id-only query. */
    private static void requireRunId(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.InvalidTransitionException('Run ID is required.');
        }
    }

    /**
     * Package-internal persistence lookup used only for lifecycle visibility
     * checks. Subscriber-facing APIs must return RunRecord instead.
     */
    public static AgentRun__c getRunRecord(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.InvalidTransitionException('Run ID is required.');
        }
        List<AgentRun__c> runs = queryRuns(new Set<Id>{ runId });
        if (runs.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found.');
        }
        return runs[0];
    }

    private static List<AgentRun__c> queryRuns(Set<Id> runIds) {
        List<String> fields = accessibleFields(
            AgentRun__c.SObjectType,
            new List<String>{
                'AgentDefinition__c',
                'AnchorRecordId__c',
                'ParentRun__c',
                'ExternalCorrelationKey__c',
                'InvocationEntryPoint__c',
                'InitiatingUser__c',
                'AttendedBy__c',
                'ExecutionIdentity__c',
                'ExpectedPrincipalUser__c',
                'ResolvedPrincipalUser__c',
                'LoopbackNamedCredential__c',
                'ExecutionContextStatus__c',
                'Status__c',
                'Revision__c',
                'CurrentCommand__c',
                'Input__c',
                'Output__c',
                'InputHash__c',
                'OutputHash__c',
                'PayloadRetentionMode__c',
                'RetainedPayloadCharacters__c',
                'ModelCallCount__c',
                'ToolCallCount__c',
                'RetryCount__c',
                'InputTokenCount__c',
                'OutputTokenCount__c',
                'TotalTokenCount__c',
                'ModelDurationMs__c',
                'ToolDurationMs__c',
                'StartedAt__c',
                'LastActivityAt__c',
                'CompletedAt__c',
                'CancellationRequestedAt__c',
                'CancellationReason__c',
                'ErrorCode__c',
                'ErrorMessage__c',
                'WaitingReason__c',
                'ResumeJsonSchema__c',
                'WaitExpiresAt__c',
                'ContinuationMode__c',
                'WaitingCommand__c'
            }
        );
        return (List<AgentRun__c>) Database.query(
            'SELECT ' + String.join(fields, ',') + ' FROM AgentRun__c WHERE Id IN :runIds LIMIT ' + MAX_RUNS_PER_READ,
            AccessLevel.USER_MODE
        );
    }

    private static AgentKernelModels.RunRecord toRunRecord(AgentRun__c source) {
        AgentKernelModels.RunRecord result = new AgentKernelModels.RunRecord();
        // Built once per record; each field read is then a map lookup.
        Map<String, Object> fields = source.getPopulatedFieldsAsMap();
        result.id = source.Id;
        result.agentDefinitionId = (Id) fields.get('AgentDefinition__c');
        String anchorRecordId = (String) fields.get('AnchorRecordId__c');
        result.anchorRecordId = String.isBlank(anchorRecordId) ? null : (Id) anchorRecordId;
        result.parentRunId = (Id) fields.get('ParentRun__c');
        result.externalCorrelationKey = (String) fields.get('ExternalCorrelationKey__c');
        result.invocationEntryPoint = (String) fields.get('InvocationEntryPoint__c');
        result.initiatingActorId = (Id) fields.get('InitiatingUser__c');
        result.attendedById = (Id) fields.get('AttendedBy__c');
        result.executionIdentityId = (Id) fields.get('ExecutionIdentity__c');
        result.expectedPrincipalId = (Id) fields.get('ExpectedPrincipalUser__c');
        result.resolvedPrincipalId = (Id) fields.get('ResolvedPrincipalUser__c');
        result.loopbackNamedCredential = (String) fields.get('LoopbackNamedCredential__c');
        result.executionContextStatus = (String) fields.get('ExecutionContextStatus__c');
        result.status = (String) fields.get('Status__c');
        result.revision = (Decimal) fields.get('Revision__c');
        result.currentCommandId = (Id) fields.get('CurrentCommand__c');
        result.input = (String) fields.get('Input__c');
        result.output = (String) fields.get('Output__c');
        result.inputHash = (String) fields.get('InputHash__c');
        result.outputHash = (String) fields.get('OutputHash__c');
        result.payloadRetentionMode = (String) fields.get('PayloadRetentionMode__c');
        result.retainedPayloadCharacters = (Decimal) fields.get('RetainedPayloadCharacters__c');
        result.modelCallCount = (Decimal) fields.get('ModelCallCount__c');
        result.toolCallCount = (Decimal) fields.get('ToolCallCount__c');
        result.retryCount = (Decimal) fields.get('RetryCount__c');
        result.inputTokenCount = (Decimal) fields.get('InputTokenCount__c');
        result.outputTokenCount = (Decimal) fields.get('OutputTokenCount__c');
        result.totalTokenCount = (Decimal) fields.get('TotalTokenCount__c');
        result.modelDurationMilliseconds = (Decimal) fields.get('ModelDurationMs__c');
        result.toolDurationMilliseconds = (Decimal) fields.get('ToolDurationMs__c');
        result.startedAt = (Datetime) fields.get('StartedAt__c');
        result.lastActivityAt = (Datetime) fields.get('LastActivityAt__c');
        result.completedAt = (Datetime) fields.get('CompletedAt__c');
        result.cancellationRequestedAt = (Datetime) fields.get('CancellationRequestedAt__c');
        result.cancellationReason = (String) fields.get('CancellationReason__c');
        result.errorCode = (String) fields.get('ErrorCode__c');
        result.errorMessage = (String) fields.get('ErrorMessage__c');
        result.waitingReason = (String) fields.get('WaitingReason__c');
        result.resumeJsonSchema = (String) fields.get('ResumeJsonSchema__c');
        result.waitExpiresAt = (Datetime) fields.get('WaitExpiresAt__c');
        result.continuationMode = (String) fields.get('ContinuationMode__c');
        result.waitingCommandId = (Id) fields.get('WaitingCommand__c');
        return result;
    }

    public static Object fieldValue(SObject source, String fieldName) {
        return source.getPopulatedFieldsAsMap().get(fieldName);
    }

    public static List<String> accessibleFields(Schema.SObjectType objectType, List<String> requestedFields) {
        Map<String, Schema.SObjectField> fieldMap = objectType.getDescribe().fields.getMap();
        List<String> accessible = new List<String>{ 'Id' };
        for (String fieldName : requestedFields) {
            Schema.SObjectField fieldToken = fieldMap.get(fieldName);
            if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
                accessible.add(fieldName);
            }
        }
        return accessible;
    }
}
