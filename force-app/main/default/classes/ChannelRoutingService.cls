/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Resolves typed channel routing metadata into a runtime-friendly model.
 */
public inherited sharing class ChannelRoutingService {
    private static final String LOG_PREFIX = '[ChannelRoutingService] ';

    public class ResolvedRoute {
        public String channel { get; set; }
        public String agentDeveloperName { get; set; }
        public String entryObjectType { get; set; }
        public String endpointDeveloperName { get; set; }
        public String endpointIdentifier { get; set; }
        public String provider { get; set; }
        public Boolean supportsAutonomousReply { get; set; }
        public String defaultDeliveryMode { get; set; }
        public String sessionPolicyDeveloperName { get; set; }
        public Decimal priority { get; set; }
    }

    public Map<String, ResolvedRoute> resolveInboundRoutes(String channel, Set<String> entryObjectTypes, Set<String> endpointIdentifiers) {
        Map<String, ResolvedRoute> routesByKey = new Map<String, ResolvedRoute>();
        if (String.isBlank(channel) || entryObjectTypes == null || entryObjectTypes.isEmpty()) {
            return routesByKey;
        }

        Set<String> normalizedEndpointIdentifiers = new Set<String>();
        if (endpointIdentifiers != null) {
            for (String endpointIdentifier : endpointIdentifiers) {
                if (String.isNotBlank(endpointIdentifier)) {
                    normalizedEndpointIdentifiers.add(endpointIdentifier.trim().toLowerCase());
                }
            }
        }

        Map<String, ChannelEndpoint__mdt> allEndpointsByDeveloperName = new Map<String, ChannelEndpoint__mdt>();
        Map<String, ChannelEndpoint__mdt> endpointsByDeveloperName = new Map<String, ChannelEndpoint__mdt>();
        for (ChannelEndpoint__mdt endpoint : [
            SELECT DeveloperName, Channel__c, Provider__c, EndpointIdentifier__c, IsActive__c, RouteKey__c, SupportsAutonomousReply__c
            FROM ChannelEndpoint__mdt
            WHERE Channel__c = :channel AND IsActive__c = TRUE
        ]) {
            allEndpointsByDeveloperName.put(endpoint.DeveloperName, endpoint);
            if (!normalizedEndpointIdentifiers.isEmpty()) {
                String normalizedIdentifier = String.isNotBlank(endpoint.EndpointIdentifier__c) ? endpoint.EndpointIdentifier__c.trim().toLowerCase() : null;
                if (!normalizedEndpointIdentifiers.contains(normalizedIdentifier)) {
                    continue;
                }
            }
            endpointsByDeveloperName.put(endpoint.DeveloperName, endpoint);
        }

        if (endpointsByDeveloperName.isEmpty()) {
            return routesByKey;
        }

        List<AgentChannelRoute__mdt> routes = [
            SELECT AgentDeveloperName__c, ChannelEndpoint__c, EntryObjectType__c, Priority__c, DefaultDeliveryMode__c, SessionPolicy__c, IsActive__c
            FROM AgentChannelRoute__mdt
            WHERE EntryObjectType__c IN :entryObjectTypes AND IsActive__c = TRUE
            ORDER BY Priority__c DESC, DeveloperName ASC
        ];

        for (AgentChannelRoute__mdt route : routes) {
            validateRouteEndpointReference(route, allEndpointsByDeveloperName);

            ChannelEndpoint__mdt endpoint = endpointsByDeveloperName.get(route.ChannelEndpoint__c);
            if (endpoint == null) {
                continue;
            }

            String key = buildRouteKey(route.EntryObjectType__c, endpoint.EndpointIdentifier__c);
            if (routesByKey.containsKey(key)) {
                continue;
            }

            ResolvedRoute resolved = new ResolvedRoute();
            resolved.channel = endpoint.Channel__c;
            resolved.agentDeveloperName = route.AgentDeveloperName__c;
            resolved.entryObjectType = route.EntryObjectType__c;
            resolved.endpointDeveloperName = route.ChannelEndpoint__c;
            resolved.endpointIdentifier = endpoint.EndpointIdentifier__c;
            resolved.provider = endpoint.Provider__c;
            resolved.supportsAutonomousReply = endpoint.SupportsAutonomousReply__c;
            resolved.defaultDeliveryMode = route.DefaultDeliveryMode__c;
            resolved.sessionPolicyDeveloperName = route.SessionPolicy__c;
            resolved.priority = route.Priority__c;
            routesByKey.put(key, resolved);
        }

        validateResolvedRoutes(routesByKey.values());
        return routesByKey;
    }

    public ResolvedRoute resolveInboundRoute(String channel, String entryObjectType, String endpointIdentifier) {
        Set<String> objectTypes = String.isNotBlank(entryObjectType) ? new Set<String>{ entryObjectType } : new Set<String>();
        Set<String> endpointIdentifiers = String.isNotBlank(endpointIdentifier) ? new Set<String>{ endpointIdentifier } : new Set<String>();
        Map<String, ResolvedRoute> routes = resolveInboundRoutes(channel, objectTypes, endpointIdentifiers);
        String exactKey = buildRouteKey(entryObjectType, endpointIdentifier);
        if (routes.containsKey(exactKey)) {
            return routes.get(exactKey);
        }
        return routes.get(buildRouteKey(entryObjectType, null));
    }

    public SessionPolicy__mdt loadSessionPolicy(ResolvedRoute route, String parentObjectApiName) {
        if (route != null && String.isNotBlank(route.sessionPolicyDeveloperName)) {
            List<SessionPolicy__mdt> namedPolicies = [
                SELECT
                    DeveloperName,
                    InactivityTtlHours__c,
                    StartNewSessionOnTerminalParent__c,
                    ParentObjectApiName__c,
                    TerminalFieldApiName__c,
                    TerminalFieldValues__c
                FROM SessionPolicy__mdt
                WHERE DeveloperName = :route.sessionPolicyDeveloperName
                LIMIT 1
            ];
            if (!namedPolicies.isEmpty()) {
                return namedPolicies[0];
            }
            throw new AIAgentException.OrchestrationException(
                'Invalid AgentChannelRoute__mdt configuration. Active route "' +
                    String.valueOf(route.endpointDeveloperName) +
                    '" references missing SessionPolicy__mdt "' +
                    route.sessionPolicyDeveloperName +
                    '".'
            );
        }

        if (String.isBlank(parentObjectApiName)) {
            return null;
        }

        List<SessionPolicy__mdt> parentPolicies = [
            SELECT
                DeveloperName,
                InactivityTtlHours__c,
                StartNewSessionOnTerminalParent__c,
                ParentObjectApiName__c,
                TerminalFieldApiName__c,
                TerminalFieldValues__c
            FROM SessionPolicy__mdt
            WHERE ParentObjectApiName__c = :parentObjectApiName
            LIMIT 1
        ];
        return parentPolicies.isEmpty() ? null : parentPolicies[0];
    }

    public String resolveCompletionMode(AIAgentDefinition__c agentDefinition, ResolvedRoute route) {
        String mode = null;
        if (route != null && String.isNotBlank(route.defaultDeliveryMode)) {
            mode = route.defaultDeliveryMode;
        } else {
            mode = String.isNotBlank(agentDefinition != null ? agentDefinition.DefaultCompletionMode__c : null)
                ? agentDefinition.DefaultCompletionMode__c
                : 'Auto Reply';
        }
        if (route != null && route.supportsAutonomousReply == false && 'Auto Reply'.equalsIgnoreCase(mode)) {
            return 'Review Before Send';
        }
        return mode;
    }

    public static String buildRouteKey(String entryObjectType, String endpointIdentifier) {
        String normalizedObject = String.isNotBlank(entryObjectType) ? entryObjectType.trim() : '*';
        String normalizedEndpoint = String.isNotBlank(endpointIdentifier) ? endpointIdentifier.trim().toLowerCase() : '*';
        return normalizedObject + '|' + normalizedEndpoint;
    }

    private void validateRouteEndpointReference(AgentChannelRoute__mdt route, Map<String, ChannelEndpoint__mdt> allEndpointsByDeveloperName) {
        if (route == null) {
            return;
        }
        if (String.isBlank(route.ChannelEndpoint__c)) {
            throw new AIAgentException.OrchestrationException(
                'Invalid AgentChannelRoute__mdt configuration. Active route for object "' +
                    String.valueOf(route.EntryObjectType__c) +
                    '" is missing ChannelEndpoint__c.'
            );
        }
        if (!allEndpointsByDeveloperName.containsKey(route.ChannelEndpoint__c)) {
            throw new AIAgentException.OrchestrationException(
                'Invalid AgentChannelRoute__mdt configuration. Active route "' +
                    String.valueOf(route.DeveloperName) +
                    '" references missing or inactive ChannelEndpoint__mdt "' +
                    route.ChannelEndpoint__c +
                    '".'
            );
        }
    }

    private void validateResolvedRoutes(List<ResolvedRoute> routes) {
        if (routes == null || routes.isEmpty()) {
            return;
        }

        Set<String> referencedPolicyNames = new Set<String>();
        for (ResolvedRoute route : routes) {
            if (route == null) {
                continue;
            }
            if (String.isBlank(route.agentDeveloperName)) {
                throw new AIAgentException.OrchestrationException(
                    'Invalid AgentChannelRoute__mdt configuration. Active route for endpoint "' +
                        String.valueOf(route.endpointDeveloperName) +
                        '" is missing AgentDeveloperName__c.'
                );
            }
            try {
                AIAgentConfigService.getAgentDefinitionByDeveloperName(route.agentDeveloperName);
            } catch (Exception e) {
                throw new AIAgentException.OrchestrationException(
                    'Invalid AgentChannelRoute__mdt configuration. Active route "' +
                        String.valueOf(route.endpointDeveloperName) +
                        '" references missing or inactive AIAgentDefinition__c DeveloperName "' +
                        route.agentDeveloperName +
                        '".'
                );
            }
            if (String.isNotBlank(route.sessionPolicyDeveloperName)) {
                referencedPolicyNames.add(route.sessionPolicyDeveloperName);
            }
        }

        if (referencedPolicyNames.isEmpty()) {
            return;
        }

        Map<String, SessionPolicy__mdt> policiesByDeveloperName = new Map<String, SessionPolicy__mdt>();
        for (SessionPolicy__mdt policy : [
            SELECT DeveloperName
            FROM SessionPolicy__mdt
            WHERE DeveloperName IN :referencedPolicyNames
        ]) {
            policiesByDeveloperName.put(policy.DeveloperName.toLowerCase(), policy);
        }

        for (ResolvedRoute route : routes) {
            if (
                route != null &&
                String.isNotBlank(route.sessionPolicyDeveloperName) &&
                !policiesByDeveloperName.containsKey(route.sessionPolicyDeveloperName.toLowerCase())
            ) {
                throw new AIAgentException.OrchestrationException(
                    'Invalid AgentChannelRoute__mdt configuration. Active route "' +
                        String.valueOf(route.endpointDeveloperName) +
                        '" references missing SessionPolicy__mdt "' +
                        route.sessionPolicyDeveloperName +
                        '".'
                );
            }
        }
    }
}
