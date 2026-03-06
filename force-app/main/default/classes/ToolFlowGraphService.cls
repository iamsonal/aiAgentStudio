/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Core runtime engine for the Tool Flow Graph.
 *
 * The flow graph is a forward-looking model where the admin defines entry tools
 * and explicit typed transitions. At runtime, only eligible tools are exposed to
 * the LLM — the LLM cannot call future tools, skip nodes, or go backwards.
 *
 * Gateway types:
 *   sequential — one specific next tool; show it when from-tool completes
 *   parallel   — all to-tools run simultaneously; show all when from-tool completes
 *   exclusive  — LLM picks one branch; show all options, lock out others once one is called
 *
 * Join gate: when from is an array, all listed tools must have succeeded before to-tools unlock.
 */
public inherited sharing class ToolFlowGraphService {
    private static final String LOG_PREFIX = '[ToolFlowGraphService] ';

    // ── Inner classes ──────────────────────────────────────────────────────────

    public class FlowRule {
        public List<String> fromTools;
        public String type; // sequential | parallel | exclusive
        public List<String> toTools;

        public FlowRule(List<String> fromList, String ruleType, List<String> toList) {
            this.fromTools = fromList != null ? fromList : new List<String>();
            this.type = String.isBlank(ruleType) ? 'sequential' : ruleType.toLowerCase().trim();
            this.toTools = toList != null ? toList : new List<String>();
        }

        public Boolean isJoinGate() {
            return this.fromTools != null && this.fromTools.size() > 1;
        }
    }

    public class FlowGraph {
        public String version;
        public String capabilitiesHash;
        public List<String> entry;
        public List<FlowRule> flow;

        public FlowGraph() {
            this.entry = new List<String>();
            this.flow = new List<FlowRule>();
        }

        public Boolean hasFlow() {
            return this.flow != null && !this.flow.isEmpty();
        }
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    /**
     * @description Entry point: filters a capability list down to those eligible
     * according to the flow graph for this execution's current state.
     * Falls back to returning all capabilities when no graph is configured.
     *
     * @param capabilities All External capabilities for the agent
     * @param agentDef     Agent definition record (must include ToolFlowGraph__c, EnableToolFlowGraph__c)
     * @param executionId  The current AgentExecution__c ID
     * @return Filtered list of capabilities the LLM may currently call
     */
    public static List<AgentCapability__c> filterToEligible(List<AgentCapability__c> capabilities, AIAgentDefinition__c agentDef, Id executionId) {
        if (capabilities == null || capabilities.isEmpty()) {
            return capabilities;
        }

        if (agentDef == null || agentDef.EnableToolFlowGraph__c != true || String.isBlank(agentDef.ToolFlowGraph__c)) {
            return capabilities;
        }

        FlowGraph graph;
        try {
            graph = parseGraph(agentDef.ToolFlowGraph__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Failed to parse ToolFlowGraph__c, returning all capabilities: ' + e.getMessage());
            return capabilities;
        }

        if (!graph.hasFlow() && (graph.entry == null || graph.entry.isEmpty())) {
            return capabilities;
        }

        Set<String> executedTools = getExecutedToolsForExecution(executionId);
        Set<String> lockedBranches = TransactionContext.getInstance().getLockedBranches(executionId);

        Set<String> eligibleNames = computeEligibleTools(graph, executedTools, lockedBranches);

        List<AgentCapability__c> filtered = new List<AgentCapability__c>();
        for (AgentCapability__c cap : capabilities) {
            if (eligibleNames.contains(cap.CapabilityName__c)) {
                filtered.add(cap);
            }
        }

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX + 'Flow graph filtered ' + capabilities.size() + ' capabilities → ' + filtered.size() + ' eligible. Execution: ' + executionId
        );

        return filtered;
    }

    /**
     * @description Computes the set of tool names eligible to be called right now.
     *
     * Algorithm:
     *   eligible = entry tools (always available unless individually locked)
     *   for each rule where ALL from-tools are in executedTools:
     *       add rule.to tools that are not in lockedBranches
     *
     * @param graph         Parsed FlowGraph
     * @param executedTools Set of tool names already executed successfully in this execution
     * @param lockedBranches Set of tool names locked out due to exclusive path selection
     * @return Set of tool names currently eligible
     */
    @TestVisible
    public static Set<String> computeEligibleTools(FlowGraph graph, Set<String> executedTools, Set<String> lockedBranches) {
        Set<String> eligible = new Set<String>();
        Set<String> executed = executedTools != null ? executedTools : new Set<String>();
        Set<String> locked = lockedBranches != null ? lockedBranches : new Set<String>();

        // Entry tools are always eligible (supports repeated calls like score_account_fit)
        if (graph.entry != null) {
            for (String entryTool : graph.entry) {
                if (!locked.contains(entryTool)) {
                    eligible.add(entryTool);
                }
            }
        }

        // Evaluate each flow rule
        if (graph.flow != null) {
            for (FlowRule rule : graph.flow) {
                if (rule.fromTools == null || rule.fromTools.isEmpty() || rule.toTools == null || rule.toTools.isEmpty()) {
                    continue;
                }

                // Check that ALL from-tools have been executed (join gate or single)
                Boolean allFromSatisfied = true;
                for (String fromTool : rule.fromTools) {
                    if (!executed.contains(fromTool)) {
                        allFromSatisfied = false;
                        break;
                    }
                }

                if (!allFromSatisfied) {
                    continue;
                }

                for (String toTool : rule.toTools) {
                    if (!locked.contains(toTool)) {
                        eligible.add(toTool);
                    }
                }
            }
        }

        return eligible;
    }

    /**
     * @description After a tool executes successfully, checks if it came from an
     * exclusive rule and locks out sibling branches in TransactionContext.
     *
     * @param agentDef    Agent definition (must include ToolFlowGraph__c)
     * @param toolName    The name of the tool that just executed successfully
     * @param executionId The current AgentExecution__c ID
     */
    public static void lockExclusiveSiblings(AIAgentDefinition__c agentDef, String toolName, Id executionId) {
        if (agentDef == null || String.isBlank(agentDef.ToolFlowGraph__c) || String.isBlank(toolName) || executionId == null) {
            return;
        }

        FlowGraph graph;
        try {
            graph = parseGraph(agentDef.ToolFlowGraph__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'lockExclusiveSiblings: Failed to parse graph: ' + e.getMessage());
            return;
        }

        if (graph.flow == null) {
            return;
        }

        Set<String> executedTools = getExecutedToolsForExecution(executionId);
        for (FlowRule rule : graph.flow) {
            if (!'exclusive'.equals(rule.type)) {
                continue;
            }
            if (rule.toTools == null || !rule.toTools.contains(toolName)) {
                continue;
            }
            Boolean fromToolsSatisfied = true;
            for (String fromTool : rule.fromTools) {
                if (executedTools == null || !executedTools.contains(fromTool)) {
                    fromToolsSatisfied = false;
                    break;
                }
            }
            if (!fromToolsSatisfied) {
                continue;
            }
            // This tool was chosen from an exclusive rule — lock the siblings
            for (String sibling : rule.toTools) {
                if (!sibling.equals(toolName)) {
                    TransactionContext.getInstance().lockBranch(executionId, sibling);
                    System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Locked exclusive sibling: ' + sibling + ' (execution: ' + executionId + ')');
                }
            }
        }
    }

    /**
     * @description Parses the ToolFlowGraph__c JSON into a FlowGraph object.
     */
    public static FlowGraph parseGraph(String graphJson) {
        FlowGraph graph = new FlowGraph();

        if (String.isBlank(graphJson)) {
            return graph;
        }

        Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(graphJson);

        graph.version = root.containsKey('version') ? String.valueOf(root.get('version')) : null;
        graph.capabilitiesHash = root.containsKey('capabilitiesHash') ? String.valueOf(root.get('capabilitiesHash')) : null;

        // Parse entry tools
        if (root.containsKey('entry')) {
            Object entryRaw = root.get('entry');
            if (entryRaw instanceof List<Object>) {
                for (Object item : (List<Object>) entryRaw) {
                    if (item != null) {
                        graph.entry.add(String.valueOf(item));
                    }
                }
            }
        }

        // Parse flow rules
        if (root.containsKey('flow')) {
            Object flowRaw = root.get('flow');
            if (flowRaw instanceof List<Object>) {
                for (Object ruleObj : (List<Object>) flowRaw) {
                    if (!(ruleObj instanceof Map<String, Object>)) {
                        continue;
                    }
                    Map<String, Object> ruleMap = (Map<String, Object>) ruleObj;

                    // Parse fromTools (string or array — LLM sometimes emits a bare string)
                    List<String> fromList = new List<String>();
                    Object fromRaw = ruleMap.get('fromTools');
                    if (fromRaw instanceof String) {
                        fromList.add((String) fromRaw);
                    } else if (fromRaw instanceof List<Object>) {
                        for (Object item : (List<Object>) fromRaw) {
                            if (item != null)
                                fromList.add(String.valueOf(item));
                        }
                    }

                    String ruleType = ruleMap.containsKey('type') ? String.valueOf(ruleMap.get('type')) : 'sequential';

                    // Parse toTools
                    List<String> toList = new List<String>();
                    Object toRaw = ruleMap.get('toTools');
                    if (toRaw instanceof List<Object>) {
                        for (Object item : (List<Object>) toRaw) {
                            if (item != null)
                                toList.add(String.valueOf(item));
                        }
                    } else if (toRaw instanceof String) {
                        toList.add((String) toRaw);
                    }

                    if (!fromList.isEmpty() && !toList.isEmpty()) {
                        graph.flow.add(new FlowRule(fromList, ruleType, toList));
                    }
                }
            }
        }

        return graph;
    }

    /**
     * @description Generates a SHA-256 capabilities hash for staleness detection.
     * Sorted by capability name for deterministic output.
     */
    public static String generateCapabilitiesHash(List<AgentCapability__c> capabilities) {
        if (capabilities == null || capabilities.isEmpty()) {
            return '';
        }

        List<String> signatures = new List<String>();
        for (AgentCapability__c cap : capabilities) {
            String sig =
                (cap.CapabilityName__c ?? '') +
                '|' +
                (cap.Description__c ?? '') +
                '|' +
                (cap.ExposureLevel__c ?? '') +
                '|' +
                (cap.RunAsynchronously__c == true ? '1' : '0');
            signatures.add(sig);
        }
        signatures.sort();

        Blob hash = Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(signatures, '||')));
        return EncodingUtil.convertToHex(hash).substring(0, 16);
    }

    /**
     * @description Returns true if the current capabilities have changed since the graph was generated.
     */
    public static Boolean isGraphStale(String currentHash, String storedHash) {
        if (String.isBlank(storedHash)) {
            return true;
        }
        return !currentHash.equals(storedHash);
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    private static Set<String> getExecutedToolsForExecution(Id executionId) {
        Set<String> executed = new Set<String>();

        if (executionId == null) {
            return executed;
        }

        // Query persisted successful tool results
        List<ExecutionStep__c> toolSteps = [
            SELECT ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId AND StepType__c = 'ToolResult' AND IsError__c = FALSE AND ToolName__c != NULL
        ];
        for (ExecutionStep__c step : toolSteps) {
            executed.add(step.ToolName__c);
        }

        // Merge in-transaction tools not yet persisted
        Set<String> transactionTools = TransactionContext.getInstance().getExecutedTools(executionId);
        if (transactionTools != null) {
            executed.addAll(transactionTools);
        }

        return executed;
    }
}
