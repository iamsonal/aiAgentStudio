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
 * Bounded loopback receiver used by recovery. Every command is independently
 * validated against durable run, revision, operation, dispatch-token, and
 * service-principal state before a worker lease and enqueue are performed.
 */
@RestResource(urlMapping='/agent-core/v1/dispatch-batch')
global without sharing class InternalCommandBatchDispatchRest {
    private static final Integer MAX_BATCH_SIZE = 25;

    global class CommandEnvelope {
        global Id runId;
        global Id commandId;
        global Decimal expectedRevision;
        global String operationKey;
        global String dispatchToken;
    }

    global class DispatchRequest {
        global List<CommandEnvelope> commands;
    }

    global class DispatchResponse {
        global Integer accepted = 0;
        global Integer skipped = 0;
    }

    @HttpPost
    global static DispatchResponse dispatch() {
        AgentKernelAccessGuard.assertInternalDispatchAuthorized();
        DispatchRequest request = (DispatchRequest) JSON.deserialize(
            RestContext.request.requestBody == null ? null : RestContext.request.requestBody.toString(),
            DispatchRequest.class
        );
        if (request == null || request.commands == null || request.commands.isEmpty() || request.commands.size() > MAX_BATCH_SIZE) {
            throw new AgentKernelException.InvalidTransitionException('A bounded dispatch batch is required.');
        }
        DispatchResponse response = new DispatchResponse();
        List<CommandLeaseService.ServicePrincipalLeaseRequest> leaseRequests = new List<CommandLeaseService.ServicePrincipalLeaseRequest>();
        for (CommandEnvelope command : request.commands) {
            CommandLeaseService.ServicePrincipalLeaseRequest leaseRequest = new CommandLeaseService.ServicePrincipalLeaseRequest();
            if (command != null) {
                leaseRequest.runId = command.runId;
                leaseRequest.commandId = command.commandId;
                leaseRequest.expectedRevision = command.expectedRevision;
                leaseRequest.operationKey = command.operationKey;
                leaseRequest.dispatchToken = command.dispatchToken;
            }
            leaseRequests.add(leaseRequest);
        }
        List<CommandLeaseService.Result> leases = CommandLeaseService.tryLeaseServicePrincipalBatch(leaseRequests);
        Boolean deliveryFailed = false;
        for (CommandLeaseService.Result lease : leases) {
            if (lease == null || lease.outcome == CommandLeaseService.Outcome.Noop) {
                response.skipped++;
                continue;
            }
            if (lease.outcome != CommandLeaseService.Outcome.Noop) {
                Id workerJobId = CommandDispatcher.dispatchLeaseResult(lease, false);
                if (workerJobId == null) {
                    response.skipped++;
                    deliveryFailed = true;
                    continue;
                }
            }
            response.accepted++;
        }
        RestContext.response.statusCode = deliveryFailed ? 503 : 202;
        return response;
    }
}
