/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Routes inbound EmailMessage records to the correct Email agent.
 *
 * Fires for every new EmailMessage. Skips outbound messages (Incoming = false)
 * and records with no parent. For qualifying messages, looks up typed channel
 * routing metadata for the parent record's SObject type and dispatches accordingly.
 *
 * Bulk-safe: all unique parent SObject types are collected first and resolved in
 * a single SOQL regardless of how many EmailMessages are in the trigger batch.
 * Unregistered object types are silently skipped (no agent declared for them).
 *
 * To register a new object type, create an active AgentChannelRoute__mdt record
 * for the Email channel endpoint and entry object type.
 */
trigger EmailMessageAgentTrigger on EmailMessage(after insert) {
    // Pass 1: collect unique parent SObject types and endpoint identifiers for a single routing resolution.
    Set<String> objectTypes = new Set<String>();
    Set<String> endpointIdentifiers = new Set<String>();
    for (EmailMessage msg : Trigger.new) {
        if (msg.Incoming == true && msg.ParentId != null) {
            objectTypes.add(msg.ParentId.getSObjectType().getDescribe().getName());
            if (String.isNotBlank(msg.ToAddress)) {
                endpointIdentifiers.add(msg.ToAddress);
            }
        }
    }
    if (objectTypes.isEmpty()) {
        return; // All messages are outbound or have no parent — nothing to route
    }

    ChannelRoutingService routingService = new ChannelRoutingService();
    Map<String, ChannelRoutingService.ResolvedRoute> routeMap = routingService.resolveInboundRoutes(
        RuntimeRegistryService.CHANNEL_EMAIL,
        objectTypes,
        endpointIdentifiers
    );

    if (routeMap.isEmpty()) {
        return; // No Email agent registered for any of the parent object types in this batch
    }

    // Pass 2: build one InvocableRequest per inbound EmailMessage with a registered agent.
    List<AgentExecutionService.InvocableRequest> requests = new List<AgentExecutionService.InvocableRequest>();
    for (EmailMessage msg : Trigger.new) {
        if (msg.Incoming != true || msg.ParentId == null) {
            continue;
        }

        String objectType = msg.ParentId.getSObjectType().getDescribe().getName();
        ChannelRoutingService.ResolvedRoute route = routeMap.get(ChannelRoutingService.buildRouteKey(objectType, msg.ToAddress));
        if (route == null) {
            route = routeMap.get(ChannelRoutingService.buildRouteKey(objectType, null));
        }
        if (route == null || String.isBlank(route.agentDeveloperName)) {
            continue; // No Email agent registered for this parent object type
        }

        AgentExecutionService.InvocableRequest req = new AgentExecutionService.InvocableRequest();
        req.agentName = route.agentDeveloperName;
        req.recordId = msg.ParentId;
        req.triggerSource = 'Email';
        req.interactionChannel = RuntimeRegistryService.CHANNEL_EMAIL;
        // Pass the specific EmailMessage ID so the orchestrator processes exactly this email.
        // Without this, a "most recent" fallback query can pick the wrong email when multiple
        // arrive simultaneously for the same parent record.
        req.triggerPayload = JSON.serialize(new Map<String, String>{ 'emailMessageId' => msg.Id });
        requests.add(req);
    }

    if (!requests.isEmpty()) {
        AgentExecutionService.startExecutionFromFlow(requests);
    }
}
