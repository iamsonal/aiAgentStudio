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
        public String inboundDedupKey { get; set; }
    }

    public ResolvedInbound prepare(
        InteractionRuntimeModels.IInteractionChannel adapter,
        Id sourceRecordId,
        String userMessage,
        Map<String, Object> metadata,
        String logPrefix
    ) {
        ResolvedInbound resolved = new ResolvedInbound();
        InboundMessageNormalizer normalizer = new InboundMessageNormalizer();
        InteractionMessageService interactionMessageService = new InteractionMessageService();
        ChannelRoutingService channelRoutingService = new ChannelRoutingService();

        resolved.envelope = normalizer.normalize(adapter, JSON.serialize(metadata), sourceRecordId, userMessage);
        resolved.envelope.entryObjectType = deriveEntryObjectType(resolved.envelope, sourceRecordId);
        resolved.inboundDedupKey = interactionMessageService.buildInboundDedupKey(
            resolved.envelope.channel,
            resolved.envelope.provider,
            resolved.envelope.endpointIdentifier,
            resolved.envelope.inboundMessageKey,
            resolved.envelope.fallbackDedupKey
        );
        resolved.route = channelRoutingService.resolveInboundRoute(
            resolved.envelope.channel,
            resolved.envelope.entryObjectType,
            resolved.envelope.endpointIdentifier
        );
        return resolved;
    }

    public InteractionRuntimeModels.InteractionSessionContext resolveSession(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.IInteractionChannel adapter,
        ResolvedInbound resolved,
        String logPrefix
    ) {
        if (resolved == null || resolved.sessionContext != null) {
            return resolved != null ? resolved.sessionContext : null;
        }
        InteractionSessionResolver sessionResolver = new InteractionSessionResolver();
        resolved.sessionContext = sessionResolver.resolve(adapter, agentDefinition, resolved.envelope, logPrefix);
        return resolved.sessionContext;
    }

    public ResolvedInbound resolve(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.IInteractionChannel adapter,
        Id sourceRecordId,
        String userMessage,
        Map<String, Object> metadata,
        String logPrefix
    ) {
        ResolvedInbound resolved = prepare(adapter, sourceRecordId, userMessage, metadata, logPrefix);
        resolveSession(agentDefinition, adapter, resolved, logPrefix);
        return resolved;
    }

    private String deriveEntryObjectType(InteractionRuntimeModels.InteractionEnvelope envelope, Id sourceRecordId) {
        if (envelope != null && String.isNotBlank(envelope.entryObjectType)) {
            return envelope.entryObjectType;
        }
        return sourceRecordId != null ? sourceRecordId.getSObjectType().getDescribe().getName() : null;
    }
}
