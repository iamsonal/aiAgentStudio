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
    @TestVisible
    private static List<AgentChannelRoute__mdt> testRoutes;
    @TestVisible
    private static Map<String, ChannelEndpoint__mdt> testEndpointsByDeveloperName;

    public class ResolvedRoute {
        public String channel { get; set; }
        public String agentDeveloperName { get; set; }
        public String entryObjectType { get; set; }
        public String endpointDeveloperName { get; set; }
        public String endpointIdentifier { get; set; }
        public String routeKey { get; set; }
        public String provider { get; set; }
        public Boolean supportsAutonomousReply { get; set; }
        public String defaultDeliveryMode { get; set; }
        public Decimal inactivityTtlHours { get; set; }
        public Boolean startNewSessionOnTerminalParent { get; set; }
        public String terminalFieldApiName { get; set; }
        public String terminalFieldValues { get; set; }
        public Decimal priority { get; set; }
    }

    @TestVisible
    static void setTestRoutingData(List<ChannelEndpoint__mdt> endpoints, List<AgentChannelRoute__mdt> routes) {
        testEndpointsByDeveloperName = new Map<String, ChannelEndpoint__mdt>();
        if (endpoints != null) {
            for (ChannelEndpoint__mdt endpoint : endpoints) {
                if (endpoint != null && String.isNotBlank(endpoint.DeveloperName)) {
                    testEndpointsByDeveloperName.put(endpoint.DeveloperName, endpoint);
                }
            }
        }

        testRoutes = routes == null ? new List<AgentChannelRoute__mdt>() : new List<AgentChannelRoute__mdt>(routes);
    }

    @TestVisible
    static void clearTestRoutingData() {
        testRoutes = null;
        testEndpointsByDeveloperName = null;
    }

    public Map<String, ResolvedRoute> resolveInboundRoutes(String channel, Set<String> entryObjectTypes, Set<String> endpointIdentifiers) {
        Map<String, ResolvedRoute> routesByKey = new Map<String, ResolvedRoute>();
        if (String.isBlank(channel)) {
            return routesByKey;
        }

        Set<String> normalizedEntryObjectTypes = new Set<String>();
        if (entryObjectTypes != null) {
            for (String entryObjectType : entryObjectTypes) {
                if (String.isNotBlank(entryObjectType)) {
                    normalizedEntryObjectTypes.add(entryObjectType.trim());
                }
            }
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
        for (ChannelEndpoint__mdt endpoint : queryActiveEndpoints()) {
            allEndpointsByDeveloperName.put(endpoint.DeveloperName, endpoint);
        }

        Map<String, ChannelEndpoint__mdt> endpointsByDeveloperName = new Map<String, ChannelEndpoint__mdt>();
        for (ChannelEndpoint__mdt endpoint : allEndpointsByDeveloperName.values()) {
            if (endpoint.Channel__c != channel) {
                continue;
            }
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

        List<AgentChannelRoute__mdt> routes = queryActiveRoutes();

        for (AgentChannelRoute__mdt route : routes) {
            validateRouteEndpointReference(route, allEndpointsByDeveloperName);
            if (!matchesEntryObjectType(normalizedEntryObjectTypes, route.EntryObjectType__c)) {
                continue;
            }

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
            resolved.routeKey = endpoint.RouteKey__c;
            resolved.provider = endpoint.Provider__c;
            resolved.supportsAutonomousReply = endpoint.SupportsAutonomousReply__c;
            resolved.defaultDeliveryMode = route.DefaultDeliveryMode__c;
            resolved.inactivityTtlHours = route.InactivityTtlHours__c;
            resolved.startNewSessionOnTerminalParent = route.StartNewSessionOnTerminalParent__c;
            resolved.terminalFieldApiName = route.TerminalFieldApiName__c;
            resolved.terminalFieldValues = route.TerminalFieldValues__c;
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
        }
    }

    private Boolean matchesEntryObjectType(Set<String> entryObjectTypes, String routeEntryObjectType) {
        if (String.isBlank(routeEntryObjectType) || '*'.equals(routeEntryObjectType.trim())) {
            return true;
        }
        return entryObjectTypes != null && entryObjectTypes.contains(routeEntryObjectType.trim());
    }

    private List<ChannelEndpoint__mdt> queryActiveEndpoints() {
        if (Test.isRunningTest() && testEndpointsByDeveloperName != null) {
            List<ChannelEndpoint__mdt> endpoints = new List<ChannelEndpoint__mdt>();
            for (ChannelEndpoint__mdt endpoint : testEndpointsByDeveloperName.values()) {
                if (endpoint != null && endpoint.IsActive__c == true) {
                    endpoints.add(endpoint);
                }
            }
            return endpoints;
        }
        return [
            SELECT DeveloperName, Channel__c, Provider__c, EndpointIdentifier__c, IsActive__c, RouteKey__c, SupportsAutonomousReply__c
            FROM ChannelEndpoint__mdt
            WHERE IsActive__c = TRUE
        ];
    }

    private List<AgentChannelRoute__mdt> queryActiveRoutes() {
        if (Test.isRunningTest() && testRoutes != null) {
            List<AgentChannelRoute__mdt> activeRoutes = new List<AgentChannelRoute__mdt>();
            for (AgentChannelRoute__mdt route : testRoutes) {
                if (route != null && route.IsActive__c == true) {
                    activeRoutes.add(route);
                }
            }
            return activeRoutes;
        }
        return [
            SELECT
                DeveloperName,
                AgentDeveloperName__c,
                ChannelEndpoint__c,
                EntryObjectType__c,
                Priority__c,
                DefaultDeliveryMode__c,
                InactivityTtlHours__c,
                StartNewSessionOnTerminalParent__c,
                TerminalFieldApiName__c,
                TerminalFieldValues__c,
                IsActive__c
            FROM AgentChannelRoute__mdt
            WHERE IsActive__c = TRUE
            ORDER BY Priority__c DESC, DeveloperName ASC
        ];
    }
}
