/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provider contract for external messaging transports such as
 * WhatsApp, SMS aggregators, or other webhook-driven messaging services.
 */
public interface IExternalMessagingProvider {
    String getProviderKey();
    ExternalMessagingModels.VerificationResult verifyWebhook(RestRequest request, ChannelEndpoint__mdt endpoint);
    void validateWebhookRequest(RestRequest request, String payloadJson, ChannelEndpoint__mdt endpoint, String logPrefix);
    List<NormalizedIngressModels.Request> parseWebhookRequests(String payloadJson, ChannelEndpoint__mdt endpoint, String logPrefix);
    ExternalMessagingModels.OutboundResult sendTextMessage(ChannelEndpoint__mdt endpoint, ExternalMessagingModels.OutboundRequest request, String logPrefix);
}
