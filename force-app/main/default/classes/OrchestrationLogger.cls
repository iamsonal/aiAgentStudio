/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Enhanced orchestration logging utility that acts as a "flight recorder" for AI agent decision-making.
 *              Provides deep, step-by-step visibility into conversational turns, supporting both traditional
 *              action execution and modern graph-based workflows. Integrates with the current framework's
 *              ActionContext, OrchestrationContext, and async processing patterns.
 *
 * @features
 * - Transaction-scoped log buffering with explicit commit control
 * - Automatic sequence management per turn
 * - Support for both sync and async execution patterns
 * - Graph execution step tracking
 * - Enhanced payload serialization with truncation
 * - Comprehensive error handling and recovery
 * - Performance-optimized caching
 * - Integration with current framework services
 */
public inherited sharing class OrchestrationLogger {
    @TestVisible
    private static List<OrchestrationLog__c> logBuffer = new List<OrchestrationLog__c>();

    @TestVisible
    private static Map<Id, Boolean> loggingEnabledCache = new Map<Id, Boolean>();

    @TestVisible
    private static Map<String, Integer> turnSequenceCache = new Map<String, Integer>();

    private static final Integer MAX_PAYLOAD_LENGTH = 131000;
    private static final Integer MAX_DETAILS_LENGTH = 131000;
    private static final Integer MAX_ERROR_LENGTH = 131000;

    public static final String TYPE_USER_PROMPT = 'UserPrompt';
    public static final String TYPE_CONTEXT_GATHERING = 'ContextGathering';
    public static final String TYPE_LLM_PREP = 'LLMRequestPreparation';
    public static final String TYPE_LLM_CALL = 'LLMCallAttempt';
    public static final String TYPE_LLM_RESPONSE = 'LLMResponse';

    public static final String TYPE_ACTION_PARSE = 'ActionRequestParsing';
    public static final String TYPE_ACTION_START = 'ActionExecutionStart';
    public static final String TYPE_ACTION_RESULT = 'ActionExecutionResult';

    public static final String TYPE_GRAPH_START = 'GraphExecutionStart';
    public static final String TYPE_GRAPH_NODE = 'GraphNodeExecution';
    public static final String TYPE_GRAPH_TRANSITION = 'GraphNodeTransition';
    public static final String TYPE_GRAPH_COMPLETE = 'GraphExecutionComplete';

    public static final String TYPE_TOOL_SAVE = 'ToolResultSaving';
    public static final String TYPE_TOOL_VALIDATION = 'ToolValidation';

    public static final String TYPE_DISPATCH = 'NextStepDispatch';
    public static final String TYPE_ASYNC_QUEUE = 'AsyncJobQueued';
    public static final String TYPE_ASYNC_RESUME = 'AsyncJobResumed';

    public static final String TYPE_TURN_COMPLETE = 'TurnCompletion';
    public static final String TYPE_TURN_FAIL = 'TurnFailure';

    public static final String TYPE_APPROVAL_REQUEST = 'ApprovalRequested';
    public static final String TYPE_APPROVAL_RESPONSE = 'ApprovalProcessed';

    public static final String STATUS_INIT = 'Initiated';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_FAILURE = 'Failure';
    public static final String STATUS_SKIPPED = 'Skipped';

    /**
     * @description Checks if detailed logging is enabled for the given session ID.
     *              Uses a transaction-scoped cache to minimize queries and improve performance.
     * @param sessionId ID of the ChatSession__c
     * @return Boolean True if enabled, false otherwise. Returns false if sessionId is null or record not found.
     */
    public static Boolean isEnabled(Id sessionId) {
        if (sessionId == null) {
            return false;
        }

        if (!loggingEnabledCache.containsKey(sessionId)) {
            Boolean isEnabled = false;
            try {
                List<ChatSession__c> sessions = [
                    SELECT EnableOrchestrationLogging__c
                    FROM ChatSession__c
                    WHERE Id = :sessionId
                    WITH USER_MODE
                    LIMIT 1
                ];
                isEnabled = (!sessions.isEmpty() && sessions[0].EnableOrchestrationLogging__c == true);
            } catch (Exception e) {
                isEnabled = false;
            }
            loggingEnabledCache.put(sessionId, isEnabled);
        }
        return loggingEnabledCache.get(sessionId);
    }

    /**
     * @description Gets the next sequence number for a given session, providing global ordering across all turns.
     *              This ensures proper chronological ordering for UI visualization.
     * @param sessionId The chat session ID for global sequence tracking
     * @param turnIdentifier The turn identifier for turn-specific tracking
     * @return Integer The next global sequence number for this session
     */
    @TestVisible
    private static Integer getNextSequence(Id sessionId, String turnIdentifier) {
        if (sessionId == null) {
            return 1;
        }

        String sessionKey = String.valueOf(sessionId);
        Integer globalSequence = turnSequenceCache.get(sessionKey);
        if (globalSequence == null) {
            globalSequence = 0;
        }

        globalSequence++;
        turnSequenceCache.put(sessionKey, globalSequence);

        if (String.isNotBlank(turnIdentifier)) {
            String turnKey = sessionKey + ':' + turnIdentifier;
            Integer turnSequence = turnSequenceCache.get(turnKey);
            turnSequence = (turnSequence == null) ? 1 : turnSequence + 1;
            turnSequenceCache.put(turnKey, turnSequence);
        }

        return globalSequence;
    }

    /**
     * @description Enhanced logging method that automatically manages sequence numbers and integrates
     *              with the current framework's context objects. Supports both ActionContext and
     *              OrchestrationContext for seamless integration.
     *
     * @param sessionId - Chat Session ID (Required)
     * @param turnIdentifier - User Turn Identifier (Required)
     * @param stepType - Picklist API Name from OrchestrationLog__c.StepType__c (Required, use constants)
     * @param status - Picklist API Name from OrchestrationLog__c.Status__c (Required, use constants)
     * @param details - Optional summary text
     * @param inputPayload - Optional input object (will be JSON serialized & truncated)
     * @param outputPayload - Optional output object (will be JSON serialized & truncated)
     * @param errorMessage - Optional error message text (if status=Failure)
     * @param errorCode - Optional error code (if status=Failure)
     * @param durationMs - Optional step duration
     * @param chatMessageId - Optional related ChatMessage__c ID
     * @param agentCapabilityId - Optional related AgentCapability__c ID
     * @param llmConfigId - Optional related LLMConfiguration__c ID
     * @param toolCallId - Optional LLM Tool Call ID
     */
    public static void logStep(
        Id sessionId,
        String turnIdentifier,
        String stepType,
        String status,
        String details,
        Object inputPayload,
        Object outputPayload,
        String errorMessage,
        String errorCode,
        Long durationMs,
        Id chatMessageId,
        Id agentCapabilityId,
        Id llmConfigId,
        String toolCallId
    ) {
        Integer sequence = getNextSequence(sessionId, turnIdentifier);
        logStepWithSequence(
            sessionId,
            turnIdentifier,
            sequence,
            stepType,
            status,
            details,
            inputPayload,
            outputPayload,
            errorMessage,
            errorCode,
            durationMs,
            chatMessageId,
            agentCapabilityId,
            llmConfigId,
            toolCallId
        );
    }

    /**
     * @description Convenience method for logging from ActionContext
     * @param context The ActionContext containing session and turn information
     * @param stepType The type of step being logged
     * @param status The status of the step
     * @param details Optional details about the step
     */
    public static void logFromActionContext(ActionContext context, String stepType, String status, String details) {
        if (context == null)
            return;

        logStep(
            context.chatSessionId,
            context.turnIdentifier,
            stepType,
            status,
            details,
            null,
            null,
            null,
            null,
            null,
            null,
            context.agentCapabilityId,
            null,
            null
        );
    }

    /**
     * @description Convenience method for logging from OrchestrationContext
     * @param context The OrchestrationContext containing session and turn information
     * @param stepType The type of step being logged
     * @param status The status of the step
     * @param details Optional details about the step
     */
    public static void logFromOrchestrationContext(OrchestrationContext context, String stepType, String status, String details) {
        if (context == null)
            return;

        logStep(context.sessionId, context.turnIdentifier, stepType, status, details, null, null, null, null, null, null, null, null, null);
    }

    /**
     * @description Internal method that handles the actual logging with explicit sequence management.
     *              This maintains backward compatibility while adding auto-sequence functionality.
     */
    @TestVisible
    private static void logStepWithSequence(
        Id sessionId,
        String turnIdentifier,
        Integer sequence,
        String stepType,
        String status,
        String details,
        Object inputPayload,
        Object outputPayload,
        String errorMessage,
        String errorCode,
        Long durationMs,
        Id chatMessageId,
        Id agentCapabilityId,
        Id llmConfigId,
        String toolCallId
    ) {
        if (sessionId == null || !isEnabled(sessionId)) {
            return;
        }

        if (String.isBlank(turnIdentifier) || sequence == null || String.isBlank(stepType) || String.isBlank(status)) {
            return;
        }

        try {
            OrchestrationLog__c log = new OrchestrationLog__c(
                ChatSession__c = sessionId,
                TurnIdentifier__c = turnIdentifier,
                Sequence__c = sequence,
                StepType__c = stepType,
                Status__c = status,
                Timestamp__c = Datetime.now(),
                Details__c = truncateText(details, MAX_DETAILS_LENGTH),
                ErrorMessage__c = truncateText(errorMessage, MAX_ERROR_LENGTH),
                ErrorCode__c = errorCode,
                DurationMillis__c = durationMs,
                ChatMessage__c = chatMessageId,
                AgentCapability__c = agentCapabilityId,
                LLMConfiguration__c = llmConfigId,
                ToolCallId__c = toolCallId
            );

            if (inputPayload != null) {
                log.PayloadInput__c = serializeAndTruncate(inputPayload);
            }
            if (outputPayload != null) {
                log.PayloadOutput__c = serializeAndTruncate(outputPayload);
            }

            logBuffer.add(log);
        } catch (Exception e) {
        }
    }

    /**
     * @description Commits (inserts) any buffered OrchestrationLog__c records for the current transaction.
     *              Enhanced with better error handling, performance metrics, and recovery mechanisms.
     *              Uses allOrNone=false and traps DML exceptions to prevent logging failures
     *              from disrupting the main agent flow. Clears the buffer after attempting insert.
     */
    public static void commitLogs() {
        if (logBuffer.isEmpty()) {
            return;
        }

        List<OrchestrationLog__c> logsToInsert = new List<OrchestrationLog__c>(logBuffer);
        logBuffer.clear();

        Long startTime = System.currentTimeMillis();

        try {
            Database.SaveResult[] results = Database.insert(logsToInsert, false);

            Integer successCount = 0;
            Integer failureCount = 0;
            List<String> errorMessages = new List<String>();

            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    failureCount++;
                    Database.Error err = results[i].getErrors()[0];
                    OrchestrationLog__c failedLog = logsToInsert[i];
                    String errMsg = String.format(
                        'Failed saving OrchestrationLog [Sess:{0}, Turn:{1}, Seq:{2}, Type:{3}]. Error: {4} - {5}',
                        new List<String>{
                            String.valueOf(failedLog?.ChatSession__c),
                            failedLog?.TurnIdentifier__c,
                            String.valueOf(failedLog?.Sequence__c),
                            failedLog?.StepType__c,
                            String.valueOf(err?.getStatusCode()),
                            err?.getMessage()
                        }
                    );
                    errorMessages.add(errMsg);
                }
            }

            Long duration = System.currentTimeMillis() - startTime;

            if (!errorMessages.isEmpty()) {
            }
        } catch (Exception e) {
            Long duration = System.currentTimeMillis() - startTime;
        } finally {
            if (!logBuffer.isEmpty()) {
                logBuffer.clear();
            }
        }
    }

    /**
     * @description Commits logs and clears sequence cache for a specific turn.
     *              Useful when a turn completes to free up memory and ensure clean state.
     * @param turnIdentifier The turn identifier to clean up
     */
    public static void commitLogsAndCleanupTurn(String turnIdentifier) {
        commitLogs();
        if (String.isNotBlank(turnIdentifier) && turnSequenceCache.containsKey(turnIdentifier)) {
            turnSequenceCache.remove(turnIdentifier);
        }
    }

    /**
     * @description Safely serializes an object to JSON and truncates if necessary.
     *              Enhanced with better error handling and performance optimization.
     */
    @TestVisible
    private static String serializeAndTruncate(Object payload) {
        if (payload == null) {
            return null;
        }

        try {
            String jsonString = JSON.serializePretty(payload);
            return truncateText(jsonString, MAX_PAYLOAD_LENGTH);
        } catch (Exception e) {
            String errMsg = '[OrchestrationLogger] Payload serialization failed: ' + e.getMessage();

            Map<String, Object> errorPayload = new Map<String, Object>{
                'error' => 'Failed to serialize payload',
                'errorType' => e.getTypeName(),
                'details' => String.valueOf(e.getMessage()).escapeJava(),
                'payloadType' => String.valueOf(payload).left(100)
            };

            try {
                return JSON.serialize(errorPayload);
            } catch (Exception finalEx) {
                return '{"error": "Critical serialization failure", "type": "' + e.getTypeName() + '"}';
            }
        }
    }

    /**
     * @description Safely truncates text to specified length with proper truncation indicator.
     * @param text The text to truncate
     * @param maxLength The maximum allowed length
     * @return String The truncated text or original if within limits
     */
    @TestVisible
    private static String truncateText(String text, Integer maxLength) {
        if (String.isBlank(text) || text.length() <= maxLength) {
            return text;
        }

        String truncationIndicator = '... [truncated]';
        Integer availableLength = maxLength - truncationIndicator.length();

        if (availableLength <= 0) {
            return truncationIndicator.left(maxLength);
        }

        String truncated = text.left(availableLength) + truncationIndicator;

        return truncated;
    }

    /**
     * @description Logs tool call parsing and validation.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param toolCallsJson The raw tool calls JSON from LLM
     * @param parsedActions The parsed action requests
     * @param validationResults Any validation results
     * @param durationMs Time taken to parse
     */
    public static void logActionParsing(
        Id sessionId,
        String turnIdentifier,
        String toolCallsJson,
        List<Object> parsedActions,
        Object validationResults,
        Long durationMs
    ) {
        Map<String, Object> inputPayload = new Map<String, Object>{
            'rawToolCallsJson' => toolCallsJson,
            'toolCallCount' => parsedActions?.size() ?? 0
        };

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_ACTION_PARSE,
            STATUS_SUCCESS,
            'Parsed ' + (parsedActions?.size() ?? 0) + ' tool calls from LLM response',
            inputPayload,
            validationResults,
            null,
            null,
            durationMs,
            null,
            null,
            null,
            null
        );
    }

    /**
     * @description Enhanced action start logging with complete context and arguments.
     * @param context The ActionContext for the execution
     * @param actionName The name of the action being executed
     * @param arguments The arguments passed to the action
     * @param toolCallId The LLM tool call ID
     * @param actionConfig The action configuration
     */
    public static void logActionStart(ActionContext context, String actionName, String arguments, String toolCallId, String actionConfig) {
        if (context == null)
            return;

        Map<String, Object> inputPayload = new Map<String, Object>{
            'actionName' => actionName,
            'arguments' => arguments,
            'actionConfig' => actionConfig,
            'originalUserId' => context.originalUserId,
            'relatedRecordId' => context.relatedRecordId,
            'agentDefinitionId' => context.agentDefinitionId,
            'implementationDetail' => context.implementationDetail,
            'currentTurnCount' => context.currentTurnCount
        };

        logStep(
            context.chatSessionId,
            context.turnIdentifier,
            TYPE_ACTION_START,
            STATUS_INIT,
            'Starting execution of action: ' + actionName,
            inputPayload,
            null,
            null,
            null,
            null,
            null,
            context.agentCapabilityId,
            null,
            toolCallId
        );
    }

    /**
     * @description Backward compatibility method for simple action start logging.
     */
    public static void logActionStart(ActionContext context, String actionName, String arguments) {
        logActionStart(context, actionName, arguments, null, null);
    }

    /**
     * @description Logs the result of an action execution with performance metrics.
     * @param context The ActionContext for the execution
     * @param actionName The name of the action that was executed
     * @param result The ActionResult from the execution
     * @param durationMs The execution duration in milliseconds
     */
    public static void logActionResult(ActionContext context, String actionName, ActionResult result, Long durationMs) {
        if (context == null || result == null)
            return;

        String status = result.isSuccess ? STATUS_SUCCESS : STATUS_FAILURE;
        String details = result.isSuccess ? 'Action completed successfully' : 'Action failed: ' + (result.errorCode ?? 'Unknown error');

        Map<String, Object> outputPayload = new Map<String, Object>{
            'success' => result.isSuccess,
            'errorCode' => result.errorCode,
            'hasOutput' => result.outputForLlm != null
        };

        logStep(
            context.chatSessionId,
            context.turnIdentifier,
            TYPE_ACTION_RESULT,
            status,
            details,
            null,
            outputPayload,
            result.isSuccess ? null : result.internalDetails,
            result.errorCode,
            durationMs,
            null,
            context.agentCapabilityId,
            null,
            null
        );
    }

    /**
     * @description Logs user prompt/message with full context for conversation tracking.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param userMessage The user's message content
     * @param messageId The ChatMessage__c ID
     * @param relatedRecordId Any related record context
     */
    public static void logUserPrompt(Id sessionId, String turnIdentifier, String userMessage, Id messageId, Id relatedRecordId) {
        Map<String, Object> inputPayload = new Map<String, Object>{
            'userMessage' => userMessage,
            'messageLength' => userMessage?.length(),
            'relatedRecordId' => relatedRecordId,
            'timestamp' => System.now()
        };

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_USER_PROMPT,
            STATUS_SUCCESS,
            'User message received: ' + (userMessage?.left(100) ?? ''),
            inputPayload,
            null,
            null,
            null,
            null,
            messageId,
            null,
            null,
            null
        );
    }

    /**
     * @description Logs context gathering phase with retrieved context information.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param contextSources List of context sources gathered
     * @param contextData The actual context data retrieved
     * @param durationMs Time taken to gather context
     */
    public static void logContextGathering(Id sessionId, String turnIdentifier, List<String> contextSources, Object contextData, Long durationMs) {
        Map<String, Object> inputPayload = new Map<String, Object>{
            'contextSources' => contextSources,
            'sourceCount' => contextSources?.size() ?? 0
        };

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_CONTEXT_GATHERING,
            STATUS_SUCCESS,
            'Context gathered from ' + (contextSources?.size() ?? 0) + ' sources',
            inputPayload,
            contextData,
            null,
            null,
            durationMs,
            null,
            null,
            null,
            null
        );
    }

    /**
     * @description Logs LLM request preparation with complete prompt and configuration.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param systemPrompt The system prompt used
     * @param userPrompt The user prompt/message
     * @param conversationHistory The conversation history included
     * @param toolDefinitions Available tool definitions
     * @param llmConfigId The LLM configuration used
     * @param durationMs Time taken to prepare request
     */
    public static void logLlmRequestPreparation(
        Id sessionId,
        String turnIdentifier,
        String systemPrompt,
        String userPrompt,
        List<Object> conversationHistory,
        List<Object> toolDefinitions,
        Id llmConfigId,
        Long durationMs
    ) {
        Map<String, Object> inputPayload = new Map<String, Object>{
            'systemPrompt' => systemPrompt,
            'userPrompt' => userPrompt,
            'historyMessageCount' => conversationHistory?.size() ?? 0,
            'availableToolCount' => toolDefinitions?.size() ?? 0,
            'totalPromptLength' => (systemPrompt?.length() ?? 0) + (userPrompt?.length() ?? 0)
        };

        Map<String, Object> outputPayload = new Map<String, Object>{
            'conversationHistory' => conversationHistory,
            'toolDefinitions' => toolDefinitions
        };

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_LLM_PREP,
            STATUS_SUCCESS,
            'LLM request prepared with ' + (toolDefinitions?.size() ?? 0) + ' tools',
            inputPayload,
            outputPayload,
            null,
            null,
            durationMs,
            null,
            null,
            llmConfigId,
            null
        );
    }

    /**
     * @description Logs LLM call attempt with complete request details.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param requestPayload The complete request sent to LLM
     * @param llmConfigId The LLM configuration used
     * @param status The call status (STATUS_INIT for start, STATUS_SUCCESS/FAILURE for completion)
     * @param durationMs The call duration (null for start)
     * @param errorMessage Any error message if failed
     * @param errorCode Any error code if failed
     */
    public static void logLlmCall(
        Id sessionId,
        String turnIdentifier,
        Object requestPayload,
        Id llmConfigId,
        String status,
        Long durationMs,
        String errorMessage,
        String errorCode
    ) {
        String details = status.equals(STATUS_INIT)
            ? 'LLM call initiated'
            : (status.equals(STATUS_SUCCESS) ? 'LLM call completed successfully' : 'LLM call failed');

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_LLM_CALL,
            status,
            details,
            requestPayload,
            null,
            errorMessage,
            errorCode,
            durationMs,
            null,
            null,
            llmConfigId,
            null
        );
    }

    /**
     * @description Logs LLM response with complete response details and analysis.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param requestPayload The original request for context
     * @param responsePayload The complete LLM response
     * @param llmConfigId The LLM configuration used
     * @param durationMs The total interaction duration
     */
    public static void logLlmResponse(
        Id sessionId,
        String turnIdentifier,
        Object requestPayload,
        Object responsePayload,
        Id llmConfigId,
        Long durationMs
    ) {
        Map<String, Object> responseAnalysis = analyzeLlmResponse(responsePayload);

        String details =
            'LLM response received - ' +
            'Tokens: ' +
            responseAnalysis.get('totalTokens') +
            ', Tools: ' +
            responseAnalysis.get('toolCallCount') +
            ', Content: ' +
            (responseAnalysis.get('hasContent') == true ? 'Yes' : 'No');

        logStep(
            sessionId,
            turnIdentifier,
            TYPE_LLM_RESPONSE,
            STATUS_SUCCESS,
            details,
            requestPayload,
            responsePayload,
            null,
            null,
            durationMs,
            null,
            null,
            llmConfigId,
            null
        );
    }

    /**
     * @description Analyzes LLM response payload to extract key metrics for logging.
     */
    @TestVisible
    private static Map<String, Object> analyzeLlmResponse(Object responsePayload) {
        Map<String, Object> analysis = new Map<String, Object>{
            'totalTokens' => 0,
            'toolCallCount' => 0,
            'hasContent' => false,
            'responseType' => 'unknown'
        };

        try {
            if (responsePayload instanceof Map<String, Object>) {
                Map<String, Object> response = (Map<String, Object>) responsePayload;

                if (response.containsKey('providerResult')) {
                    Map<String, Object> providerResult = (Map<String, Object>) response.get('providerResult');
                    if (providerResult?.containsKey('totalTokens')) {
                        analysis.put('totalTokens', providerResult.get('totalTokens'));
                    }

                    if (providerResult?.containsKey('requestedActions')) {
                        List<Object> actions = (List<Object>) providerResult.get('requestedActions');
                        analysis.put('toolCallCount', actions?.size() ?? 0);
                        analysis.put('responseType', (actions?.size() ?? 0) > 0 ? 'tool_call' : 'content');
                    }

                    if (providerResult?.containsKey('content')) {
                        String content = (String) providerResult.get('content');
                        analysis.put('hasContent', String.isNotBlank(content));
                        if (analysis.get('responseType') == 'unknown') {
                            analysis.put('responseType', String.isNotBlank(content) ? 'content' : 'empty');
                        }
                    }
                }
            }
        } catch (Exception e) {
        }

        return analysis;
    }

    /**
     * @description Logs graph execution steps with node information.
     * @param sessionId The chat session ID
     * @param turnIdentifier The turn identifier
     * @param stepType The type of graph step
     * @param status The status of the step
     * @param nodeName The name of the graph node
     * @param nodeInputs The inputs to the node
     * @param nodeOutputs The outputs from the node
     * @param durationMs The execution duration
     */
    public static void logGraphStep(
        Id sessionId,
        String turnIdentifier,
        String stepType,
        String status,
        String nodeName,
        Object nodeInputs,
        Object nodeOutputs,
        Long durationMs
    ) {
        String details = 'Graph node: ' + nodeName;

        logStep(sessionId, turnIdentifier, stepType, status, details, nodeInputs, nodeOutputs, null, null, durationMs, null, null, null, null);
    }

    /**
     * @description Gets current buffer size for monitoring and debugging.
     * @return Integer The number of logs currently buffered
     */
    public static Integer getBufferSize() {
        return logBuffer.size();
    }

    /**
     * @description Gets current sequence for a turn (for debugging).
     * @param turnIdentifier The turn identifier
     * @return Integer The current sequence number for the turn
     */
    @TestVisible
    public static Integer getCurrentSequence(String turnIdentifier) {
        return turnSequenceCache.get(turnIdentifier);
    }

    /**
     * @description Clears all caches and buffers (for testing or transaction resets).
     */
    @TestVisible
    private static void clearCache() {
        loggingEnabledCache.clear();
        turnSequenceCache.clear();
        logBuffer.clear();
    }

    /**
     * @description Emergency method to force commit logs if transaction is about to fail.
     *              Should only be used in exception handlers as a last resort.
     */
    public static void emergencyCommit() {
        if (!logBuffer.isEmpty()) {
            commitLogs();
        }
    }
}
