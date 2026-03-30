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
        Map<String, String> routeNamesByKey = new Map<String, String>();
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
            if (!matchesEntryObjectType(normalizedEntryObjectTypes, route.EntryObjectType__c)) {
                continue;
            }
            if (String.isBlank(route.ChannelEndpoint__c)) {
                System.debug(
                    LoggingLevel.WARN,
                    LOG_PREFIX + 'Skipping invalid active route "' + String.valueOf(route.DeveloperName) + '" because ChannelEndpoint__c was blank.'
                );
                continue;
            }

            ChannelEndpoint__mdt endpoint = endpointsByDeveloperName.get(route.ChannelEndpoint__c);
            if (endpoint == null) {
                if (!allEndpointsByDeveloperName.containsKey(route.ChannelEndpoint__c)) {
                    System.debug(
                        LoggingLevel.WARN,
                        LOG_PREFIX +
                            'Skipping invalid active route "' +
                            String.valueOf(route.DeveloperName) +
                            '" because endpoint "' +
                            route.ChannelEndpoint__c +
                            '" was missing or inactive.'
                    );
                }
                continue;
            }

            String key = buildRouteKey(route.EntryObjectType__c, endpoint.EndpointIdentifier__c);
            if (routesByKey.containsKey(key)) {
                throw new AIAgentException.OrchestrationException(
                    'Duplicate active AgentChannelRoute__mdt configuration. Routes "' +
                        routeNamesByKey.get(key) +
                        '" and "' +
                        String.valueOf(route.DeveloperName) +
                        '" resolve to the same inbound key "' +
                        key +
                        '".'
                );
            }

            ResolvedRoute resolved = new ResolvedRoute();
            resolved.channel = endpoint.Channel__c;
            resolved.agentDeveloperName = route.AgentDeveloperName__c;
            resolved.entryObjectType = route.EntryObjectType__c;
            resolved.endpointDeveloperName = route.ChannelEndpoint__c;
            resolved.endpointIdentifier = endpoint.EndpointIdentifier__c;
            resolved.routeKey = endpoint.RouteKey__c;
            resolved.provider = deriveProviderKey(endpoint);
            resolved.supportsAutonomousReply = endpoint.SupportsAutonomousReply__c;
            resolved.defaultDeliveryMode = route.DefaultDeliveryMode__c;
            resolved.inactivityTtlHours = route.InactivityTtlHours__c;
            resolved.startNewSessionOnTerminalParent = route.StartNewSessionOnTerminalParent__c;
            resolved.terminalFieldApiName = route.TerminalFieldApiName__c;
            resolved.terminalFieldValues = route.TerminalFieldValues__c;
            resolved.priority = route.Priority__c;
            routesByKey.put(key, resolved);
            routeNamesByKey.put(key, route.DeveloperName);
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

    public String resolveEffectiveCompletionMode(AIAgentDefinition__c agentDefinition, AgentExecution__c execution) {
        if (execution != null && String.isNotBlank(execution.CompletionMode__c)) {
            return execution.CompletionMode__c;
        }
        return String.isNotBlank(agentDefinition != null ? agentDefinition.DefaultCompletionMode__c : null)
            ? agentDefinition.DefaultCompletionMode__c
            : 'Auto Reply';
    }

    public static String buildRouteKey(String entryObjectType, String endpointIdentifier) {
        String normalizedObject = String.isNotBlank(entryObjectType) ? entryObjectType.trim() : '*';
        String normalizedEndpoint = String.isNotBlank(endpointIdentifier) ? endpointIdentifier.trim().toLowerCase() : '*';
        return normalizedObject + '|' + normalizedEndpoint;
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
            SELECT DeveloperName, Channel__c, ProviderAdapterClass__c, EndpointIdentifier__c, IsActive__c, RouteKey__c, SupportsAutonomousReply__c
            FROM ChannelEndpoint__mdt
            WHERE IsActive__c = TRUE
        ];
    }

    private String deriveProviderKey(ChannelEndpoint__mdt endpoint) {
        if (endpoint == null) {
            return null;
        }
        if (String.isBlank(endpoint.ProviderAdapterClass__c)) {
            return null;
        }

        Type providerType = Type.forName(endpoint.ProviderAdapterClass__c);
        if (providerType == null) {
            throw new AIAgentException.OrchestrationException(
                'External messaging provider class not found: ' + endpoint.ProviderAdapterClass__c + ' for endpoint ' + endpoint.DeveloperName
            );
        }

        Object instanceObj = providerType.newInstance();
        if (!(instanceObj instanceof IExternalMessagingProvider)) {
            throw new AIAgentException.OrchestrationException(
                'External messaging provider must implement IExternalMessagingProvider: ' + endpoint.ProviderAdapterClass__c
            );
        }

        String providerKey = ((IExternalMessagingProvider) instanceObj).getProviderKey();
        if (String.isBlank(providerKey)) {
            throw new AIAgentException.OrchestrationException(
                'External messaging provider "' + endpoint.ProviderAdapterClass__c + '" returned a blank provider key for endpoint ' + endpoint.DeveloperName + '.'
            );
        }
        return providerKey;
    }

    private List<AgentChannelRoute__mdt> queryActiveRoutes() {
        if (Test.isRunningTest() && testRoutes != null) {
            List<AgentChannelRoute__mdt> activeRoutes = new List<AgentChannelRoute__mdt>();
            for (AgentChannelRoute__mdt route : testRoutes) {
                if (route != null && route.IsActive__c == true) {
                    activeRoutes.add(route);
                }
            }
            return sortRoutesLikeProduction(activeRoutes);
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

    private List<AgentChannelRoute__mdt> sortRoutesLikeProduction(List<AgentChannelRoute__mdt> routes) {
        List<RouteSortWrapper> wrappers = new List<RouteSortWrapper>();
        for (AgentChannelRoute__mdt route : routes) {
            wrappers.add(new RouteSortWrapper(route));
        }
        wrappers.sort();

        List<AgentChannelRoute__mdt> sortedRoutes = new List<AgentChannelRoute__mdt>();
        for (RouteSortWrapper wrapper : wrappers) {
            sortedRoutes.add(wrapper.route);
        }
        return sortedRoutes;
    }

    private class RouteSortWrapper implements Comparable {
        private AgentChannelRoute__mdt route;

        private RouteSortWrapper(AgentChannelRoute__mdt route) {
            this.route = route;
        }

        public Integer compareTo(Object otherObj) {
            RouteSortWrapper other = (RouteSortWrapper) otherObj;
            Decimal thisPriority = route != null && route.Priority__c != null ? route.Priority__c : 0;
            Decimal otherPriority = other != null && other.route != null && other.route.Priority__c != null ? other.route.Priority__c : 0;
            if (thisPriority > otherPriority) {
                return -1;
            }
            if (thisPriority < otherPriority) {
                return 1;
            }

            String thisName = route != null && String.isNotBlank(route.DeveloperName) ? route.DeveloperName : '';
            String otherName = other != null && other.route != null && String.isNotBlank(other.route.DeveloperName) ? other.route.DeveloperName : '';
            return thisName.compareTo(otherName);
        }
    }
}
