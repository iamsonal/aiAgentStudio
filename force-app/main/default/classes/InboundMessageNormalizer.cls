/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Canonical normalization seam for inbound channel payloads.
 */
public inherited sharing class InboundMessageNormalizer {
    public InteractionRuntimeModels.InteractionEnvelope normalize(
        InteractionRuntimeModels.IInteractionChannel channel,
        String payloadJson,
        Id sourceRecordId,
        String userMessage
    ) {
        return channel.normalizeInbound(payloadJson, sourceRecordId, userMessage);
    }
}
