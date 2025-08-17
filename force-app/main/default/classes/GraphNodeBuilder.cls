/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * GraphNodeBuilder provides a fluent, programmatic API for constructing and configuring
 * graph node records (GraphNode__c) for AI agent workflow graphs. It enables developers to:
 *   - Define node properties, input mappings, and routing logic using a readable builder pattern
 *   - Configure conditional and unconditional edges for graph traversal
 *   - Map semantic references to primitive capability inputs
 *   - Ensure node configuration validity before creation
 *
 * This builder is intended for use in test setup, dynamic graph construction, and automation scenarios
 * where graph nodes must be created or modified in code rather than declaratively.
 */
public class GraphNodeBuilder {
    private String nodeName;
    private Id agentCapabilityId;
    private Id primitiveCapabilityId;
    private Boolean isEntryPoint = false;
    private Boolean startAsynchronously = false;
    private Map<String, String> inputMappings = new Map<String, String>();
    private List<ConditionalEdge> edges = new List<ConditionalEdge>();

    /**
     * Private constructor to enforce use of the static create() method for builder instantiation.
     *
     * @param nodeName  The unique name for this graph node.
     */
    private GraphNodeBuilder(String nodeName) {
        this.nodeName = nodeName;
    }

    /**
     * Creates a new GraphNodeBuilder instance for the specified node name.
     *
     * @param nodeName  The unique name for this graph node.
     * @return GraphNodeBuilder  A new builder instance for method chaining.
     */
    public static GraphNodeBuilder create(String nodeName) {
        return new GraphNodeBuilder(nodeName);
    }

    /**
     * Associates this node with a parent AgentCapability__c graph.
     *
     * @param agentCapabilityId  The Id of the parent AgentCapability__c record.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder forCapability(Id agentCapabilityId) {
        this.agentCapabilityId = agentCapabilityId;
        return this;
    }

    /**
     * Specifies the primitive capability this node should execute by name.
     *
     * @param capabilityName  The name of the primitive capability to run.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     * @throws IllegalArgumentException if the capability name is not found.
     */
    public GraphNodeBuilder runCapability(String capabilityName) {
        this.primitiveCapabilityId = findCapabilityId(capabilityName);
        return this;
    }

    /**
     * Marks this node as the entry point for graph execution.
     *
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder asEntryPoint() {
        this.isEntryPoint = true;
        return this;
    }

    /**
     * Configures this node to start execution asynchronously.
     *
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder startAsync() {
        this.startAsynchronously = true;
        return this;
    }

    /**
     * Maps a semantic reference to a target input field for this node's primitive capability.
     *
     * @param targetField  The name of the input parameter for the primitive capability.
     * @param semanticRef  The semantic reference (e.g., {!input.fieldName}) to map.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder mapInput(String targetField, String semanticRef) {
        inputMappings.put(targetField, semanticRef);
        return this;
    }

    /**
     * Adds a conditional edge that routes to the specified node if the primitive execution succeeds.
     *
     * @param nextNode  The name of the node to route to on success.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder routeWhenSuccess(String nextNode) {
        edges.add(new ConditionalEdge('{!result.isSuccess} == true', nextNode, 1));
        return this;
    }

    /**
     * Adds a conditional edge that routes to the specified node if the primitive execution fails.
     *
     * @param nextNode  The name of the node to route to on error.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder routeWhenError(String nextNode) {
        edges.add(new ConditionalEdge('{!result.isSuccess} != true', nextNode, 2));
        return this;
    }

    /**
     * Adds a custom conditional edge that routes to the specified node if the condition is met.
     *
     * @param nextNode  The name of the node to route to.
     * @param condition The semantic reference condition to evaluate (e.g., '{!result.output.productFamily} == \'Hardware\'').
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder addConditionalEdge(String nextNode, String condition) {
        // Use a priority that is lower than success/error but higher than 'always'
        edges.add(new ConditionalEdge(condition, nextNode, 3));
        return this;
    }

    /**
     * Adds an unconditional edge that always routes to the specified node, regardless of result.
     *
     * @param nextNode  The name of the node to route to unconditionally.
     * @return GraphNodeBuilder  This builder instance for method chaining.
     */
    public GraphNodeBuilder routeAlways(String nextNode) {
        edges.add(new ConditionalEdge('true', nextNode, 999));
        return this;
    }

    /**
     * Builds and returns the configured GraphNode__c record.
     *
     * @return GraphNode__c  The constructed graph node record.
     * @throws IllegalArgumentException if required configuration is missing.
     * @sideeffect Throws if nodeName or agentCapabilityId are not set.
     */
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

    /**
     * Validates the current builder configuration before building.
     *
     * @throws IllegalArgumentException if required fields are missing.
     */
    private void validate() {
        if (String.isBlank(nodeName))
            throw new IllegalArgumentException('Node name required');
        if (agentCapabilityId == null)
            throw new IllegalArgumentException('Agent capability required');
    }

    /**
     * Serializes the input mappings to JSON for storage in GraphNode__c.
     *
     * @return String  The JSON string representing input mappings.
     */
    private String buildInputMappingsJson() {
        if (inputMappings.isEmpty())
            return '{}';
        return JSON.serialize(inputMappings);
    }

    /**
     * Serializes the conditional edges to JSON for storage in GraphNode__c.
     * Edges are sorted by priority to ensure correct evaluation order.
     *
     * @return String  The JSON string representing conditional edges.
     */
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

    /**
     * Finds the Id of an AgentCapability__c by its name.
     *
     * @param capabilityName  The name of the capability to look up.
     * @return Id  The Id of the found capability.
     * @throws IllegalArgumentException if the capability is not found.
     */
    private Id findCapabilityId(String capabilityName) {
        List<AgentCapability__c> caps = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = :capabilityName LIMIT 1];
        if (caps.isEmpty()) {
            System.debug(LoggingLevel.ERROR, '[GraphNodeBuilder] Capability not found: ' + capabilityName);
            throw new IllegalArgumentException('Capability not found: ' + capabilityName);
        }
        return caps[0].Id;
    }

    /**
     * Represents a conditional edge for graph routing, with a condition, target node, and priority.
     */
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

    /**
     * Comparator for sorting ConditionalEdge objects by priority (ascending).
     */
    private class EdgeComparator implements Comparator<ConditionalEdge> {
        public Integer compare(ConditionalEdge a, ConditionalEdge b) {
            return a.priority - b.priority;
        }
    }
}
