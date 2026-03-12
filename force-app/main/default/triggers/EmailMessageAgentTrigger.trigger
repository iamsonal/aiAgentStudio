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
 * and records with no parent. For qualifying messages, looks up which active
 * Email agent has declared AIAgentDefinition__c.EmailParentObject__c matching
 * the parent record's SObject type and dispatches accordingly.
 *
 * Bulk-safe: all unique parent SObject types are collected first and resolved in
 * a single SOQL regardless of how many EmailMessages are in the trigger batch.
 * Unregistered object types are silently skipped (no agent declared for them).
 *
 * To register a new object type, set EmailParentObject__c on the Email agent's
 * AIAgentDefinition__c record — no code change required.
 */
trigger EmailMessageAgentTrigger on EmailMessage(after insert) {
    // Pass 1: collect unique parent SObject types for a single routing SOQL.
    Set<String> objectTypes = new Set<String>();
    for (EmailMessage msg : Trigger.new) {
        if (msg.Incoming == true && msg.ParentId != null) {
            objectTypes.add(msg.ParentId.getSObjectType().getDescribe().getName());
        }
    }
    if (objectTypes.isEmpty()) {
        return; // All messages are outbound or have no parent — nothing to route
    }

    // One SOQL resolves all unique object types to agent developer names.
    // If two active Email agents declare the same EmailParentObject__c, the one
    // with the lower Id (first alphabetically) wins — operators should avoid this.
    Map<String, String> routeMap = new Map<String, String>();
    for (AIAgentDefinition__c agent : [
        SELECT DeveloperName__c, EmailParentObject__c
        FROM AIAgentDefinition__c
        WHERE AgentType__c         = 'Email'
          AND EmailParentObject__c IN :objectTypes
          AND IsActive__c          = true
        ORDER BY Id ASC
    ]) {
        if (!routeMap.containsKey(agent.EmailParentObject__c)) {
            routeMap.put(agent.EmailParentObject__c, agent.DeveloperName__c);
        }
    }

    if (routeMap.isEmpty()) {
        return; // No Email agent registered for any of the parent object types in this batch
    }

    // Pass 2: build one InvocableRequest per inbound EmailMessage with a registered agent.
    List<AgentExecutionService.InvocableRequest> requests = new List<AgentExecutionService.InvocableRequest>();
    for (EmailMessage msg : Trigger.new) {
        if (msg.Incoming != true || msg.ParentId == null) {
            continue;
        }

        String agentName = routeMap.get(msg.ParentId.getSObjectType().getDescribe().getName());
        if (String.isBlank(agentName)) {
            continue; // No Email agent registered for this parent object type
        }

        AgentExecutionService.InvocableRequest req = new AgentExecutionService.InvocableRequest();
        req.agentName = agentName;
        req.recordId = msg.ParentId;
        req.triggerSource = 'Email';
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
