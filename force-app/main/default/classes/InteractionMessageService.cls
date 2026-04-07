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
    public class InboundMessageRef {
        public Id messageId { get; set; }
        public Id sessionId { get; set; }
        public Id executionId { get; set; }
    }

    public class InboundClaimResult {
        public Boolean claimed { get; set; }
        public Id messageId { get; set; }
        public Id sessionId { get; set; }
        public Id executionId { get; set; }
    }

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
        return getInboundMessageRefByDedupKey(dedupKey) != null;
    }

    public InboundMessageRef getInboundMessageRefByDedupKey(String dedupKey) {
        if (String.isBlank(dedupKey)) {
            return null;
        }
        List<InteractionMessage__c> messages = [
            SELECT Id, InteractionSession__c, Execution__c
            FROM InteractionMessage__c
            WHERE InboundDedupKey__c = :dedupKey
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (messages.isEmpty()) {
            return null;
        }

        InboundMessageRef ref = new InboundMessageRef();
        ref.messageId = messages[0].Id;
        ref.sessionId = messages[0].InteractionSession__c;
        ref.executionId = messages[0].Execution__c;
        return ref;
    }

    public InboundClaimResult claimInboundProcessing(
        String channel,
        String provider,
        String providerMessageId,
        String dedupKey,
        String turnIdentifier,
        String payloadJson
    ) {
        InboundClaimResult result = new InboundClaimResult();
        try {
            result.messageId = recordInboundProcessing(null, null, channel, provider, providerMessageId, dedupKey, turnIdentifier, payloadJson);
            result.claimed = true;
            return result;
        } catch (DmlException e) {
            if (e.getDmlType(0) != StatusCode.DUPLICATE_VALUE) {
                throw e;
            }
        }

        InboundMessageRef existingInbound = getInboundMessageRefByDedupKey(dedupKey);
        result.claimed = false;
        result.messageId = existingInbound != null ? existingInbound.messageId : null;
        result.sessionId = existingInbound != null ? existingInbound.sessionId : null;
        result.executionId = existingInbound != null ? existingInbound.executionId : null;
        return result;
    }

    public Id recordInboundProcessing(
        Id sessionId,
        Id executionId,
        String channel,
        String provider,
        String providerMessageId,
        String dedupKey,
        String turnIdentifier,
        String payloadJson
    ) {
        InteractionMessage__c inboundMessage = new InteractionMessage__c(
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
        insert inboundMessage;
        return inboundMessage.Id;
    }

    public void attachInboundProcessing(Id messageId, Id sessionId, Id executionId, String payloadJson) {
        if (messageId == null) {
            return;
        }

        InteractionMessage__c inboundMessage = new InteractionMessage__c(Id = messageId);
        inboundMessage.InteractionSession__c = sessionId;
        inboundMessage.Execution__c = executionId;
        if (payloadJson != null) {
            inboundMessage.PayloadSnapshotJson__c = payloadJson;
        }
        update inboundMessage;
    }

    public Id recordOutboundMessage(
        Id sessionId,
        Id executionId,
        String channel,
        String provider,
        String providerMessageId,
        String turnIdentifier,
        String payloadJson,
        String status
    ) {
        InteractionMessage__c outboundMessage = new InteractionMessage__c(
            InteractionSession__c = sessionId,
            Execution__c = executionId,
            TurnIdentifier__c = turnIdentifier,
            Channel__c = channel,
            Provider__c = provider,
            ProviderMessageId__c = providerMessageId,
            Direction__c = 'Outbound',
            Status__c = String.isNotBlank(status) ? status : 'Sent',
            OccurredAt__c = Datetime.now(),
            PayloadSnapshotJson__c = payloadJson
        );
        insert outboundMessage;
        return outboundMessage.Id;
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
        updateInboundStatus(dedupKey, status, outboundProviderMessageId, errorCode, errorMessage, null);
    }

    public void updateInboundStatus(
        String dedupKey,
        String status,
        String outboundProviderMessageId,
        String errorCode,
        String errorMessage,
        Id reviewArtifactId
    ) {
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
        if (reviewArtifactId != null) {
            messages[0].ReviewArtifactId__c = reviewArtifactId;
        }
        update messages[0];
    }

    public void updateProviderMessageStatus(String providerMessageId, String providerStatus, String normalizedStatus, String errorCode, String errorMessage) {
        if (String.isBlank(providerMessageId)) {
            return;
        }
        List<InteractionMessage__c> messages = [
            SELECT Id, Status__c, ProviderStatus__c, ErrorCode__c, ErrorMessage__c
            FROM InteractionMessage__c
            WHERE ProviderMessageId__c = :providerMessageId OR OutboundProviderMessageId__c = :providerMessageId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (messages.isEmpty()) {
            return;
        }

        InteractionMessage__c message = messages[0];
        if (String.isNotBlank(providerStatus)) {
            message.ProviderStatus__c = providerStatus;
        }
        if (String.isNotBlank(normalizedStatus)) {
            message.Status__c = normalizedStatus;
        }
        if (String.isNotBlank(errorCode)) {
            message.ErrorCode__c = errorCode;
        }
        if (String.isNotBlank(errorMessage)) {
            message.ErrorMessage__c = errorMessage;
        }
        update message;
    }
}
