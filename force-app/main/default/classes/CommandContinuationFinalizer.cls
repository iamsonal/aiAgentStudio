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
 * Continues durable agent work only after the worker transaction that created
 * the next command has committed. When the worker job fails, it records a
 * durable anomaly for the leased command and recovers it immediately. The
 * finalizer itself does not consume an additional daily asynchronous Apex
 * execution.
 */
public without sharing class CommandContinuationFinalizer implements Finalizer {
    private final Id runId;
    private final Id leasedCommandId;
    private final String leaseToken;
    private Id continuationCommandId;

    public CommandContinuationFinalizer(Id runId, Id leasedCommandId, String leaseToken) {
        this.runId = runId;
        this.leasedCommandId = leasedCommandId;
        this.leaseToken = leaseToken;
    }

    public void prepare(Id continuationCommandId) {
        this.continuationCommandId = continuationCommandId;
    }

    public void execute(FinalizerContext context) {
        if (context == null) {
            return;
        }
        if (context.getResult() == ParentJobResult.SUCCESS) {
            if (continuationCommandId != null) {
                CommandDispatcher.continueAfterCommit(continuationCommandId);
            }
            return;
        }
        Exception failure = context.getException();
        AgentOperationsLog.signal('WORKER_FAILED', runId, leasedCommandId, failure == null ? null : failure.getTypeName());
        if (leasedCommandId == null) {
            return;
        }
        try {
            CommandDeliveryTracker.recordAnomaly(leasedCommandId, 'WORKER_FAILED');
            CommandLeaseRecoveryService.recoverFailedWorker(leasedCommandId, leaseToken);
        } catch (Exception recoveryFailure) {
            AgentOperationsLog.signal('WORKER_FAILURE_RECOVERY_FAILED', runId, leasedCommandId, recoveryFailure.getTypeName());
        }
    }
}
