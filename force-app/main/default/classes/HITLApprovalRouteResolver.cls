/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Resolves HITL approval-routing metadata into a deterministic
 * approval process + routing snapshot for a pending HITL artifact.
 */
public inherited sharing class HITLApprovalRouteResolver {
    public class RouteResolutionException extends Exception {
    }

    public class RouteContext {
        public String artifactType { get; set; }
        public String interactionChannel { get; set; }
        public String agentDeveloperName { get; set; }
        public String capabilityDeveloperName { get; set; }
    }

    public class ResolvedRoute {
        public String routeDeveloperName { get; set; }
        public String artifactType { get; set; }
        public String interactionChannel { get; set; }
        public String agentDeveloperName { get; set; }
        public String capabilityDeveloperName { get; set; }
        public String approvalCategory { get; set; }
        public String approvalProcessDeveloperName { get; set; }
        public String approverRoutingType { get; set; }
        public String approverRoutingKey { get; set; }
        public Integer priority { get; set; }
    }

    @TestVisible
    private static List<HITLApprovalRoute__mdt> testRoutes;

    public static ResolvedRoute resolveForToolApproval(HITLGatewayService.HITLContext context, String interactionChannel) {
        if (context == null) {
            throw new RouteResolutionException('HITL context is required to resolve approval routing.');
        }

        RouteContext routeContext = new RouteContext();
        routeContext.artifactType = HITLGatewayService.ARTIFACT_TYPE_TOOL_APPROVAL;
        routeContext.interactionChannel = interactionChannel;
        routeContext.agentDeveloperName = context.agentDefinition != null ? context.agentDefinition.DeveloperName__c : null;
        routeContext.capabilityDeveloperName = getCapabilityDeveloperName(context.capability);
        return resolve(routeContext);
    }

    public static ResolvedRoute resolveForOutboundDraftReview(AIAgentDefinition__c agentDefinition, String interactionChannel) {
        RouteContext routeContext = new RouteContext();
        routeContext.artifactType = HITLGatewayService.ARTIFACT_TYPE_OUTBOUND_DRAFT_REVIEW;
        routeContext.interactionChannel = interactionChannel;
        routeContext.agentDeveloperName = agentDefinition != null ? agentDefinition.DeveloperName__c : null;
        return resolve(routeContext);
    }

    public static ResolvedRoute resolve(RouteContext context) {
        if (context == null || String.isBlank(context.artifactType)) {
            throw new RouteResolutionException('Artifact type is required to resolve approval routing.');
        }

        List<RouteCandidate> matches = new List<RouteCandidate>();
        for (HITLApprovalRoute__mdt route : getActiveRoutes()) {
            if (!matches(route, context)) {
                continue;
            }
            matches.add(new RouteCandidate(route));
        }

        if (matches.isEmpty()) {
            throw new RouteResolutionException(
                'No active HITL approval route matched artifact "' +
                context.artifactType +
                '" for channel "' +
                safeValue(context.interactionChannel) +
                '", agent "' +
                safeValue(context.agentDeveloperName) +
                '", capability developer name "' +
                safeValue(context.capabilityDeveloperName) +
                '".'
            );
        }

        matches.sort();
        RouteCandidate winner = matches[0];
        if (matches.size() > 1 && winner.hasSamePrecedence(matches[1])) {
            throw new RouteResolutionException(
                'Ambiguous HITL approval routes matched with the same precedence: "' +
                winner.route.DeveloperName +
                '" and "' +
                matches[1].route.DeveloperName +
                '".'
            );
        }

        validateResolvedRoute(winner.route);
        return toResolvedRoute(winner.route);
    }

    @TestVisible
    static void setTestRoutes(List<HITLApprovalRoute__mdt> routes) {
        testRoutes = routes;
    }

    private static List<HITLApprovalRoute__mdt> getActiveRoutes() {
        if (testRoutes != null) {
            return testRoutes;
        }

        return [
            SELECT
                DeveloperName,
                ArtifactType__c,
                InteractionChannel__c,
                AgentDeveloperName__c,
                CapabilityDeveloperName__c,
                ApprovalCategory__c,
                ApprovalProcessDeveloperName__c,
                ApproverRoutingType__c,
                ApproverRoutingKey__c,
                Priority__c
            FROM HITLApprovalRoute__mdt
            WHERE IsActive__c = TRUE
        ];
    }

    private static Boolean matches(HITLApprovalRoute__mdt route, RouteContext context) {
        return matchesValue(route.ArtifactType__c, context.artifactType) &&
            matchesValue(route.InteractionChannel__c, context.interactionChannel) &&
            matchesValue(route.AgentDeveloperName__c, context.agentDeveloperName) &&
            matchesValue(route.CapabilityDeveloperName__c, context.capabilityDeveloperName);
    }

    private static Boolean matchesValue(String routeValue, String contextValue) {
        if (String.isBlank(routeValue)) {
            return true;
        }
        return normalize(routeValue) == normalize(contextValue);
    }

    private static String normalize(String value) {
        return String.isBlank(value) ? null : value.trim().toLowerCase();
    }

    private static String safeValue(String value) {
        return String.isBlank(value) ? '*' : value;
    }

    private static String getCapabilityDeveloperName(AgentCapability__c capability) {
        if (capability == null) {
            return null;
        }

        // AgentCapability__c does not currently expose a separate DeveloperName field,
        // so routing uses CapabilityName__c as the capability's stable developer-facing key.
        return capability.CapabilityName__c;
    }

    private static void validateResolvedRoute(HITLApprovalRoute__mdt route) {
        if (String.isBlank(route.ApprovalCategory__c)) {
            throw new RouteResolutionException('HITL approval route "' + route.DeveloperName + '" is missing ApprovalCategory__c.');
        }
        if (String.isBlank(route.ApprovalProcessDeveloperName__c)) {
            throw new RouteResolutionException('HITL approval route "' + route.DeveloperName + '" is missing ApprovalProcessDeveloperName__c.');
        }
    }

    private static ResolvedRoute toResolvedRoute(HITLApprovalRoute__mdt route) {
        ResolvedRoute resolved = new ResolvedRoute();
        resolved.routeDeveloperName = route.DeveloperName;
        resolved.artifactType = route.ArtifactType__c;
        resolved.interactionChannel = route.InteractionChannel__c;
        resolved.agentDeveloperName = route.AgentDeveloperName__c;
        resolved.capabilityDeveloperName = route.CapabilityDeveloperName__c;
        resolved.approvalCategory = route.ApprovalCategory__c;
        resolved.approvalProcessDeveloperName = route.ApprovalProcessDeveloperName__c;
        resolved.approverRoutingType = route.ApproverRoutingType__c;
        resolved.approverRoutingKey = route.ApproverRoutingKey__c;
        resolved.priority = route.Priority__c == null ? 0 : route.Priority__c.intValue();
        return resolved;
    }

    private class RouteCandidate implements Comparable {
        private HITLApprovalRoute__mdt route;
        private Integer priority;
        private Integer specificityScore;

        RouteCandidate(HITLApprovalRoute__mdt route) {
            this.route = route;
            this.priority = route.Priority__c == null ? 0 : route.Priority__c.intValue();
            this.specificityScore = 0;
            if (String.isNotBlank(route.ArtifactType__c)) {
                this.specificityScore++;
            }
            if (String.isNotBlank(route.InteractionChannel__c)) {
                this.specificityScore++;
            }
            if (String.isNotBlank(route.AgentDeveloperName__c)) {
                this.specificityScore++;
            }
            if (String.isNotBlank(route.CapabilityDeveloperName__c)) {
                this.specificityScore++;
            }
        }

        public Integer compareTo(Object other) {
            RouteCandidate otherCandidate = (RouteCandidate) other;
            if (this.priority != otherCandidate.priority) {
                return otherCandidate.priority - this.priority;
            }
            if (this.specificityScore != otherCandidate.specificityScore) {
                return otherCandidate.specificityScore - this.specificityScore;
            }
            return String.valueOf(this.route.DeveloperName).toLowerCase().compareTo(String.valueOf(otherCandidate.route.DeveloperName).toLowerCase());
        }

        public Boolean hasSamePrecedence(RouteCandidate other) {
            return other != null && this.priority == other.priority && this.specificityScore == other.specificityScore;
        }
    }
}
