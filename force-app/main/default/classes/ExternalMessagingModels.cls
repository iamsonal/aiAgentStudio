/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared DTOs for provider-backed external messaging channels.
 */
public inherited sharing class ExternalMessagingModels {
    public class VerificationResult {
        public Boolean isSuccess { get; set; }
        public String challengeResponse { get; set; }
        public String errorMessage { get; set; }
    }

    public class InboundMessageEvent {
        public String provider { get; set; }
        public String providerEventType { get; set; }
        public String endpointIdentifier { get; set; }
        public String replyRouteKey { get; set; }
        public String conversationKey { get; set; }
        public String participantKey { get; set; }
        public String providerMessageId { get; set; }
        public String messageContent { get; set; }
        public Datetime occurredAt { get; set; }
        public String payloadJson { get; set; }
    }

    public class StatusEvent {
        public String provider { get; set; }
        public String providerMessageId { get; set; }
        public String providerStatus { get; set; }
        public String normalizedStatus { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
        public String payloadJson { get; set; }
    }

    public class OutboundRequest {
        public String routeKey { get; set; }
        public String recipientKey { get; set; }
        public String messageBody { get; set; }
        public Id executionId { get; set; }
        public Id interactionSessionId { get; set; }
        public String payloadJson { get; set; }
    }

    public class OutboundResult {
        public Boolean isSuccess { get; set; }
        public String providerMessageId { get; set; }
        public String providerStatus { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
        public String responseBody { get; set; }
    }
}
