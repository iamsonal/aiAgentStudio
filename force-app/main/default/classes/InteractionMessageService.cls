/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Transport-scoped persistence service for InteractionMessage__c.
 * Handles duplicate suppression, send claiming, and delivery status updates
 * without overloading ExecutionStep__c with provider-level transport state.
 */
public inherited sharing class InteractionMessageService {
    public String buildInboundDedupKey(String channel, String provider, String endpointIdentifier, String inboundMessageKey, String fallbackFingerprint) {
        String raw =
            channel +
            '|' +
            provider +
            '|' +
            endpointIdentifier +
            '|' +
            (String.isNotBlank(inboundMessageKey) ? inboundMessageKey : fallbackFingerprint);
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(raw)));
    }

    public Boolean hasProcessedInbound(String dedupKey) {
        if (String.isBlank(dedupKey)) {
            return false;
        }
        return ![
                SELECT Id
                FROM InteractionMessage__c
                WHERE InboundDedupKey__c = :dedupKey
                LIMIT 1
            ]
            .isEmpty();
    }

    public void recordInboundProcessing(
        Id sessionId,
        Id executionId,
        String channel,
        String provider,
        String providerMessageId,
        String dedupKey,
        String turnIdentifier,
        String payloadJson
    ) {
        insert new InteractionMessage__c(
            InteractionSession__c = sessionId,
            Execution__c = executionId,
            TurnIdentifier__c = turnIdentifier,
            Channel__c = channel,
            Provider__c = provider,
            ProviderMessageId__c = providerMessageId,
            InboundDedupKey__c = dedupKey,
            Direction__c = 'Inbound',
            Status__c = 'Processing',
            OccurredAt__c = Datetime.now(),
            PayloadSnapshotJson__c = payloadJson
        );
    }

    public Boolean claimOutboundSlot(String dedupKey, String logPrefix) {
        if (String.isBlank(dedupKey)) {
            return true;
        }

        List<InteractionMessage__c> messages = [
            SELECT Id, Status__c
            FROM InteractionMessage__c
            WHERE InboundDedupKey__c = :dedupKey
            LIMIT 1
            FOR UPDATE
        ];
        if (messages.isEmpty()) {
            return true;
        }

        if (messages[0].Status__c == 'Sent' || messages[0].Status__c == 'Processing') {
            // Keep the legacy semantics: a currently processing or already sent inbound message
            // should not be sent twice.
            if (messages[0].Status__c == 'Sent') {
                return false;
            }
        }

        messages[0].Status__c = 'Processing';
        update messages[0];
        return true;
    }

    public void updateInboundStatus(String dedupKey, String status, String outboundProviderMessageId, String errorCode, String errorMessage) {
        if (String.isBlank(dedupKey)) {
            return;
        }
        List<InteractionMessage__c> messages = [
            SELECT Id
            FROM InteractionMessage__c
            WHERE InboundDedupKey__c = :dedupKey
            LIMIT 1
        ];
        if (messages.isEmpty()) {
            return;
        }

        messages[0].Status__c = status;
        if (String.isNotBlank(outboundProviderMessageId)) {
            messages[0].OutboundProviderMessageId__c = outboundProviderMessageId;
        }
        if (String.isNotBlank(errorCode)) {
            messages[0].ErrorCode__c = errorCode;
        }
        if (String.isNotBlank(errorMessage)) {
            messages[0].ErrorMessage__c = errorMessage;
        }
        update messages[0];
    }
}
