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
 * System-owned state machine for AgentRun__c. This class intentionally runs
 * without sharing so every lifecycle mutation uses one invariant-preserving
 * boundary; callers remain responsible for access checks at the facade.
 *
 * Kept as one class on purpose (maintainer decision): every run transition
 * shares the same locks, revision checks, and event sequencing here. Its size
 * is not a review finding; do not propose splitting it.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentKernel {
    private static final Integer MAX_ERROR_LENGTH = 1000;
    /** Why someone other than the starter cannot rescue or continue a run of an agent without an identity. */
    public static final String INITIATING_USER_CONTINUE_REFUSED = 'Only the person who started this run can continue it. Cancel it, or ask them to start again.';
    /** Pauses whose fix changes the tool binding, which a re-armed command keeps frozen. */
    private static final Set<String> BINDING_PAUSE_CODES = new Set<String>{ 'TOOL_BINDING_CHANGED', 'TOOL_CONFIGURATION_ERROR' };
    /** Transcript turns a terminal transition protects; the window is at most 59 turns. */
    private static final Integer TERMINAL_PROTECTION_LIMIT = 100;
    /** Turns past the window protected per transition; each transition adds at most a few turns. */
    private static final Integer OVERFLOW_PROTECTION_BATCH = 10;
    private static final Integer PROTECTION_CHUNK_SIZE = 10;
    /** Events logged as warnings. */
    private static final Set<String> WARNING_EVENTS = new Set<String>{
        AgentKernelModels.EVENT_RUN_FAILED,
        AgentKernelModels.EVENT_RUN_PAUSED,
        AgentKernelModels.EVENT_WAIT_EXPIRED,
        AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN
    };
    private static final String APPROVAL_RESUME_SCHEMA = '{"type":"object","properties":{"approved":{"type":"boolean"}},"required":["approved"],"additionalProperties":false}';

    public class StaleLeaseRecoveryResult {
        public List<Id> requeuedCommandIds = new List<Id>();
        public Integer unknown = 0;
        public Integer cancelled = 0;
        public Integer paused = 0;
        public Integer skipped = 0;
        public Set<Id> skippedCommandIds = new Set<Id>();
        public Set<Id> deferredCommandIds = new Set<Id>();
    }

    public class IntentionalWaitExpiryResult {
        public Integer expired = 0;
        public Integer skipped = 0;
        /** Expired approval waits to deny and continue, by run, with the observed revision. */
        public Map<Id, Decimal> approvalDenials = new Map<Id, Decimal>();
    }

    /** Persists a run and its first command. The caller dispatches the command. */
    public static AgentKernelModels.StartResult startRun(AgentKernelModels.StartRequest request, String invocationEntryPoint) {
        if (request == null) {
            throw new AgentKernelException.InvalidTransitionException('Start request is required.');
        }
        AgentDefinition__c definition = request.definitionId != null
            ? AgentConfigService.getActiveDefinition(request.definitionId)
            : AgentConfigService.getActiveDefinition(request.developerName);
        return startRun(definition, request, invocationEntryPoint);
    }

    /** Persists a run of a definition the caller already loaded active, so a start reads it once. */
    public static AgentKernelModels.StartResult startRun(AgentDefinition__c definition, AgentKernelModels.StartRequest request, String invocationEntryPoint) {
        if (request == null || definition == null) {
            throw new AgentKernelException.InvalidTransitionException('Start request is required.');
        }
        return startRunInternal(definition, request.input, request.parentRunId, request.externalCorrelationKey, invocationEntryPoint, request.anchorRecordId);
    }

    /** Audits final answers resolved for delivery: one event per run, written together. */
    public static void recordTrustOutputResolutions(Map<Id, Set<String>> categoriesByRun, Map<Id, Integer> tokenCountByRun) {
        if (!TrustService.isFinalOutputResolutionPermitted()) {
            throw new AgentKernelException.AuthorizationException('Trust resolution permission is required.');
        }
        Set<Id> runIds = categoriesByRun == null ? new Set<Id>() : categoriesByRun.keySet();
        if (runIds.isEmpty()) {
            return;
        }
        Integer visibleRuns;
        try {
            visibleRuns = [SELECT COUNT() FROM AgentRun__c WHERE Id IN :runIds WITH USER_MODE];
        } catch (Exception inaccessible) {
            visibleRuns = 0;
        }
        if (visibleRuns != runIds.size()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found or is inaccessible.');
        }
        List<AgentRun__c> runs = lockRuns(runIds);
        List<AgentEvent__c> events = new List<AgentEvent__c>();
        for (AgentRun__c run : runs) {
            List<String> sortedCategories = new List<String>(categoriesByRun.get(run.Id) == null ? new Set<String>() : categoriesByRun.get(run.Id));
            sortedCategories.sort();
            Integer tokenCount = tokenCountByRun == null ? null : tokenCountByRun.get(run.Id);
            Map<String, Object> payload = new Map<String, Object>{
                'actorId' => UserInfo.getUserId(),
                'categories' => sortedCategories,
                'purpose' => 'Final output delivery',
                'tokenCount' => tokenCount == null ? 0 : tokenCount
            };
            events.add(
                AgentLifecycleRecords.buildEvent(
                    run,
                    AgentLifecycleRecords.nextEventSequence(run),
                    AgentKernelModels.EVENT_TRUST_OUTPUT_RESOLVED,
                    null,
                    'Protected final output resolved for delivery.',
                    JSON.serialize(payload)
                )
            );
        }
        AgentLifecycleStore.insertEvents(events);
        for (AgentEvent__c event : events) {
            AgentOperationsLog.emit(LoggingLevel.INFO, event.EventType__c, event.AgentRun__c, null, null, null);
        }
        AgentLifecycleStore.updateRuns(runs);
    }

    public static void recordTrustApprovalInputResolution(Id runId, AgentCommand__c command, Set<String> categories, Integer tokenCount) {
        AgentHumanDecisionGuard.assertAuthorized();
        AgentRun__c run = lockRun(runId);
        List<String> sortedCategories = new List<String>(categories == null ? new Set<String>() : categories);
        sortedCategories.sort();
        Map<String, Object> payload = new Map<String, Object>{
            'actorId' => UserInfo.getUserId(),
            'categories' => sortedCategories,
            'purpose' => 'Tool approval review',
            'tokenCount' => tokenCount == null ? 0 : tokenCount
        };
        persistEvent(
            run,
            AgentLifecycleRecords.nextEventSequence(run),
            AgentKernelModels.EVENT_TRUST_APPROVAL_INPUT_RESOLVED,
            command.OperationKey__c,
            'Protected tool input resolved for approval review.',
            JSON.serialize(payload)
        );
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
    }

    public static AgentKernelModels.CommandOutcome applyOutcome(AgentKernelModels.CommandOutcome outcome) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            AgentKernelModels.CommandOutcome result = applyOutcomeInternal(outcome);
            Database.releaseSavepoint(unitOfWork);
            return result;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static AgentKernelModels.CommandOutcome applyOutcomeInternal(AgentKernelModels.CommandOutcome outcome) {
        validateOutcomeIdentity(outcome);

        AgentRun__c run = lockRun(outcome.runId);
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        assertExpectedRevision(run, outcome.expectedRunRevision);
        assertMutable(run);
        String statusBefore = run.Status__c;

        AgentCommand__c command = lockCommand(outcome.commandId, run.Id);
        if (run.CurrentCommand__c != command.Id) {
            throw new AgentKernelException.InvalidTransitionException('The command is not the run current command.');
        }
        if (command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED) {
            throw new AgentKernelException.InvalidTransitionException('The command must be leased before an outcome can be applied.');
        }
        if (command.ExpectedRunRevision__c != run.Revision__c) {
            throw new AgentKernelException.ConcurrencyException('The command expects a different run revision.');
        }
        if (command.OperationKey__c != outcome.operationKey) {
            throw new AgentKernelException.ConcurrencyException('The command operation key does not match.');
        }
        if (String.isBlank(outcome.leaseToken) || !outcome.leaseToken.equals(command.LeaseToken__c)) {
            throw new AgentKernelException.ConcurrencyException('The command lease token does not match.');
        }

        validateOutcomeShape(outcome);
        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        incrementCounters(run, command, outcome);
        recordConfiguration(run, outcome.configurationHash, command.OperationKey__c);
        String commandErrorCode = outcome.errorCode;
        String commandErrorMessage = outcome.errorMessage;
        Boolean cancellationPending = run.CancellationRequestedAt__c != null;
        if (cancellationPending) {
            outcome.nextCommand = null;
            outcome.nextCommands = null;
            if (outcome.commandStatus == AgentKernelModels.COMMAND_STATUS_UNKNOWN) {
                outcome.runStatus = AgentKernelModels.RUN_STATUS_WAITING;
                outcome.eventType = AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN;
            } else {
                outcome.runStatus = AgentKernelModels.RUN_STATUS_CANCELLED;
                outcome.eventType = AgentKernelModels.EVENT_RUN_CANCELLED;
                outcome.summary = 'Leased command resolved after cancellation was requested.';
            }
        }

        AgentDefinition__c limits = budgetLimits(run);
        AgentCommand__c blockedBatchCommand = nextBlockedBatchCommand(command);
        Boolean feedbackFailedToolToModel =
            outcome.commandStatus == AgentKernelModels.COMMAND_STATUS_FAILED &&
            String.isBlank(outcome.runStatus) &&
            (outcome.nextCommand != null || (outcome.nextCommands != null && !outcome.nextCommands.isEmpty()));
        if (feedbackFailedToolToModel) {
            applyBudgetDecision(run, outcome, limits);
            cancelBlockedBatchCommands(command);
        } else if (blockedBatchCommand == null || !String.isBlank(outcome.runStatus)) {
            applyBudgetDecision(run, outcome, limits);
        } else {
            outcome.nextCommand = null;
            outcome.nextCommands = null;
            outcome.eventType = AgentKernelModels.EVENT_TOOL_COMPLETED;
        }
        Boolean answered = command.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL && outcome.runStatus == AgentKernelModels.RUN_STATUS_SUCCEEDED;
        if (answered) {
            command.AnswerTurn__c = true;
            awaitReplyWhenConversational(outcome, limits, cancellationPending);
        }

        command.Status__c = outcome.commandStatus;
        command.Output__c = outcome.output;
        command.ErrorCode__c = sanitizeCode(commandErrorCode);
        command.ErrorMessage__c = sanitizeError(commandErrorMessage);
        applyTelemetry(run, command, outcome);
        command.LeaseToken__c = null;
        command.LeaseExpiresAt__c = null;
        command.WorkerJobId__c = null;
        command.WorkerEnqueuedAt__c = null;

        AgentCommand__c nextCommand;
        List<AgentCommand__c> createdBatch = new List<AgentCommand__c>();
        if (!feedbackFailedToolToModel && blockedBatchCommand != null && String.isBlank(outcome.runStatus)) {
            blockedBatchCommand.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
            blockedBatchCommand.ExpectedRunRevision__c = nextRevision;
            blockedBatchCommand.AvailableAt__c = System.now();
            updateCommand(blockedBatchCommand);
            nextCommand = blockedBatchCommand;
            outcome.nextCommandId = blockedBatchCommand.Id;
            run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
            run.CurrentCommand__c = blockedBatchCommand.Id;
        } else if (String.isBlank(outcome.runStatus)) {
            List<AgentKernelModels.CommandSpec> requestedCommands = requestedCommands(outcome);
            if (requestedCommands.size() == 1) {
                nextCommand = buildCommand(run, nextRevision, requestedCommands[0]);
                AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ nextCommand });
            } else {
                createdBatch = buildToolBatch(run, nextRevision, command.OperationKey__c, requestedCommands);
                AgentLifecycleStore.insertCommands(createdBatch);
                nextCommand = createdBatch[0];
            }
            outcome.nextCommandId = nextCommand.Id;
            run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
            run.CurrentCommand__c = nextCommand.Id;
        } else {
            run.Status__c = outcome.runStatus;
            run.CurrentCommand__c = outcome.runStatus == AgentKernelModels.RUN_STATUS_PAUSED &&
                command.Status__c == AgentKernelModels.COMMAND_STATUS_FAILED
                ? command.Id
                : null;
            if (outcome.runStatus == AgentKernelModels.RUN_STATUS_WAITING && outcome.commandStatus != AgentKernelModels.COMMAND_STATUS_UNKNOWN) {
                applyWaitingMetadata(run, outcome.waitingReason, outcome.resumeJsonSchema, outcome.waitExpiresAt, outcome.continuationMode, null);
            } else if (outcome.runStatus == AgentKernelModels.RUN_STATUS_WAITING) {
                AgentLifecycleRecords.setUnknownDeadline(run, System.now());
            }
            if (
                outcome.runStatus == AgentKernelModels.RUN_STATUS_SUCCEEDED ||
                outcome.runStatus == AgentKernelModels.RUN_STATUS_FAILED ||
                outcome.runStatus == AgentKernelModels.RUN_STATUS_CANCELLED
            ) {
                run.CompletedAt__c = System.now();
                AgentLifecycleRecords.setPurgeAfter(run);
            }
            if (outcome.runStatus == AgentKernelModels.RUN_STATUS_PAUSED) {
                run.CompletedAt__c = null;
                run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(System.now(), run.PayloadRetentionDays__c);
            }
            if (
                outcome.runStatus == AgentKernelModels.RUN_STATUS_FAILED ||
                outcome.runStatus == AgentKernelModels.RUN_STATUS_CANCELLED ||
                outcome.runStatus == AgentKernelModels.RUN_STATUS_PAUSED
            ) {
                cancelBlockedBatchCommands(command);
            }
        }

        run.Revision__c = nextRevision;
        run.LastActivityAt__c = System.now();
        if (answered) {
            // A conversational run's latest answer is readable while it waits for the reply.
            run.Output__c = outcome.output;
        }
        // A failure handed back to the model is the command's error, not the run's: a run that continues shows none.
        Boolean continuing = String.isBlank(outcome.runStatus);
        run.ErrorCode__c = continuing ? null : sanitizeCode(outcome.errorCode);
        run.ErrorMessage__c = continuing ? null : sanitizeError(outcome.errorMessage);
        if (cancellationPending && outcome.runStatus == AgentKernelModels.RUN_STATUS_CANCELLED) {
            run.ErrorCode__c = 'RUN_CANCELLED';
            run.ErrorMessage__c = run.CancellationReason__c;
        }

        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        String eventType = deriveEventType(outcome);
        if (createdBatch.isEmpty()) {
            Boolean requestedCommandEvent = eventType == AgentKernelModels.EVENT_TOOL_REQUESTED || eventType == AgentKernelModels.EVENT_MODEL_REQUESTED;
            String eventCommandKey = requestedCommandEvent && nextCommand != null ? nextCommand.OperationKey__c : command.OperationKey__c;
            persistEvent(run, eventSequence, eventType, eventCommandKey, outcome.summary, outcome.payload);
        } else {
            List<AgentEvent__c> requestedEvents = new List<AgentEvent__c>();
            for (Integer index = 0; index < createdBatch.size(); index++) {
                AgentCommand__c batchCommand = createdBatch[index];
                requestedEvents.add(
                    AgentLifecycleRecords.buildEvent(
                        run,
                        eventSequence + index,
                        AgentKernelModels.EVENT_TOOL_REQUESTED,
                        batchCommand.OperationKey__c,
                        'Model requested tool ' + batchCommand.ToolName__c + '.',
                        null
                    )
                );
            }
            run.LastEventSequence__c = eventSequence + createdBatch.size() - 1;
            AgentLifecycleStore.insertEvents(requestedEvents);
            for (AgentEvent__c requestedEvent : requestedEvents) {
                AgentOperationsLog.emit(LoggingLevel.INFO, requestedEvent.EventType__c, run.Id, null, null, requestedEvent.CommandKey__c);
            }
        }
        if (isTerminalStatus(run.Status__c)) {
            minimizeTerminalPayloads(run, command);
        } else {
            minimizeCompletedCommandPayload(run, command);
        }
        updateCommand(command);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        // Subscribers react to run status changes; each step stays an Agent Event on the run.
        if (run.Status__c != statusBefore) {
            AgentLifecyclePublisher.publish(run, lifecycleTransition(eventType), eventSequence, command.OperationKey__c);
        }
        return outcome;
    }

    /**
     * A conversational agent (Wait for Reply set) keeps the run open after each
     * answer: the run waits for the person's next message instead of ending,
     * and ends with its last answer when no reply arrives in time.
     */
    private static void awaitReplyWhenConversational(AgentKernelModels.CommandOutcome outcome, AgentDefinition__c limits, Boolean cancellationPending) {
        Integer replyWindowHours = AgentConfigService.replyWindowHours(limits);
        if (replyWindowHours == null || cancellationPending) {
            return;
        }
        outcome.runStatus = AgentKernelModels.RUN_STATUS_WAITING;
        outcome.eventType = AgentKernelModels.EVENT_RUN_WAITING;
        outcome.summary = 'Answered; waiting for the person\'s reply.';
        outcome.waitingReason = 'Waiting for the person\'s reply.';
        outcome.resumeJsonSchema = AgentKernelModels.CONVERSATION_RESUME_SCHEMA;
        outcome.waitExpiresAt = System.now().addHours(replyWindowHours);
        outcome.continuationMode = AgentKernelModels.CONTINUATION_CONVERSATION;
    }

    public static void cancel(Id runId, Decimal expectedRevision, String reason) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            cancelInternal(runId, expectedRevision, reason);
            Database.releaseSavepoint(unitOfWork);
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static void cancelInternal(Id runId, Decimal expectedRevision, String reason) {
        AgentKernelAccessGuard.assertRunReadable(runId);
        AgentRun__c run = lockRun(runId);
        assertExpectedRevision(run, expectedRevision);
        ExecutionIdentityService.assertCanCancel(run);
        assertMutable(run);

        AgentCommand__c currentCommand = run.CurrentCommand__c == null ? null : lockCommand(run.CurrentCommand__c, run.Id);
        Boolean leased = currentCommand != null && currentCommand.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED;
        if (leased && run.CancellationRequestedAt__c != null) {
            return;
        }
        String cancellationReason = sanitizeError(String.isBlank(reason) ? 'Cancellation requested.' : reason);
        cancellationReason = protectAndSave(run.Id, cancellationReason);
        if (currentCommand != null) {
            if (leased) {
                run.CancellationRequestedAt__c = System.now();
                run.CancellationReason__c = cancellationReason;
                run.LastActivityAt__c = System.now();
                Decimal requestSequence = AgentLifecycleRecords.nextEventSequence(run);
                persistEvent(
                    run,
                    requestSequence,
                    AgentKernelModels.EVENT_RUN_CANCELLATION_REQUESTED,
                    currentCommand.OperationKey__c,
                    'Cancellation requested for leased command.',
                    cancellationReason
                );
                AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
                AgentLifecyclePublisher.publish(run, 'CancellationRequested', requestSequence, currentCommand.OperationKey__c);
                return;
            }
            if (
                currentCommand.Status__c == AgentKernelModels.COMMAND_STATUS_PENDING ||
                currentCommand.Status__c == AgentKernelModels.COMMAND_STATUS_RETRY_WAITING ||
                (currentCommand.Status__c == AgentKernelModels.COMMAND_STATUS_FAILED &&
                run.Status__c == AgentKernelModels.RUN_STATUS_PAUSED)
            ) {
                AgentLifecycleRecords.cancelCommand(currentCommand, cancellationReason);
                AgentLifecycleRecords.protectCommandFields(currentCommand, PayloadProtectionService.fromRun(run));
                updateCommand(currentCommand);
            }
        } else if (run.WaitingCommand__c != null) {
            AgentCommand__c waitingCommand = lockCommand(run.WaitingCommand__c, run.Id);
            if (waitingCommand.Status__c == AgentKernelModels.COMMAND_STATUS_WAITING) {
                AgentLifecycleRecords.cancelCommand(waitingCommand, cancellationReason);
                AgentLifecycleRecords.protectCommandFields(waitingCommand, PayloadProtectionService.fromRun(run));
                updateCommand(waitingCommand);
            }
            AgentApprovalService.closePending(new Set<Id>{ waitingCommand.Id }, AgentKernelModels.APPROVAL_STATUS_CANCELLED);
        } else if (run.Status__c == AgentKernelModels.RUN_STATUS_WAITING && hasUnknownCommand(run.Id)) {
            throw new AgentKernelException.InvalidTransitionException('A run with an unknown command outcome must be reconciled before it can be cancelled.');
        }
        cancelAllBlockedCommands(run);

        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(run, eventSequence, AgentKernelModels.EVENT_RUN_CANCELLED, null, 'Run cancelled.', cancellationReason);

        run.Revision__c = nextRevision;
        AgentLifecycleRecords.markCancelled(run, cancellationReason, System.now());
        run.CancellationRequestedAt__c = System.now();
        run.CancellationReason__c = cancellationReason;
        AgentLifecycleRecords.clearWaitingMetadata(run);
        minimizeTerminalPayloads(run, null);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Cancelled', eventSequence, null);
    }

    public static Id resume(Id runId, Decimal expectedRevision, String payload) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Id commandId = resumeInternal(runId, expectedRevision, payload);
            Database.releaseSavepoint(unitOfWork);
            return commandId;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Id resumeInternal(Id runId, Decimal expectedRevision, String payload) {
        AgentKernelAccessGuard.assertRunReadable(runId);
        AgentRun__c run = lockRun(runId);
        assertExpectedRevision(run, expectedRevision);
        ExecutionIdentityService.assertCanResume(run);
        return resumeAuthorized(run, payload, new Map<String, Object>());
    }

    /**
     * The key a tool hands to an outside system so that system can resume the
     * run's wait for this call, and nothing else: the run Id and an HMAC of the
     * call's operation key under the org trust key. Core stores and logs no copy.
     */
    public static String resumeKey(Id runId, String operationKey) {
        return String.valueOf(runId) + '.' + EncodingUtil.convertToHex(resumeMac(operationKey));
    }

    private static Blob resumeMac(String operationKey) {
        return Crypto.generateMac('HmacSHA256', Blob.valueOf('resume:' + operationKey), TrustKeyProvider.currentKey());
    }

    /**
     * Resumes a tool's wait for outside input with the key the tool received.
     * The key is the authority: the caller needs no Run Control and no revision,
     * and the key works only while that call's wait is the run's current one.
     */
    public static Id resumeWithKey(String resumeKey, String payload) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Id commandId = resumeWithKeyInternal(resumeKey, payload);
            Database.releaseSavepoint(unitOfWork);
            return commandId;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Id resumeWithKeyInternal(String resumeKey, String payload) {
        String invalid = 'The resume key is not valid for a wait this run has now.';
        Id runId;
        Blob mac;
        try {
            runId = Id.valueOf(resumeKey.substringBefore('.'));
            mac = EncodingUtil.convertFromHex(resumeKey.substringAfter('.'));
        } catch (Exception malformed) {
            throw new AgentKernelException.InvalidTransitionException(invalid);
        }
        if (runId.getSObjectType() != AgentRun__c.SObjectType) {
            throw new AgentKernelException.InvalidTransitionException(invalid);
        }
        // The key is checked before the run is locked, so a caller without a valid key cannot hold the run's lock.
        AgentCommand__c waitingCall = latestWaitingCall(runId);
        if (
            waitingCall == null || !Crypto.verifyHMac('HmacSHA256', Blob.valueOf('resume:' + waitingCall.OperationKey__c), TrustKeyProvider.currentKey(), mac)
        ) {
            throw new AgentKernelException.InvalidTransitionException(invalid);
        }
        AgentRun__c run = lockRun(runId);
        if (run.Status__c != AgentKernelModels.RUN_STATUS_WAITING || run.ContinuationMode__c != AgentKernelModels.CONTINUATION_MODEL) {
            throw new AgentKernelException.InvalidTransitionException('The run is not waiting for outside input.');
        }
        AgentCommand__c lockedCall = latestWaitingCall(run.Id);
        if (lockedCall == null || lockedCall.Id != waitingCall.Id) {
            throw new AgentKernelException.InvalidTransitionException(invalid);
        }
        // A run without an identity continues only in its starter's job chain.
        if (!ExecutionIdentityService.usesIdentity(run) && run.InitiatingUser__c != UserInfo.getUserId()) {
            throw new AgentKernelException.AuthorizationException(
                'Only the person who started this run can resume it, because its agent has no Agent Execution Identity.'
            );
        }
        return resumeAuthorized(run, payload, new Map<String, Object>{ 'resumedWithKey' => true });
    }

    /** While a tool waits, its succeeded call is the run's newest command; blocked batch siblings never ran. Null otherwise. */
    private static AgentCommand__c latestWaitingCall(Id runId) {
        List<AgentCommand__c> latest = [
            SELECT Id, CommandType__c, Status__c, OperationKey__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId AND Status__c NOT IN (:AgentKernelModels.COMMAND_STATUS_BLOCKED, :AgentKernelModels.COMMAND_STATUS_CANCELLED)
            WITH SYSTEM_MODE
            ORDER BY Sequence__c DESC
            LIMIT 1
        ];
        return latest.isEmpty() ||
            latest[0].CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL ||
            latest[0].Status__c != AgentKernelModels.COMMAND_STATUS_SUCCEEDED
            ? null
            : latest[0];
    }

    /** Continues a waiting run whose caller is already authorized; shared by replies and keyed resumes. */
    private static Id resumeAuthorized(AgentRun__c run, String payload, Map<String, Object> eventPayload) {
        if (run.Status__c != AgentKernelModels.RUN_STATUS_WAITING) {
            throw new AgentKernelException.InvalidTransitionException('Only a waiting run can be resumed.');
        }
        if (hasUnknownCommand(run.Id)) {
            throw new AgentKernelException.InvalidTransitionException('A run with an unknown command outcome must be reconciled explicitly.');
        }
        if (String.isBlank(run.ContinuationMode__c)) {
            throw new AgentKernelException.InvalidTransitionException('The waiting run has no intentional continuation metadata.');
        }
        if (run.ContinuationMode__c == AgentKernelModels.CONTINUATION_REINVOKE_TOOL) {
            throw new AgentKernelException.InvalidTransitionException('A tool-approval wait is decided with AgentRunService.decideApproval.');
        }
        if (run.ContinuationMode__c != AgentKernelModels.CONTINUATION_MODEL && run.ContinuationMode__c != AgentKernelModels.CONTINUATION_CONVERSATION) {
            throw new AgentKernelException.InvalidTransitionException('The intentional continuation mode is invalid.');
        }
        if (run.WaitExpiresAt__c != null && run.WaitExpiresAt__c <= System.now()) {
            throw new AgentKernelException.InvalidTransitionException('The intentional wait has expired.');
        }
        try {
            ToolJsonSchemaValidator.validateInstance(payload, run.ResumeJsonSchema__c, 'Resume payload');
        } catch (ToolJsonSchemaValidator.ValidationException invalidPayload) {
            throw new AgentKernelException.InvalidTransitionException('Resume payload does not match the configured schema: ' + invalidPayload.getMessage());
        }
        String protectedPayload = protectAndSave(run.Id, payload);

        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        cancelAllBlockedCommands(run);
        AgentKernelModels.CommandSpec spec = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, protectedPayload, null);
        spec.inputSource = AgentKernelModels.INPUT_SOURCE_HUMAN_RESPONSE;
        AgentCommand__c command = buildCommand(run, nextRevision, spec);
        AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ command });
        if (run.ContinuationMode__c == AgentKernelModels.CONTINUATION_CONVERSATION) {
            openReplyBudgetWindow(run);
        }
        if (exhaustedModelBudget(run, budgetLimits(run), 1) != null) {
            return pauseWithUnansweredReply(run, command);
        }
        return markResumed(run, command, nextRevision, eventPayload);
    }

    /**
     * Keeps a reply that arrives after the model budget is spent: it waits as
     * the run's queued command, and rescue answers it once the budget is raised.
     */
    private static Id pauseWithUnansweredReply(AgentRun__c run, AgentCommand__c command) {
        AgentDefinition__c limits = budgetLimits(run);
        AgentLifecycleRecords.clearWaitingMetadata(run);
        pauseAfterFault(
            run,
            System.now(),
            'BUDGET_EXCEEDED',
            'A reply arrived, but the model budget is spent; raise Max Model Calls or Max Total Tokens and rescue the run to answer it.',
            command.Id
        );
        Map<String, Object> eventPayload = budgetFacts(run, limits, exhaustedModelBudget(run, limits, 1), 1, 0);
        eventPayload.put('actorId', UserInfo.getUserId());
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(
            run,
            eventSequence,
            AgentKernelModels.EVENT_RUN_PAUSED,
            command.OperationKey__c,
            'Reply received, but the model-call budget is exhausted; run paused.',
            JSON.serialize(eventPayload)
        );
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Paused', eventSequence, command.OperationKey__c);
        return null;
    }

    private static Id markResumed(AgentRun__c run, AgentCommand__c command, Decimal nextRevision, Map<String, Object> eventPayload) {
        eventPayload.put('actorId', UserInfo.getUserId());
        eventPayload.put('continuationMode', run.ContinuationMode__c);
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(run, eventSequence, AgentKernelModels.EVENT_RUN_RESUMED, command.OperationKey__c, 'Run resumed.', JSON.serialize(eventPayload));

        run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
        run.Revision__c = nextRevision;
        run.CurrentCommand__c = command.Id;
        run.LastActivityAt__c = System.now();
        run.CompletedAt__c = null;
        run.ErrorCode__c = null;
        run.ErrorMessage__c = null;
        AgentLifecycleRecords.clearWaitingMetadata(run);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Resumed', eventSequence, command.OperationKey__c);
        return command.Id;
    }

    public static void pause(Id runId, Decimal expectedRevision, String reason) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            pauseInternal(runId, expectedRevision, reason);
            Database.releaseSavepoint(unitOfWork);
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static void pauseInternal(Id runId, Decimal expectedRevision, String reason) {
        AgentRun__c run = lockRunForAdministration(runId, expectedRevision);
        if (run.CancellationRequestedAt__c != null) {
            throw new AgentKernelException.InvalidTransitionException('A run with pending cancellation cannot be paused.');
        }
        if (run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING || run.CurrentCommand__c == null) {
            throw new AgentKernelException.InvalidTransitionException('Only a running run with queued work can be paused.');
        }
        AgentCommand__c command = lockCommand(run.CurrentCommand__c, run.Id);
        if (!new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c)) {
            throw new AgentKernelException.InvalidTransitionException('A leased command must resolve before the run can be paused safely.');
        }
        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        String safeReason = sanitizeError(String.isBlank(reason) ? 'Paused by an operator.' : reason);
        safeReason = protectAndSave(run.Id, safeReason);
        command.ExpectedRunRevision__c = nextRevision;
        run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
        run.Revision__c = nextRevision;
        run.LastActivityAt__c = System.now();
        run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(run.LastActivityAt__c, run.PayloadRetentionDays__c);
        run.ErrorCode__c = 'RUN_PAUSED';
        run.ErrorMessage__c = safeReason;
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(run, eventSequence, AgentKernelModels.EVENT_RUN_PAUSED, command.OperationKey__c, 'Run paused by an operator.', safeReason);
        updateCommand(command);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Paused', eventSequence, command.OperationKey__c);
    }

    public static Id rescue(AgentKernelModels.RescueRequest request) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Id commandId = rescueInternal(request);
            Database.releaseSavepoint(unitOfWork);
            return commandId;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Id rescueInternal(AgentKernelModels.RescueRequest request) {
        if (request == null || request.runId == null || request.expectedRunRevision == null) {
            throw new AgentKernelException.InvalidTransitionException('Rescue run ID and expected revision are required.');
        }
        AgentRun__c run = lockRunForAdministration(request.runId, request.expectedRunRevision);
        assertMayContinue(run);
        if (run.Status__c != AgentKernelModels.RUN_STATUS_PAUSED) {
            throw new AgentKernelException.InvalidTransitionException('Only a paused run can be rescued.');
        }
        if (run.PayloadPurgedAt__c != null) {
            throw new AgentKernelException.InvalidTransitionException('A paused run cannot be rescued after its retained payload was purged.');
        }
        if (run.CancellationRequestedAt__c != null) {
            throw new AgentKernelException.InvalidTransitionException('A run with pending cancellation cannot be rescued.');
        }
        if (hasUnknownCommand(run.Id)) {
            throw new AgentKernelException.InvalidTransitionException('An unknown tool outcome must be reconciled before rescue.');
        }
        Decimal rescueNextRevision = valueOrZero(run.Revision__c) + 1;
        String rescuePausedErrorCode = run.ErrorCode__c;
        Decimal rescuePriorAttemptNumber = null;
        String rescueMode = null;
        AgentCommand__c command;
        if (run.CurrentCommand__c != null) {
            command = lockCommand(run.CurrentCommand__c, run.Id);
            Boolean rearmableQueuedCommand = new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }
                .contains(command.Status__c);
            Boolean failedCommand = command.Status__c == AgentKernelModels.COMMAND_STATUS_FAILED;
            // A binding fix cannot reach the re-armed command, whose admitted binding is frozen,
            // so the model re-plans and its next call is admitted with the corrected binding.
            Boolean rearmableFailedCommand =
                failedCommand &&
                AgentKernelRecovery.isRecoverySafe(command) &&
                !BINDING_PAUSE_CODES.contains(rescuePausedErrorCode);
            if (!rearmableQueuedCommand && !failedCommand) {
                throw new AgentKernelException.InvalidTransitionException('The paused current command cannot be re-armed.');
            }
            rescuePriorAttemptNumber = command.AttemptNumber__c;
            if (rearmableQueuedCommand || rearmableFailedCommand) {
                rescueMode = rearmableFailedCommand ? 'rearm_failed' : 'rearm_queued';
                assertCommandAdmission(run, command.CommandType__c);
                command.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
                command.ExpectedRunRevision__c = rescueNextRevision;
                command.AvailableAt__c = System.now();
                command.ErrorCode__c = null;
                command.ErrorMessage__c = null;
                command.LeaseToken__c = null;
                command.LeaseExpiresAt__c = null;
                command.WorkerJobId__c = null;
                command.WorkerEnqueuedAt__c = null;
                if (rearmableFailedCommand) {
                    command.RetryWindowStartAttempt__c = valueOrZero(command.AttemptNumber__c);
                }
                updateCommand(command);
            } else {
                rescueMode = 'reflect_new_model';
                if (!AgentLifecycleRecords.isTranscriptTurn(command)) {
                    AgentLifecycleRecords.protectCommandFields(command, PayloadProtectionService.fromRun(run));
                    updateCommand(command);
                }
                command = null;
            }
        }
        if (command == null) {
            if (rescueMode == null) {
                rescueMode = 'reflect_new_model';
            }
            assertCommandAdmission(run, AgentKernelModels.COMMAND_TYPE_MODEL);
            // Operator guidance reaches the model as trusted instruction, so it carries only
            // the operator's words and Core's error code. A paused error message can echo
            // record or tool text; the model already sees a failed call's message as its tool result.
            Map<String, Object> rescueContext = new Map<String, Object>{
                'event' => 'operator_rescue',
                'pausedErrorCode' => rescuePausedErrorCode,
                'guidance' => boundedReason(request.guidance)
            };
            String input = protectAndSave(run.Id, JSON.serialize(rescueContext));
            AgentKernelModels.CommandSpec spec = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, input, null);
            spec.inputSource = AgentKernelModels.INPUT_SOURCE_OPERATOR_GUIDANCE;
            command = buildCommand(run, rescueNextRevision, spec);
            AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ command });
        }

        run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
        run.Revision__c = rescueNextRevision;
        run.CurrentCommand__c = command.Id;
        run.LastActivityAt__c = System.now();
        run.CompletedAt__c = null;
        run.PurgeAfter__c = null;
        run.ErrorCode__c = null;
        run.ErrorMessage__c = null;
        AgentLifecycleRecords.clearWaitingMetadata(run);
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        Map<String, Object> rescuePayload = new Map<String, Object>{
            'mode' => rescueMode,
            'actorId' => UserInfo.getUserId(),
            'pausedErrorCode' => rescuePausedErrorCode,
            'priorAttemptNumber' => rescuePriorAttemptNumber,
            'retryCount' => run.RetryCount__c
        };
        persistEvent(
            run,
            eventSequence,
            AgentKernelModels.EVENT_RUN_RESCUED,
            command.OperationKey__c,
            'Paused run rescued by an operator.',
            JSON.serialize(rescuePayload)
        );
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Rescued', eventSequence, command.OperationKey__c);
        return command.Id;
    }

    /**
     * Decides one Agent Approval. Approval re-arms the waiting tool with the
     * same operation key; rejection fails it and continues to a Model command
     * without cancelling the run. Returns the next command Id, null when the
     * same decision was already recorded or rejection exhausts the model budget.
     */
    public static Id decideApproval(AgentKernelModels.ApprovalDecision decision) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Id commandId = decideApprovalInternal(decision);
            Database.releaseSavepoint(unitOfWork);
            return commandId;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Id decideApprovalInternal(AgentKernelModels.ApprovalDecision decision) {
        if (decision == null || decision.approvalId == null || decision.approved == null) {
            throw new AgentKernelException.InvalidTransitionException('An approval decision requires the approval and an approved value.');
        }
        AgentApproval__c approval = AgentApprovalService.lock(decision.approvalId);
        String decidedStatus = decision.approved ? AgentKernelModels.APPROVAL_STATUS_APPROVED : AgentKernelModels.APPROVAL_STATUS_REJECTED;
        if (approval.Status__c != AgentKernelModels.APPROVAL_STATUS_PENDING) {
            Id requestedDecider = decision.deciderId == null ? UserInfo.getUserId() : decision.deciderId;
            if (approval.Status__c == decidedStatus && approval.DecidedBy__c == requestedDecider) {
                return null;
            }
            throw new AgentKernelException.InvalidTransitionException('The approval is already ' + approval.Status__c + '.');
        }
        AgentRun__c run = lockRun(approval.AgentRun__c);
        AgentApprovalService.Authorization authorization = AgentApprovalService.authorize(approval, run, decision.deciderId);
        if (
            run.Status__c != AgentKernelModels.RUN_STATUS_WAITING ||
            run.ContinuationMode__c != AgentKernelModels.CONTINUATION_REINVOKE_TOOL ||
            run.WaitingCommand__c != approval.AgentCommand__c ||
            run.Revision__c != approval.RunRevision__c
        ) {
            throw new AgentKernelException.InvalidTransitionException('The run is no longer waiting for this approval.');
        }
        if (approval.ExpiresAt__c <= System.now() || (run.WaitExpiresAt__c != null && run.WaitExpiresAt__c <= System.now())) {
            throw new AgentKernelException.InvalidTransitionException('The approval has expired.');
        }
        if (hasUnknownCommand(run.Id)) {
            throw new AgentKernelException.InvalidTransitionException('A run with an unknown command outcome must be reconciled explicitly.');
        }
        AgentCommand__c waitingCommand = lockCommand(run.WaitingCommand__c, run.Id);
        if (waitingCommand.Status__c != AgentKernelModels.COMMAND_STATUS_WAITING || waitingCommand.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL) {
            throw new AgentKernelException.InvalidTransitionException('The approval command is not waiting.');
        }
        // The approver's words are kept on the approval for audit and, on rejection, returned to the model.
        String comment = sanitizeError(decision.comment);
        comment = comment == null ? null : protectAndSave(run.Id, comment);
        AgentApprovalService.close(approval, decidedStatus, authorization, comment);
        Map<String, Object> eventPayload = new Map<String, Object>{ 'approvalId' => approval.Id, 'deciderId' => authorization.deciderId };
        if (authorization.relayedById != null) {
            eventPayload.put('relayedById', authorization.relayedById);
        }
        if (decision.approved) {
            return approveTool(run, waitingCommand, eventPayload);
        }
        String denialReason = comment == null ? 'A human reviewer denied the tool approval.' : comment;
        return denyTool(run, waitingCommand, AgentKernelModels.ERROR_TOOL_APPROVAL_DENIED, denialReason, eventPayload);
    }

    /**
     * Re-arms the approved call with the same operation key. When the tool
     * budget is already spent, the decision still stands: the run pauses with
     * the approved call as its current command, so raising the budget and
     * rescuing runs it without asking the approver again.
     */
    private static Id approveTool(AgentRun__c run, AgentCommand__c command, Map<String, Object> eventPayload) {
        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        command.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
        command.ExpectedRunRevision__c = nextRevision;
        command.PolicyApproved__c = true;
        command.AvailableAt__c = System.now();
        command.ErrorCode__c = null;
        command.ErrorMessage__c = null;
        updateCommand(command);
        AgentDefinition__c limits = budgetLimits(run);
        if (toolCallsUsed(run) + 1 > limits.MaxToolCalls__c) {
            AgentLifecycleRecords.clearWaitingMetadata(run);
            pauseAfterFault(
                run,
                System.now(),
                'BUDGET_EXCEEDED',
                'The tool call was approved, but the configured tool-call budget is exhausted; raise the budget and rescue the run.',
                command.Id
            );
            eventPayload.put('actorId', UserInfo.getUserId());
            eventPayload.putAll(budgetFacts(run, limits, 'tool', 0, 1));
            Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                eventSequence,
                AgentKernelModels.EVENT_RUN_PAUSED,
                command.OperationKey__c,
                'Tool approved, but the tool-call budget is exhausted; run paused.',
                JSON.serialize(eventPayload)
            );
            AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
            AgentLifecyclePublisher.publish(run, 'Paused', eventSequence, command.OperationKey__c);
            return null;
        }
        return markResumed(run, command, nextRevision, eventPayload);
    }

    /**
     * Fails the waiting tool call without running it and gives the model the
     * denial or expiry as the tool result. Pauses instead when no model call
     * remains in the budget.
     */
    private static Id denyTool(AgentRun__c run, AgentCommand__c waitingCommand, String errorCode, String denialReason, Map<String, Object> eventPayload) {
        Boolean expired = errorCode == AgentKernelModels.ERROR_TOOL_APPROVAL_EXPIRED;
        String failurePayload = AgentKernelModels.toolFailurePayload(errorCode, denialReason);

        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        waitingCommand.Status__c = AgentKernelModels.COMMAND_STATUS_FAILED;
        waitingCommand.ExpectedRunRevision__c = nextRevision;
        waitingCommand.PolicyApproved__c = false;
        waitingCommand.Output__c = failurePayload;
        waitingCommand.ErrorCode__c = errorCode;
        waitingCommand.ErrorMessage__c = denialReason;
        waitingCommand.LeaseToken__c = null;
        waitingCommand.LeaseExpiresAt__c = null;
        waitingCommand.WorkerJobId__c = null;
        waitingCommand.WorkerEnqueuedAt__c = null;
        updateCommand(waitingCommand);
        cancelBlockedBatchCommands(waitingCommand);

        AgentDefinition__c limits = budgetLimits(run);
        String exhaustedBudget = exhaustedModelBudget(run, limits, 1);
        if (exhaustedBudget != null) {
            run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
            run.Revision__c = nextRevision;
            run.CurrentCommand__c = null;
            run.LastActivityAt__c = System.now();
            run.CompletedAt__c = null;
            run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(run.LastActivityAt__c, run.PayloadRetentionDays__c);
            run.ErrorCode__c = 'BUDGET_EXCEEDED';
            run.ErrorMessage__c = 'The configured run budget was exhausted after the tool approval was not granted; operator intervention is required.';
            AgentLifecycleRecords.clearWaitingMetadata(run);
            Decimal exhaustedSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                exhaustedSequence,
                AgentKernelModels.EVENT_RUN_PAUSED,
                waitingCommand.OperationKey__c,
                'Tool approval not granted and the model budget was exhausted; run paused.',
                JSON.serialize(budgetFacts(run, limits, exhaustedBudget, 1, 0))
            );
            AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
            AgentLifecyclePublisher.publish(run, 'Paused', exhaustedSequence, waitingCommand.OperationKey__c);
            return null;
        }

        AgentCommand__c modelCommand = buildCommand(
            run,
            nextRevision,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, failurePayload, null)
        );
        AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ modelCommand });

        eventPayload.put('actorId', UserInfo.getUserId());
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(
            run,
            eventSequence,
            AgentKernelModels.EVENT_TOOL_COMPLETED,
            waitingCommand.OperationKey__c,
            expired ? 'Tool approval expired; continuing to model.' : 'Tool approval denied; continuing to model.',
            JSON.serialize(eventPayload)
        );

        run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
        run.Revision__c = nextRevision;
        run.CurrentCommand__c = modelCommand.Id;
        run.LastActivityAt__c = System.now();
        run.CompletedAt__c = null;
        run.ErrorCode__c = null;
        run.ErrorMessage__c = null;
        AgentLifecycleRecords.clearWaitingMetadata(run);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Resumed', eventSequence, waitingCommand.OperationKey__c);
        return modelCommand.Id;
    }

    /**
     * Validates the complete loopback envelope and establishes the service
     * principal once. The REST boundary leases and enqueues the command in the
     * same request after this identity transition succeeds.
     */
    public static void acceptLoopbackDispatch(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String dispatchToken) {
        AgentRun__c run = lockRun(runId);
        assertExpectedRevision(run, expectedRevision);
        if (
            !ExecutionIdentityService.usesIdentity(run) ||
            run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
            run.CurrentCommand__c != commandId ||
            String.isBlank(run.LoopbackNamedCredential__c)
        ) {
            throw new AgentKernelException.InvalidTransitionException('The run cannot accept a service-principal dispatch.');
        }
        AgentCommand__c command = lockCommand(commandId, run.Id);
        if (
            !new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c) ||
            command.ExpectedRunRevision__c != run.Revision__c ||
            String.isBlank(operationKey) ||
            !operationKey.equals(command.OperationKey__c) ||
            String.isBlank(dispatchToken) ||
            !dispatchToken.equals(command.DispatchToken__c)
        ) {
            throw new AgentKernelException.ConcurrencyException('The loopback command identity does not match current durable state.');
        }

        Id currentPrincipal = UserInfo.getUserId();
        if (run.ExpectedPrincipalUser__c != currentPrincipal) {
            throw new AgentKernelException.ConfigurationException('The current user is not the run\'s execution user.');
        }
        if (run.ResolvedPrincipalUser__c != null && run.ResolvedPrincipalUser__c != currentPrincipal) {
            throw new AgentKernelException.ConfigurationException('The Named Credential resolved to a different service principal.');
        }
        if (run.ResolvedPrincipalUser__c == null || run.ExecutionContextStatus__c != ExecutionIdentityService.CONTEXT_ESTABLISHED) {
            run.ResolvedPrincipalUser__c = currentPrincipal;
            run.ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED;
            AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        }
    }

    /** Parks the leased tool command and opens its Agent Approval in one transaction. */
    public static void waitForApproval(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String leaseToken,
        AgentApprovalService.Request request
    ) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            waitForApprovalInternal(runId, commandId, expectedRevision, operationKey, leaseToken, request);
            Database.releaseSavepoint(unitOfWork);
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static void waitForApprovalInternal(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String leaseToken,
        AgentApprovalService.Request request
    ) {
        if (request == null || request.expiresAt == null || String.isBlank(request.approverType)) {
            throw new AgentKernelException.ConfigurationException('An approval wait requires an assignment and a deadline.');
        }
        AgentRun__c run = lockRun(runId);
        assertExpectedRevision(run, expectedRevision);
        assertMutable(run);
        AgentCommand__c command = lockCommand(commandId, run.Id);
        if (
            run.CurrentCommand__c != command.Id ||
            command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL ||
            command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED ||
            command.ExpectedRunRevision__c != run.Revision__c ||
            String.isBlank(operationKey) ||
            !operationKey.equals(command.OperationKey__c) ||
            String.isBlank(leaseToken) ||
            !leaseToken.equals(command.LeaseToken__c)
        ) {
            throw new AgentKernelException.ConcurrencyException('The approval request no longer owns the current tool command.');
        }
        if (run.CancellationRequestedAt__c != null) {
            AgentLifecycleRecords.cancelCommand(command, run.CancellationReason__c);
            run.Revision__c = valueOrZero(run.Revision__c) + 1;
            AgentLifecycleRecords.markCancelled(run, run.CancellationReason__c, System.now());
            Decimal cancelledSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                cancelledSequence,
                AgentKernelModels.EVENT_RUN_CANCELLED,
                command.OperationKey__c,
                'Cancellation completed before tool approval.',
                null
            );
            cancelAllBlockedCommands(run);
            minimizeTerminalPayloads(run, command);
            updateCommand(command);
            AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
            AgentLifecyclePublisher.publish(run, 'Cancelled', cancelledSequence, command.OperationKey__c);
            return;
        }
        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        command.Status__c = AgentKernelModels.COMMAND_STATUS_WAITING;
        command.LeaseToken__c = null;
        command.LeaseExpiresAt__c = null;
        command.WorkerJobId__c = null;
        command.WorkerEnqueuedAt__c = null;
        command.ExpectedRunRevision__c = nextRevision;
        command.PolicyApproved__c = false;
        command.ApprovalFingerprint__c = ToolApprovalFingerprint.compute(
            command,
            AgentRunConfigurationService.getTool(run.Id, command.ToolName__c),
            AgentRunConfigurationService.getDefinition(run.Id)
        );
        run.Status__c = AgentKernelModels.RUN_STATUS_WAITING;
        run.Revision__c = nextRevision;
        run.CurrentCommand__c = null;
        run.LastActivityAt__c = System.now();
        applyWaitingMetadata(run, request.reason, APPROVAL_RESUME_SCHEMA, request.expiresAt, AgentKernelModels.CONTINUATION_REINVOKE_TOOL, command.Id);
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        updateCommand(command);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentApproval__c approval = AgentApprovalService.open(run, command, request);
        persistEvent(
            run,
            eventSequence,
            AgentKernelModels.EVENT_RUN_WAITING,
            command.OperationKey__c,
            'Tool approval required.',
            JSON.serialize(new Map<String, Object>{ 'approvalId' => approval.Id, 'approverType' => request.approverType })
        );
        AgentLifecyclePublisher.publish(run, 'Waiting', eventSequence, command.OperationKey__c);
    }

    /**
     * Expires an approval whose tool says Deny and Continue: the tool never
     * runs, the model learns the approval lapsed, and the run continues.
     * Returns the next command Id, or null when the run no longer qualifies
     * or the model budget is exhausted.
     */
    public static Id expireApprovalWithDenial(Id runId, Decimal expectedRevision) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Id commandId = expireApprovalWithDenialInternal(runId, expectedRevision);
            Database.releaseSavepoint(unitOfWork);
            return commandId;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Id expireApprovalWithDenialInternal(Id runId, Decimal expectedRevision) {
        AgentRun__c run = lockRun(runId);
        if (
            run.Status__c != AgentKernelModels.RUN_STATUS_WAITING ||
            run.Revision__c != expectedRevision ||
            run.ContinuationMode__c != AgentKernelModels.CONTINUATION_REINVOKE_TOOL ||
            run.WaitingCommand__c == null ||
            run.WaitExpiresAt__c == null ||
            run.WaitExpiresAt__c > System.now()
        ) {
            return null;
        }
        AgentCommand__c waitingCommand = lockCommand(run.WaitingCommand__c, run.Id);
        if (waitingCommand.Status__c != AgentKernelModels.COMMAND_STATUS_WAITING) {
            return null;
        }
        AgentApprovalService.closePending(new Set<Id>{ waitingCommand.Id }, AgentKernelModels.APPROVAL_STATUS_EXPIRED);
        return denyTool(
            run,
            waitingCommand,
            AgentKernelModels.ERROR_TOOL_APPROVAL_EXPIRED,
            'The approval expired before anyone decided.',
            new Map<String, Object>{ 'expiredAt' => run.WaitExpiresAt__c }
        );
    }

    public static AgentKernelModels.ReconciliationResult reconcileUnknownOutcome(AgentKernelModels.ReconciliationRequest request) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            AgentKernelModels.ReconciliationResult result = reconcileUnknownOutcomeInternal(request);
            Database.releaseSavepoint(unitOfWork);
            return result;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static AgentKernelModels.ReconciliationResult reconcileUnknownOutcomeInternal(AgentKernelModels.ReconciliationRequest request) {
        validateReconciliationRequest(request);
        AgentKernelAccessGuard.assertRunReadable(request.runId);
        AgentRun__c run = lockRun(request.runId);
        assertExpectedRevision(run, request.expectedRunRevision);
        // Checking the outside system is an operator's job, so Run Control decides it, never the run's own execution user.
        ExecutionIdentityService.assertCanReconcile(run);
        // A run whose Unknown outcome passed its deadline is paused, and stays reconcilable until retention clears it.
        if (run.Status__c != AgentKernelModels.RUN_STATUS_WAITING && run.Status__c != AgentKernelModels.RUN_STATUS_PAUSED) {
            throw new AgentKernelException.InvalidTransitionException('Only a waiting or paused run can reconcile an unknown outcome.');
        }
        if (run.PayloadPurgedAt__c != null) {
            throw new AgentKernelException.InvalidTransitionException(
                'Retention already cleared this run\'s data, so its unknown outcome cannot be reconciled. Cancel the run and start a new one if the work is still needed.'
            );
        }

        List<AgentCommand__c> unknownCommands = [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                AttemptNumber__c,
                RetryWindowStartAttempt__c,
                AvailableAt__c,
                Input__c,
                Output__c,
                InputHash__c,
                OutputHash__c,
                ToolName__c,
                BatchKey__c,
                BatchOrdinal__c,
                BatchSize__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :run.Id AND Status__c = :AgentKernelModels.COMMAND_STATUS_UNKNOWN
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (unknownCommands.size() != 1) {
            throw new AgentKernelException.InvalidTransitionException('The run must have exactly one unresolved unknown command.');
        }
        AgentCommand__c command = unknownCommands[0];
        if (
            command.Id != request.commandId ||
            command.OperationKey__c != request.operationKey ||
            command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL
        ) {
            throw new AgentKernelException.ConcurrencyException('The reconciliation command identity does not match.');
        }

        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        Id dispatchCommandId;
        String decisionName = String.valueOf(request.decision);
        Boolean cancellationPending = run.CancellationRequestedAt__c != null;
        if (cancellationPending && request.decision == AgentKernelModels.ReconciliationDecision.Retry) {
            throw new AgentKernelException.InvalidTransitionException('A cancelled run cannot retry an unknown command.');
        }
        Boolean continuesRun = !cancellationPending && (request.decision != AgentKernelModels.ReconciliationDecision.ConfirmFailed || request.pauseRun != true);
        if (continuesRun) {
            assertMayContinue(run);
        }
        if (request.decision == AgentKernelModels.ReconciliationDecision.ConfirmSucceeded) {
            try {
                ToolJsonSchemaValidator.validateInstance(request.confirmedOutput, ToolJsonSchemaValidator.TOOL_RESULT_SCHEMA, 'Confirmed tool output');
            } catch (ToolJsonSchemaValidator.ValidationException invalidOutput) {
                throw new AgentKernelException.InvalidTransitionException('Confirmed tool output must be a JSON object.');
            }
            String protectedConfirmedOutput = protectAndSave(run.Id, request.confirmedOutput);
            command.Status__c = AgentKernelModels.COMMAND_STATUS_SUCCEEDED;
            command.Output__c = protectedConfirmedOutput;
            command.ErrorCode__c = null;
            command.ErrorMessage__c = null;
            AgentCommand__c nextBatchCommand = cancellationPending ? null : nextBlockedBatchCommand(command);
            if (cancellationPending) {
                cancelBlockedBatchCommands(command);
                run.Status__c = AgentKernelModels.RUN_STATUS_CANCELLED;
                run.CurrentCommand__c = null;
                run.CompletedAt__c = System.now();
                AgentLifecycleRecords.setPurgeAfter(run);
            } else if (!hasBudgetAfterConfirmedSuccess(run, nextBatchCommand)) {
                // The confirmed result is a fact the run keeps; a spent budget pauses as everywhere else,
                // and rescue continues to the model, whose transcript shows this result.
                cancelBlockedBatchCommands(command);
                run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
                run.CurrentCommand__c = null;
                run.CompletedAt__c = null;
                run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(System.now(), run.PayloadRetentionDays__c);
                run.DeleteAfter__c = null;
            } else {
                AgentCommand__c nextCommand = nextBatchCommand;
                if (nextCommand == null) {
                    assertCommandAdmission(run, AgentKernelModels.COMMAND_TYPE_MODEL);
                    nextCommand = buildCommand(
                        run,
                        nextRevision,
                        new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, protectedConfirmedOutput, null)
                    );
                    AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ nextCommand });
                } else {
                    assertCommandAdmission(run, AgentKernelModels.COMMAND_TYPE_TOOL);
                    nextCommand.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
                    nextCommand.ExpectedRunRevision__c = nextRevision;
                    nextCommand.AvailableAt__c = System.now();
                    updateCommand(nextCommand);
                }
                dispatchCommandId = nextCommand.Id;
                run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
                run.CurrentCommand__c = nextCommand.Id;
            }
            run.ErrorCode__c = cancellationPending ? 'RUN_CANCELLED' : null;
            run.ErrorMessage__c = cancellationPending ? run.CancellationReason__c : null;
            if (run.Status__c == AgentKernelModels.RUN_STATUS_PAUSED) {
                run.ErrorCode__c = 'BUDGET_EXCEEDED';
                run.ErrorMessage__c = 'The tool call was confirmed, but the run budget is spent; raise the budget and rescue the run.';
            }
        } else if (request.decision == AgentKernelModels.ReconciliationDecision.ConfirmFailed) {
            command.Status__c = AgentKernelModels.COMMAND_STATUS_FAILED;
            command.ErrorCode__c = sanitizeCode(String.isBlank(request.errorCode) ? 'RECONCILED_TOOL_FAILURE' : request.errorCode);
            command.ErrorMessage__c = sanitizeError(
                String.isBlank(request.errorMessage) ? 'The reconciled tool operation was confirmed failed.' : request.errorMessage
            );
            command.ErrorMessage__c = protectAndSave(run.Id, command.ErrorMessage__c);
            cancelBlockedBatchCommands(command);
            // The confirmed failure is a fact the model can act on, like any failed call. The operator
            // pauses instead only by asking to, and a spent model budget pauses as everywhere else.
            Boolean continueToModel = !cancellationPending && request.pauseRun != true && exhaustedModelBudget(run, budgetLimits(run), 1) == null;
            if (continueToModel) {
                String failurePayload = AgentKernelModels.toolFailurePayload(command.ErrorCode__c, command.ErrorMessage__c);
                command.Output__c = failurePayload;
                AgentCommand__c modelCommand = buildCommand(
                    run,
                    nextRevision,
                    new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, failurePayload, null)
                );
                AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ modelCommand });
                dispatchCommandId = modelCommand.Id;
                run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
                run.CurrentCommand__c = modelCommand.Id;
                run.ErrorCode__c = null;
                run.ErrorMessage__c = null;
            } else {
                run.Status__c = cancellationPending ? AgentKernelModels.RUN_STATUS_CANCELLED : AgentKernelModels.RUN_STATUS_PAUSED;
                run.CurrentCommand__c = cancellationPending ? null : command.Id;
                if (cancellationPending) {
                    run.CompletedAt__c = System.now();
                    AgentLifecycleRecords.setPurgeAfter(run);
                } else {
                    run.CompletedAt__c = null;
                    run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(System.now(), run.PayloadRetentionDays__c);
                    run.DeleteAfter__c = null;
                }
                run.ErrorCode__c = cancellationPending ? 'RUN_CANCELLED' : command.ErrorCode__c;
                run.ErrorMessage__c = cancellationPending ? run.CancellationReason__c : command.ErrorMessage__c;
            }
        } else {
            if (request.safeToRetryAttested != true) {
                throw new AgentKernelException.InvalidTransitionException('Retry requires an explicit safe-to-retry attestation.');
            }
            Decimal nextRetryCount = valueOrZero(run.RetryCount__c) + 1;
            assertCommandAdmission(run, AgentKernelModels.COMMAND_TYPE_TOOL);
            // An operator who checked the outside system and attests a repeat is safe starts a new
            // retry window, as rescue does, so automatic retries already spent do not block it.
            command.RetryWindowStartAttempt__c = valueOrZero(command.AttemptNumber__c);
            command.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
            command.ExpectedRunRevision__c = nextRevision;
            command.AvailableAt__c = System.now();
            command.LeaseToken__c = null;
            command.LeaseExpiresAt__c = null;
            command.WorkerJobId__c = null;
            command.WorkerEnqueuedAt__c = null;
            command.ErrorCode__c = null;
            command.ErrorMessage__c = null;
            dispatchCommandId = command.Id;
            run.Status__c = AgentKernelModels.RUN_STATUS_RUNNING;
            run.CurrentCommand__c = command.Id;
            run.RetryCount__c = nextRetryCount;
            run.ErrorCode__c = null;
            run.ErrorMessage__c = null;
        }

        Map<String, Object> eventPayload = new Map<String, Object>{
            'decision' => decisionName,
            'reason' => boundedReason(protectAndSave(run.Id, request.reason)),
            'commandId' => command.Id,
            'operationKey' => command.OperationKey__c,
            'actorId' => UserInfo.getUserId()
        };
        if (request.decision == AgentKernelModels.ReconciliationDecision.Retry) {
            eventPayload.put('safeToRetryAttested', true);
        }
        Decimal eventSequence = AgentLifecycleRecords.nextEventSequence(run);
        persistEvent(
            run,
            eventSequence,
            AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED,
            command.OperationKey__c,
            'Unknown tool outcome reconciled: ' + decisionName + '.',
            JSON.serialize(eventPayload)
        );
        run.Revision__c = nextRevision;
        run.LastActivityAt__c = System.now();
        AgentLifecycleRecords.clearWaitingMetadata(run);
        if (run.Status__c == AgentKernelModels.RUN_STATUS_RUNNING) {
            run.PurgeAfter__c = null;
        }
        if (isTerminalStatus(run.Status__c)) {
            minimizeTerminalPayloads(run, command);
        } else {
            minimizeCompletedCommandPayload(run, command);
        }
        updateCommand(command);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentLifecyclePublisher.publish(run, 'Reconciled', eventSequence, command.OperationKey__c);

        AgentKernelModels.ReconciliationResult result = new AgentKernelModels.ReconciliationResult();
        result.runId = run.Id;
        result.reconciledCommandId = command.Id;
        result.dispatchedCommandId = dispatchCommandId;
        result.revision = nextRevision;
        result.operationKey = command.OperationKey__c;
        result.runStatus = run.Status__c;
        result.commandStatus = command.Status__c;
        return result;
    }

    public static void pauseAfterFault(AgentRun__c run, Datetime pausedAt, String errorCode, String errorMessage, Id resumableCommandId) {
        if (run == null || pausedAt == null) {
            throw new AgentKernelException.InvalidTransitionException('A run and pause timestamp are required.');
        }
        run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
        run.Revision__c = valueOrZero(run.Revision__c) + 1;
        run.CurrentCommand__c = resumableCommandId;
        run.LastActivityAt__c = pausedAt;
        run.CompletedAt__c = null;
        run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(pausedAt, run.PayloadRetentionDays__c);
        run.ErrorCode__c = sanitizeCode(errorCode);
        run.ErrorMessage__c = sanitizeError(errorMessage);
    }

    /**
     * Requeues the same durable operation after a retryable execution failure.
     * This is the only lifecycle path allowed to advance retry state.
     */
    public static Boolean scheduleRetry(AgentKernelModels.RetryRequest request) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            Boolean scheduled = scheduleRetryInternal(request);
            Database.releaseSavepoint(unitOfWork);
            return scheduled;
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    private static Boolean scheduleRetryInternal(AgentKernelModels.RetryRequest request) {
        if (request == null || String.isBlank(request.operationKey) || String.isBlank(request.leaseToken)) {
            throw new AgentKernelException.InvalidTransitionException('A retry request needs the lease identity.');
        }
        AgentRun__c run = lockRun(request.runId);
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        assertExpectedRevision(run, request.expectedRevision);
        assertMutable(run);
        AgentCommand__c command = lockCommand(request.commandId, run.Id);
        if (
            run.CurrentCommand__c != command.Id ||
            command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED ||
            command.ExpectedRunRevision__c != run.Revision__c ||
            !request.operationKey.equals(command.OperationKey__c) ||
            !request.leaseToken.equals(command.LeaseToken__c)
        ) {
            throw new AgentKernelException.ConcurrencyException('The retry request no longer owns the current command lease.');
        }

        // The tool worker asks for a retry only after the call was admitted. An
        // unadmitted call is a worker fault: failing the job hands the lease to
        // recovery, which treats a possible outside effect as Unknown.
        if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL && String.isBlank(command.AdmittedToolBindingHash__c)) {
            throw new AgentKernelException.InvalidTransitionException('An unadmitted tool call cannot be retried.');
        }

        AgentExecutionPolicyService.Policy executionPolicy = AgentRunConfigurationService.getExecutionPolicy(run.Id);
        Decimal nextRevision = valueOrZero(run.Revision__c) + 1;
        Decimal nextRetryCount = valueOrZero(run.RetryCount__c) + 1;
        Boolean cancellationPending = run.CancellationRequestedAt__c != null;
        Boolean terminationRequested = cancellationPending;
        String safeCode = sanitizeCode(request.errorCode);
        String safeMessage = sanitizeError(request.errorMessage);

        command.LeaseToken__c = null;
        command.LeaseExpiresAt__c = null;
        command.WorkerJobId__c = null;
        command.WorkerEnqueuedAt__c = null;
        command.ErrorCode__c = safeCode;
        command.ErrorMessage__c = safeMessage;
        run.Revision__c = nextRevision;
        run.RetryCount__c = terminationRequested ? valueOrZero(run.RetryCount__c) : nextRetryCount;
        // A model retry gave no usable answer, so it does not spend Max Model Calls; Max Retries
        // bounds it, and any tokens the provider reported still count below.
        if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
            run.ToolCallCount__c = valueOrZero(run.ToolCallCount__c) + 1;
        }
        run.LastActivityAt__c = System.now();
        run.ErrorCode__c = safeCode;
        run.ErrorMessage__c = safeMessage;
        applyTelemetry(run, command, request.telemetry);
        recordConfiguration(run, request.configurationHash, command.OperationKey__c);

        Integer operationAttemptCount = operationAttemptCount(command, request.completedAttemptCount);
        Boolean exhausted = operationAttemptCount > valueOrZero(executionPolicy.maxRetries);
        Map<String, Object> retryPayload = new Map<String, Object>{ 'retryCount' => nextRetryCount, 'errorCode' => safeCode };
        retryPayload.put('operationAttemptCount', operationAttemptCount);
        if (request.completedAttemptCount != null) {
            retryPayload.put('attempt', request.completedAttemptCount);
            retryPayload.put('delaySource', 'exponential');
            retryPayload.put('retryAfterApplied', request.retryAfterApplied == true);
            retryPayload.put('exponentialSeconds', request.exponentialSeconds);
            retryPayload.put('delaySeconds', request.delaySeconds);
        }
        if (request.contextSources != null && !request.contextSources.isEmpty()) {
            retryPayload.put('contextSources', request.contextSources);
        }
        addTelemetryPayload(retryPayload, request.telemetry);
        Decimal lifecycleEventSequence;
        Boolean budgetPaused = false;
        if (terminationRequested) {
            Boolean uncertainEffect = !AgentKernelRecovery.isRecoverySafe(command);
            command.Status__c = uncertainEffect ? AgentKernelModels.COMMAND_STATUS_UNKNOWN : AgentKernelModels.COMMAND_STATUS_CANCELLED;
            run.Status__c = uncertainEffect ? AgentKernelModels.RUN_STATUS_WAITING : AgentKernelModels.RUN_STATUS_CANCELLED;
            run.CurrentCommand__c = null;
            run.ErrorCode__c = uncertainEffect ? 'TOOL_OUTCOME_UNKNOWN' : 'RUN_CANCELLED';
            run.ErrorMessage__c = uncertainEffect ? 'A side-effecting tool outcome was uncertain when execution was stopped.' : run.CancellationReason__c;
            if (uncertainEffect) {
                AgentLifecycleRecords.setUnknownDeadline(run, System.now());
            } else {
                run.CompletedAt__c = System.now();
                AgentLifecycleRecords.setPurgeAfter(run);
                cancelBlockedBatchCommands(command);
            }
            lifecycleEventSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                lifecycleEventSequence,
                uncertainEffect ? AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN : AgentKernelModels.EVENT_RUN_CANCELLED,
                command.OperationKey__c,
                uncertainEffect ? 'Stopped tool outcome requires reconciliation.' : 'Cancellation completed after retry was requested.',
                retryPayload.isEmpty() ? null : JSON.serialize(retryPayload)
            );
            if (!uncertainEffect) {
                minimizeTerminalPayloads(run, command);
            }
        } else if (exhausted) {
            command.Status__c = AgentKernelModels.COMMAND_STATUS_FAILED;
            command.ExpectedRunRevision__c = nextRevision;
            run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
            run.CurrentCommand__c = command.Id;
            run.ErrorCode__c = 'RETRY_EXHAUSTED';
            run.ErrorMessage__c = 'The retry budget for the current operation was exhausted.';
            command.ErrorCode__c = run.ErrorCode__c;
            command.ErrorMessage__c = run.ErrorMessage__c;
            lifecycleEventSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                lifecycleEventSequence,
                AgentKernelModels.EVENT_RUN_PAUSED,
                command.OperationKey__c,
                'Operation retry budget exhausted; run paused.',
                retryPayload.isEmpty() ? null : JSON.serialize(retryPayload)
            );
            cancelBlockedBatchCommands(command);
        } else if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL && tokenCeilingReached(run)) {
            // Estimated or reported tokens of failed attempts count, so retries stop at Max Total Tokens.
            // The retry stays queued: raise the ceiling and rescue the run to call the model again.
            AgentDefinition__c limits = budgetLimits(run);
            budgetPaused = true;
            command.Status__c = AgentKernelModels.COMMAND_STATUS_RETRY_WAITING;
            command.ExpectedRunRevision__c = nextRevision;
            command.AvailableAt__c = System.now();
            run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
            run.CurrentCommand__c = command.Id;
            run.CompletedAt__c = null;
            run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(System.now(), run.PayloadRetentionDays__c);
            run.ErrorCode__c = 'BUDGET_EXCEEDED';
            run.ErrorMessage__c = sanitizeError(budgetMessage(run, limits, 'token', 1, 0));
            retryPayload.putAll(budgetFacts(run, limits, 'token', 1, 0));
            lifecycleEventSequence = AgentLifecycleRecords.nextEventSequence(run);
            persistEvent(
                run,
                lifecycleEventSequence,
                AgentKernelModels.EVENT_RUN_PAUSED,
                command.OperationKey__c,
                'Model retry stopped at the token ceiling; run paused.',
                JSON.serialize(retryPayload)
            );
        } else {
            Integer safeDelay = request.delaySeconds == null ? 60 : Math.max(0, request.delaySeconds);
            command.Status__c = AgentKernelModels.COMMAND_STATUS_RETRY_WAITING;
            command.ExpectedRunRevision__c = nextRevision;
            command.AvailableAt__c = System.now().addSeconds(safeDelay);
            retryPayload.put('availableAt', command.AvailableAt__c);
            persistEvent(
                run,
                AgentLifecycleRecords.nextEventSequence(run),
                AgentKernelModels.EVENT_COMMAND_RETRY_SCHEDULED,
                command.OperationKey__c,
                'Command retry scheduled.',
                JSON.serialize(retryPayload)
            );
        }
        updateCommand(command);
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        if (terminationRequested) {
            AgentLifecyclePublisher.publish(
                run,
                run.Status__c == AgentKernelModels.RUN_STATUS_WAITING ? 'Waiting' : 'Cancelled',
                lifecycleEventSequence,
                command.OperationKey__c
            );
        } else if (exhausted || budgetPaused) {
            AgentLifecyclePublisher.publish(run, 'Paused', lifecycleEventSequence, command.OperationKey__c);
        }
        return !terminationRequested && !exhausted && !budgetPaused;
    }

    private static AgentKernelModels.StartResult startRunInternal(
        AgentDefinition__c definition,
        String input,
        Id parentRunId,
        String externalCorrelationKey,
        String invocationEntryPoint,
        Id anchorRecordId
    ) {
        Savepoint startBoundary = Database.setSavepoint();
        try {
            AgentKernelModels.StartResult result = persistRunInternal(
                definition,
                input,
                parentRunId,
                externalCorrelationKey,
                invocationEntryPoint,
                anchorRecordId
            );
            Database.releaseSavepoint(startBoundary);
            return result;
        } catch (Exception startFailure) {
            Database.rollback(startBoundary);
            Database.releaseSavepoint(startBoundary);
            throw startFailure;
        }
    }

    private static AgentKernelModels.StartResult persistRunInternal(
        AgentDefinition__c definition,
        String input,
        Id parentRunId,
        String externalCorrelationKey,
        String invocationEntryPoint,
        Id anchorRecordId
    ) {
        validateStartValues(input, parentRunId, externalCorrelationKey);
        validateInvocationEntryPoint(invocationEntryPoint);
        AgentKernelAccessGuard.assertDefinitionReadable(definition.Id);
        // A person may link only a run they can see. Automation already holds
        // the execution user's access, and a link can only narrow it.
        if (parentRunId != null && AttendedAccessService.attendedRequester() != null) {
            AgentKernelAccessGuard.assertRunReadable(parentRunId);
        }
        List<AgentTool__c> tools;
        Exception validationFailure;
        ExtensionExecutionGuard.Boundary validationBoundary = ExtensionExecutionGuard.open();
        try {
            tools = AgentConfigService.validate(definition);
        } catch (Exception caughtFailure) {
            validationFailure = caughtFailure;
        }
        ExtensionExecutionGuard.Result validationIsolation = ExtensionExecutionGuard.close(validationBoundary);
        if (
            validationIsolation.performedDml ||
            validationIsolation.performedCallout ||
            validationIsolation.performedProhibitedAsync() ||
            validationFailure instanceof CalloutException
        ) {
            throw new AgentKernelException.ConfigurationException('Extension initialization must remain query-only.');
        }
        if (validationFailure != null) {
            throw validationFailure;
        }
        Map<String, Object> configuration = AgentConfigService.configurationFingerprint(
            definition,
            tools,
            AgentConfigService.getActiveContextProviders(definition.Id)
        );
        String configurationHash = AgentConfigService.fingerprintHash(configuration);
        String identityError = AgentDefinitionIdentityRules.error(definition);
        if (identityError != null) {
            throw new AgentKernelException.ConfigurationException(identityError);
        }
        ExecutionIdentityService.assertMayStart(definition);
        String normalizedCorrelationKey = String.isBlank(externalCorrelationKey) ? null : externalCorrelationKey.trim();
        String startDeduplicationKey = AgentRunDeduplicationService.deduplicationKey(definition.Id, normalizedCorrelationKey);
        String startRequestHash = startDeduplicationKey == null
            ? null
            : AgentRunDeduplicationService.requestHash(
                  definition.Id,
                  anchorRecordId,
                  parentRunId,
                  input,
                  invocationEntryPoint,
                  definition.ExecutionIdentity__c
              );
        ExecutionIdentityService.Snapshot identity = ExecutionIdentityService.snapshotForStart(definition.ExecutionIdentity__c);
        AgentKernelAccessGuard.assertAnchorReadable(anchorRecordId, identity.expectedPrincipalId);
        AgentExecutionPolicyService.Policy executionPolicy = AgentExecutionPolicyService.resolve(definition);
        PayloadProtectionService.Policy payloadPolicy = AgentExecutionPolicyService.toPayloadPolicy(executionPolicy);
        Datetime nowValue = System.now();
        AgentRun__c run = new AgentRun__c(
            AgentDefinition__c = definition.Id,
            Status__c = AgentKernelModels.RUN_STATUS_RUNNING,
            Revision__c = 0,
            AnchorRecordId__c = anchorRecordId == null ? null : String.valueOf(anchorRecordId),
            ParentRun__c = parentRunId,
            ExternalCorrelationKey__c = normalizedCorrelationKey,
            StartDeduplicationKey__c = startDeduplicationKey,
            StartRequestHash__c = startRequestHash,
            InvocationEntryPoint__c = invocationEntryPoint,
            InitiatingUser__c = identity.initiatingActorId,
            AttendedBy__c = AttendedAccessService.attendedByForStart(identity.executionIdentityId != null, parentRunId),
            LoopbackNamedCredential__c = identity.loopbackNamedCredential,
            ExpectedPrincipalUser__c = identity.expectedPrincipalId,
            ExecutionIdentity__c = identity.executionIdentityId,
            ResolvedPrincipalUser__c = identity.resolvedPrincipalId,
            ExecutionContextStatus__c = identity.contextStatus,
            ModelCallCount__c = 0,
            ToolCallCount__c = 0,
            RetryCount__c = 0,
            InputTokenCount__c = 0,
            OutputTokenCount__c = 0,
            TotalTokenCount__c = 0,
            ModelDurationMs__c = 0,
            ToolDurationMs__c = 0,
            MaxRetries__c = executionPolicy.maxRetries,
            PayloadRetentionMode__c = payloadPolicy.mode,
            PayloadRetentionDays__c = executionPolicy.payloadRetentionDays,
            RecordRetentionDays__c = executionPolicy.recordRetentionDays,
            RetainedPayloadCharacters__c = payloadPolicy.retainedCharacters,
            SensitiveJsonKeys__c = executionPolicy.sensitiveJsonKeys,
            StartedAt__c = nowValue,
            LastActivityAt__c = nowValue,
            ConfigurationHash__c = configurationHash
        );
        // Tokens need the run Id, so the run is inserted without input and
        // receives only protected input; raw input is never persisted.
        AgentLifecycleStore.insertRuns(new List<AgentRun__c>{ run });
        run.Input__c = protectAndSave(run.Id, input);

        Decimal initialRevision = 1;
        AgentKernelModels.CommandSpec spec = new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, run.Input__c, null);
        AgentCommand__c command = buildCommand(run, initialRevision, spec);
        AgentLifecycleStore.insertEvents(
            new List<AgentEvent__c>{
                AgentLifecycleRecords.buildEvent(
                    run,
                    1,
                    AgentKernelModels.EVENT_RUN_STARTED,
                    null,
                    'Run started.',
                    JSON.serialize(new Map<String, Object>{ 'configuration' => configuration })
                ),
                AgentLifecycleRecords.buildEvent(run, 2, AgentKernelModels.EVENT_INPUT_ACCEPTED, command.OperationKey__c, 'Input accepted.', run.Input__c)
            }
        );
        AgentLifecycleStore.insertCommands(new List<AgentCommand__c>{ command });

        run.Revision__c = initialRevision;
        run.CurrentCommand__c = command.Id;
        run.LastEventSequence__c = 2;
        AgentLifecycleStore.updateRuns(new List<AgentRun__c>{ run });
        AgentOperationsLog.emit(LoggingLevel.INFO, AgentKernelModels.EVENT_RUN_STARTED, run.Id, command.Id, null, command.OperationKey__c);
        AgentLifecyclePublisher.publish(run, 'Started', 1, command.OperationKey__c);

        AgentKernelModels.StartResult result = new AgentKernelModels.StartResult();
        result.runId = run.Id;
        result.commandId = command.Id;
        result.revision = initialRevision;
        result.operationKey = command.OperationKey__c;
        result.anchorRecordId = anchorRecordId;
        result.parentRunId = parentRunId;
        result.externalCorrelationKey = run.ExternalCorrelationKey__c;
        result.invocationEntryPoint = run.InvocationEntryPoint__c;
        result.deduplicated = false;
        result.runStatus = run.Status__c;
        return result;
    }

    private static void validateStartValues(String input, Id parentRunId, String externalCorrelationKey) {
        if (input != null && input.length() > 131072) {
            throw new AgentKernelException.InvalidTransitionException('Run input exceeds the supported length.');
        }
        if (parentRunId != null && parentRunId.getSObjectType() != AgentRun__c.SObjectType) {
            throw new AgentKernelException.InvalidTransitionException('Parent run ID must identify an AgentRun record.');
        }
        if (externalCorrelationKey != null && externalCorrelationKey.trim().length() > 255) {
            throw new AgentKernelException.InvalidTransitionException('External correlation key exceeds 255 characters.');
        }
    }

    private static void validateInvocationEntryPoint(String invocationEntryPoint) {
        if (
            !new Set<String>{
                    AgentKernelModels.INVOCATION_APEX,
                    AgentKernelModels.INVOCATION_FLOW,
                    AgentKernelModels.INVOCATION_REST,
                    AgentKernelModels.INVOCATION_PLATFORM_EVENT,
                    AgentKernelModels.INVOCATION_CHAT
                }
                .contains(invocationEntryPoint)
        ) {
            throw new AgentKernelException.InvalidTransitionException('Invocation entry point is invalid.');
        }
    }

    private static AgentRun__c lockRunForAdministration(Id runId, Decimal expectedRevision) {
        AgentKernelAccessGuard.assertRunReadable(runId);
        AgentRun__c run = lockRun(runId);
        assertExpectedRevision(run, expectedRevision);
        ExecutionIdentityService.assertCanAdminister(run);
        return run;
    }

    /**
     * A run of an agent without an identity executes as the person who started
     * it, and only their own job chain can carry it on, so nobody else may continue it.
     * Checked before any change; cancelling stays open to operators.
     */
    private static void assertMayContinue(AgentRun__c run) {
        if (!mayContinue(run.ExecutionIdentity__c, run.InitiatingUser__c)) {
            throw new AgentKernelException.AuthorizationException(INITIATING_USER_CONTINUE_REFUSED);
        }
    }

    /** Whether the current user may continue a run with this identity and starter; shared with the operator view. */
    public static Boolean mayContinue(Id executionIdentityId, Id initiatingUserId) {
        return executionIdentityId != null || initiatingUserId == UserInfo.getUserId();
    }

    /**
     * What a run paused on its budget has used of each limit, and the budget rescue
     * would be refused on right now ('model', 'tool', 'token', or null); null for any
     * other run. Shared with the operator view, so an operator raises the right limit
     * before pressing a button that must fail.
     */
    public static Map<String, Object> budgetStanding(Id runId) {
        List<AgentRun__c> runs = [
            SELECT
                Status__c,
                ErrorCode__c,
                AgentDefinition__c,
                CurrentCommand__c,
                CurrentCommand__r.CommandType__c,
                CurrentCommand__r.Status__c,
                ModelCallCount__c,
                ReplyModelCallBase__c,
                ToolCallCount__c,
                ReplyToolCallBase__c,
                TotalTokenCount__c,
                ReplyTokenBase__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (runs.isEmpty() || runs[0].Status__c != AgentKernelModels.RUN_STATUS_PAUSED || runs[0].ErrorCode__c != 'BUDGET_EXCEEDED') {
            return null;
        }
        AgentRun__c run = runs[0];
        AgentDefinition__c limits = budgetLimits(run);
        // Rescue admits a queued command as it is, or a new model turn when nothing is queued;
        // a failed command may go either way, so it is left for rescue itself to judge.
        Boolean queued =
            run.CurrentCommand__c != null &&
            new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }
                .contains(run.CurrentCommand__r.Status__c);
        String admitted = run.CurrentCommand__c == null ? AgentKernelModels.COMMAND_TYPE_MODEL : queued ? run.CurrentCommand__r.CommandType__c : null;
        String rescueBlockedBy = null;
        if (admitted == AgentKernelModels.COMMAND_TYPE_MODEL) {
            rescueBlockedBy = exhaustedModelBudget(run, limits, 1);
        } else if (admitted == AgentKernelModels.COMMAND_TYPE_TOOL && toolCallsUsed(run) + 1 > limits.MaxToolCalls__c) {
            rescueBlockedBy = 'tool';
        }
        return new Map<String, Object>{
            'modelCalls' => modelCallsUsed(run).intValue(),
            'maxModelCalls' => limits.MaxModelCalls__c.intValue(),
            'toolCalls' => toolCallsUsed(run).intValue(),
            'maxToolCalls' => limits.MaxToolCalls__c.intValue(),
            'tokens' => tokensUsed(run).longValue(),
            'maxTokens' => AgentConfigService.maxTotalTokens(limits),
            'perReply' => run.ReplyModelCallBase__c != null,
            'rescueBlockedBy' => rescueBlockedBy
        };
    }

    private static AgentRun__c lockRun(Id runId) {
        if (runId == null) {
            throw new AgentKernelException.InvalidTransitionException('Run ID is required.');
        }
        List<AgentRun__c> runs = lockRuns(new Set<Id>{ runId });
        if (runs.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found.');
        }
        return runs[0];
    }

    private static List<AgentRun__c> lockRuns(Set<Id> runIds) {
        return [
            SELECT
                Id,
                AgentDefinition__c,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Status__c,
                Revision__c,
                LastEventSequence__c,
                CommandSequence__c,
                CurrentCommand__c,
                Input__c,
                Output__c,
                InputHash__c,
                OutputHash__c,
                MaxRetries__c,
                PayloadRetentionMode__c,
                PayloadRetentionDays__c,
                RecordRetentionDays__c,
                RetainedPayloadCharacters__c,
                SensitiveJsonKeys__c,
                ModelCallCount__c,
                ToolCallCount__c,
                RetryCount__c,
                InputTokenCount__c,
                OutputTokenCount__c,
                TotalTokenCount__c,
                UnmeteredModelAttempts__c,
                ReplyModelCallBase__c,
                ReplyToolCallBase__c,
                ReplyTokenBase__c,
                ModelDurationMs__c,
                ToolDurationMs__c,
                ErrorCode__c,
                ErrorMessage__c,
                CancellationRequestedAt__c,
                CancellationReason__c,
                WaitingReason__c,
                ResumeJsonSchema__c,
                WaitExpiresAt__c,
                ContinuationMode__c,
                WaitingCommand__c,
                PurgeAfter__c,
                PayloadPurgedAt__c,
                ConfigurationHash__c
            FROM AgentRun__c
            WHERE Id IN :runIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
    }

    private static AgentCommand__c lockCommand(Id commandId, Id runId) {
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                AttemptNumber__c,
                RetryWindowStartAttempt__c,
                LeaseToken__c,
                LeaseExpiresAt__c,
                AdmittedEffects__c,
                AdmittedToolBindingHash__c,
                AvailableAt__c,
                Input__c,
                Output__c,
                InputHash__c,
                OutputHash__c,
                ToolName__c,
                ProviderRequestId__c,
                DurationMs__c,
                InputTokens__c,
                OutputTokens__c,
                TotalTokens__c,
                ExternalReference__c,
                ProviderToolCallId__c,
                PolicyApproved__c,
                ApprovalFingerprint__c,
                BatchKey__c,
                BatchOrdinal__c,
                BatchSize__c,
                InputSource__c,
                AnswerTurn__c,
                PayloadProtected__c,
                Sequence__c
            FROM AgentCommand__c
            WHERE Id = :commandId AND AgentRun__c = :runId
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (commands.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent command was not found for the run.');
        }
        return commands[0];
    }

    /**
     * Lifecycle writes go through AgentLifecycleStore in system mode. Command
     * updates omit the non-reparentable AgentRun__c master-detail field.
     */
    private static void persistEvent(AgentRun__c run, Decimal sequence, String eventType, String commandKey, String summary, String payload) {
        AgentLifecycleStore.insertEvents(new List<AgentEvent__c>{ AgentLifecycleRecords.buildEvent(run, sequence, eventType, commandKey, summary, payload) });
        LoggingLevel level = WARNING_EVENTS.contains(eventType) ? LoggingLevel.WARN : LoggingLevel.INFO;
        AgentOperationsLog.emit(level, eventType, run.Id, null, null, commandKey);
    }

    private static void updateCommand(AgentCommand__c command) {
        updateCommands(new List<AgentCommand__c>{ command });
    }

    private static void updateCommands(List<AgentCommand__c> commands) {
        AgentLifecycleStore.updateCommands(commands);
    }

    private static AgentCommand__c buildCommand(AgentRun__c run, Decimal expectedRevision, AgentKernelModels.CommandSpec spec) {
        validateCommandSpec(spec);
        run.CommandSequence__c = valueOrZero(run.CommandSequence__c) + 1;
        String operationKey = operationKey(run.Id, run.CommandSequence__c, spec.commandType, spec.toolName);
        return new AgentCommand__c(
            AgentRun__c = run.Id,
            CommandType__c = spec.commandType,
            Status__c = AgentKernelModels.COMMAND_STATUS_PENDING,
            ExpectedRunRevision__c = expectedRevision,
            OperationKey__c = operationKey,
            Sequence__c = run.CommandSequence__c,
            DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            AttemptNumber__c = spec.attemptNumber == null ? 0 : spec.attemptNumber,
            RetryWindowStartAttempt__c = 0,
            AvailableAt__c = spec.availableAt == null ? System.now() : spec.availableAt,
            Input__c = spec.input,
            InputSource__c = spec.inputSource,
            ToolName__c = spec.toolName,
            ProviderToolCallId__c = boundedIdentifier(spec.toolCallId),
            Rationale__c = spec.rationale
        );
    }

    private static List<AgentKernelModels.CommandSpec> requestedCommands(AgentKernelModels.CommandOutcome outcome) {
        if (outcome.nextCommands != null && !outcome.nextCommands.isEmpty()) {
            return outcome.nextCommands;
        }
        return new List<AgentKernelModels.CommandSpec>{ outcome.nextCommand };
    }

    private static List<AgentCommand__c> buildToolBatch(
        AgentRun__c run,
        Decimal firstRevision,
        String sourceOperationKey,
        List<AgentKernelModels.CommandSpec> specs
    ) {
        if (specs == null || specs.size() < 2 || specs.size() > AgentKernelModels.MAX_TOOL_CALLS_PER_TURN) {
            throw new AgentKernelException.InvalidTransitionException('A durable tool batch must contain between 2 and 8 commands.');
        }
        String batchKey = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(sourceOperationKey))).toLowerCase();
        List<AgentCommand__c> commands = new List<AgentCommand__c>();
        for (Integer index = 0; index < specs.size(); index++) {
            AgentKernelModels.CommandSpec spec = specs[index];
            if (spec.commandType != AgentKernelModels.COMMAND_TYPE_TOOL) {
                throw new AgentKernelException.InvalidTransitionException('A multi-command batch may contain only tool commands.');
            }
            AgentCommand__c command = buildCommand(run, firstRevision, spec);
            command.Status__c = index == 0 ? AgentKernelModels.COMMAND_STATUS_PENDING : AgentKernelModels.COMMAND_STATUS_BLOCKED;
            command.BatchKey__c = batchKey;
            command.BatchOrdinal__c = index + 1;
            command.BatchSize__c = specs.size();
            commands.add(command);
        }
        return commands;
    }

    private static AgentCommand__c nextBlockedBatchCommand(AgentCommand__c command) {
        if (
            command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL ||
            String.isBlank(command.BatchKey__c) ||
            command.BatchOrdinal__c == null ||
            command.BatchSize__c == null ||
            command.BatchOrdinal__c >= command.BatchSize__c
        ) {
            return null;
        }
        Decimal nextOrdinal = command.BatchOrdinal__c + 1;
        List<AgentCommand__c> commands = [
            SELECT Id, AgentRun__c, Status__c, ExpectedRunRevision__c, OperationKey__c, DispatchToken__c, BatchKey__c, BatchOrdinal__c, BatchSize__c
            FROM AgentCommand__c
            WHERE
                AgentRun__c = :command.AgentRun__c
                AND BatchKey__c = :command.BatchKey__c
                AND BatchOrdinal__c = :nextOrdinal
                AND Status__c = :AgentKernelModels.COMMAND_STATUS_BLOCKED
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        return commands.isEmpty() ? null : commands[0];
    }

    private static void cancelBlockedBatchCommands(AgentCommand__c command) {
        if (String.isBlank(command.BatchKey__c)) {
            return;
        }
        List<AgentCommand__c> blocked = [
            SELECT Id, Status__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :command.AgentRun__c AND BatchKey__c = :command.BatchKey__c AND Status__c = :AgentKernelModels.COMMAND_STATUS_BLOCKED
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        // Cancelled siblings stay transcript turns, so the model learns they did not run;
        // retention protects them when they leave the window or the run ends.
        for (AgentCommand__c sibling : blocked) {
            sibling.Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED;
        }
        if (!blocked.isEmpty()) {
            updateCommands(blocked);
        }
    }

    private static void cancelAllBlockedCommands(AgentRun__c run) {
        List<AgentCommand__c> blocked = [
            SELECT Id, Status__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :run.Id AND Status__c = :AgentKernelModels.COMMAND_STATUS_BLOCKED
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        // Cancelled siblings stay transcript turns, so the model learns they did not run;
        // retention protects them when they leave the window or the run ends.
        for (AgentCommand__c sibling : blocked) {
            sibling.Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED;
        }
        if (!blocked.isEmpty()) {
            updateCommands(blocked);
        }
    }

    private static Boolean isTerminalStatus(String status) {
        return status == AgentKernelModels.RUN_STATUS_SUCCEEDED ||
            status == AgentKernelModels.RUN_STATUS_FAILED ||
            status == AgentKernelModels.RUN_STATUS_CANCELLED;
    }

    private static void applyWaitingMetadata(
        AgentRun__c run,
        String reason,
        String resumeJsonSchema,
        Datetime expiresAt,
        String continuationMode,
        Id waitingCommandId
    ) {
        ToolJsonSchemaValidator.validateSchema(resumeJsonSchema, 'Resume schema');
        String mode = String.isBlank(continuationMode) ? AgentKernelModels.CONTINUATION_MODEL : continuationMode;
        if (
            !new Set<String>{ AgentKernelModels.CONTINUATION_MODEL, AgentKernelModels.CONTINUATION_CONVERSATION, AgentKernelModels.CONTINUATION_REINVOKE_TOOL }
                .contains(mode)
        ) {
            throw new AgentKernelException.InvalidTransitionException('Waiting continuation mode is invalid.');
        }
        run.WaitingReason__c = boundedReason(String.isBlank(reason) ? 'Awaiting external input.' : reason);
        if (run.WaitingReason__c != null && run.WaitingReason__c.length() > 255) {
            run.WaitingReason__c = run.WaitingReason__c.substring(0, 255);
        }
        run.ResumeJsonSchema__c = resumeJsonSchema;
        run.WaitExpiresAt__c = expiresAt;
        run.ContinuationMode__c = mode;
        run.WaitingCommand__c = waitingCommandId;
    }

    private static String lifecycleTransition(String eventType) {
        if (eventType == AgentKernelModels.EVENT_RUN_WAITING || eventType == AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN) {
            return 'Waiting';
        }
        if (eventType == AgentKernelModels.EVENT_RUN_COMPLETED) {
            return 'Succeeded';
        }
        if (eventType == AgentKernelModels.EVENT_RUN_PAUSED || eventType == AgentKernelModels.EVENT_WAIT_EXPIRED) {
            return 'Paused';
        }
        if (eventType == AgentKernelModels.EVENT_RUN_RESCUED) {
            return 'Rescued';
        }
        if (eventType == AgentKernelModels.EVENT_RUN_FAILED) {
            return 'Failed';
        }
        if (eventType == AgentKernelModels.EVENT_RUN_CANCELLED) {
            return 'Cancelled';
        }
        if (eventType == AgentKernelModels.EVENT_UNKNOWN_OUTCOME_RECONCILED) {
            return 'Reconciled';
        }
        return eventType;
    }

    private static void minimizeTerminalPayloads(AgentRun__c run, AgentCommand__c currentCommand) {
        if (!isTerminalStatus(run.Status__c)) {
            return;
        }
        PayloadProtectionService.Policy policy = PayloadProtectionService.fromRun(run);
        AgentLifecycleRecords.protectRunFields(run, policy);
        if (currentCommand != null) {
            AgentLifecycleRecords.protectCommandFields(currentCommand, policy);
        }
        // Transcript turns kept replayable while the run was active get the retention mode now.
        List<Id> pendingTurnIds = new List<Id>();
        for (AgentCommand__c turn : [
            SELECT Id
            FROM AgentCommand__c
            WHERE
                AgentRun__c = :run.Id
                AND PayloadProtected__c = FALSE
                AND ((CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                AND Status__c IN :AgentLifecycleRecords.TRANSCRIPT_TOOL_STATUSES)
                OR (CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL
                AND (InputSource__c != NULL
                OR AnswerTurn__c = TRUE)))
            WITH SYSTEM_MODE
            ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC, Id DESC
            LIMIT :TERMINAL_PROTECTION_LIMIT
        ]) {
            if (currentCommand == null || turn.Id != currentCommand.Id) {
                pendingTurnIds.add(turn.Id);
            }
        }
        protectInChunks(run, pendingTurnIds);
    }

    /**
     * Applies retention to a finished command that is not a transcript turn,
     * then to the turns that just left the model's transcript window. Turns
     * inside the window stay replayable until the run ends.
     */
    private static void minimizeCompletedCommandPayload(AgentRun__c run, AgentCommand__c command) {
        if (command == null || isRescueCheckpoint(run, command)) {
            return;
        }
        if (
            !AgentLifecycleRecords.isTranscriptTurn(command) &&
            new Set<String>{ AgentKernelModels.COMMAND_STATUS_SUCCEEDED, AgentKernelModels.COMMAND_STATUS_FAILED, AgentKernelModels.COMMAND_STATUS_CANCELLED }
                .contains(command.Status__c)
        ) {
            AgentLifecycleRecords.protectCommandFields(command, PayloadProtectionService.fromRun(run));
        }
        minimizeTranscriptOverflow(run, command);
    }

    private static void minimizeTranscriptOverflow(AgentRun__c run, AgentCommand__c completedCommand) {
        Integer window = AgentLifecycleRecords.transcriptWindow(AgentConfigService.transcriptTurnLimit(budgetLimits(run)));
        Integer lookahead = window + OVERFLOW_PROTECTION_BATCH;
        List<AgentCommand__c> newestFirst = [
            SELECT Id, PayloadProtected__c
            FROM AgentCommand__c
            WHERE
                AgentRun__c = :run.Id
                AND ((CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                AND Status__c IN :AgentLifecycleRecords.TRANSCRIPT_TOOL_STATUSES)
                OR (CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL
                AND (InputSource__c != NULL
                OR AnswerTurn__c = TRUE)))
            WITH SYSTEM_MODE
            ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC, Id DESC
            LIMIT :lookahead
        ];
        List<Id> overflowIds = new List<Id>();
        for (Integer index = window; index < newestFirst.size(); index++) {
            AgentCommand__c turn = newestFirst[index];
            if (turn.PayloadProtected__c != true && (completedCommand == null || turn.Id != completedCommand.Id)) {
                overflowIds.add(turn.Id);
            }
        }
        protectInChunks(run, overflowIds);
    }

    /** Loads and protects payloads a few rows at a time so heap stays bounded. */
    private static void protectInChunks(AgentRun__c run, List<Id> commandIds) {
        PayloadProtectionService.Policy policy = PayloadProtectionService.fromRun(run);
        for (Integer offset = 0; offset < commandIds.size(); offset += PROTECTION_CHUNK_SIZE) {
            List<Id> chunk = new List<Id>();
            for (Integer index = offset; index < Math.min(commandIds.size(), offset + PROTECTION_CHUNK_SIZE); index++) {
                chunk.add(commandIds[index]);
            }
            List<AgentCommand__c> rows = [
                SELECT Id, Input__c, Output__c, InputHash__c, OutputHash__c, PayloadProtected__c
                FROM AgentCommand__c
                WHERE Id IN :chunk AND PayloadProtected__c = FALSE
                WITH SYSTEM_MODE
            ];
            for (AgentCommand__c row : rows) {
                AgentLifecycleRecords.protectCommandFields(row, policy);
            }
            if (!rows.isEmpty()) {
                updateCommands(rows);
            }
        }
    }

    private static Boolean isRescueCheckpoint(AgentRun__c run, AgentCommand__c command) {
        return run.Status__c == AgentKernelModels.RUN_STATUS_PAUSED &&
            run.CurrentCommand__c == command.Id &&
            command.Status__c == AgentKernelModels.COMMAND_STATUS_FAILED;
    }

    private static String protectAndSave(Id runId, String content) {
        if (!TrustService.needsProtection(new List<String>{ content })) {
            return content;
        }
        // Every caller has already authorized the transition that stores this content.
        TrustService.ProtectionContext context = TrustService.openForAuthorizedTransition(runId);
        String protectedContent = TrustService.protect(context, content);
        TrustService.save(context);
        return protectedContent;
    }

    private static String operationKey(Id runId, Decimal commandSequence, String commandType, String toolName) {
        String key = String.valueOf(runId) + ':' + String.valueOf(commandSequence.intValue()) + ':' + commandType;
        if (!String.isBlank(toolName)) {
            key += ':' + toolName.trim().toLowerCase();
        }
        return key;
    }

    private static void validateOutcomeIdentity(AgentKernelModels.CommandOutcome outcome) {
        if (
            outcome == null ||
            outcome.runId == null ||
            outcome.commandId == null ||
            outcome.expectedRunRevision == null ||
            String.isBlank(outcome.operationKey)
        ) {
            throw new AgentKernelException.InvalidTransitionException('Outcome identity and concurrency fields are required.');
        }
    }

    private static void validateReconciliationRequest(AgentKernelModels.ReconciliationRequest request) {
        if (
            request == null ||
            request.runId == null ||
            request.commandId == null ||
            request.expectedRunRevision == null ||
            String.isBlank(request.operationKey) ||
            request.decision == null ||
            String.isBlank(request.reason)
        ) {
            throw new AgentKernelException.InvalidTransitionException('Reconciliation identity, decision, and reason are required.');
        }
        if (request.decision == AgentKernelModels.ReconciliationDecision.ConfirmSucceeded && request.confirmedOutput == null) {
            throw new AgentKernelException.InvalidTransitionException('Confirmed tool output is required.');
        }
    }

    private static String boundedReason(String value) {
        String sanitized = sanitizeError(value);
        return sanitized != null && sanitized.length() > 500 ? sanitized.substring(0, 500) : sanitized;
    }

    private static void validateOutcomeShape(AgentKernelModels.CommandOutcome outcome) {
        Set<String> validCommandStatuses = new Set<String>{
            AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
            AgentKernelModels.COMMAND_STATUS_FAILED,
            AgentKernelModels.COMMAND_STATUS_UNKNOWN
        };
        if (!validCommandStatuses.contains(outcome.commandStatus)) {
            throw new AgentKernelException.InvalidTransitionException('Outcome command status must be Succeeded, Failed, or Unknown.');
        }

        Boolean hasSingleNext = outcome.nextCommand != null;
        Boolean hasBatchNext = outcome.nextCommands != null && !outcome.nextCommands.isEmpty();
        if (String.isBlank(outcome.runStatus)) {
            if (hasSingleNext == hasBatchNext) {
                throw new AgentKernelException.InvalidTransitionException('A nonterminal outcome requires exactly one next command or command batch.');
            }
            List<AgentKernelModels.CommandSpec> specs = requestedCommands(outcome);
            if (specs.size() > AgentKernelModels.MAX_TOOL_CALLS_PER_TURN) {
                throw new AgentKernelException.InvalidTransitionException('A command batch may contain at most 8 commands.');
            }
            for (AgentKernelModels.CommandSpec spec : specs) {
                validateCommandSpec(spec);
            }
        } else {
            Set<String> stoppingStatuses = new Set<String>{
                AgentKernelModels.RUN_STATUS_SUCCEEDED,
                AgentKernelModels.RUN_STATUS_FAILED,
                AgentKernelModels.RUN_STATUS_WAITING,
                AgentKernelModels.RUN_STATUS_PAUSED
            };
            if (!stoppingStatuses.contains(outcome.runStatus) || hasSingleNext || hasBatchNext) {
                throw new AgentKernelException.InvalidTransitionException('An outcome must specify one valid stopping state or one next command.');
            }
        }
        if (outcome.retryIncrement != null && outcome.retryIncrement < 0) {
            throw new AgentKernelException.InvalidTransitionException('Retry increment cannot be negative.');
        }
    }

    private static void validateCommandSpec(AgentKernelModels.CommandSpec spec) {
        if (spec == null || String.isBlank(spec.commandType)) {
            throw new AgentKernelException.InvalidTransitionException('Next command type is required.');
        }
        Set<String> commandTypes = new Set<String>{ AgentKernelModels.COMMAND_TYPE_MODEL, AgentKernelModels.COMMAND_TYPE_TOOL };
        if (!commandTypes.contains(spec.commandType)) {
            throw new AgentKernelException.InvalidTransitionException('Next command type is invalid.');
        }
        if (spec.commandType == AgentKernelModels.COMMAND_TYPE_TOOL && String.isBlank(spec.toolName)) {
            throw new AgentKernelException.InvalidTransitionException('A tool command requires a tool name.');
        }
        if (spec.input != null && spec.input.length() > 131072) {
            throw new AgentKernelException.InvalidTransitionException('Next command input exceeds the supported length.');
        }
        if (spec.toolName != null && spec.toolName.length() > 80) {
            throw new AgentKernelException.InvalidTransitionException('Next command tool name exceeds the supported length.');
        }
        if (spec.toolCallId != null && spec.toolCallId.length() > 255) {
            throw new AgentKernelException.InvalidTransitionException('Next command tool-call ID exceeds the supported length.');
        }
        if (spec.attemptNumber != null && spec.attemptNumber < 0) {
            throw new AgentKernelException.InvalidTransitionException('Command attempt number cannot be negative.');
        }
    }

    private static void incrementCounters(AgentRun__c run, AgentCommand__c command, AgentKernelModels.CommandOutcome outcome) {
        if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL) {
            run.ModelCallCount__c = valueOrZero(run.ModelCallCount__c) + 1;
        } else if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL && outcome.toolNotInvoked != true) {
            // A call paused before its tool ran is repeated on rescue, so only the attempt that runs counts.
            run.ToolCallCount__c = valueOrZero(run.ToolCallCount__c) + 1;
        }
        run.RetryCount__c = valueOrZero(run.RetryCount__c) + (outcome.retryIncrement == null ? 0 : outcome.retryIncrement);
    }

    private static void applyTelemetry(AgentRun__c run, AgentCommand__c command, AgentKernelModels.CommandOutcome outcome) {
        AgentKernelModels.OperationalTelemetry telemetry = new AgentKernelModels.OperationalTelemetry();
        telemetry.providerRequestId = outcome.providerRequestId;
        telemetry.durationMilliseconds = outcome.durationMilliseconds;
        telemetry.inputTokens = outcome.inputTokens;
        telemetry.outputTokens = outcome.outputTokens;
        telemetry.totalTokens = outcome.totalTokens;
        telemetry.externalReference = outcome.externalReference;
        telemetry.tokensEstimated = outcome.tokensEstimated;
        applyTelemetry(run, command, telemetry);
    }

    private static void applyTelemetry(AgentRun__c run, AgentCommand__c command, AgentKernelModels.OperationalTelemetry telemetry) {
        if (telemetry == null) {
            return;
        }
        String providerRequestId = boundedIdentifier(telemetry.providerRequestId);
        if (providerRequestId != null) {
            command.ProviderRequestId__c = providerRequestId;
        }
        String externalReference = boundedIdentifier(telemetry.externalReference);
        if (externalReference != null) {
            command.ExternalReference__c = externalReference;
        }
        Decimal duration = safeTelemetryValue(telemetry.durationMilliseconds);
        Decimal inputTokens = safeTelemetryValue(telemetry.inputTokens);
        Decimal outputTokens = safeTelemetryValue(telemetry.outputTokens);
        Decimal totalTokens = safeTelemetryValue(telemetry.totalTokens);
        if (duration != null) {
            command.DurationMs__c = addTelemetryValues(command.DurationMs__c, duration);
            if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL) {
                run.ModelDurationMs__c = addTelemetryValues(run.ModelDurationMs__c, duration);
            } else if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
                run.ToolDurationMs__c = addTelemetryValues(run.ToolDurationMs__c, duration);
            }
        }
        if (inputTokens != null) {
            command.InputTokens__c = addTelemetryValues(command.InputTokens__c, inputTokens);
            run.InputTokenCount__c = addTelemetryValues(run.InputTokenCount__c, inputTokens);
        }
        if (outputTokens != null) {
            command.OutputTokens__c = addTelemetryValues(command.OutputTokens__c, outputTokens);
            run.OutputTokenCount__c = addTelemetryValues(run.OutputTokenCount__c, outputTokens);
        }
        if (totalTokens != null) {
            command.TotalTokens__c = addTelemetryValues(command.TotalTokens__c, totalTokens);
            run.TotalTokenCount__c = addTelemetryValues(run.TotalTokenCount__c, totalTokens);
        }
        // A model attempt that reported no usage still cost input; its estimate counts toward Max Total Tokens.
        if (telemetry.tokensEstimated == true) {
            run.UnmeteredModelAttempts__c = valueOrZero(run.UnmeteredModelAttempts__c) + 1;
        }
    }

    private static void addTelemetryPayload(Map<String, Object> payload, AgentKernelModels.OperationalTelemetry telemetry) {
        if (telemetry == null) {
            return;
        }
        String providerRequestId = boundedIdentifier(telemetry.providerRequestId);
        String externalReference = boundedIdentifier(telemetry.externalReference);
        if (providerRequestId != null) {
            payload.put('providerRequestId', providerRequestId);
        }
        if (externalReference != null) {
            payload.put('externalReference', externalReference);
        }
        Decimal duration = safeTelemetryValue(telemetry.durationMilliseconds);
        Decimal inputTokens = safeTelemetryValue(telemetry.inputTokens);
        Decimal outputTokens = safeTelemetryValue(telemetry.outputTokens);
        Decimal totalTokens = safeTelemetryValue(telemetry.totalTokens);
        if (duration != null) {
            payload.put('durationMs', duration);
        }
        if (inputTokens != null) {
            payload.put('inputTokens', inputTokens);
        }
        if (outputTokens != null) {
            payload.put('outputTokens', outputTokens);
        }
        if (totalTokens != null) {
            payload.put('totalTokens', totalTokens);
        }
        if (telemetry.tokensEstimated == true) {
            payload.put('tokensEstimated', true);
        }
    }

    private static Decimal safeTelemetryValue(Long value) {
        if (value == null || value < 0) {
            return null;
        }
        Decimal numeric = Decimal.valueOf(String.valueOf(value));
        Decimal maximum = Decimal.valueOf('999999999999999999');
        return numeric > maximum ? maximum : numeric;
    }

    private static Decimal addTelemetryValues(Decimal current, Decimal increment) {
        Decimal maximum = Decimal.valueOf('999999999999999999');
        Decimal total = valueOrZero(current) + increment;
        return total > maximum ? maximum : total;
    }

    private static String boundedIdentifier(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String sanitized = value.replace('\r', ' ').replace('\n', ' ').trim();
        return sanitized.length() > 255 ? sanitized.substring(0, 255) : sanitized;
    }

    private static void applyBudgetDecision(AgentRun__c run, AgentKernelModels.CommandOutcome outcome, AgentDefinition__c limits) {
        if (String.isBlank(outcome.runStatus)) {
            List<AgentKernelModels.CommandSpec> specs = requestedCommands(outcome);
            Integer requestedModels = 0;
            Integer requestedTools = 0;
            for (AgentKernelModels.CommandSpec spec : specs) {
                requestedModels += spec.commandType == AgentKernelModels.COMMAND_TYPE_MODEL ? 1 : 0;
                requestedTools += spec.commandType == AgentKernelModels.COMMAND_TYPE_TOOL ? 1 : 0;
            }
            String modelBudget = exhaustedModelBudget(run, limits, requestedModels);
            Boolean toolExceeded = toolCallsUsed(run) + requestedTools > limits.MaxToolCalls__c;
            if (modelBudget != null || toolExceeded) {
                String exceeded = modelBudget != null ? modelBudget : 'tool';
                outcome.runStatus = AgentKernelModels.RUN_STATUS_PAUSED;
                outcome.nextCommand = null;
                outcome.nextCommands = null;
                outcome.eventType = AgentKernelModels.EVENT_RUN_PAUSED;
                outcome.errorCode = 'BUDGET_EXCEEDED';
                outcome.errorMessage = budgetMessage(run, limits, exceeded, requestedModels, requestedTools);
                outcome.summary = (exceeded == 'token' ? 'Token' : exceeded == 'model' ? 'Model-call' : 'Tool-call') + ' budget exhausted; run paused.';
                outcome.payload = withPauseFacts(outcome.payload, budgetFacts(run, limits, exceeded, requestedModels, requestedTools));
            }
        }
    }

    /** The counts that explain a BUDGET_EXCEEDED pause, kept on its event because rescue clears the run's error. */
    private static Map<String, Object> budgetFacts(
        AgentRun__c run,
        AgentDefinition__c limits,
        String exceeded,
        Integer requestedModels,
        Integer requestedTools
    ) {
        return new Map<String, Object>{
            'errorCode' => 'BUDGET_EXCEEDED',
            'budget' => new Map<String, Object>{
                'exceeded' => exceeded,
                'modelCalls' => modelCallsUsed(run).intValue(),
                'maxModelCalls' => limits.MaxModelCalls__c.intValue(),
                'requestedModelCalls' => requestedModels,
                'toolCalls' => toolCallsUsed(run).intValue(),
                'maxToolCalls' => limits.MaxToolCalls__c.intValue(),
                'requestedToolCalls' => requestedTools,
                'tokens' => tokensUsed(run).longValue(),
                'maxTokens' => AgentConfigService.maxTotalTokens(limits),
                'perReply' => run.ReplyModelCallBase__c != null
            }
        };
    }

    /** Adds pause facts to the event's telemetry payload, keeping the telemetry when it is a JSON object. */
    private static String withPauseFacts(String payload, Map<String, Object> facts) {
        Map<String, Object> merged = new Map<String, Object>();
        if (!String.isBlank(payload)) {
            try {
                Object parsed = JSON.deserializeUntyped(payload);
                if (parsed instanceof Map<String, Object>) {
                    merged = (Map<String, Object>) parsed;
                }
            } catch (JSONException unreadable) {
                merged = new Map<String, Object>();
            }
        }
        merged.putAll(facts);
        return JSON.serialize(merged);
    }

    private static String deriveEventType(AgentKernelModels.CommandOutcome outcome) {
        if (!String.isBlank(outcome.eventType)) {
            return outcome.eventType;
        }
        if (outcome.runStatus == AgentKernelModels.RUN_STATUS_SUCCEEDED) {
            return AgentKernelModels.EVENT_RUN_COMPLETED;
        }
        if (outcome.runStatus == AgentKernelModels.RUN_STATUS_FAILED) {
            return AgentKernelModels.EVENT_RUN_FAILED;
        }
        if (outcome.runStatus == AgentKernelModels.RUN_STATUS_WAITING) {
            return outcome.commandStatus == AgentKernelModels.COMMAND_STATUS_UNKNOWN
                ? AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN
                : AgentKernelModels.EVENT_RUN_WAITING;
        }
        List<AgentKernelModels.CommandSpec> specs = requestedCommands(outcome);
        return specs[0].commandType == AgentKernelModels.COMMAND_TYPE_TOOL ? AgentKernelModels.EVENT_TOOL_REQUESTED : AgentKernelModels.EVENT_MODEL_REQUESTED;
    }

    private static void assertExpectedRevision(AgentRun__c run, Decimal expectedRevision) {
        if (expectedRevision == null || run.Revision__c != expectedRevision) {
            throw new AgentKernelException.ConcurrencyException('The run revision is stale; reload the run before retrying.');
        }
    }

    private static void assertMutable(AgentRun__c run) {
        if (
            run.Status__c == AgentKernelModels.RUN_STATUS_SUCCEEDED ||
            run.Status__c == AgentKernelModels.RUN_STATUS_FAILED ||
            run.Status__c == AgentKernelModels.RUN_STATUS_CANCELLED
        ) {
            throw new AgentKernelException.InvalidTransitionException('The run is already in a final state.');
        }
    }

    /** An Unknown command blocks resume, cancel, rescue, and approval until it is reconciled. */
    private static Boolean hasUnknownCommand(Id runId) {
        return [
                SELECT COUNT()
                FROM AgentCommand__c
                WHERE AgentRun__c = :runId AND Status__c = :AgentKernelModels.COMMAND_STATUS_UNKNOWN
                WITH SYSTEM_MODE
            ] > 0;
    }

    private static Decimal valueOrZero(Decimal value) {
        return value == null ? 0 : value;
    }

    private static Integer operationAttemptCount(AgentCommand__c command, Integer completedAttemptCount) {
        Integer completed = completedAttemptCount == null ? Integer.valueOf(valueOrZero(command.AttemptNumber__c)) : completedAttemptCount;
        Integer baseline = Integer.valueOf(valueOrZero(command.RetryWindowStartAttempt__c));
        return Math.max(0, completed - baseline);
    }

    /**
     * Budget ceilings for lifecycle transitions, read in system mode: the
     * caller may be an approver without configuration access, or the agent
     * may have been deactivated after its command ran. The next command still
     * rechecks the live definition before it runs.
     */
    private static AgentDefinition__c budgetLimits(AgentRun__c run) {
        return [
            SELECT MaxModelCalls__c, MaxToolCalls__c, MaxTotalTokens__c, TranscriptTurnLimit__c, ReplyWindowHours__c
            FROM AgentDefinition__c
            WHERE Id = :run.AgentDefinition__c
            WITH SYSTEM_MODE
            LIMIT 1
        ];
    }

    /** Whether the step after a confirmed call fits the budget: the batch's next tool, or else a model turn. */
    private static Boolean hasBudgetAfterConfirmedSuccess(AgentRun__c run, AgentCommand__c nextBatchCommand) {
        AgentDefinition__c limits = budgetLimits(run);
        return nextBatchCommand != null ? toolCallsUsed(run) + 1 <= limits.MaxToolCalls__c : exhaustedModelBudget(run, limits, 1) == null;
    }

    private static void assertCommandAdmission(AgentRun__c run, String commandType) {
        AgentDefinition__c limits = budgetLimits(run);
        String modelBudget = commandType == AgentKernelModels.COMMAND_TYPE_MODEL ? exhaustedModelBudget(run, limits, 1) : null;
        if (modelBudget == 'token') {
            throw new AgentKernelException.InvalidTransitionException('The configured token budget is exhausted; raise Max Total Tokens.');
        }
        if (modelBudget == 'model') {
            throw new AgentKernelException.InvalidTransitionException('The configured model-call budget is exhausted.');
        }
        if (commandType == AgentKernelModels.COMMAND_TYPE_TOOL && toolCallsUsed(run) + 1 > limits.MaxToolCalls__c) {
            throw new AgentKernelException.InvalidTransitionException('The configured tool-call budget is exhausted.');
        }
    }

    /**
     * Budgets count the whole run. A conversational run starts a new window at
     * each reply, so a long conversation is limited per answer, not in total.
     */
    private static void openReplyBudgetWindow(AgentRun__c run) {
        run.ReplyModelCallBase__c = valueOrZero(run.ModelCallCount__c);
        run.ReplyToolCallBase__c = valueOrZero(run.ToolCallCount__c);
        run.ReplyTokenBase__c = valueOrZero(run.TotalTokenCount__c);
    }

    private static Decimal modelCallsUsed(AgentRun__c run) {
        return valueOrZero(run.ModelCallCount__c) - valueOrZero(run.ReplyModelCallBase__c);
    }

    private static Decimal toolCallsUsed(AgentRun__c run) {
        return valueOrZero(run.ToolCallCount__c) - valueOrZero(run.ReplyToolCallBase__c);
    }

    private static Boolean tokenCeilingReached(AgentRun__c run) {
        return exhaustedModelBudget(run, budgetLimits(run), 1) == 'token';
    }

    private static Decimal tokensUsed(AgentRun__c run) {
        return valueOrZero(run.TotalTokenCount__c) - valueOrZero(run.ReplyTokenBase__c);
    }

    /** 'model' or 'token' when requesting these model calls would exceed the budget; null when they fit. */
    private static String exhaustedModelBudget(AgentRun__c run, AgentDefinition__c limits, Integer requestedModels) {
        if (modelCallsUsed(run) + requestedModels > limits.MaxModelCalls__c) {
            return 'model';
        }
        return requestedModels > 0 && tokensUsed(run) >= AgentConfigService.maxTotalTokens(limits) ? 'token' : null;
    }

    private static String budgetMessage(AgentRun__c run, AgentDefinition__c limits, String exceeded, Integer requestedModels, Integer requestedTools) {
        String scope = run.ReplyModelCallBase__c == null ? 'the run has used ' : 'this reply has used ';
        if (exceeded == 'token') {
            return 'The next step needs a model call, but ' +
                scope +
                tokensUsed(run).longValue() +
                ' of ' +
                AgentConfigService.maxTotalTokens(limits) +
                ' tokens; raise Max Total Tokens and rescue the run.';
        }
        if (exceeded == 'model') {
            return 'The next step needs ' +
                requestedModels +
                ' more model call(s), but ' +
                scope +
                modelCallsUsed(run).intValue() +
                ' of ' +
                limits.MaxModelCalls__c.intValue() +
                '; raise Max Model Calls and rescue the run.';
        }
        String toolMessage =
            'The next step needs ' +
            requestedTools +
            ' more tool call(s), but ' +
            scope +
            toolCallsUsed(run).intValue() +
            ' of ' +
            limits.MaxToolCalls__c.intValue();
        // Every tool result goes back to the model, so raising only Max Tool Calls would pause the run again at once.
        if (modelCallsUsed(run) >= limits.MaxModelCalls__c) {
            return toolMessage +
                ', and model calls are used up too (' +
                modelCallsUsed(run).intValue() +
                ' of ' +
                limits.MaxModelCalls__c.intValue() +
                '); raise Max Tool Calls and Max Model Calls and rescue the run.';
        }
        return toolMessage + '; raise Max Tool Calls and rescue the run.';
    }

    /** Records the configuration a command ran with, and a Configuration Changed event when it differs from the run's last one. */
    private static void recordConfiguration(AgentRun__c run, String configurationHash, String commandKey) {
        if (String.isBlank(configurationHash) || configurationHash == run.ConfigurationHash__c) {
            return;
        }
        if (!String.isBlank(run.ConfigurationHash__c)) {
            Map<String, Object> payload = new Map<String, Object>{ 'previousHash' => run.ConfigurationHash__c, 'currentHash' => configurationHash };
            payload.putAll(AgentRunConfigurationService.describeChange(run.Id, run.ConfigurationHash__c, configurationHash));
            String summary = payload.containsKey('changes') ? AgentConfigService.describeChanges((List<Object>) payload.get('changes')) : null;
            persistEvent(
                run,
                AgentLifecycleRecords.nextEventSequence(run),
                AgentKernelModels.EVENT_CONFIGURATION_CHANGED,
                commandKey,
                summary == null ? 'The agent configuration changed during the run.' : summary,
                JSON.serialize(payload)
            );
        }
        run.ConfigurationHash__c = configurationHash;
    }

    public static String sanitizeCode(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String sanitized = value.replaceAll('[^A-Za-z0-9_.-]', '_');
        return sanitized.length() > 80 ? sanitized.substring(0, 80) : sanitized;
    }

    public static String sanitizeError(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String sanitized = value.replace('\r', ' ').replace('\n', ' ').trim();
        return sanitized.length() > MAX_ERROR_LENGTH ? sanitized.substring(0, MAX_ERROR_LENGTH) : sanitized;
    }
}
