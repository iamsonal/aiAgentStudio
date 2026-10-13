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
 * Internal mechanics shared by the model and tool command workers.
 * Apex requires shared top-level types to be public; this class deliberately
 * contains no lifecycle mutations or extension calls.
 */
public inherited sharing class CommandWorkerSupport {
    public static Boolean ownsLease(
        AgentRun__c run,
        AgentCommand__c command,
        Decimal expectedRevision,
        String operationKey,
        String leaseToken,
        Id workerJobId,
        String commandType
    ) {
        if (run == null || command == null || String.isBlank(operationKey) || String.isBlank(leaseToken)) {
            return false;
        }
        return run.Status__c == AgentKernelModels.RUN_STATUS_RUNNING &&
            run.CurrentCommand__c == command.Id &&
            run.Revision__c == expectedRevision &&
            command.AgentRun__c == run.Id &&
            command.CommandType__c == commandType &&
            command.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED &&
            command.ExpectedRunRevision__c == expectedRevision &&
            operationKey.equals(command.OperationKey__c) &&
            leaseToken.equals(command.LeaseToken__c) &&
            (workerJobId == null ? Test.isRunningTest() : workerJobId.equals(command.WorkerJobId__c));
    }

    /** Milliseconds between the worker's enqueue and its start, or null when the enqueue time is unknown. */
    public static Long queueWait(AgentCommand__c command) {
        if (command == null || command.WorkerEnqueuedAt__c == null) {
            return null;
        }
        return Math.max(0L, System.now().getTime() - command.WorkerEnqueuedAt__c.getTime());
    }

    public static String defaultCode(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    public static String defaultMessage(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    public static String safeMessage(Exception error, String fallback) {
        return String.isBlank(error.getMessage()) ? fallback : error.getMessage();
    }

    public static String boundedIdentifier(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String trimmed = value.replace('\r', ' ').replace('\n', ' ').trim();
        return trimmed.length() > 255 ? trimmed.substring(0, 255) : trimmed;
    }
}
