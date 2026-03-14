/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Base implementation for interaction channel adapters.
 */
public abstract inherited sharing class BaseInteractionChannel implements InteractionRuntimeModels.IInteractionChannel {
    public virtual InteractionRuntimeModels.InteractionEnvelope normalizeInbound(String payloadJson, Id sourceRecordId, String userMessage) {
        InteractionRuntimeModels.InteractionEnvelope envelope = new InteractionRuntimeModels.InteractionEnvelope();
        envelope.sourceRecordId = sourceRecordId;
        envelope.messageContent = userMessage;
        envelope.channelMetadataJson = payloadJson;
        return envelope;
    }

    public virtual InteractionRuntimeModels.InteractionSessionContext resolveOrCreateSession(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.InteractionEnvelope envelope,
        String logPrefix
    ) {
        return new InteractionRuntimeModels.InteractionSessionContext();
    }

    public virtual String buildPromptAdditions(Id executionId, OrchestrationContext context) {
        return '';
    }

    public virtual InteractionRuntimeModels.DeliveryDecision determineDeliveryAction(
        AIAgentDefinition__c agentDefinition,
        OrchestrationContext context,
        String contentResponse,
        String logPrefix
    ) {
        return new InteractionRuntimeModels.DeliveryDecision(InteractionRuntimeModels.DeliveryAction.None, null, null);
    }

    public virtual Boolean sendReply(String contentResponse, OrchestrationContext context, String logPrefix) {
        return true;
    }

    public virtual Id saveDraft(String contentResponse, OrchestrationContext context, String logPrefix) {
        return null;
    }

    public virtual void suppressReply(OrchestrationContext context, String logPrefix) {
    }
}
