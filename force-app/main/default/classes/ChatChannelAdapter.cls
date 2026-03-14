/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Channel adapter for Salesforce-native chat interactions.
 */
public inherited sharing class ChatChannelAdapter extends BaseInteractionChannel {
    private static final String PROVIDER_NAME = 'SalesforceChat';
    private static final String ENDPOINT_IDENTIFIER = 'SalesforceChatUI';

    public override InteractionRuntimeModels.InteractionEnvelope normalizeInbound(String payloadJson, Id sourceRecordId, String userMessage) {
        Map<String, Object> payload = String.isNotBlank(payloadJson) ? (Map<String, Object>) JSON.deserializeUntyped(payloadJson) : new Map<String, Object>();

        InteractionRuntimeModels.InteractionEnvelope envelope = new InteractionRuntimeModels.InteractionEnvelope();
        envelope.channel = RuntimeRegistryService.CHANNEL_CHAT;
        envelope.provider = PROVIDER_NAME;
        envelope.endpointIdentifier = ENDPOINT_IDENTIFIER;
        envelope.conversationKey = (String) payload.get('conversationKey');
        if (String.isBlank(envelope.conversationKey)) {
            envelope.conversationKey = (String) payload.get('turnIdentifier');
        }
        envelope.participantKey = (String) payload.get('userId');
        envelope.replyRouteKey = envelope.participantKey;
        envelope.channelMetadataJson = payloadJson;
        envelope.sourceRecordId = sourceRecordId;
        envelope.messageContent = userMessage;
        return envelope;
    }

    public override InteractionRuntimeModels.InteractionSessionContext resolveOrCreateSession(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.InteractionEnvelope envelope,
        String logPrefix
    ) {
        Map<String, Object> metadata = String.isNotBlank(envelope.channelMetadataJson)
            ? (Map<String, Object>) JSON.deserializeUntyped(envelope.channelMetadataJson)
            : new Map<String, Object>();

        InteractionSessionService sessionService = new InteractionSessionService();
        if (metadata.containsKey('interactionSessionId') && String.isNotBlank((String) metadata.get('interactionSessionId'))) {
            return sessionService.getSessionContext(Id.valueOf((String) metadata.get('interactionSessionId')));
        }
        if (metadata.containsKey('existingExecutionId') && String.isNotBlank((String) metadata.get('existingExecutionId'))) {
            InteractionRuntimeModels.InteractionSessionContext existingContext = sessionService.getSessionContextForExecution(
                Id.valueOf((String) metadata.get('existingExecutionId'))
            );
            if (existingContext != null && existingContext.sessionId != null) {
                return existingContext;
            }
        }

        return sessionService.resolveOrCreateSession(
            RuntimeRegistryService.CHANNEL_CHAT,
            envelope.conversationKey,
            envelope.replyRouteKey,
            envelope.participantKey,
            PROVIDER_NAME,
            envelope.sourceRecordId,
            ENDPOINT_IDENTIFIER,
            logPrefix
        );
    }
}
