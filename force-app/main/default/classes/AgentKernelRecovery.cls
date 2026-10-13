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
 * Recovery transitions for stale leases and intentional-wait expiry.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentKernelRecovery {
    public static AgentKernel.StaleLeaseRecoveryResult recoverStaleLeases(List<Id> requestedCommandIds, Datetime recoveryTime) {
        return recoverStaleLeases(requestedCommandIds, recoveryTime, null);
    }

    public static AgentKernel.StaleLeaseRecoveryResult recoverStaleLeases(
        List<Id> requestedCommandIds,
        Datetime recoveryTime,
        Map<Id, CommandDeliveryTracker.JobState> resolvedJobStates
    ) {
        AgentKernel.StaleLeaseRecoveryResult result = new AgentKernel.StaleLeaseRecoveryResult();
        if (requestedCommandIds == null || requestedCommandIds.isEmpty()) {
            return result;
        }
        Datetime nowValue = recoveryTime == null ? System.now() : recoveryTime;
        Set<Id> commandIds = new Set<Id>();
        for (Id commandId : requestedCommandIds) {
            if (commandId == null || commandIds.contains(commandId) || result.deferredCommandIds.contains(commandId)) {
                continue;
            }
            if (commandIds.size() < CommandDispatcher.MAXIMUM_BATCH_SIZE) {
                commandIds.add(commandId);
            } else {
                result.deferredCommandIds.add(commandId);
            }
        }
        List<AgentCommand__c> references = [SELECT Id, AgentRun__c FROM AgentCommand__c WHERE Id IN :commandIds WITH SYSTEM_MODE];
        Set<Id> runIds = new Set<Id>();
        for (AgentCommand__c reference : references) {
            runIds.add(reference.AgentRun__c);
        }
        // One query for every run's execution policy, instead of one per recovered command.
        AgentRunConfigurationService.preload(runIds);
        Map<Id, AgentRun__c> runsById = new Map<Id, AgentRun__c>(
            [
                SELECT
                    Id,
                    AgentDefinition__c,
                    Status__c,
                    Revision__c,
                    LastEventSequence__c,
                    CurrentCommand__c,
                    ModelCallCount__c,
                    ToolCallCount__c,
                    RetryCount__c,
                    PayloadRetentionMode__c,
                    PayloadRetentionDays__c,
                    RecordRetentionDays__c,
                    RetainedPayloadCharacters__c,
                    SensitiveJsonKeys__c,
                    LastActivityAt__c,
                    CompletedAt__c,
                    CancellationRequestedAt__c,
                    CancellationReason__c,
                    ErrorCode__c,
                    ErrorMessage__c,
                    Input__c,
                    Output__c,
                    InputHash__c,
                    OutputHash__c,
                    (
                        SELECT Id, Input__c, Output__c, InputHash__c, OutputHash__c, PayloadProtected__c
                        FROM Commands__r
                        WHERE
                            PayloadProtected__c = FALSE
                            AND ((CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                            AND Status__c IN :AgentLifecycleRecords.TRANSCRIPT_TOOL_STATUSES)
                            OR (CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL
                            AND (InputSource__c != NULL
                            OR AnswerTurn__c = TRUE)))
                        ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC, Id DESC
                        LIMIT 60
                    )
                FROM AgentRun__c
                WHERE Id IN :runIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                LeaseToken__c,
                LeaseExpiresAt__c,
                RecoveryCheckAt__c,
                AdmittedEffects__c,
                AdmittedToolBindingHash__c,
                WorkerJobId__c,
                WorkerEnqueuedAt__c,
                AvailableAt__c,
                AttemptNumber__c,
                RetryWindowStartAttempt__c,
                ToolName__c,
                ErrorCode__c,
                ErrorMessage__c,
                Input__c,
                Output__c,
                InputHash__c,
                OutputHash__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        Map<Id, CommandDeliveryTracker.JobState> jobStates = resolvedJobStates == null ? CommandDeliveryTracker.resolveCommands(commands) : resolvedJobStates;
        List<AgentCommand__c> commandsToUpdate = new List<AgentCommand__c>();
        List<AgentRun__c> runsToUpdate = new List<AgentRun__c>();
        List<AgentEvent__c> eventsToInsert = new List<AgentEvent__c>();
        List<AgentLifecyclePublisher.Notification> notifications = new List<AgentLifecyclePublisher.Notification>();
        Set<Id> stoppedRunIds = new Set<Id>();
        for (AgentCommand__c command : commands) {
            AgentRun__c run = runsById.get(command.AgentRun__c);
            if (
                run == null ||
                run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
                run.CurrentCommand__c != command.Id ||
                command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED ||
                command.ExpectedRunRevision__c != run.Revision__c ||
                command.LeaseExpiresAt__c == null ||
                command.LeaseExpiresAt__c > nowValue
            ) {
                result.skipped++;
                result.skippedCommandIds.add(command.Id);
                continue;
            }
            if (jobStates.get(command.Id) == CommandDeliveryTracker.JobState.Active) {
                AgentOperationsLog.emit(LoggingLevel.WARN, 'RECOVERY_ACTIVE_WORKER_SKIPPED', command.AgentRun__c, command.Id, null, command.OperationKey__c);
                result.skipped++;
                result.skippedCommandIds.add(command.Id);
                continue;
            }
            command.WorkerJobId__c = null;
            command.WorkerEnqueuedAt__c = null;
            if (run.CancellationRequestedAt__c != null && isRecoverySafe(command)) {
                AgentLifecycleRecords.cancelCommand(command, run.CancellationReason__c);
                run.Revision__c = valueOrZero(run.Revision__c) + 1;
                AgentLifecycleRecords.markCancelled(run, run.CancellationReason__c, nowValue);
                Decimal sequence = AgentLifecycleRecords.nextEventSequence(run);
                eventsToInsert.add(
                    AgentLifecycleRecords.buildEvent(
                        run,
                        sequence,
                        AgentKernelModels.EVENT_RUN_CANCELLED,
                        command.OperationKey__c,
                        'Cancellation completed after lease expiry.',
                        null
                    )
                );
                AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
                notification.run = run;
                notification.transition = 'Cancelled';
                notification.sequence = sequence;
                notification.operationKey = command.OperationKey__c;
                notifications.add(notification);
                AgentLifecycleRecords.protectRunFields(run, PayloadProtectionService.fromRun(run));
                AgentLifecycleRecords.protectCommandFields(command, PayloadProtectionService.fromRun(run));
                AgentLifecycleRecords.addRetainedTranscript(run, commandsToUpdate);
                commandsToUpdate.add(command);
                runsToUpdate.add(run);
                stoppedRunIds.add(run.Id);
                result.cancelled++;
                continue;
            }
            if (run.CancellationRequestedAt__c == null && isRecoverySafe(command)) {
                recordCompletedCall(run, command.CommandType__c);
                Integer operationAttemptCount = Math.max(
                    0,
                    Integer.valueOf(valueOrZero(command.AttemptNumber__c) - valueOrZero(command.RetryWindowStartAttempt__c))
                );
                AgentExecutionPolicyService.Policy policy = AgentRunConfigurationService.getExecutionPolicy(run.Id);
                Boolean retryBudgetExhausted = operationAttemptCount > valueOrZero(policy.maxRetries);
                command.LeaseToken__c = null;
                command.LeaseExpiresAt__c = null;
                command.WorkerJobId__c = null;
                command.WorkerEnqueuedAt__c = null;
                run.Revision__c = valueOrZero(run.Revision__c) + 1;
                run.LastActivityAt__c = nowValue;
                if (retryBudgetExhausted) {
                    command.Status__c = AgentKernelModels.COMMAND_STATUS_FAILED;
                    command.ExpectedRunRevision__c = run.Revision__c;
                    command.ErrorCode__c = 'RETRY_EXHAUSTED';
                    command.ErrorMessage__c = 'The retry budget was exhausted while recovering a stale lease.';
                    run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
                    run.CurrentCommand__c = command.Id;
                    run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(nowValue, run.PayloadRetentionDays__c);
                    run.ErrorCode__c = command.ErrorCode__c;
                    run.ErrorMessage__c = command.ErrorMessage__c;
                    Decimal pausedSequence = AgentLifecycleRecords.nextEventSequence(run);
                    eventsToInsert.add(
                        AgentLifecycleRecords.buildEvent(
                            run,
                            pausedSequence,
                            AgentKernelModels.EVENT_RUN_PAUSED,
                            command.OperationKey__c,
                            'Stale lease recovery exhausted the operation budget; run paused.',
                            null
                        )
                    );
                    AgentLifecyclePublisher.Notification pausedNotification = new AgentLifecyclePublisher.Notification();
                    pausedNotification.run = run;
                    pausedNotification.transition = 'Paused';
                    pausedNotification.sequence = pausedSequence;
                    pausedNotification.operationKey = command.OperationKey__c;
                    notifications.add(pausedNotification);
                    stoppedRunIds.add(run.Id);
                    result.paused++;
                } else {
                    command.Status__c = AgentKernelModels.COMMAND_STATUS_PENDING;
                    command.ExpectedRunRevision__c = run.Revision__c;
                    command.AvailableAt__c = nowValue;
                    command.ErrorCode__c = 'STALE_LEASE_RETRY';
                    command.ErrorMessage__c = 'A retry-safe stale lease was recovered for another attempt.';
                    run.RetryCount__c = valueOrZero(run.RetryCount__c) + 1;
                    run.ErrorCode__c = command.ErrorCode__c;
                    run.ErrorMessage__c = command.ErrorMessage__c;
                    Decimal retrySequence = AgentLifecycleRecords.nextEventSequence(run);
                    eventsToInsert.add(
                        AgentLifecycleRecords.buildEvent(
                            run,
                            retrySequence,
                            AgentKernelModels.EVENT_COMMAND_RETRY_SCHEDULED,
                            command.OperationKey__c,
                            'Retry-safe stale lease recovered.',
                            null
                        )
                    );
                    result.requeuedCommandIds.add(command.Id);
                }
                commandsToUpdate.add(command);
                runsToUpdate.add(run);
                continue;
            }
            command.Status__c = AgentKernelModels.COMMAND_STATUS_UNKNOWN;
            command.LeaseToken__c = null;
            command.LeaseExpiresAt__c = null;
            command.WorkerJobId__c = null;
            command.WorkerEnqueuedAt__c = null;
            command.ErrorCode__c = 'STALE_LEASE_OUTCOME_UNKNOWN';
            command.ErrorMessage__c = 'A stale lease of a tool with external effects requires outcome reconciliation.';
            run.ToolCallCount__c = valueOrZero(run.ToolCallCount__c) + 1;
            run.Status__c = AgentKernelModels.RUN_STATUS_WAITING;
            AgentLifecycleRecords.setUnknownDeadline(run, nowValue);
            run.Revision__c = valueOrZero(run.Revision__c) + 1;
            run.CurrentCommand__c = null;
            run.LastActivityAt__c = nowValue;
            run.ErrorCode__c = command.ErrorCode__c;
            run.ErrorMessage__c = command.ErrorMessage__c;
            Decimal sequence = AgentLifecycleRecords.nextEventSequence(run);
            eventsToInsert.add(
                AgentLifecycleRecords.buildEvent(
                    run,
                    sequence,
                    AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN,
                    command.OperationKey__c,
                    'Stale tool lease outcome is unknown.',
                    null
                )
            );
            AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
            notification.run = run;
            notification.transition = 'Waiting';
            notification.sequence = sequence;
            notification.operationKey = command.OperationKey__c;
            notifications.add(notification);
            commandsToUpdate.add(command);
            runsToUpdate.add(run);
            result.unknown++;
        }
        AgentLifecycleRecords.addCancelledBlockedCommands(stoppedRunIds, runsById, commandsToUpdate);
        persistLifecycle(commandsToUpdate, eventsToInsert, runsToUpdate);
        AgentLifecyclePublisher.publishBatch(notifications);
        return result;
    }

    /**
     * Ends runs without an identity whose next command was never picked up by the
     * starting user's job chain. Only Pending and Retry Waiting commands are
     * ended, so no tool effect is left unproven.
     */
    public static Integer endLostInitiatingUserChains(List<Id> commandIds, Datetime recoveryTime) {
        if (commandIds == null || commandIds.isEmpty()) {
            return 0;
        }
        Datetime nowValue = recoveryTime == null ? System.now() : recoveryTime;
        Set<String> dispatchable = new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING };
        Set<Id> runIds = new Set<Id>();
        for (AgentCommand__c reference : [SELECT AgentRun__c FROM AgentCommand__c WHERE Id IN :commandIds WITH SYSTEM_MODE]) {
            runIds.add(reference.AgentRun__c);
        }
        Map<Id, AgentRun__c> runsById = new Map<Id, AgentRun__c>(
            [
                SELECT
                    Id,
                    AgentDefinition__c,
                    Status__c,
                    ExecutionIdentity__c,
                    Revision__c,
                    LastEventSequence__c,
                    CurrentCommand__c,
                    PayloadRetentionMode__c,
                    PayloadRetentionDays__c,
                    RecordRetentionDays__c,
                    RetainedPayloadCharacters__c,
                    SensitiveJsonKeys__c,
                    LastActivityAt__c,
                    CompletedAt__c,
                    CancellationRequestedAt__c,
                    CancellationReason__c,
                    ErrorCode__c,
                    ErrorMessage__c,
                    Input__c,
                    Output__c,
                    InputHash__c,
                    OutputHash__c,
                    (
                        SELECT Id, Input__c, Output__c, InputHash__c, OutputHash__c, PayloadProtected__c
                        FROM Commands__r
                        WHERE
                            PayloadProtected__c = FALSE
                            AND ((CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                            AND Status__c IN :AgentLifecycleRecords.TRANSCRIPT_TOOL_STATUSES)
                            OR (CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL
                            AND (InputSource__c != NULL
                            OR AnswerTurn__c = TRUE)))
                        ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC, Id DESC
                        LIMIT 60
                    )
                FROM AgentRun__c
                WHERE Id IN :runIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        List<AgentCommand__c> commandsToUpdate = new List<AgentCommand__c>();
        List<AgentRun__c> runsToUpdate = new List<AgentRun__c>();
        List<AgentEvent__c> eventsToInsert = new List<AgentEvent__c>();
        List<AgentLifecyclePublisher.Notification> notifications = new List<AgentLifecyclePublisher.Notification>();
        Set<Id> stoppedRunIds = new Set<Id>();
        for (AgentCommand__c command : [
            SELECT Id, AgentRun__c, Status__c, ExpectedRunRevision__c, OperationKey__c, Input__c, Output__c, InputHash__c, OutputHash__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            AgentRun__c run = runsById.get(command.AgentRun__c);
            if (
                run == null ||
                stoppedRunIds.contains(run.Id) ||
                run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
                ExecutionIdentityService.usesIdentity(run) ||
                run.CurrentCommand__c != command.Id ||
                command.ExpectedRunRevision__c != run.Revision__c ||
                !dispatchable.contains(command.Status__c)
            ) {
                continue;
            }
            Boolean cancelled = run.CancellationRequestedAt__c != null;
            command.Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED;
            command.ErrorCode__c = cancelled ? 'RUN_CANCELLED' : 'INITIATING_USER_CHAIN_LOST';
            command.ErrorMessage__c = cancelled ? run.CancellationReason__c : 'The starting user\'s job chain ended before this command ran; start a new run.';
            run.Status__c = cancelled ? AgentKernelModels.RUN_STATUS_CANCELLED : AgentKernelModels.RUN_STATUS_FAILED;
            run.Revision__c = valueOrZero(run.Revision__c) + 1;
            run.CurrentCommand__c = null;
            run.LastActivityAt__c = nowValue;
            run.CompletedAt__c = nowValue;
            AgentLifecycleRecords.setPurgeAfter(run);
            run.ErrorCode__c = command.ErrorCode__c;
            run.ErrorMessage__c = command.ErrorMessage__c;
            String eventType = cancelled ? AgentKernelModels.EVENT_RUN_CANCELLED : AgentKernelModels.EVENT_RUN_FAILED;
            Decimal sequence = AgentLifecycleRecords.nextEventSequence(run);
            eventsToInsert.add(
                AgentLifecycleRecords.buildEvent(
                    run,
                    sequence,
                    eventType,
                    command.OperationKey__c,
                    cancelled ? 'Cancellation completed after the job chain ended.' : 'The starting user\'s job chain ended; run failed.',
                    null
                )
            );
            AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
            notification.run = run;
            notification.transition = cancelled ? 'Cancelled' : 'Failed';
            notification.sequence = sequence;
            notification.operationKey = command.OperationKey__c;
            notifications.add(notification);
            PayloadProtectionService.Policy policy = PayloadProtectionService.fromRun(run);
            AgentLifecycleRecords.protectRunFields(run, policy);
            AgentLifecycleRecords.protectCommandFields(command, policy);
            AgentLifecycleRecords.addRetainedTranscript(run, commandsToUpdate);
            commandsToUpdate.add(command);
            runsToUpdate.add(run);
            stoppedRunIds.add(run.Id);
        }
        AgentLifecycleRecords.addCancelledBlockedCommands(stoppedRunIds, runsById, commandsToUpdate);
        persistLifecycle(commandsToUpdate, eventsToInsert, runsToUpdate);
        AgentLifecyclePublisher.publishBatch(notifications);
        return stoppedRunIds.size();
    }

    public static AgentKernel.IntentionalWaitExpiryResult expireIntentionalWaits(Map<Id, Decimal> intentionalWaitRevisions, Datetime recoveryTime) {
        AgentKernel.IntentionalWaitExpiryResult result = new AgentKernel.IntentionalWaitExpiryResult();
        Map<Id, Decimal> waitCandidates = intentionalWaitRevisions == null ? new Map<Id, Decimal>() : intentionalWaitRevisions;
        Set<Id> runIds = new Set<Id>();
        runIds.addAll(waitCandidates.keySet());
        if (runIds.isEmpty()) {
            return result;
        }
        Datetime nowValue = recoveryTime == null ? System.now() : recoveryTime;
        Map<Id, AgentRun__c> runsById = new Map<Id, AgentRun__c>(
            [
                SELECT
                    Id,
                    AgentDefinition__c,
                    Status__c,
                    Revision__c,
                    LastEventSequence__c,
                    CurrentCommand__c,
                    Input__c,
                    Output__c,
                    InputHash__c,
                    OutputHash__c,
                    PayloadRetentionMode__c,
                    PayloadRetentionDays__c,
                    RecordRetentionDays__c,
                    RetainedPayloadCharacters__c,
                    SensitiveJsonKeys__c,
                    WaitingReason__c,
                    ResumeJsonSchema__c,
                    WaitExpiresAt__c,
                    ContinuationMode__c,
                    WaitingCommand__c,
                    LastActivityAt__c,
                    ErrorCode__c,
                    ErrorMessage__c,
                    (
                        SELECT Id, Input__c, Output__c, InputHash__c, OutputHash__c, PayloadProtected__c
                        FROM Commands__r
                        WHERE
                            PayloadProtected__c = FALSE
                            AND ((CommandType__c = :AgentKernelModels.COMMAND_TYPE_TOOL
                            AND Status__c IN :AgentLifecycleRecords.TRANSCRIPT_TOOL_STATUSES)
                            OR (CommandType__c = :AgentKernelModels.COMMAND_TYPE_MODEL
                            AND (InputSource__c != NULL
                            OR AnswerTurn__c = TRUE)))
                        ORDER BY Sequence__c DESC NULLS LAST, CreatedDate DESC, Id DESC
                        LIMIT 60
                    )
                FROM AgentRun__c
                WHERE Id IN :runIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        Set<Id> commandIds = new Set<Id>();
        for (AgentRun__c run : runsById.values()) {
            if (run.CurrentCommand__c != null) {
                commandIds.add(run.CurrentCommand__c);
            }
            if (run.WaitingCommand__c != null) {
                commandIds.add(run.WaitingCommand__c);
            }
        }
        Map<Id, AgentCommand__c> commandsById = new Map<Id, AgentCommand__c>(
            [
                SELECT
                    Id,
                    AgentRun__c,
                    Status__c,
                    ExpectedRunRevision__c,
                    OperationKey__c,
                    LeaseToken__c,
                    LeaseExpiresAt__c,
                    Input__c,
                    Output__c,
                    InputHash__c,
                    OutputHash__c
                FROM AgentCommand__c
                WHERE Id IN :commandIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        Set<Id> approvalCommandIds = new Set<Id>();
        for (AgentRun__c run : runsById.values()) {
            if (run.ContinuationMode__c == AgentKernelModels.CONTINUATION_REINVOKE_TOOL && run.WaitingCommand__c != null) {
                approvalCommandIds.add(run.WaitingCommand__c);
            }
        }
        Map<Id, AgentApproval__c> approvalsByCommand = AgentApprovalService.pendingByCommand(approvalCommandIds);
        List<AgentApproval__c> expiredApprovals = new List<AgentApproval__c>();
        List<AgentCommand__c> commandsToUpdate = new List<AgentCommand__c>();
        List<AgentRun__c> runsToUpdate = new List<AgentRun__c>();
        List<AgentEvent__c> eventsToInsert = new List<AgentEvent__c>();
        List<AgentLifecyclePublisher.Notification> notifications = new List<AgentLifecyclePublisher.Notification>();
        Set<Id> pausedRunIds = new Set<Id>();
        for (Id runId : runIds) {
            AgentRun__c run = runsById.get(runId);
            AgentCommand__c command;
            command = run == null || run.WaitingCommand__c == null ? null : commandsById.get(run.WaitingCommand__c);
            if (
                run == null ||
                run.Status__c != AgentKernelModels.RUN_STATUS_WAITING ||
                run.Revision__c != waitCandidates.get(runId) ||
                run.WaitExpiresAt__c == null ||
                run.WaitExpiresAt__c > nowValue ||
                (run.WaitingCommand__c != null &&
                command == null)
            ) {
                result.skipped++;
                continue;
            }
            if (String.isBlank(run.ContinuationMode__c)) {
                // An Unknown outcome nobody reconciled in time. Pausing never retries the call; the
                // Unknown command stays for reconciliation, and retention may now clear the data.
                AgentKernel.pauseAfterFault(
                    run,
                    nowValue,
                    UNKNOWN_UNRESOLVED,
                    'Nobody reconciled the tool call with an unknown outcome before its deadline. Check the outside system and reconcile it, or cancel the run.',
                    null
                );
                AgentLifecycleRecords.clearWaitingMetadata(run);
                run.PurgeAfter__c = nowValue;
                Decimal unresolvedSequence = AgentLifecycleRecords.nextEventSequence(run);
                eventsToInsert.add(
                    AgentLifecycleRecords.buildEvent(
                        run,
                        unresolvedSequence,
                        AgentKernelModels.EVENT_WAIT_EXPIRED,
                        null,
                        'Unknown outcome not reconciled before its deadline; run paused.',
                        null
                    )
                );
                AgentLifecyclePublisher.Notification unresolved = new AgentLifecyclePublisher.Notification();
                unresolved.run = run;
                unresolved.transition = 'Paused';
                unresolved.sequence = unresolvedSequence;
                notifications.add(unresolved);
                runsToUpdate.add(run);
                result.expired++;
                continue;
            }
            if (run.ContinuationMode__c == AgentKernelModels.CONTINUATION_CONVERSATION) {
                // Nobody replied in time: the conversation is over and its last answer stands.
                AgentLifecycleRecords.clearWaitingMetadata(run);
                run.Status__c = AgentKernelModels.RUN_STATUS_SUCCEEDED;
                run.Revision__c = valueOrZero(run.Revision__c) + 1;
                run.LastActivityAt__c = nowValue;
                run.CompletedAt__c = nowValue;
                run.ErrorCode__c = null;
                run.ErrorMessage__c = null;
                AgentLifecycleRecords.setPurgeAfter(run);
                Decimal completedSequence = AgentLifecycleRecords.nextEventSequence(run);
                eventsToInsert.add(
                    AgentLifecycleRecords.buildEvent(
                        run,
                        completedSequence,
                        AgentKernelModels.EVENT_RUN_COMPLETED,
                        null,
                        'Conversation ended: no reply before the reply window closed.',
                        null
                    )
                );
                AgentLifecyclePublisher.Notification completion = new AgentLifecyclePublisher.Notification();
                completion.run = run;
                completion.transition = 'Succeeded';
                completion.sequence = completedSequence;
                notifications.add(completion);
                AgentLifecycleRecords.protectRunFields(run, PayloadProtectionService.fromRun(run));
                AgentLifecycleRecords.addRetainedTranscript(run, commandsToUpdate);
                runsToUpdate.add(run);
                result.expired++;
                continue;
            }
            AgentApproval__c approval = command == null ? null : approvalsByCommand.get(command.Id);
            if (approval != null && approval.ExpiryAction__c == AgentKernelModels.APPROVAL_EXPIRY_DENY) {
                result.approvalDenials.put(run.Id, run.Revision__c);
                continue;
            }
            if (approval != null) {
                expiredApprovals.add(approval);
            }
            String errorCode = 'WAIT_EXPIRED';
            String errorMessage = 'The intentional wait expired before it was resumed.';
            if (command != null && command.Status__c == AgentKernelModels.COMMAND_STATUS_WAITING) {
                command.Status__c = AgentKernelModels.COMMAND_STATUS_FAILED;
                command.ErrorCode__c = errorCode;
                command.ErrorMessage__c = errorMessage;
                // A failed tool call stays a replayable transcript turn until the run ends.
                commandsToUpdate.add(command);
            }
            AgentLifecycleRecords.clearWaitingMetadata(run);
            AgentKernel.pauseAfterFault(run, nowValue, errorCode, errorMessage, null);
            Decimal sequence = AgentLifecycleRecords.nextEventSequence(run);
            String operationKey = command == null ? null : command.OperationKey__c;
            eventsToInsert.add(
                AgentLifecycleRecords.buildEvent(run, sequence, AgentKernelModels.EVENT_WAIT_EXPIRED, operationKey, 'Intentional wait expired.', null)
            );
            AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
            notification.run = run;
            notification.transition = 'Paused';
            notification.sequence = sequence;
            notification.operationKey = operationKey;
            notifications.add(notification);
            pausedRunIds.add(run.Id);
            runsToUpdate.add(run);
            result.expired++;
        }
        AgentLifecycleRecords.addCancelledBlockedCommands(pausedRunIds, runsById, commandsToUpdate);
        persistLifecycle(commandsToUpdate, eventsToInsert, runsToUpdate);
        AgentApprovalService.closeAll(expiredApprovals, AgentKernelModels.APPROVAL_STATUS_EXPIRED);
        AgentLifecyclePublisher.publishBatch(notifications);
        return result;
    }

    public static final String DISPATCH_UNDELIVERABLE = 'DISPATCH_UNDELIVERABLE';
    public static final String UNKNOWN_UNRESOLVED = 'UNKNOWN_UNRESOLVED';

    /**
     * Pauses Running runs whose queued command scheduled recovery redispatched
     * several times without the execution user ever picking it up. The command
     * never started, so it stays queued and rescue re-arms it once the identity
     * is fixed. Returns the number of runs paused.
     */
    public static Integer pauseUndeliverableCommands(List<Id> commandIds, Datetime recoveryTime) {
        if (commandIds == null || commandIds.isEmpty()) {
            return 0;
        }
        Datetime nowValue = recoveryTime == null ? System.now() : recoveryTime;
        Set<String> dispatchable = new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING };
        Set<Id> runIds = new Set<Id>();
        for (AgentCommand__c reference : [SELECT AgentRun__c FROM AgentCommand__c WHERE Id IN :commandIds WITH SYSTEM_MODE]) {
            runIds.add(reference.AgentRun__c);
        }
        Map<Id, AgentRun__c> runsById = new Map<Id, AgentRun__c>(
            [
                SELECT
                    Id,
                    AgentDefinition__c,
                    Status__c,
                    Revision__c,
                    LastEventSequence__c,
                    CurrentCommand__c,
                    PayloadRetentionMode__c,
                    PayloadRetentionDays__c,
                    RecordRetentionDays__c,
                    RetainedPayloadCharacters__c,
                    SensitiveJsonKeys__c,
                    LastActivityAt__c,
                    CancellationRequestedAt__c,
                    ErrorCode__c,
                    ErrorMessage__c
                FROM AgentRun__c
                WHERE Id IN :runIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        List<AgentCommand__c> commandsToUpdate = new List<AgentCommand__c>();
        List<AgentRun__c> runsToUpdate = new List<AgentRun__c>();
        List<AgentEvent__c> eventsToInsert = new List<AgentEvent__c>();
        List<AgentLifecyclePublisher.Notification> notifications = new List<AgentLifecyclePublisher.Notification>();
        for (AgentCommand__c command : [
            SELECT Id, AgentRun__c, Status__c, ExpectedRunRevision__c, OperationKey__c, RedispatchCount__c, DeliveryAnomalyCode__c
            FROM AgentCommand__c
            WHERE Id IN :commandIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            AgentRun__c run = runsById.get(command.AgentRun__c);
            if (
                run == null ||
                run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
                run.CancellationRequestedAt__c != null ||
                run.CurrentCommand__c != command.Id ||
                command.ExpectedRunRevision__c != run.Revision__c ||
                !dispatchable.contains(command.Status__c)
            ) {
                continue;
            }
            run.Status__c = AgentKernelModels.RUN_STATUS_PAUSED;
            run.Revision__c = valueOrZero(run.Revision__c) + 1;
            run.LastActivityAt__c = nowValue;
            run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(nowValue, run.PayloadRetentionDays__c);
            run.ErrorCode__c = DISPATCH_UNDELIVERABLE;
            run.ErrorMessage__c =
                'The next step never reached the execution user after ' +
                valueOrZero(command.RedispatchCount__c).intValue() +
                ' redispatches' +
                (String.isBlank(command.DeliveryAnomalyCode__c) ? '' : ' (last problem: ' + command.DeliveryAnomalyCode__c + ')') +
                '. Check the Agent Execution Identity: its user is active, its Named Credential signs in as that user, and the person or schedule that dispatches it may use the credential. Then rescue the run.';
            command.ExpectedRunRevision__c = run.Revision__c;
            Decimal sequence = AgentLifecycleRecords.nextEventSequence(run);
            eventsToInsert.add(
                AgentLifecycleRecords.buildEvent(
                    run,
                    sequence,
                    AgentKernelModels.EVENT_RUN_PAUSED,
                    command.OperationKey__c,
                    'The next step could not be delivered to the execution user; run paused.',
                    JSON.serialize(new Map<String, Object>{ 'errorCode' => DISPATCH_UNDELIVERABLE, 'redispatchCount' => command.RedispatchCount__c })
                )
            );
            AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
            notification.run = run;
            notification.transition = 'Paused';
            notification.sequence = sequence;
            notification.operationKey = command.OperationKey__c;
            notifications.add(notification);
            commandsToUpdate.add(new AgentCommand__c(Id = command.Id, ExpectedRunRevision__c = command.ExpectedRunRevision__c));
            runsToUpdate.add(run);
        }
        persistLifecycle(commandsToUpdate, eventsToInsert, runsToUpdate);
        AgentLifecyclePublisher.publishBatch(notifications);
        return runsToUpdate.size();
    }

    private static void persistLifecycle(List<AgentCommand__c> commands, List<AgentEvent__c> events, List<AgentRun__c> runs) {
        Savepoint unitOfWork = Database.setSavepoint();
        try {
            AgentLifecycleStore.updateCommands(commands);
            AgentLifecycleStore.insertEvents(events);
            AgentLifecycleStore.updateRuns(runs);
            Database.releaseSavepoint(unitOfWork);
            for (AgentEvent__c event : events) {
                LoggingLevel level = new Set<String>{
                            AgentKernelModels.EVENT_RUN_PAUSED,
                            AgentKernelModels.EVENT_RUN_FAILED,
                            AgentKernelModels.EVENT_WAIT_EXPIRED,
                            AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN
                        }
                        .contains(event.EventType__c)
                    ? LoggingLevel.WARN
                    : LoggingLevel.INFO;
                AgentOperationsLog.emit(level, event.EventType__c, event.AgentRun__c, null, null, event.CommandKey__c);
            }
        } catch (Exception failure) {
            Database.rollback(unitOfWork);
            Database.releaseSavepoint(unitOfWork);
            throw failure;
        }
    }

    /** Whether a lost attempt of this command left nothing behind, so it may run again. */
    public static Boolean isRecoverySafe(AgentCommand__c command) {
        if (command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL) {
            return true;
        }
        return AgentToolTypeService.isRetrySafe(command);
    }

    private static void recordCompletedCall(AgentRun__c run, String commandType) {
        if (commandType == AgentKernelModels.COMMAND_TYPE_MODEL) {
            run.ModelCallCount__c = valueOrZero(run.ModelCallCount__c) + 1;
        } else if (commandType == AgentKernelModels.COMMAND_TYPE_TOOL) {
            run.ToolCallCount__c = valueOrZero(run.ToolCallCount__c) + 1;
        }
    }

    private static Decimal valueOrZero(Decimal value) {
        return value == null ? 0 : value;
    }
}
