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
 * In-memory shaping of lifecycle records shared by AgentKernel and
 * AgentKernelRecovery: events, payload protection, waiting and retention
 * fields. It performs no DML; callers persist through AgentLifecycleStore.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentLifecycleRecords {
    /** Tool command statuses whose result the transcript replays. */
    public static final Set<String> TRANSCRIPT_TOOL_STATUSES = new Set<String>{
        AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
        AgentKernelModels.COMMAND_STATUS_FAILED,
        AgentKernelModels.COMMAND_STATUS_CANCELLED
    };

    /** Ends a command because its run was cancelled, releasing any lease. */
    public static void cancelCommand(AgentCommand__c command, String reason) {
        command.Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED;
        command.LeaseToken__c = null;
        command.LeaseExpiresAt__c = null;
        command.WorkerJobId__c = null;
        command.WorkerEnqueuedAt__c = null;
        command.ErrorCode__c = 'RUN_CANCELLED';
        command.ErrorMessage__c = reason;
    }

    /** Marks a run cancelled at cancelledAt. Callers advance the revision and record the event. */
    public static void markCancelled(AgentRun__c run, String reason, Datetime cancelledAt) {
        run.Status__c = AgentKernelModels.RUN_STATUS_CANCELLED;
        run.CurrentCommand__c = null;
        run.LastActivityAt__c = cancelledAt;
        run.CompletedAt__c = cancelledAt;
        setPurgeAfter(run);
        run.ErrorCode__c = 'RUN_CANCELLED';
        run.ErrorMessage__c = reason;
    }

    public static AgentEvent__c buildEvent(AgentRun__c run, Decimal sequence, String eventType, String commandKey, String summary, String payload) {
        String safeSummary = String.isBlank(summary) ? defaultSummary(eventType) : summary.trim();
        if (safeSummary.length() > 255) {
            safeSummary = safeSummary.substring(0, 255);
        }
        PayloadProtectionService.ProtectionResult protectedPayload = PayloadProtectionService.protect(payload, PayloadProtectionService.fromRun(run));
        return new AgentEvent__c(
            AgentRun__c = run.Id,
            Sequence__c = sequence,
            EventType__c = eventType,
            CommandKey__c = commandKey,
            OccurredAt__c = System.now(),
            Summary__c = safeSummary,
            Payload__c = protectedPayload.protectedPayload,
            PayloadHash__c = protectedPayload.payloadHash,
            PayloadProtectionMode__c = protectedPayload.mode,
            OriginalPayloadLength__c = protectedPayload.originalLength,
            PayloadTruncated__c = protectedPayload.truncated,
            PayloadRedacted__c = protectedPayload.redacted
        );
    }

    public static Decimal nextEventSequence(AgentRun__c run) {
        run.LastEventSequence__c = (run.LastEventSequence__c == null ? 0 : run.LastEventSequence__c) + 1;
        return run.LastEventSequence__c;
    }

    public static void protectRunFields(AgentRun__c run, PayloadProtectionService.Policy policy) {
        PayloadProtectionService.ProtectionResult protectedInput = PayloadProtectionService.protect(run.Input__c, policy);
        PayloadProtectionService.ProtectionResult protectedOutput = PayloadProtectionService.protectFinalOutput(run.Output__c, policy);
        run.InputHash__c = protectedInput.payloadHash;
        run.OutputHash__c = protectedOutput.payloadHash;
        run.Input__c = retainedOperationalValue(protectedInput, policy);
        run.Output__c = retainedOperationalValue(protectedOutput, policy);
    }

    /**
     * Applies the run's retention mode once. A second pass would hash the
     * already-protected value and overwrite the evidence hash.
     */
    public static void protectCommandFields(AgentCommand__c command, PayloadProtectionService.Policy policy) {
        if (command.getPopulatedFieldsAsMap().get('PayloadProtected__c') == true) {
            return;
        }
        command.PayloadProtected__c = true;
        PayloadProtectionService.ProtectionResult protectedInput = PayloadProtectionService.protect(command.Input__c, policy);
        PayloadProtectionService.ProtectionResult protectedOutput = PayloadProtectionService.protect(command.Output__c, policy);
        command.InputHash__c = protectedInput.payloadHash;
        command.OutputHash__c = protectedOutput.payloadHash;
        command.Input__c = retainedOperationalValue(protectedInput, policy);
        command.Output__c = retainedOperationalValue(protectedOutput, policy);
        // The rationale explains the input in the model's words, so it is kept only where the input is kept.
        if (policy.mode != PayloadProtectionService.MODE_FULL && policy.mode != PayloadProtectionService.MODE_REDACTED) {
            command.Rationale__c = null;
        }
    }

    public static void clearWaitingMetadata(AgentRun__c run) {
        run.WaitingReason__c = null;
        run.ResumeJsonSchema__c = null;
        run.WaitExpiresAt__c = null;
        run.ContinuationMode__c = null;
        run.WaitingCommand__c = null;
    }

    /**
     * An Unknown outcome must be reconciled before the run's payload retention
     * ends. At that deadline recovery pauses the run, without retrying, so
     * retention can clear its protected values like any paused run.
     */
    public static void setUnknownDeadline(AgentRun__c run, Datetime nowValue) {
        run.WaitExpiresAt__c = PayloadRetentionPurgeService.purgeAfter(nowValue, run.PayloadRetentionDays__c);
    }

    public static void setPurgeAfter(AgentRun__c run) {
        run.PurgeAfter__c = PayloadRetentionPurgeService.purgeAfter(run.CompletedAt__c, run.PayloadRetentionDays__c);
        run.DeleteAfter__c = PayloadRetentionPurgeService.deleteAfter(run.CompletedAt__c, run.RecordRetentionDays__c);
    }

    /** Cancels the blocked batch siblings of stopped runs, protecting their payloads; the caller persists them. */
    public static void addCancelledBlockedCommands(Set<Id> runIds, Map<Id, AgentRun__c> runsById, List<AgentCommand__c> commandsToUpdate) {
        if (runIds == null || runIds.isEmpty()) {
            return;
        }
        for (AgentCommand__c sibling : [
            SELECT Id, AgentRun__c, Status__c, Input__c, Output__c, InputHash__c, OutputHash__c
            FROM AgentCommand__c
            WHERE AgentRun__c IN :runIds AND Status__c = :AgentKernelModels.COMMAND_STATUS_BLOCKED
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            sibling.Status__c = AgentKernelModels.COMMAND_STATUS_CANCELLED;
            AgentRun__c run = runsById.get(sibling.AgentRun__c);
            if (run != null) {
                protectCommandFields(sibling, PayloadProtectionService.fromRun(run));
            }
            commandsToUpdate.add(sibling);
        }
    }

    /**
     * Newest transcript turns the model may still be sent: the definition's
     * turn limit plus the tool results of one model turn. Payload retention
     * applies to a turn only once it leaves this window or the run ends, so a
     * stricter retention mode never changes what the model sees mid-run.
     */
    public static Integer transcriptWindow(Integer turnLimit) {
        return Math.max(0, turnLimit == null ? 0 : turnLimit) + AgentKernelModels.MAX_TOOL_CALLS_PER_TURN + 1;
    }

    /**
     * Whether a command is a turn the model sees again: a finished tool call, a
     * requested call that was cancelled before it ran, or a model input that is its own turn.
     */
    public static Boolean isTranscriptTurn(AgentCommand__c command) {
        if (command == null) {
            return false;
        }
        if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
            return command.Status__c == AgentKernelModels.COMMAND_STATUS_SUCCEEDED ||
                command.Status__c == AgentKernelModels.COMMAND_STATUS_FAILED ||
                command.Status__c == AgentKernelModels.COMMAND_STATUS_CANCELLED;
        }
        return command.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL &&
            (!String.isBlank(command.InputSource__c) || command.getPopulatedFieldsAsMap().get('AnswerTurn__c') == true);
    }

    /** Protects the transcript commands loaded with a terminal run; the caller persists them. */
    public static void addRetainedTranscript(AgentRun__c run, List<AgentCommand__c> commandsToUpdate) {
        if (run == null || run.Commands__r == null) {
            return;
        }
        PayloadProtectionService.Policy policy = PayloadProtectionService.fromRun(run);
        for (AgentCommand__c transcriptCommand : run.Commands__r) {
            protectCommandFields(transcriptCommand, policy);
            commandsToUpdate.add(transcriptCommand);
        }
    }

    private static String retainedOperationalValue(PayloadProtectionService.ProtectionResult protectedValue, PayloadProtectionService.Policy policy) {
        return policy.mode == PayloadProtectionService.MODE_FULL ||
            policy.mode == PayloadProtectionService.MODE_REDACTED
            ? protectedValue.protectedPayload
            : null;
    }

    private static String defaultSummary(String eventType) {
        return String.isBlank(eventType) ? 'Agent event recorded.' : eventType + ' recorded.';
    }
}
