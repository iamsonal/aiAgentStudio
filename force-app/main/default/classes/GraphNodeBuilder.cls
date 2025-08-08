/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Fluent API for building graph nodes with semantic references
 */
public class GraphNodeBuilder {
    private String nodeName;
    private Id agentCapabilityId;
    private Id primitiveCapabilityId;
    private Boolean isEntryPoint = false;
    private Boolean startAsynchronously = false;
    private Map<String, String> inputMappings = new Map<String, String>();
    private List<ConditionalEdge> edges = new List<ConditionalEdge>();

    private GraphNodeBuilder(String nodeName) {
        this.nodeName = nodeName;
    }

    public static GraphNodeBuilder create(String nodeName) {
        return new GraphNodeBuilder(nodeName);
    }

    public GraphNodeBuilder forCapability(Id agentCapabilityId) {
        this.agentCapabilityId = agentCapabilityId;
        return this;
    }

    public GraphNodeBuilder runCapability(String capabilityName) {
        this.primitiveCapabilityId = findCapabilityId(capabilityName);
        return this;
    }

    public GraphNodeBuilder asEntryPoint() {
        this.isEntryPoint = true;
        return this;
    }

    public GraphNodeBuilder startAsync() {
        this.startAsynchronously = true;
        return this;
    }

    public GraphNodeBuilder mapInput(String targetField, String semanticRef) {
        inputMappings.put(targetField, semanticRef);
        return this;
    }

    public GraphNodeBuilder routeWhenSuccess(String nextNode) {
        edges.add(new ConditionalEdge('{!result.isSuccess} == true', nextNode, 1));
        return this;
    }

    public GraphNodeBuilder routeWhenError(String nextNode) {
        edges.add(new ConditionalEdge('{!result.isSuccess} != true', nextNode, 2));
        return this;
    }

    public GraphNodeBuilder routeAlways(String nextNode) {
        edges.add(new ConditionalEdge('true', nextNode, 999));
        return this;
    }

    public GraphNode__c build() {
        validate();

        return new GraphNode__c(
            NodeName__c = nodeName,
            AgentCapability__c = agentCapabilityId,
            PrimitiveCapabilityToRun__c = primitiveCapabilityId,
            IsEntryPoint__c = isEntryPoint,
            StartAsynchronously__c = startAsynchronously,
            InputMappings__c = buildInputMappingsJson(),
            ConditionalEdges__c = buildConditionalEdgesJson()
        );
    }

    private void validate() {
        if (String.isBlank(nodeName))
            throw new IllegalArgumentException('Node name required');
        if (agentCapabilityId == null)
            throw new IllegalArgumentException('Agent capability required');
    }

    private String buildInputMappingsJson() {
        if (inputMappings.isEmpty())
            return '{}';
        return JSON.serialize(inputMappings);
    }

    private String buildConditionalEdgesJson() {
        if (edges.isEmpty())
            return '[]';

        edges.sort(new EdgeComparator());
        List<Map<String, String>> converted = new List<Map<String, String>>();

        for (ConditionalEdge edge : edges) {
            converted.add(new Map<String, String>{ 'condition' => edge.condition, 'nextNode' => edge.nextNode });
        }
        return JSON.serialize(converted);
    }

    private Id findCapabilityId(String capabilityName) {
        List<AgentCapability__c> caps = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = :capabilityName LIMIT 1];
        if (caps.isEmpty())
            throw new IllegalArgumentException('Capability not found: ' + capabilityName);
        return caps[0].Id;
    }

    private class ConditionalEdge {
        String condition;
        String nextNode;
        Integer priority;

        ConditionalEdge(String condition, String nextNode, Integer priority) {
            this.condition = condition;
            this.nextNode = nextNode;
            this.priority = priority;
        }
    }

    private class EdgeComparator implements Comparator<ConditionalEdge> {
        public Integer compare(ConditionalEdge a, ConditionalEdge b) {
            return a.priority - b.priority;
        }
    }
}
