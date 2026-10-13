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
 * Minimal org-internal loopback endpoint. It accepts no business payload and
 * validates run, command, revision, operation key, mode, and principal before
 * atomically leasing the command and beginning its worker Queueable.
 */
@RestResource(urlMapping='/agent-core/v1/dispatch')
global without sharing class InternalCommandDispatchRest {
    global class DispatchRequest {
        global Id runId;
        global Id commandId;
        global Decimal expectedRevision;
        global String operationKey;
        global String dispatchToken;
    }

    /**
     * 202 when the command was accepted, 503 when its worker could not be
     * queued (the caller retries), 409 when it is no longer current (a
     * newer transition won), and 403 when this principal may not run it, such
     * as a Named Credential that signs in as a different user. The caller
     * records a 403 and leaves the command to recovery, which pauses the run
     * after repeated failures instead of retrying forever.
     */
    @HttpPost
    global static void dispatch() {
        Savepoint beforeDispatch = Database.setSavepoint();
        try {
            AgentKernelAccessGuard.assertInternalDispatchAuthorized();
            DispatchRequest request = (DispatchRequest) JSON.deserialize(
                RestContext.request.requestBody == null ? null : RestContext.request.requestBody.toString(),
                DispatchRequest.class
            );
            if (
                request == null ||
                request.runId == null ||
                request.commandId == null ||
                request.expectedRevision == null ||
                String.isBlank(request.operationKey) ||
                String.isBlank(request.dispatchToken)
            ) {
                throw new AgentKernelException.InvalidTransitionException('A complete dispatch identity is required.');
            }
            AgentKernel.acceptLoopbackDispatch(request.runId, request.commandId, request.expectedRevision, request.operationKey, request.dispatchToken);
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(
                request.runId,
                request.commandId,
                request.expectedRevision,
                request.operationKey,
                request.dispatchToken
            );
            Id workerJobId = CommandDispatcher.dispatchLeaseResult(lease, false);
            Database.releaseSavepoint(beforeDispatch);
            if (lease != null && lease.outcome == CommandLeaseService.Outcome.Leased && workerJobId == null) {
                // The worker could not be queued and its lease was released; a 503 makes the caller retry in a minute.
                respond(503, 'DISPATCH_ENQUEUE_FAILED');
                return;
            }
            RestContext.response.statusCode = 202;
        } catch (AgentKernelException failure) {
            Database.rollback(beforeDispatch);
            Database.releaseSavepoint(beforeDispatch);
            if (failure instanceof AgentKernelException.ConfigurationException) {
                respond(403, 'DISPATCH_PRINCIPAL_REFUSED');
            } else if (
                failure instanceof AgentKernelException.ConcurrencyException ||
                failure instanceof AgentKernelException.InvalidTransitionException ||
                failure instanceof AgentKernelException.NotFoundException
            ) {
                respond(409, 'DISPATCH_STALE');
            } else {
                throw failure;
            }
        }
    }

    private static void respond(Integer status, String code) {
        RestContext.response.statusCode = status;
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, String>{ 'code' => code }));
    }
}
