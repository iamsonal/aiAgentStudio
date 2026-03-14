/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared inbound runtime pipeline for normalize -> route -> session resolution.
 * Keeps channel entrypoints thin so future channels only need an adapter and metadata.
 */
public inherited sharing class InboundInteractionPipelineService {
    public class ResolvedInbound {
        public InteractionRuntimeModels.InteractionEnvelope envelope { get; set; }
        public InteractionRuntimeModels.InteractionSessionContext sessionContext { get; set; }
        public ChannelRoutingService.ResolvedRoute route { get; set; }
        public SessionPolicy__mdt sessionPolicy { get; set; }
        public String inboundDedupKey { get; set; }
    }

    public ResolvedInbound resolve(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.IInteractionChannel adapter,
        String channel,
        Id sourceRecordId,
        String userMessage,
        Map<String, Object> metadata,
        String logPrefix
    ) {
        ResolvedInbound resolved = new ResolvedInbound();
        InboundMessageNormalizer normalizer = new InboundMessageNormalizer();
        InteractionSessionResolver sessionResolver = new InteractionSessionResolver();

        resolved.envelope = normalizer.normalize(adapter, JSON.serialize(metadata), sourceRecordId, userMessage);
        resolved.sessionContext = sessionResolver.resolve(adapter, agentDefinition, resolved.envelope, logPrefix);
        return resolved;
    }

    public ResolvedInbound resolveEmailInbound(
        AIAgentDefinition__c agentDefinition,
        Id sourceRecordId,
        String userMessage,
        Map<String, Object> triggerMetadata,
        String logPrefix
    ) {
        EmailChannelAdapter emailChannel = new EmailChannelAdapter();
        InteractionMessageService interactionMessageService = new InteractionMessageService();
        ChannelRoutingService channelRoutingService = new ChannelRoutingService();

        String threadIdentifier = (String) triggerMetadata.get('threadIdentifier');
        String incomingEmailId = (String) triggerMetadata.get('emailMessageId');
        if (String.isBlank(incomingEmailId)) {
            String rfcMessageId = (String) triggerMetadata.get('messageId');
            if (String.isNotBlank(rfcMessageId)) {
                incomingEmailId = rfcMessageId;
            } else {
                String fromAddr = (String) triggerMetadata.get('fromAddress');
                Object msgDate = triggerMetadata.get('messageDate');
                if (String.isNotBlank(threadIdentifier) && String.isNotBlank(fromAddr)) {
                    String raw = threadIdentifier + '|' + fromAddr + '|' + (msgDate != null ? String.valueOf(msgDate) : '');
                    String digest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(raw)));
                    incomingEmailId = 'synth:' + digest.substring(0, 32);
                }
            }
        }

        if (String.isNotBlank(incomingEmailId)) {
            triggerMetadata.put('emailMessageId', incomingEmailId);
        }

        String fallbackFingerprint =
            threadIdentifier +
            '|' +
            String.valueOf(triggerMetadata.get('fromAddress')) +
            '|' +
            String.valueOf(triggerMetadata.get('messageDate'));
        String inboundDedupKey = interactionMessageService.buildInboundDedupKey(
            RuntimeRegistryService.CHANNEL_EMAIL,
            'SalesforceEmail',
            (String) triggerMetadata.get('toAddress'),
            incomingEmailId,
            fallbackFingerprint
        );
        triggerMetadata.put('inboundDedupKey', inboundDedupKey);

        String objectApiName = sourceRecordId != null ? sourceRecordId.getSObjectType().getDescribe().getName() : null;

        ResolvedInbound resolved = resolve(
            agentDefinition,
            emailChannel,
            RuntimeRegistryService.CHANNEL_EMAIL,
            sourceRecordId,
            userMessage,
            triggerMetadata,
            logPrefix
        );
        resolved.inboundDedupKey = inboundDedupKey;
        resolved.route = channelRoutingService.resolveInboundRoute(
            RuntimeRegistryService.CHANNEL_EMAIL,
            objectApiName,
            (String) triggerMetadata.get('toAddress')
        );
        resolved.sessionPolicy = channelRoutingService.loadSessionPolicy(resolved.route, objectApiName);
        return resolved;
    }
}
