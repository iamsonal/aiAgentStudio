/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Shared DTOs for the lightweight normalized ingress boundary.
 */
public inherited sharing class NormalizedIngressModels {
    public static final String EVENT_TYPE_INBOUND_MESSAGE = 'InboundMessage';
    public static final String EVENT_TYPE_DELIVERY_STATUS = 'DeliveryStatus';
    public static final String EVENT_TYPE_VERIFICATION = 'Verification';

    public static final String MODE_DIRECT = 'Direct';
    public static final String MODE_STAGED = 'Staged';

    public static final String ORIGIN_MIDDLEWARE = 'Middleware';
    public static final String ORIGIN_DIRECT_EXTERNAL = 'DirectExternal';
    public static final String ORIGIN_INTERNAL_PLATFORM = 'InternalPlatform';
    public static final String ORIGIN_INTERNAL_API = 'InternalApi';

    public class Request {
        public String ingressType { get; set; }
        public String channel { get; set; }
        public String provider { get; set; }
        public String eventType { get; set; }
        public String processingMode { get; set; }
        public String submissionOrigin { get; set; }
        public String endpointDeveloperName { get; set; }
        public String endpointIdentifier { get; set; }
        public String routeKey { get; set; }
        public String participantExternalKey { get; set; }
        public String conversationKey { get; set; }
        public String providerMessageId { get; set; }
        public String messageContent { get; set; }
        public Datetime occurredAt { get; set; }
        public String verificationStatus { get; set; }
        public String triggerSource { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
        public String rawPayloadJson { get; set; }
        public String normalizedPayloadJson { get; set; }
        public String matchedRecordId { get; set; }
    }

    public class AcceptResult {
        public Boolean accepted { get; set; }
        public String processingMode { get; set; }
        public String processingStatus { get; set; }
        public Id ingressEventId { get; set; }
        public Id interactionSessionId { get; set; }
        public Id interactionMessageId { get; set; }
        public Id executionId { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
    }

    public class ProcessingResult {
        public Boolean success { get; set; }
        public Boolean duplicateSuppressed { get; set; }
        public String processingStatus { get; set; }
        public Id interactionSessionId { get; set; }
        public Id interactionMessageId { get; set; }
        public Id executionId { get; set; }
        public String inboundDedupKey { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
    }
}
