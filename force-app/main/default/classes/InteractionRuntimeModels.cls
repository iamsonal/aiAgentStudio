/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Shared DTOs and contracts for the channel runtime refactor.
 * Keeps the new runtime concepts centralized and easy to reuse without
 * forcing every service to define duplicate transport/session structures.
 */
public inherited sharing class InteractionRuntimeModels {
    public enum ExecutionStrategyType {
        SingleShot,
        Iterative
    }

    public enum DeliveryAction {
        None,
        Send,
        Draft,
        Suppress,
        Handoff
    }

    public class TraitSet {
        public Boolean supportsContextLedger { get; set; }
        public Boolean publishesUiEvents { get; set; }
        public Boolean supportsConfirmationHitl { get; set; }
        public Boolean requiresCleanPreCalloutTransaction { get; set; }
        public Boolean routesFailuresBackToUser { get; set; }
        public Boolean supportsSameExecutionResume { get; set; }

        public TraitSet() {
            this.supportsContextLedger = false;
            this.publishesUiEvents = false;
            this.supportsConfirmationHitl = false;
            this.requiresCleanPreCalloutTransaction = false;
            this.routesFailuresBackToUser = false;
            this.supportsSameExecutionResume = false;
        }
    }

    public class InteractionEnvelope {
        public String channel { get; set; }
        public String provider { get; set; }
        public String endpointIdentifier { get; set; }
        public String conversationKey { get; set; }
        public String participantKey { get; set; }
        public String inboundMessageKey { get; set; }
        public String replyRouteKey { get; set; }
        public String channelMetadataJson { get; set; }
        public Id sourceRecordId { get; set; }
        public String messageContent { get; set; }
        public Datetime messageTimestamp { get; set; }
    }

    public class InteractionSessionContext {
        public Id sessionId { get; set; }
        public String channel { get; set; }
        public String provider { get; set; }
        public String conversationKey { get; set; }
        public String participantKey { get; set; }
        public String replyRouteKey { get; set; }
        public Id sourceRecordId { get; set; }
        public Id lastExecutionId { get; set; }
        public Datetime lastInboundAt { get; set; }
        public String sessionStatus { get; set; }
    }

    public class TerminalDecision {
        public Boolean isTerminal { get; set; }
        public Boolean requiresFollowUp { get; set; }
        public String userVisibleContent { get; set; }
        public String effectiveDeliveryMode { get; set; }

        public TerminalDecision() {
        }

        public TerminalDecision(Boolean isTerminal, Boolean requiresFollowUp, String deliveryMode, String content) {
            this.isTerminal = isTerminal;
            this.requiresFollowUp = requiresFollowUp;
            this.effectiveDeliveryMode = deliveryMode;
            this.userVisibleContent = content;
        }
    }

    public class DeliveryDecision {
        public DeliveryAction action { get; set; }
        public String deliveryMode { get; set; }
        public String routeKey { get; set; }
        public String statusMessage { get; set; }

        public DeliveryDecision() {
        }

        public DeliveryDecision(DeliveryAction action, String routeKey, String deliveryMode) {
            this.action = action;
            this.routeKey = routeKey;
            this.deliveryMode = deliveryMode;
        }
    }

    public interface IInteractionChannel {
        InteractionEnvelope normalizeInbound(String payloadJson, Id sourceRecordId, String userMessage);
        InteractionSessionContext resolveOrCreateSession(AIAgentDefinition__c agentDefinition, InteractionEnvelope envelope, String logPrefix);
        String buildPromptAdditions(Id executionId, OrchestrationContext context);
        DeliveryDecision determineDeliveryAction(AIAgentDefinition__c agentDefinition, OrchestrationContext context, String contentResponse, String logPrefix);
        Boolean sendReply(String contentResponse, OrchestrationContext context, String logPrefix);
        Id saveDraft(String contentResponse, OrchestrationContext context, String logPrefix);
        void suppressReply(OrchestrationContext context, String logPrefix);
    }
}
