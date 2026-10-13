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
 * DML-only command lease transaction. External work is always delegated to a
 * fresh Queueable after the lease commit.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class CommandLeaseQueueable implements Queueable {
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String dispatchToken;
    @TestVisible
    private static Boolean captureDispatchForTest = false;
    @TestVisible
    private static Id capturedDeferredCommandId;
    @TestVisible
    private static Integer capturedDelayMinutes;
    @TestVisible
    private static Id capturedWorkerCommandId;

    public CommandLeaseQueueable(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String dispatchToken) {
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.dispatchToken = dispatchToken;
    }

    public void execute(QueueableContext context) {
        CommandLeaseService.Result lease = CommandLeaseService.tryLease(runId, commandId, expectedRevision, operationKey, dispatchToken);
        if (lease.outcome == CommandLeaseService.Outcome.Deferred) {
            dispatchDeferred(commandId, lease.delayMinutes);
            return;
        }
        if (lease.outcome == CommandLeaseService.Outcome.Leased) {
            dispatchWorker(lease.run, lease.command);
        }
    }

    private static void dispatchDeferred(Id deferredCommandId, Integer delayMinutes) {
        if (captureDispatchForTest) {
            capturedDeferredCommandId = deferredCommandId;
            capturedDelayMinutes = delayMinutes;
            return;
        }
        CommandDispatcher.dispatchAfter(deferredCommandId, delayMinutes);
    }

    private static void dispatchWorker(AgentRun__c run, AgentCommand__c command) {
        if (captureDispatchForTest) {
            capturedWorkerCommandId = command.Id;
            return;
        }
        CommandDispatcher.enqueueWorker(run, command);
    }
}
