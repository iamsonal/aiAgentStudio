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
        public Map<String, String> conditions;

        public FlowRule(List<String> fromList, String ruleType, List<String> toList, Map<String, String> ruleConditions) {
            this.fromTools = fromList != null ? fromList : new List<String>();
            this.type = String.isBlank(ruleType) ? 'sequential' : ruleType.toLowerCase().trim();
            this.toTools = toList != null ? toList : new List<String>();
            this.conditions = ruleConditions != null ? ruleConditions : new Map<String, String>();
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

    public class ValidationResult {
        public List<String> errors = new List<String>();
        public List<String> warnings = new List<String>();

        public Boolean isValid() {
            return this.errors.isEmpty();
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
        Set<String> lockedBranches = getLockedBranchesForExecution(graph, executionId, executedTools);

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
            if (!(entryRaw instanceof List<Object>)) {
                throw new AIAgentException('Tool flow graph entry must be an array.');
            }
            for (Object item : (List<Object>) entryRaw) {
                if (item != null) {
                    graph.entry.add(String.valueOf(item));
                }
            }
        }

        // Parse flow rules
        if (root.containsKey('flow')) {
            Object flowRaw = root.get('flow');
            if (!(flowRaw instanceof List<Object>)) {
                throw new AIAgentException('Tool flow graph flow must be an array.');
            }
            for (Object ruleObj : (List<Object>) flowRaw) {
                if (!(ruleObj instanceof Map<String, Object>)) {
                    throw new AIAgentException('Each tool flow rule must be an object.');
                }
                Map<String, Object> ruleMap = (Map<String, Object>) ruleObj;

                Object fromRaw = ruleMap.get('fromTools');
                if (!(fromRaw instanceof List<Object>)) {
                    throw new AIAgentException('Tool flow rule fromTools must be an array.');
                }
                List<String> fromList = new List<String>();
                for (Object item : (List<Object>) fromRaw) {
                    if (item != null) {
                        fromList.add(String.valueOf(item));
                    }
                }

                String ruleType = ruleMap.containsKey('type') ? String.valueOf(ruleMap.get('type')) : 'sequential';

                Object toRaw = ruleMap.get('toTools');
                if (!(toRaw instanceof List<Object>)) {
                    throw new AIAgentException('Tool flow rule toTools must be an array.');
                }
                List<String> toList = new List<String>();
                for (Object item : (List<Object>) toRaw) {
                    if (item != null) {
                        toList.add(String.valueOf(item));
                    }
                }

                Map<String, String> conditions = new Map<String, String>();
                if (ruleMap.containsKey('conditions') && ruleMap.get('conditions') instanceof Map<String, Object>) {
                    Map<String, Object> rawConditions = (Map<String, Object>) ruleMap.get('conditions');
                    for (String key : rawConditions.keySet()) {
                        Object value = rawConditions.get(key);
                        if (String.isNotBlank(key) && value != null) {
                            conditions.put(key, String.valueOf(value));
                        }
                    }
                }

                if (!fromList.isEmpty() && !toList.isEmpty()) {
                    graph.flow.add(new FlowRule(fromList, ruleType, toList, conditions));
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

    public static void validateGraphSemantics(FlowGraph graph, Set<String> validCapabilityNames, Boolean parallelCallingEnabled) {
        ValidationResult result = collectValidationIssues(graph, validCapabilityNames, parallelCallingEnabled);
        if (!result.isValid()) {
            throw new AIAgentException(String.join(result.errors, ' '));
        }
    }

    public static Map<String, String> validateRequestedTools(AIAgentDefinition__c agentDef, Id executionId, List<String> requestedToolNames) {
        Map<String, String> errorsByTool = new Map<String, String>();
        if (
            agentDef == null ||
            agentDef.EnableToolFlowGraph__c != true ||
            String.isBlank(agentDef.ToolFlowGraph__c) ||
            requestedToolNames == null ||
            requestedToolNames.isEmpty()
        ) {
            return errorsByTool;
        }

        FlowGraph graph;
        try {
            graph = parseGraph(agentDef.ToolFlowGraph__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'validateRequestedTools: Failed to parse graph, skipping runtime validation. ' + e.getMessage());
            return errorsByTool;
        }

        Set<String> executedTools = getExecutedToolsForExecution(executionId);
        Set<String> lockedBranches = getLockedBranchesForExecution(graph, executionId, executedTools);
        Set<String> eligibleNames = computeEligibleTools(graph, executedTools, lockedBranches);

        for (String toolName : requestedToolNames) {
            if (String.isBlank(toolName)) {
                continue;
            }
            if (!eligibleNames.contains(toolName)) {
                errorsByTool.put(toolName, 'Tool "' + toolName + '" is not eligible in the current Tool Flow Graph state.');
            }
        }

        if (graph.flow == null || graph.flow.isEmpty()) {
            return errorsByTool;
        }

        Set<String> requestedSet = new Set<String>();
        requestedSet.addAll(requestedToolNames);

        for (FlowRule rule : graph.flow) {
            if (!'exclusive'.equals(rule.type) || rule.toTools == null || rule.toTools.size() < 2) {
                continue;
            }
            if (!areAllFromToolsSatisfied(rule, executedTools)) {
                continue;
            }

            List<String> requestedBranches = new List<String>();
            for (String toTool : rule.toTools) {
                if (requestedSet.contains(toTool)) {
                    requestedBranches.add(toTool);
                }
            }

            if (requestedBranches.size() > 1) {
                String sourceLabel = String.join(rule.fromTools, ', ');
                for (String branchTool : requestedBranches) {
                    errorsByTool.put(
                        branchTool,
                        'Only one branch may be chosen from exclusive gateway [' + sourceLabel + ']. Requested: ' + String.join(requestedBranches, ', ') + '.'
                    );
                }
            }
        }

        return errorsByTool;
    }

    // ── Private helpers ────────────────────────────────────────────────────────

    @TestVisible
    private static ValidationResult collectValidationIssues(FlowGraph graph, Set<String> validCapabilityNames, Boolean parallelCallingEnabled) {
        ValidationResult result = new ValidationResult();
        if (graph == null) {
            result.errors.add('Graph payload is required.');
            return result;
        }
        if (validCapabilityNames == null || validCapabilityNames.isEmpty()) {
            result.errors.add('Cannot validate a Tool Flow Graph without external capabilities.');
            return result;
        }
        if (graph.entry == null || graph.entry.isEmpty()) {
            result.errors.add('Tool Flow Graph must define at least one entry tool.');
            return result;
        }

        Map<String, Set<String>> adjacency = new Map<String, Set<String>>();
        Map<String, List<FlowRule>> rulesBySource = new Map<String, List<FlowRule>>();

        for (String entryTool : graph.entry) {
            if (!validCapabilityNames.contains(entryTool)) {
                result.errors.add('Entry tool "' + entryTool + '" is not a valid capability.');
                continue;
            }
            if (!adjacency.containsKey(entryTool)) {
                adjacency.put(entryTool, new Set<String>());
            }
        }

        if (graph.flow != null) {
            Integer ruleIndex = 1;
            for (FlowRule rule : graph.flow) {
                if (rule.fromTools == null || rule.fromTools.isEmpty()) {
                    result.errors.add('Each flow rule must declare fromTools.');
                    ruleIndex++;
                    continue;
                }
                if (rule.toTools == null || rule.toTools.isEmpty()) {
                    result.errors.add('Each flow rule must declare toTools.');
                    ruleIndex++;
                    continue;
                }
                if (!new Set<String>{ 'sequential', 'parallel', 'exclusive' }.contains(rule.type)) {
                    result.errors.add('Rule ' + ruleIndex + ' has unsupported type "' + rule.type + '".');
                }
                if (hasDuplicates(rule.fromTools)) {
                    result.errors.add('Rule ' + ruleIndex + ' contains duplicate fromTools.');
                }
                if (hasDuplicates(rule.toTools)) {
                    result.errors.add('Rule ' + ruleIndex + ' contains duplicate toTools.');
                }
                if ('sequential'.equals(rule.type) && rule.toTools.size() != 1) {
                    result.errors.add('Sequential rules must declare exactly one toTool.');
                }
                if (rule.isJoinGate() && 'parallel'.equals(rule.type)) {
                    result.errors.add('Join gates cannot use the parallel rule type.');
                }
                if ('parallel'.equals(rule.type) && parallelCallingEnabled != true) {
                    result.errors.add('Parallel rules are not allowed when Parallel Tool Calling is disabled on the agent.');
                }
                if ('exclusive'.equals(rule.type)) {
                    if (rule.toTools.size() < 2) {
                        result.errors.add('Exclusive rules must declare at least two toTools.');
                    }
                    validateExclusiveConditions(rule, ruleIndex, result);
                }

                for (String fromTool : rule.fromTools) {
                    if (!validCapabilityNames.contains(fromTool)) {
                        result.errors.add('Rule references unknown fromTool "' + fromTool + '".');
                        continue;
                    }
                    if (!adjacency.containsKey(fromTool)) {
                        adjacency.put(fromTool, new Set<String>());
                    }
                    for (String toTool : rule.toTools) {
                        if (!validCapabilityNames.contains(toTool)) {
                            result.errors.add('Rule references unknown toTool "' + toTool + '".');
                            continue;
                        }
                        adjacency.get(fromTool).add(toTool);
                        if (!adjacency.containsKey(toTool)) {
                            adjacency.put(toTool, new Set<String>());
                        }
                    }
                }

                String sourceSignature = buildSourceSignature(rule.fromTools);
                if (!rulesBySource.containsKey(sourceSignature)) {
                    rulesBySource.put(sourceSignature, new List<FlowRule>());
                }
                rulesBySource.get(sourceSignature).add(rule);
                ruleIndex++;
            }
        }

        for (String sourceSignature : rulesBySource.keySet()) {
            List<FlowRule> siblingRules = rulesBySource.get(sourceSignature);
            if (siblingRules == null || siblingRules.size() <= 1) {
                continue;
            }

            result.errors.add(
                'Source set [' +
                    sourceSignature +
                    '] is defined by multiple flow rules. Consolidate it into a single ' +
                    siblingRules[0].type +
                    ', parallel, or exclusive rule.'
            );

            Set<String> siblingTargets = new Set<String>();
            for (FlowRule siblingRule : siblingRules) {
                for (String toTool : siblingRule.toTools) {
                    if (siblingTargets.contains(toTool)) {
                        result.errors.add('Source set [' + sourceSignature + '] routes to "' + toTool + '" more than once.');
                    } else {
                        siblingTargets.add(toTool);
                    }
                }
            }
        }

        Set<String> reachable = computeReachableTools(graph.entry, adjacency);
        for (String capabilityName : validCapabilityNames) {
            if (!reachable.contains(capabilityName)) {
                result.errors.add('Capability "' + capabilityName + '" is not reachable from the graph entry set.');
            }
        }
        if (hasCycle(adjacency)) {
            result.errors.add('Tool Flow Graph cannot contain cycles.');
        }

        return result;
    }

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

    private static String buildSourceSignature(List<String> fromTools) {
        List<String> normalized = new List<String>();
        if (fromTools != null) {
            normalized.addAll(fromTools);
        }
        normalized.sort();
        return String.join(normalized, ', ');
    }

    private static Boolean hasDuplicates(List<String> values) {
        if (values == null || values.isEmpty()) {
            return false;
        }
        Set<String> seen = new Set<String>();
        for (String value : values) {
            if (seen.contains(value)) {
                return true;
            }
            seen.add(value);
        }
        return false;
    }

    private static void validateExclusiveConditions(FlowRule rule, Integer ruleIndex, ValidationResult result) {
        Set<String> normalizedConditions = new Set<String>();
        for (String toTool : rule.toTools) {
            String conditionLabel = rule.conditions != null ? rule.conditions.get(toTool) : null;
            if (String.isBlank(conditionLabel)) {
                result.errors.add('Exclusive rule ' + ruleIndex + ' is missing a condition label for "' + toTool + '".');
                continue;
            }

            String normalized = conditionLabel.trim().toLowerCase();
            if (isPlaceholderConditionLabel(normalized)) {
                result.errors.add('Exclusive rule ' + ruleIndex + ' uses placeholder condition text for "' + toTool + '".');
            }
            if (normalizedConditions.contains(normalized)) {
                result.errors.add('Exclusive rule ' + ruleIndex + ' reuses the same condition label for multiple branches.');
            } else {
                normalizedConditions.add(normalized);
            }
        }
    }

    private static Boolean isPlaceholderConditionLabel(String normalizedCondition) {
        if (String.isBlank(normalizedCondition)) {
            return true;
        }
        return normalizedCondition == 'default condition' || normalizedCondition.startsWith('condition ');
    }

    private static Boolean areAllFromToolsSatisfied(FlowRule rule, Set<String> executedTools) {
        Set<String> executed = executedTools != null ? executedTools : new Set<String>();
        if (rule == null || rule.fromTools == null || rule.fromTools.isEmpty()) {
            return false;
        }
        for (String fromTool : rule.fromTools) {
            if (!executed.contains(fromTool)) {
                return false;
            }
        }
        return true;
    }

    private static Set<String> computeReachableTools(List<String> entryTools, Map<String, Set<String>> adjacency) {
        Set<String> reachable = new Set<String>();
        List<String> worklist = new List<String>();
        if (entryTools != null) {
            worklist.addAll(entryTools);
        }

        while (!worklist.isEmpty()) {
            String current = worklist.remove(worklist.size() - 1);
            if (reachable.contains(current)) {
                continue;
            }
            reachable.add(current);
            if (adjacency.containsKey(current)) {
                for (String nextTool : adjacency.get(current)) {
                    if (!reachable.contains(nextTool)) {
                        worklist.add(nextTool);
                    }
                }
            }
        }
        return reachable;
    }

    private static Boolean hasCycle(Map<String, Set<String>> adjacency) {
        Set<String> visited = new Set<String>();
        Set<String> inStack = new Set<String>();
        for (String node : adjacency.keySet()) {
            if (detectCycle(node, adjacency, visited, inStack)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean detectCycle(String node, Map<String, Set<String>> adjacency, Set<String> visited, Set<String> inStack) {
        if (inStack.contains(node)) {
            return true;
        }
        if (visited.contains(node)) {
            return false;
        }

        visited.add(node);
        inStack.add(node);
        if (adjacency.containsKey(node)) {
            for (String nextNode : adjacency.get(node)) {
                if (detectCycle(nextNode, adjacency, visited, inStack)) {
                    return true;
                }
            }
        }
        inStack.remove(node);
        return false;
    }

    private static Set<String> getLockedBranchesForExecution(FlowGraph graph, Id executionId, Set<String> executedTools) {
        Set<String> locked = new Set<String>();
        Set<String> executed = executedTools != null ? executedTools : new Set<String>();

        if (graph != null && graph.flow != null && !graph.flow.isEmpty()) {
            for (FlowRule rule : graph.flow) {
                if (!'exclusive'.equals(rule.type) || rule.toTools == null || rule.toTools.isEmpty()) {
                    continue;
                }

                Boolean fromToolsSatisfied = true;
                for (String fromTool : rule.fromTools) {
                    if (!executed.contains(fromTool)) {
                        fromToolsSatisfied = false;
                        break;
                    }
                }

                if (!fromToolsSatisfied) {
                    continue;
                }

                String selectedBranch = null;
                for (String toTool : rule.toTools) {
                    if (executed.contains(toTool)) {
                        selectedBranch = toTool;
                        break;
                    }
                }

                if (selectedBranch == null) {
                    continue;
                }

                for (String toTool : rule.toTools) {
                    if (toTool != selectedBranch) {
                        locked.add(toTool);
                    }
                }
            }
        }

        locked.addAll(TransactionContext.getInstance().getLockedBranches(executionId));
        return locked;
    }
}
