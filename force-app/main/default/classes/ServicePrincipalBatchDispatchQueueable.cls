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
 * Resets the asynchronous transaction boundary for a bounded recovery batch.
 * The receiving REST transaction validates every durable command identity.
 */
public without sharing class ServicePrincipalBatchDispatchQueueable implements Queueable, Database.AllowsCallouts {
    private static final Integer MAX_BATCH_SIZE = 25;
    private final String namedCredential;
    private final String requestJson;
    @TestVisible
    private static String preparedEndpointForTest;
    @TestVisible
    private static String preparedBodyForTest;

    public ServicePrincipalBatchDispatchQueueable(String namedCredential, List<InternalCommandBatchDispatchRest.CommandEnvelope> envelopes) {
        this.namedCredential = namedCredential;
        List<InternalCommandBatchDispatchRest.CommandEnvelope> bounded = new List<InternalCommandBatchDispatchRest.CommandEnvelope>();
        if (envelopes != null) {
            for (InternalCommandBatchDispatchRest.CommandEnvelope envelope : envelopes) {
                if (bounded.size() == MAX_BATCH_SIZE) {
                    break;
                }
                bounded.add(envelope);
            }
        }
        this.requestJson = JSON.serialize(new Map<String, Object>{ 'commands' => bounded });
        if (Test.isRunningTest()) {
            preparedEndpointForTest = endpoint();
            preparedBodyForTest = requestJson;
        }
    }

    public void execute(QueueableContext context) {
        if (String.isBlank(namedCredential) || String.isBlank(requestJson)) {
            return;
        }
        HttpRequest request = new HttpRequest();
        request.setMethod('POST');
        request.setEndpoint(endpoint());
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(20000);
        request.setBody(requestJson);
        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            throw new AgentKernelException.RetryableException('Internal service-principal recovery dispatch was not accepted.');
        }
    }

    private String endpoint() {
        return 'callout:' + namedCredential + '/services/apexrest/agent-core/v1/dispatch-batch';
    }
}
