/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description The core engine for executing graph-driven capabilities. This version implements
 *              advanced transaction control to run chains of synchronous nodes together,
 *              efficiently pre-fetches the entire graph definition, and correctly dispatches
 *              asynchronous jobs for async primitives.
 */
public with sharing class GraphExecutionService {
    private static final Integer MAX_SYNC_STEPS_PER_TXN = 5;

    public class GraphConfigurationException extends AIAgentException {
    }
    public class GraphRuntimeException extends AIAgentException {
    }

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
            this();
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
     * @description (NEW) Comparator to sort conditional edges by logical priority.
     *              Ensures that specific conditions are evaluated before generic ones.
     */
    @TestVisible
    private class EdgeComparator implements Comparator<ConditionalEdge> {
        private final Map<String, Integer> priorities;

        public EdgeComparator() {
            this.priorities = new Map<String, Integer>{ 'success' => 10, 'failure' => 20, 'custom' => 30, 'always' => 999 };
        }

        private String getConditionType(String condition) {
            if (String.isBlank(condition) || condition.equalsIgnoreCase('true'))
                return 'always';
            if (condition.contains('{!result.isSuccess} == true'))
                return 'success';
            if (condition.contains('{!result.isSuccess} == false'))
                return 'failure';
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
     * @description Holds the state of a single executed node.
     *              Separates the clean output (for {!node...} references) from the full result
     *              (for {!result...} condition evaluation).
     */
    @TestVisible
    private class NodeRunState {
        public Object output;
        public ActionResult resultForConditions;
        public Map<String, Object> mappedInputs;
    }

    @TestVisible
    private class ConditionalEdge {
        public String condition;
        public String nextNode;
    }

    /**
     * @description Initiates a new graph run. Queries all nodes once, sets initial state,
     *              and dispatches the first execution step (sync or async).
     *              Enhanced with orchestration logging for graph execution tracking.
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
                'Graph execution started in the background.',
                'Graph enqueued.'
            );
        } else {
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
     * @description The definitive transactional loop. Manages state in-memory
     *              and only performs DML when necessary to break the transaction.
     * @param sessionId The active session ID.
     * @param startingNodeName The name of the node to start this chain with.
     * @param currentState The current in-memory state of the graph.
     * @param allNodesMap The pre-queried map of all nodes.
     * @return ActionResult if the graph completes synchronously, otherwise null.
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

            NodeRunState nodeState = new NodeRunState();
            nodeState.output = primitiveResult.outputForLlm;
            nodeState.resultForConditions = primitiveResult;
            nodeState.mappedInputs = processedArgs;
            currentState.nodes.put(currentNodeName, nodeState);

            String nextNodeName = findNextNode(currentNode.ConditionalEdges__c, currentState, primitiveResult, logPrefix);

            if (String.isNotBlank(nextNodeName)) {
                GraphNode__c nextNode = allNodesMap.get(nextNodeName);
                if (nextNode == null)
                    throw new GraphConfigurationException('Next node "' + nextNodeName + '" defined in edges does not exist.');

                if (nextNode.PrimitiveCapabilityToRun__r != null && nextNode.PrimitiveCapabilityToRun__r.RunAsynchronously__c) {
                    persistAndDispatchAsync(sessionId, currentState, nextNodeName, currentNode.AgentCapability__c, logPrefix);
                    return null;
                }
                currentNodeName = nextNodeName;
            } else {
                return finalizeGraphRun(sessionId, currentState, logPrefix);
            }
        }

        persistAndDispatchAsync(sessionId, currentState, currentNodeName, allNodesMap.values()[0].AgentCapability__c, logPrefix);
        return null;
    }

    public void executeNextStepChain(Id sessionId, Map<String, GraphNode__c> allNodesMap) {
        ChatSession__c session = [SELECT Id, CurrentState__c, CurrentGraphNode__c FROM ChatSession__c WHERE Id = :sessionId LIMIT 1 FOR UPDATE];
        if (String.isBlank(session.CurrentGraphNode__c)) {
            return;
        }

        Map<String, Object> stateMap = (Map<String, Object>) JSON.deserializeUntyped(session.CurrentState__c);
        GraphRunState currentState = reconstructStateFromMap(stateMap);

        executeNextStepChain(sessionId, session.CurrentGraphNode__c, currentState, allNodesMap);
    }

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

    private ActionResult executePrimitiveForNode(GraphNode__c node, GraphRunState state, String logPrefix) {
        if (node.PrimitiveCapabilityToRun__c == null) {
            return new ActionResult(new Map<String, Object>{ 'status' => 'NO_OP' }, 'No operation performed.', 'No primitive defined for node.');
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
            return new ActionResult(
                'Graph Primitive Execution Failed',
                e.getMessage() + '\n' + e.getStackTraceString(),
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR
            );
        }
    }

    private ActionResult finalizeGraphRun(Id sessionId, GraphRunState finalState, String logPrefix) {
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
        }

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

        commitLogs(finalState, logPrefix);

        return null;
    }

    /**
     * @description Safely navigates the state JSON to prepare arguments for a primitive.
     *              This is a wrapper around getValueFromPath for the specific use case of argument mapping.
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
                finalValue = processTemplateString((String) sourceValueOrPath, stateMapForEval, logPrefix);
            } else {
                finalValue = sourceValueOrPath;
            }
            mappedArgs.put(targetArg, finalValue);
        }

        return mappedArgs;
    }

    /**
     * @description Evaluates conditional edges to determine the name of the next node.
     * @param conditionalEdgesJson The JSON array from the GraphNode__c.ConditionalEdges__c field.
     * @param state The current GraphRunState to evaluate conditions against.
     * @param currentResult The result of the current node execution for condition evaluation.
     * @param logPrefix A logging prefix.
     * @return String The name of the next node to execute, or null if no condition is met.
     */
    @TestVisible
    private String findNextNode(String conditionalEdgesJson, GraphRunState state, ActionResult currentResult, String logPrefix) {
        if (String.isBlank(conditionalEdgesJson))
            return null;

        List<ConditionalEdge> edges = (List<ConditionalEdge>) JSON.deserialize(conditionalEdgesJson, List<ConditionalEdge>.class);
        if (edges.isEmpty())
            return null;

        edges.sort(new EdgeComparator());

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
                return edge.nextNode;
            }
        }

        return null;
    }

    /**
     * @description A simple expression evaluator using semantic references.
     * @param condition The condition string using semantic syntax, e.g., "$result.isSuccess == true"
     * @param state The untyped map representation of the current graph state.
     * @return Boolean True if the condition evaluates to true.
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
                return String.valueOf(actualValue).equalsIgnoreCase(parts[1].trim());
            }

            if (condition.contains('!=')) {
                List<String> parts = condition.split('!=');
                if (parts.size() != 2)
                    return false;
                Object actualValue = resolveSemanticValue(parts[0].trim(), stateMapForEval, 'EVAL:');
                return !String.valueOf(actualValue).equalsIgnoreCase(parts[1].trim());
            }
        } catch (Exception e) {
            return false;
        }
        return false;
    }

    /**
     * @description Resolves semantic references directly without legacy conversion
     * @param sourcePath The semantic reference path ({!input.field}, {!node.field}, etc.)
     * @param stateMap The current state map for evaluation
     * @param logPrefix Logging prefix for debugging
     * @return Object The resolved value
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
     * @description Processes a template string containing multiple semantic references
     * @param templateString The string containing merge field references like "Case {!input.case_id} escalated by {!context.user_id}"
     * @param stateMap The current state map for evaluation
     * @param logPrefix Logging prefix for debugging
     * @return String The processed string with all references substituted
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
            }
        }

        return result;
    }

    /**
     * @description Navigates a nested Map structure using a dot-notation path.
     * @param data The root map (representing the state).
     * @param path The dot-notation path, e.g., "nodes.step_1.result.isSuccess".
     * @return Object The value found at the path, or null if the path is invalid or the value is null.
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
                    return null;
                }
            } else {
                return null;
            }
        }
        return currentValue;
    }

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

    private void persistAndDispatchAsync(Id sessionId, GraphRunState currentState, String nextNodeName, Id graphCapabilityId, String logPrefix) {
        commitLogs(currentState, logPrefix);

        update new ChatSession__c(Id = sessionId, CurrentState__c = JSON.serialize(currentState), CurrentGraphNode__c = nextNodeName);
        new AgentJobEnqueuer().enqueueGraphStep(sessionId, graphCapabilityId);
    }

    private void commitLogs(GraphRunState state, String logPrefix) {
        if (!state.logBuffer.isEmpty()) {
            try {
                Database.insert(state.logBuffer, false);
            } catch (Exception e) {
            } finally {
                state.logBuffer.clear();
            }
        }
    }
}
