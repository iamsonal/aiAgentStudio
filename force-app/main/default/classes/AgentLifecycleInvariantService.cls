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

/** Universal record invariants; AgentKernel remains the transition decision maker. */
public inherited sharing class AgentLifecycleInvariantService {
    /**
     * A queued command is due for dispatch a grace period after it becomes
     * available. The due time is set when the command is queued (or re-armed
     * with a new available time) and otherwise kept, so recovery can push it
     * back between redispatches.
     */
    public static void prepareCommands(List<AgentCommand__c> commands, Map<Id, AgentCommand__c> previousById) {
        for (AgentCommand__c command : commands) {
            AgentCommand__c previous = previousById == null ? null : previousById.get(command.Id);
            if (command.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED && command.RecoveryCheckAt__c == null) {
                command.RecoveryCheckAt__c = command.LeaseExpiresAt__c;
            } else if (command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED) {
                command.RecoveryCheckAt__c = null;
            }
            if (command.Status__c == AgentKernelModels.COMMAND_STATUS_PENDING || command.Status__c == AgentKernelModels.COMMAND_STATUS_RETRY_WAITING) {
                Boolean queuedAgain =
                    previous == null ||
                    previous.Status__c != command.Status__c ||
                    previous.AvailableAt__c != command.AvailableAt__c ||
                    command.DispatchDueAt__c == null;
                if (queuedAgain) {
                    Datetime availableAt = command.AvailableAt__c == null ? System.now() : command.AvailableAt__c;
                    command.DispatchDueAt__c = availableAt.addSeconds(CommandLeaseRecoveryService.ORPHAN_GRACE_SECONDS);
                    command.RedispatchCount__c = 0;
                }
            } else {
                command.DispatchDueAt__c = null;
                command.RedispatchCount__c = null;
            }
        }
    }

    public static void guardRuns(Map<Id, AgentRun__c> previousById, List<AgentRun__c> nextRuns) {
        for (AgentRun__c nextRun : nextRuns) {
            AgentRun__c previous = previousById.get(nextRun.Id);
            Decimal oldRevision = previous.Revision__c == null ? 0 : previous.Revision__c;
            Decimal newRevision = nextRun.Revision__c == null ? 0 : nextRun.Revision__c;
            Boolean statusChanged = previous.Status__c != nextRun.Status__c;
            Boolean commandChanged = previous.CurrentCommand__c != nextRun.CurrentCommand__c;
            Boolean terminal = isTerminalRun(previous.Status__c);
            if (newRevision < oldRevision || newRevision > oldRevision + 1 || ((statusChanged || commandChanged) && newRevision != oldRevision + 1)) {
                nextRun.addError('Run lifecycle changes require exactly one revision advance.');
            }
            if (
                (nextRun.CommandSequence__c == null ? 0 : nextRun.CommandSequence__c) < (previous.CommandSequence__c == null ? 0 : previous.CommandSequence__c)
            ) {
                nextRun.addError('Command sequence cannot move backward.');
            }
            if (terminal && (statusChanged || commandChanged || newRevision != oldRevision)) {
                nextRun.addError('A terminal run cannot resume or advance.');
            } else if (statusChanged && !legalRunTransition(previous.Status__c, nextRun.Status__c, previous.ContinuationMode__c)) {
                nextRun.addError('Run status transition is not allowed.');
            }
        }
    }

    public static void guardCommands(Map<Id, AgentCommand__c> previousById, List<AgentCommand__c> nextCommands) {
        for (AgentCommand__c nextCommand : nextCommands) {
            AgentCommand__c previous = previousById.get(nextCommand.Id);
            if (
                previous.LeaseExpiresAt__c != nextCommand.LeaseExpiresAt__c &&
                nextCommand.RecoveryCheckAt__c == previous.RecoveryCheckAt__c &&
                previous.RecoveryCheckAt__c == previous.LeaseExpiresAt__c
            ) {
                nextCommand.RecoveryCheckAt__c = nextCommand.LeaseExpiresAt__c;
            }
            if (previous.Status__c != nextCommand.Status__c && !legalCommandTransition(previous.Status__c, nextCommand.Status__c)) {
                nextCommand.addError('Command status transition is not allowed.');
            }
            Decimal oldAttempt = previous.AttemptNumber__c == null ? 0 : previous.AttemptNumber__c;
            Decimal newAttempt = nextCommand.AttemptNumber__c == null ? 0 : nextCommand.AttemptNumber__c;
            if (newAttempt < oldAttempt || newAttempt > oldAttempt + 1) {
                nextCommand.addError('Command attempt number must advance by at most one.');
            }
            if (
                previous.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED &&
                nextCommand.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED &&
                String.isBlank(nextCommand.LeaseToken__c)
            ) {
                nextCommand.addError('A leased command requires a lease token.');
            }
            if (
                previous.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED &&
                nextCommand.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED &&
                !String.isBlank(previous.LeaseToken__c) &&
                previous.LeaseToken__c != nextCommand.LeaseToken__c
            ) {
                nextCommand.addError('An active lease token cannot be replaced or cleared.');
            }
        }
    }

    private static Boolean isTerminalRun(String status) {
        return new Set<String>{ AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelModels.RUN_STATUS_FAILED, AgentKernelModels.RUN_STATUS_CANCELLED }
            .contains(status);
    }

    private static Boolean legalRunTransition(String oldStatus, String newStatus, String continuationMode) {
        if (oldStatus == AgentKernelModels.RUN_STATUS_RUNNING) {
            return new Set<String>{
                    AgentKernelModels.RUN_STATUS_WAITING,
                    AgentKernelModels.RUN_STATUS_PAUSED,
                    AgentKernelModels.RUN_STATUS_SUCCEEDED,
                    AgentKernelModels.RUN_STATUS_FAILED,
                    AgentKernelModels.RUN_STATUS_CANCELLED
                }
                .contains(newStatus);
        }
        if (oldStatus == AgentKernelModels.RUN_STATUS_WAITING) {
            // A conversation that nobody answered in time ends with its last answer.
            if (newStatus == AgentKernelModels.RUN_STATUS_SUCCEEDED) {
                return continuationMode == AgentKernelModels.CONTINUATION_CONVERSATION;
            }
            return new Set<String>{ AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelModels.RUN_STATUS_PAUSED, AgentKernelModels.RUN_STATUS_CANCELLED }
                .contains(newStatus);
        }
        return oldStatus == AgentKernelModels.RUN_STATUS_PAUSED &&
            new Set<String>{ AgentKernelModels.RUN_STATUS_RUNNING, AgentKernelModels.RUN_STATUS_CANCELLED }.contains(newStatus);
    }

    private static Boolean legalCommandTransition(String oldStatus, String newStatus) {
        if (oldStatus == AgentKernelModels.COMMAND_STATUS_PENDING || oldStatus == AgentKernelModels.COMMAND_STATUS_RETRY_WAITING) {
            return new Set<String>{ AgentKernelModels.COMMAND_STATUS_LEASED, AgentKernelModels.COMMAND_STATUS_CANCELLED }.contains(newStatus);
        }
        if (oldStatus == AgentKernelModels.COMMAND_STATUS_BLOCKED) {
            return new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_CANCELLED }.contains(newStatus);
        }
        if (oldStatus == AgentKernelModels.COMMAND_STATUS_LEASED) {
            return new Set<String>{
                    AgentKernelModels.COMMAND_STATUS_PENDING,
                    AgentKernelModels.COMMAND_STATUS_RETRY_WAITING,
                    AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                    AgentKernelModels.COMMAND_STATUS_FAILED,
                    AgentKernelModels.COMMAND_STATUS_CANCELLED,
                    AgentKernelModels.COMMAND_STATUS_WAITING,
                    AgentKernelModels.COMMAND_STATUS_UNKNOWN
                }
                .contains(newStatus);
        }
        if (oldStatus == AgentKernelModels.COMMAND_STATUS_WAITING || oldStatus == AgentKernelModels.COMMAND_STATUS_FAILED) {
            return new Set<String>{
                    AgentKernelModels.COMMAND_STATUS_PENDING,
                    AgentKernelModels.COMMAND_STATUS_FAILED,
                    AgentKernelModels.COMMAND_STATUS_CANCELLED
                }
                .contains(newStatus);
        }
        return oldStatus == AgentKernelModels.COMMAND_STATUS_UNKNOWN &&
            new Set<String>{
                    AgentKernelModels.COMMAND_STATUS_PENDING,
                    AgentKernelModels.COMMAND_STATUS_SUCCEEDED,
                    AgentKernelModels.COMMAND_STATUS_FAILED,
                    AgentKernelModels.COMMAND_STATUS_CANCELLED
                }
                .contains(newStatus);
    }
}
