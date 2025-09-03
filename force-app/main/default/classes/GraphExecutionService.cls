/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * GraphExecutionService orchestrates the execution of graph-based AI agent workflows.
 * It manages the lifecycle of a graph run, including:
 *   - Initializing and maintaining execution state across synchronous and asynchronous boundaries
 *   - Chaining node executions with intelligent transaction control to avoid governor limits
 *   - Dispatching jobs for asynchronous processing when required by node configuration or system constraints
 *   - Evaluating conditional routing between nodes using semantic references and result-based logic
 *   - Logging execution steps and outcomes for observability and troubleshooting
 *   - Handling errors and state persistence to support robust, resumable graph execution
 *
 * This class is designed for extensibility and maintainability, providing a clear separation between graph orchestration,
 * node execution, state management, and logging. It is the central engine for running complex, multi-step agent workflows
 * in a scalable and fault-tolerant manner.
 */
public with sharing class GraphExecutionService {
    // --- Constants ---
    private static final Integer MAX_SYNC_STEPS_PER_TXN = 5; // Prevents governor limit violations in synchronous execution chains

    // --- Exceptions ---
    public class GraphConfigurationException extends AIAgentException {
    }
    public class GraphRuntimeException extends AIAgentException {
    }

    /**
     * @description Maintains the complete execution state of a graph run.
     *              Tracks inputs, node execution results, execution path, and context information
     *              required for state persistence and recovery across transaction boundaries.
     */
    @TestVisible
    private class GraphRunState {
        public Map<String, Object> inputs;
        public Map<String, NodeRunState> nodes;
        public List<String> executionPath;
        public Id chatSessionId;
        public String turnIdentifier;
        public Integer currentTurnCount;
        public Id originalUserId;
        public Id executionUserId;
        public Id agentDefinitionId;
        public List<GraphExecutionLog__c> logBuffer;

        public GraphRunState() {
            this.inputs = new Map<String, Object>();
            this.nodes = new Map<String, NodeRunState>();
            this.executionPath = new List<String>();
            this.logBuffer = new List<GraphExecutionLog__c>();
        }

        public GraphRunState(Map<String, Object> initialInputs, ActionContext context) {
            this(); // Initialize collections
            this.inputs = initialInputs;
            this.chatSessionId = context.chatSessionId;
            this.turnIdentifier = context.turnIdentifier;
            this.currentTurnCount = context.currentTurnCount;
            this.originalUserId = context.originalUserId;
            this.executionUserId = context.executionUserId;
            this.agentDefinitionId = context.agentDefinitionId;
        }
    }

    /**
     * @description Comparator for conditional edge evaluation priority.
     *              Ensures specific conditions (success/failure) are evaluated before
     *              generic conditions (always), preventing incorrect routing decisions.
     */
    @TestVisible
    private class EdgeComparator implements Comparator<ConditionalEdge> {
        private final Map<String, Integer> priorities;

        public EdgeComparator() {
            this.priorities = new Map<String, Integer>{
                'success' => 10,
                'failure' => 20,
                'custom' => 30,
                'always' => 999 // Lowest priority
            };
        }

        private String getConditionType(String condition) {
            if (String.isBlank(condition) || condition.equalsIgnoreCase('true'))
                return 'always';
            if (condition.contains('{!result.isSuccess} == true'))
                return 'success';
            if (condition.contains('{!result.isSuccess} == false'))
                return 'failure'; // Note: an explicit 'false' check
            return 'custom';
        }

        public Integer compare(ConditionalEdge a, ConditionalEdge b) {
            String aType = getConditionType(a.condition);
            String bType = getConditionType(b.condition);

            Integer aPriority = this.priorities.get(aType);
            Integer bPriority = this.priorities.get(bType);

            return aPriority - bPriority;
        }
    }

    /**
     * @description Encapsulates the execution state and results of a single graph node.
     *              Maintains both clean output data for semantic references and complete
     *              result information for conditional edge evaluation.
     */
    @TestVisible
    private class NodeRunState {
        public Object output; // The clean payload from ActionResult.outputForLlm
        public ActionResult resultForConditions; // The full ActionResult object
        public Map<String, Object> mappedInputs;
    }

    @TestVisible
    private class ConditionalEdge {
        public String condition;
        public String nextNode;
    }

    /**
     * Initiates a new graph run for the specified agent capability.
     *
     * - Loads all nodes for the graph and determines the entry point.
     * - Sets up the initial execution state and logs the start of execution.
     * - Depending on the entry node configuration, either starts execution synchronously (in current transaction)
     *   or persists state and dispatches an asynchronous job for execution.
     *
     * @param graphCapability   The AgentCapability__c record representing the graph to execute.
     * @param llmArgumentsJson  JSON string of initial input arguments for the graph.
     * @param context           The ActionContext containing session and user metadata.
     * @return ActionResult    If synchronous, returns the result of execution; if asynchronous, returns a status message.
     * @throws GraphConfigurationException if the graph is misconfigured (e.g., missing entry point).
     */
    public ActionResult startGraphRun(AgentCapability__c graphCapability, String llmArgumentsJson, ActionContext context) {
        String logPrefix = '[GraphExecSvc.Start Sess:' + context.chatSessionId + '] ';

        OrchestrationLogger.logStep(
            context.chatSessionId,
            context.turnIdentifier,
            OrchestrationLogger.TYPE_GRAPH_START,
            OrchestrationLogger.STATUS_INIT,
            'Starting graph execution: ' + graphCapability.CapabilityName__c,
            new Map<String, Object>{ 'graphCapabilityId' => graphCapability.Id, 'arguments' => llmArgumentsJson },
            null,
            null,
            null,
            null,
            null,
            context.agentCapabilityId,
            null,
            null
        );

        Map<String, GraphNode__c> allNodesMap = queryAndMapAllNodes(graphCapability.Id);
        GraphNode__c entryNode = findEntryPoint(allNodesMap);

        Map<String, Object> initialArgs = String.isBlank(llmArgumentsJson)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(llmArgumentsJson);
        GraphRunState initialState = new GraphRunState(initialArgs, context);

        if (entryNode.StartAsynchronously__c) {
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Initiating asynchronous graph execution for capability: ' + graphCapability.CapabilityName__c
            );
            OrchestrationLogger.logStep(
                context.chatSessionId,
                context.turnIdentifier,
                OrchestrationLogger.TYPE_ASYNC_QUEUE,
                OrchestrationLogger.STATUS_SUCCESS,
                'Graph queued for async execution',
                null,
                new Map<String, Object>{ 'entryNode' => entryNode.NodeName__c },
                null,
                null,
                null,
                null,
                context.agentCapabilityId,
                null,
                null
            );

            update new ChatSession__c(
                Id = context.chatSessionId,
                CurrentState__c = JSON.serialize(initialState),
                CurrentGraphNode__c = entryNode.NodeName__c
            );
            new AgentJobEnqueuer().enqueueGraphStep(context.chatSessionId, graphCapability.Id);
            return new ActionResult(
                new Map<String, Object>{ 'status' => 'SUBMITTED' },
                'Graph execution started in the background.'
            );
        } else {
            System.debug(LoggingLevel.INFO, logPrefix + 'Executing graph synchronously for capability: ' + graphCapability.CapabilityName__c);
            OrchestrationLogger.logStep(
                context.chatSessionId,
                context.turnIdentifier,
                OrchestrationLogger.TYPE_GRAPH_START,
                OrchestrationLogger.STATUS_SUCCESS,
                'Graph starting synchronous execution',
                null,
                new Map<String, Object>{ 'entryNode' => entryNode.NodeName__c },
                null,
                null,
                null,
                null,
                context.agentCapabilityId,
                null,
                null
            );
            return this.executeNextStepChain(context.chatSessionId, entryNode.NodeName__c, initialState, allNodesMap);
        }
    }

    /**
     * Executes a chain of graph nodes synchronously, up to the transaction step limit.
     *
     * - Iteratively processes nodes, updating execution state and logging each step.
     * - Evaluates conditional edges to determine the next node.
     * - If a node requires asynchronous execution or the sync step limit is reached, persists state and dispatches async job.
     * - Finalizes the graph run if the path is complete.
     *
     * @param sessionId         The active chat session ID.
     * @param startingNodeName  The name of the node to start execution from.
     * @param currentState      The current in-memory state of the graph run.
     * @param allNodesMap       Map of all nodes in the graph, keyed by node name.
     * @return ActionResult     If the graph completes synchronously, returns the result; otherwise, returns null (async handoff).
     * @throws GraphRuntimeException or GraphConfigurationException for execution errors or misconfiguration.
     */
    public ActionResult executeNextStepChain(
        Id sessionId,
        String startingNodeName,
        GraphRunState currentState,
        Map<String, GraphNode__c> allNodesMap
    ) {
        String logPrefix = '[GraphExecSvc.Chain Sess:' + sessionId + '] ';
        String currentNodeName = startingNodeName;
        Integer sequenceCounter = currentState.executionPath.size();

        for (Integer syncStepCounter = 0; syncStepCounter < MAX_SYNC_STEPS_PER_TXN; syncStepCounter++) {
            if (String.isBlank(currentNodeName)) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Chain processing stopped as next node is blank. Finalizing.');
                return finalizeGraphRun(sessionId, currentState, logPrefix);
            }

            GraphNode__c currentNode = allNodesMap.get(currentNodeName);
            if (currentNode == null)
                throw new GraphRuntimeException('Node "' + currentNodeName + '" not found in graph map.');

            currentState.executionPath.add(currentNodeName);
            sequenceCounter++;

            Long actionStartTime = System.currentTimeMillis();

            Map<String, Object> processedArgs = mapStateToArguments(currentState, currentNode.InputMappings__c, logPrefix);
            ActionResult primitiveResult = executePrimitiveForNode(currentNode, currentState, logPrefix);
            Long actionDuration = System.currentTimeMillis() - actionStartTime;

            logGraphStep(currentState, currentNode, sequenceCounter, primitiveResult, actionDuration, processedArgs);

            // Update state with the result
            NodeRunState nodeState = new NodeRunState();
            nodeState.output = primitiveResult.outputForLlm;
            nodeState.resultForConditions = primitiveResult;
            nodeState.mappedInputs = processedArgs;
            currentState.nodes.put(currentNodeName, nodeState);

            // Determine the next node by evaluating conditional edges
            String nextNodeName = findNextNode(currentNode.ConditionalEdges__c, currentState, primitiveResult, logPrefix);

            // Look ahead to see if we need to break the transaction
            if (String.isNotBlank(nextNodeName)) {
                GraphNode__c nextNode = allNodesMap.get(nextNodeName);
                if (nextNode == null)
                    throw new GraphConfigurationException('Next node "' + nextNodeName + '" defined in edges does not exist.');

                // Check if the next primitive capability requires an async job.
                if (nextNode.PrimitiveCapabilityToRun__r != null && nextNode.PrimitiveCapabilityToRun__r.RunAsynchronously__c) {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Chain Break: Next node "' + nextNodeName + '" requires async. Persisting and dispatching.'
                    );
                    persistAndDispatchAsync(sessionId, currentState, nextNodeName, currentNode.AgentCapability__c, logPrefix);
                    return null; // Null indicates handoff to an async process
                }
                currentNodeName = nextNodeName;
            } else {
                // No more edges from the current node, the graph path is complete.
                System.debug(LoggingLevel.INFO, logPrefix + 'Node ' + currentNodeName + ' has no valid next node. Finalizing graph.');
                return finalizeGraphRun(sessionId, currentState, logPrefix);
            }
        }

        System.debug(LoggingLevel.WARN, logPrefix + 'Max synchronous steps reached. Persisting state and forcing async dispatch.');
        persistAndDispatchAsync(sessionId, currentState, currentNodeName, allNodesMap.values()[0].AgentCapability__c, logPrefix);
        return null; // Handoff to async process
    }

    /**
     * Resumes execution of a graph run from persisted state, typically invoked by an async job.
     *
     * - Loads the current session and state from the database.
     * - If a current node is present, resumes execution from that node.
     * - No-op if the session has no current node (already completed or invalid).
     *
     * @param sessionId   The chat session ID to resume.
     * @param allNodesMap Map of all nodes in the graph, keyed by node name.
     */
    public void executeNextStepChain(Id sessionId, Map<String, GraphNode__c> allNodesMap) {
        ChatSession__c session = [SELECT Id, CurrentState__c, CurrentGraphNode__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1 FOR UPDATE];
        if (String.isBlank(session.CurrentGraphNode__c)) {
            System.debug(LoggingLevel.INFO, '[GraphExecSvc.AsyncResume] No current node for session ' + sessionId + '. Execution will not proceed.');
            return;
        }
        Map<String, Object> stateMap = (Map<String, Object>) JSON.deserializeUntyped(session.CurrentState__c);
        GraphRunState currentState = reconstructStateFromMap(stateMap);
        executeNextStepChain(sessionId, session.CurrentGraphNode__c, currentState, allNodesMap);
    }

    /**
     * Queries all active nodes for a given graph capability and returns them as a map keyed by node name.
     *
     * @param graphCapabilityId  The Id of the AgentCapability__c representing the graph.
     * @return Map<String, GraphNode__c>  Map of node name to GraphNode__c record.
     */
    public Map<String, GraphNode__c> queryAndMapAllNodes(Id graphCapabilityId) {
        List<GraphNode__c> allNodesList = [
            SELECT
                Id,
                NodeName__c,
                InputMappings__c,
                ConditionalEdges__c,
                IsEntryPoint__c,
                StartAsynchronously__c,
                PrimitiveCapabilityToRun__c,
                PrimitiveCapabilityToRun__r.ImplementationType__c,
                PrimitiveCapabilityToRun__r.ImplementationDetail__c,
                PrimitiveCapabilityToRun__r.RunAsynchronously__c,
                PrimitiveCapabilityToRun__r.StandardActionType__c,
                PrimitiveCapabilityToRun__r.BackendConfiguration__c,
                AgentCapability__c,
                PrimitiveCapabilityToRun__r.CapabilityName__c
            FROM GraphNode__c
            WHERE AgentCapability__c = :graphCapabilityId AND IsActive__c = TRUE
        ];
        Map<String, GraphNode__c> mapToReturn = new Map<String, GraphNode__c>();
        for (GraphNode__c node : allNodesList) {
            mapToReturn.put(node.NodeName__c, node);
        }
        return mapToReturn;
    }

    /**
     * Finds the entry point node in the provided node map.
     *
     * @param allNodesMap  Map of all nodes in the graph.
     * @return GraphNode__c  The entry point node.
     * @throws GraphConfigurationException if no entry point or multiple entry points are found.
     */
    @TestVisible
    private GraphNode__c findEntryPoint(Map<String, GraphNode__c> allNodesMap) {
        GraphNode__c entryNode = null;
        for (GraphNode__c node : allNodesMap.values()) {
            if (node.IsEntryPoint__c) {
                if (entryNode != null)
                    throw new GraphConfigurationException('Graph has multiple Entry Points.');
                entryNode = node;
            }
        }
        if (entryNode == null)
            throw new GraphConfigurationException('Graph has no Entry Point.');
        return entryNode;
    }

    /**
     * Executes the primitive capability associated with a graph node.
     *
     * - Maps state to input arguments for the primitive.
     * - Invokes the ActionExecutionService to execute the primitive action.
     * - Handles and logs errors, returning a failure ActionResult if execution fails.
     *
     * @param node      The GraphNode__c to execute.
     * @param state     The current graph run state.
     * @param logPrefix Prefix for debug logging.
     * @return ActionResult  The result of the primitive execution, or a NO_OP if no primitive is defined.
     */
    @TestVisible
    private ActionResult executePrimitiveForNode(GraphNode__c node, GraphRunState state, String logPrefix) {
        if (node.PrimitiveCapabilityToRun__c == null) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Node "' + node.NodeName__c + '" has no primitive capability. Skipping execution (NO_OP).');
            return new ActionResult(new Map<String, Object>{ 'status' => 'NO_OP' }, 'No operation performed.');
        }
        ActionExecutionService primitiveExecutor = new ActionExecutionService();
        Map<String, Object> mappedArgs = mapStateToArguments(state, node.InputMappings__c, logPrefix);
        ActionContext primitiveContext = new ActionContext(
            state.chatSessionId,
            state.originalUserId,
            state.executionUserId,
            null,
            state.agentDefinitionId,
            node.PrimitiveCapabilityToRun__c,
            node.PrimitiveCapabilityToRun__r.ImplementationDetail__c,
            state.turnIdentifier,
            state.currentTurnCount
        );
        try {
            return primitiveExecutor.executeSingleAction(node.PrimitiveCapabilityToRun__r, JSON.serialize(mappedArgs), primitiveContext);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Primitive execution failed for node "' + node.NodeName__c + '": ' + e.getMessage());
            return new ActionResult(
                'Graph Primitive Execution Failed',
                e.getMessage() + '\n' + e.getStackTraceString(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR
            );
        }
    }

    /**
     * Finalizes a graph run, clearing session state and logging the result.
     *
     * - Updates the session to clear current state and node.
     * - Aggregates node results for reporting.
     * - Links the result to the initiating assistant message, if available.
     * - Triggers follow-up LLM call and enqueues next turn.
     * - Commits execution logs.
     *
     * @param sessionId   The chat session ID.
     * @param finalState  The final state of the graph run.
     * @param logPrefix   Prefix for debug logging.
     * @return ActionResult|null  Always returns null; result is handled asynchronously.
     */
    private ActionResult finalizeGraphRun(Id sessionId, GraphRunState finalState, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Graph run complete. Clearing session state and preparing final result.');
        update new ChatSession__c(Id = sessionId, CurrentState__c = null, CurrentGraphNode__c = null);
        List<Object> compositeDataList = new List<Object>();
        for (String nodeName : finalState.executionPath) {
            if (finalState.nodes.containsKey(nodeName)) {
                NodeRunState nodeState = finalState.nodes.get(nodeName);
                if (nodeState.resultForConditions != null) {
                    compositeDataList.add(
                        new Map<String, Object>{
                            'nodeName' => nodeName,
                            'sequence' => finalState.executionPath.indexOf(nodeName) + 1,
                            'status' => nodeState.resultForConditions.isSuccess ? 'SUCCESS' : 'FAILURE',
                            'output' => nodeState.output
                        }
                    );
                }
            }
        }
        ActionResult finalGraphResult = new ActionResult(
            compositeDataList,
            'Graph completed. Path: ' + String.join(finalState.executionPath, ' -> ')
        );
        // Link result to initiating assistant message, if present
        List<ChatMessage__c> assistantMessagesInTurn = [
            SELECT Id, AssistantToolCalls__c
            FROM ChatMessage__c
            WHERE ChatSession__c = :sessionId AND TurnIdentifier__c = :finalState.turnIdentifier AND Role__c = 'assistant'
            ORDER BY CreatedDate DESC
        ];
        ChatMessage__c initiatingAssistantMessage = assistantMessagesInTurn.isEmpty() ? null : assistantMessagesInTurn[0];
        if (initiatingAssistantMessage != null && String.isNotBlank(initiatingAssistantMessage.AssistantToolCalls__c)) {
            String toolCallId = null;
            String graphCapabilityName = null;
            List<Object> toolCalls = (List<Object>) JSON.deserializeUntyped(initiatingAssistantMessage.AssistantToolCalls__c);
            if (!toolCalls.isEmpty()) {
                Map<String, Object> firstToolCall = (Map<String, Object>) toolCalls[0];
                toolCallId = (String) firstToolCall.get('id');
                Map<String, Object> functionMap = (Map<String, Object>) firstToolCall.get('function');
                graphCapabilityName = (String) functionMap.get('name');
            }
            if (toolCallId != null) {
                String resultJsonForStorage = OrchestrationService.serializeActionResult(finalGraphResult, logPrefix);
                Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(finalGraphResult);
                ChatMessageService.saveToolResultMessage(
                    sessionId,
                    finalState.turnIdentifier,
                    initiatingAssistantMessage.Id,
                    toolCallId,
                    resultJsonForStorage,
                    finalGraphResult.internalDetails,
                    finalGraphResult.errorCode,
                    0L,
                    newRecordContextId,
                    resultJsonForStorage,
                    graphCapabilityName,
                    logPrefix
                );
            }
        } else {
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'No initiating assistant message found for this graph run. Final result will not be linked.'
            );
        }
        // Trigger follow-up LLM call and enqueue next turn
        TurnLifecycleService turnSvc = new TurnLifecycleService();
        AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer(turnSvc);
        turnSvc.resumeForFollowUpLlmCall(sessionId, finalState.turnIdentifier, null, logPrefix);
        dispatchSvc.enqueueFollowUp(
            sessionId,
            finalState.originalUserId,
            finalState.agentDefinitionId,
            finalState.turnIdentifier,
            finalState.currentTurnCount + 1,
            logPrefix,
            false
        );
        // Commit logs before exiting the transaction
        commitLogs(finalState, logPrefix);
        return finalGraphResult; // Return the final result for synchronous execution
    }

    /**
     * Maps the current graph state to input arguments for a primitive node, resolving semantic references.
     *
     * @param state        The current graph run state.
     * @param mappingJson  JSON string describing argument mappings.
     * @param logPrefix    Prefix for debug logging.
     * @return Map<String, Object>  The mapped arguments for the primitive.
     */
    @TestVisible
    private Map<String, Object> mapStateToArguments(GraphRunState state, String mappingJson, String logPrefix) {
        if (String.isBlank(mappingJson))
            return new Map<String, Object>();

        Map<String, Object> mappedArgs = new Map<String, Object>();
        Map<String, Object> mappings = (Map<String, Object>) JSON.deserializeUntyped(mappingJson);
        Map<String, Object> stateMapForEval = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(state));

        for (String targetArg : mappings.keySet()) {
            Object sourceValueOrPath = mappings.get(targetArg);
            Object finalValue;
            if (sourceValueOrPath instanceof String && ((String) sourceValueOrPath).contains('{!')) {
                String sourceString = (String) sourceValueOrPath;
                // Check if this is a pure semantic reference (starts with {! and ends with })
                if (sourceString.startsWith('{!') && sourceString.endsWith('}') && sourceString.indexOf('{!') == sourceString.lastIndexOf('{!')) {
                    // Pure semantic reference - resolve directly to preserve type
                    finalValue = resolveSemanticValue(sourceString, stateMapForEval, logPrefix);
                } else {
                    // Template string with multiple references or mixed content
                    finalValue = processTemplateString(sourceString, stateMapForEval, logPrefix);
                }
            } else {
                finalValue = sourceValueOrPath; // Literal value
            }
            mappedArgs.put(targetArg, finalValue);
        }
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Mapped inputs for primitive: ' + JSON.serialize(mappedArgs));
        return mappedArgs;
    }

    /**
     * Evaluates conditional edges for a node to determine the next node to execute.
     *
     * - Sorts edges by priority (success/failure/custom/always).
     * - Evaluates each condition in order, using the current state and result.
     * - Returns the next node name for the first condition that evaluates to true.
     *
     * @param conditionalEdgesJson  JSON array of ConditionalEdge objects.
     * @param state                The current graph run state.
     * @param currentResult        The result of the current node execution.
     * @param logPrefix            Prefix for debug logging.
     * @return String              The name of the next node to execute, or null if no condition is met.
     */
    @TestVisible
    private String findNextNode(String conditionalEdgesJson, GraphRunState state, ActionResult currentResult, String logPrefix) {
        if (String.isBlank(conditionalEdgesJson))
            return null;

        List<ConditionalEdge> edges = (List<ConditionalEdge>) JSON.deserialize(conditionalEdgesJson, List<ConditionalEdge>.class);
        if (edges.isEmpty())
            return null;

        edges.sort(new EdgeComparator());
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Sorted edges for evaluation. Order: ' + JSON.serialize(edges));

        Map<String, Object> stateMapForEval = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(state));
        if (currentResult != null) {
            stateMapForEval.put(
                'currentNodeResult',
                new Map<String, Object>{
                    'isSuccess' => currentResult.isSuccess,
                    'output' => currentResult.outputForLlm,
                    'errorCode' => currentResult.errorCode
                }
            );
        }

        for (ConditionalEdge edge : edges) {
            if (evaluateCondition(edge.condition, stateMapForEval)) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Edge condition "' + edge.condition + '" met. Routing to: ' + edge.nextNode);
                return edge.nextNode;
            }
        }
        System.debug(LoggingLevel.WARN, logPrefix + 'No conditional edge was met. Terminating this path.');
        return null;
    }

    /**
     * Evaluates a condition string using semantic references and the current state.
     *
     * Supports '==' and '!=' operators. Returns true if the condition evaluates to true.
     *
     * @param condition   The condition string (e.g., "$result.isSuccess == true").
     * @param stateMapForEval  The current state as an untyped map.
     * @return Boolean    True if the condition is met, false otherwise.
     */
    @TestVisible
    private Boolean evaluateCondition(String condition, Map<String, Object> stateMapForEval) {
        if (condition.equalsIgnoreCase('true'))
            return true;

        try {
            if (condition.contains('==')) {
                List<String> parts = condition.split('==');
                if (parts.size() != 2)
                    return false;
                Object actualValue = resolveSemanticValue(parts[0].trim(), stateMapForEval, 'EVAL:');
                String expectedValue = parts[1].trim();
                return compareValues(actualValue, expectedValue);
            }

            if (condition.contains('!=')) {
                List<String> parts = condition.split('!=');
                if (parts.size() != 2)
                    return false;
                Object actualValue = resolveSemanticValue(parts[0].trim(), stateMapForEval, 'EVAL:');
                String expectedValue = parts[1].trim();
                return !compareValues(actualValue, expectedValue);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[GraphExecSvc] Condition evaluation failed for "' + condition + '". Error: ' + e.getMessage());
            return false;
        }
        return false;
    }

    /**
     * Compares two values with type-aware comparison logic.
     *
     * @param actualValue   The actual value from semantic reference resolution.
     * @param expectedValue The expected value as a string from the condition.
     * @return Boolean      True if the values are equal, false otherwise.
     */
    @TestVisible
    private Boolean compareValues(Object actualValue, String expectedValue) {
        if (actualValue == null) {
            return String.isBlank(expectedValue) || expectedValue.equalsIgnoreCase('null');
        }

        // Handle boolean comparisons
        if (actualValue instanceof Boolean) {
            return ((Boolean) actualValue).toString().equalsIgnoreCase(expectedValue);
        }

        // Handle numeric comparisons
        if (actualValue instanceof Integer || actualValue instanceof Long || actualValue instanceof Decimal || actualValue instanceof Double) {
            try {
                Decimal actualDecimal = Decimal.valueOf(String.valueOf(actualValue));
                Decimal expectedDecimal = Decimal.valueOf(expectedValue);
                return actualDecimal.equals(expectedDecimal);
            } catch (Exception e) {
                // Fall back to string comparison if numeric conversion fails
                return String.valueOf(actualValue).equalsIgnoreCase(expectedValue);
            }
        }

        // Default to string comparison
        return String.valueOf(actualValue).equalsIgnoreCase(expectedValue);
    }

    /**
     * Resolves a semantic reference path (e.g., {!input.field}) against the current state map.
     *
     * @param sourcePath  The semantic reference path.
     * @param stateMap    The current state map for evaluation.
     * @param logPrefix   Prefix for debug logging.
     * @return Object     The resolved value, or throws if resolution fails.
     */
    @TestVisible
    private Object resolveSemanticValue(String sourcePath, Map<String, Object> stateMap, String logPrefix) {
        if (String.isBlank(sourcePath))
            return null;
        try {
            SemanticReference ref = SemanticReference.parse(sourcePath);
            return ref.resolveValue(stateMap);
        } catch (Exception e) {
            throw new GraphRuntimeException(
                'Failed to resolve semantic reference "' + sourcePath + '" during graph execution. Error: ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Processes a template string, replacing all semantic references with their resolved values from state.
     *
     * @param templateString  The string containing merge field references (e.g., "Case {!input.case_id}").
     * @param stateMap        The current state map for evaluation.
     * @param logPrefix       Prefix for debug logging.
     * @return String         The processed string with all references substituted.
     */
    @TestVisible
    private String processTemplateString(String templateString, Map<String, Object> stateMap, String logPrefix) {
        if (String.isBlank(templateString))
            return templateString;

        String result = templateString;
        Pattern referencePattern = Pattern.compile('\\{![^}]+\\}');
        Matcher matcher = referencePattern.matcher(templateString);

        while (matcher.find()) {
            String reference = matcher.group();
            try {
                Object value = resolveSemanticValue(reference, stateMap, logPrefix);
                String stringValue = (value == null) ? '' : String.valueOf(value);
                result = result.replace(reference, stringValue);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to resolve reference ' + reference + ' in template: ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Template processed: "' + templateString + '" -> "' + result + '"');
        return result;
    }

    /**
     * Navigates a nested map structure using a dot-notation path to retrieve a value.
     *
     * @param data  The root map (representing the state).
     * @param path  The dot-notation path (e.g., "nodes.step_1.result.isSuccess").
     * @return Object  The value found at the path, or null if the path is invalid or the value is null.
     */
    @TestVisible
    private Object getValueFromPath(Map<String, Object> data, String path) {
        if (path == null || data == null)
            return null;

        List<String> keys = path.split('\\.');
        Object currentValue = data;

        for (String key : keys) {
            if (currentValue instanceof Map<String, Object>) {
                currentValue = ((Map<String, Object>) currentValue).get(key);
                if (currentValue == null) {
                    return null; // Path does not exist or value is null
                }
            } else {
                // The path is invalid because we tried to traverse into a non-map object (e.g., a String or Boolean).
                return null;
            }
        }
        return currentValue;
    }

    /**
     * Reconstructs a GraphRunState object from a deserialized state map.
     *
     * @param stateMap  The deserialized state map.
     * @return GraphRunState  The reconstructed state object.
     */
    private GraphRunState reconstructStateFromMap(Map<String, Object> stateMap) {
        GraphRunState state = new GraphRunState();
        state.inputs = (Map<String, Object>) stateMap.get('inputs');
        state.chatSessionId = (Id) stateMap.get('chatSessionId');
        state.turnIdentifier = (String) stateMap.get('turnIdentifier');
        state.currentTurnCount = (Integer) stateMap.get('currentTurnCount');
        state.originalUserId = (Id) stateMap.get('originalUserId');
        state.agentDefinitionId = (Id) stateMap.get('agentDefinitionId');
        Object executionPathObj = stateMap.get('executionPath');
        if (executionPathObj instanceof List<Object>) {
            List<String> pathList = new List<String>();
            for (Object pathItem : (List<Object>) executionPathObj) {
                pathList.add((String) pathItem);
            }
            state.executionPath = pathList;
        } else {
            state.executionPath = new List<String>();
        }
        Map<String, Object> nodesUntypedMap = (Map<String, Object>) stateMap.get('nodes');
        if (nodesUntypedMap != null) {
            for (String nodeName : nodesUntypedMap.keySet()) {
                Map<String, Object> nodeStateUntyped = (Map<String, Object>) nodesUntypedMap.get(nodeName);
                NodeRunState nodeState = new NodeRunState();
                nodeState.output = nodeStateUntyped.get('output');
                nodeState.mappedInputs = (Map<String, Object>) nodeStateUntyped.get('mappedInputs');
                Map<String, Object> resultUntyped = (Map<String, Object>) nodeStateUntyped.get('resultForConditions');
                if (resultUntyped != null) {
                    Boolean isSuccess = (Boolean) resultUntyped.get('isSuccess');
                    if (isSuccess) {
                        nodeState.resultForConditions = new ActionResult(
                            resultUntyped.get('outputForLlm'),
                            (String) resultUntyped.get('internalDetails')
                        );
                    } else {
                        nodeState.resultForConditions = new ActionResult(
                            resultUntyped.get('outputForLlm'),
                            (String) resultUntyped.get('internalDetails'),
                            (String) resultUntyped.get('errorCode')
                        );
                    }
                }
                state.nodes.put(nodeName, nodeState);
            }
        }
        return state;
    }

    /**
     * Logs a single step of graph execution to the in-memory log buffer for later persistence.
     *
     * @param state         The current graph run state.
     * @param node          The node being executed.
     * @param sequence      The sequence number of this step.
     * @param result        The result of the node execution.
     * @param duration      The execution duration in milliseconds.
     * @param processedArgs The input arguments used for this node.
     */
    private void logGraphStep(
        GraphRunState state,
        GraphNode__c node,
        Integer sequence,
        ActionResult result,
        Long duration,
        Map<String, Object> processedArgs
    ) {
        GraphExecutionLog__c log = new GraphExecutionLog__c(
            ChatSession__c = state.chatSessionId,
            GraphCapability__c = node.AgentCapability__c,
            NodeName__c = node.NodeName__c,
            PrimitiveCapabilityRun__c = node.PrimitiveCapabilityToRun__c,
            Sequence__c = sequence,
            Status__c = result.isSuccess ? 'Success' : 'Failure',
            Input__c = JSON.serialize(processedArgs),
            Output__c = OrchestrationService.serializeActionResult(result, ''),
            DurationMillis__c = duration
        );
        state.logBuffer.add(log);
    }

    /**
     * Persists the current graph state and dispatches an asynchronous job to continue execution.
     *
     * @param sessionId        The chat session ID.
     * @param currentState     The current graph run state.
     * @param nextNodeName     The name of the next node to execute.
     * @param graphCapabilityId The Id of the graph capability.
     * @param logPrefix        Prefix for debug logging.
     */
    private void persistAndDispatchAsync(Id sessionId, GraphRunState currentState, String nextNodeName, Id graphCapabilityId, String logPrefix) {
        commitLogs(currentState, logPrefix);
        update new ChatSession__c(Id = sessionId, CurrentState__c = JSON.serialize(currentState), CurrentGraphNode__c = nextNodeName);
        System.debug(LoggingLevel.INFO, logPrefix + 'Persisted state and dispatched async job for next node: ' + nextNodeName);
        new AgentJobEnqueuer().enqueueGraphStep(sessionId, graphCapabilityId);
    }

    /**
     * Commits all buffered execution logs to the database, allowing partial success.
     *
     * @param state     The current graph run state.
     * @param logPrefix Prefix for debug logging.
     */
    private void commitLogs(GraphRunState state, String logPrefix) {
        if (!state.logBuffer.isEmpty()) {
            try {
                Database.insert(state.logBuffer, false); // Allow partial success for logging
                System.debug(LoggingLevel.DEBUG, logPrefix + 'Inserted ' + state.logBuffer.size() + ' GraphExecutionLog records.');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to insert GraphExecutionLog records: ' + e.getMessage());
            } finally {
                state.logBuffer.clear();
            }
        }
    }
}
