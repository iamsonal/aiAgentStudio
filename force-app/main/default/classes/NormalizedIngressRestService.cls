/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Authenticated REST surface for middleware or integration layers
 * that already speak the normalized ingress contract.
 */
@RestResource(urlMapping='/ai/ingress')
global with sharing class NormalizedIngressRestService {
    private static final String LOG_PREFIX = '[NormalizedIngressRestService] ';

    @HttpPost
    global static String submit() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        String logPrefix = LOG_PREFIX + '[Req:' + UUID.randomUUID().toString().left(8) + '] ';

        try {
            if (request == null || request.requestBody == null || request.requestBody.size() == 0) {
                throw new AIAgentException.OrchestrationException('Normalized ingress request body is required.');
            }

            Envelope envelope = (Envelope) JSON.deserialize(request.requestBody.toString(), Envelope.class);
            if (envelope == null || envelope.events == null || envelope.events.isEmpty()) {
                throw new AIAgentException.OrchestrationException('At least one normalized ingress event is required.');
            }

            List<NormalizedIngressModels.AcceptResult> results = new IngressProcessingService().accept(envelope.events, logPrefix);
            response.statusCode = 200;
            return JSON.serialize(new Map<String, Object>{ 'accepted' => true, 'eventsAccepted' => results.size(), 'results' => results });
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getMessage() + '\n' + e.getStackTraceString());
            response.statusCode = 400;
            return JSON.serialize(new Map<String, Object>{ 'accepted' => false, 'error' => e.getMessage() });
        }
    }

    global class Envelope {
        public List<NormalizedIngressModels.Request> events { get; set; }
    }
}
