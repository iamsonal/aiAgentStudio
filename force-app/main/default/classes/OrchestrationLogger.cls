/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * OrchestrationLogger is a robust, transaction-scoped logging utility for AI agent orchestration flows.
 * It provides detailed, chronological visibility into conversational turns, action execution, LLM interactions,
 * and decision-making processes. The logger buffers log entries for efficient bulk commit, manages sequence
 * numbers for ordering, and supports granular step-type/status tracking. Its design prioritizes debuggability,
 * extensibility, and minimal disruption to mainline agent execution, even in the face of logging failures.
 *
 * Key responsibilities:
 *   - Buffering and committing orchestration logs for each chat session/turn
 *   - Automatic sequence management for ordered log records
 *   - Rich, structured payload capture (inputs, outputs, errors, durations, etc.)
 *   - Context-aware logging for LLM, action, and graph execution steps
 *   - Resilience: logging failures never block or break agent flows
 *   - Developer-friendly debug output for troubleshooting and monitoring
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

    // Step type constants for orchestration logging
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
     * Checks if orchestration logging is enabled for the given chat session.
     *
     * @param sessionId   The ChatSession__c Id to check logging status for.
     * @return            True if logging is enabled for this session, false if not or if session is missing.
     * @sideeffect       Caches the result for the sessionId for the duration of the transaction.
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
                System.debug(
                    LoggingLevel.ERROR,
                    '[OrchestrationLogger.isEnabled] Error checking logging flag for session ' + sessionId + ': ' + e.getMessage()
                );
                // Default to false on error to prevent logging failures from disrupting main flow
                isEnabled = false;
            }
            loggingEnabledCache.put(sessionId, isEnabled);
            System.debug(LoggingLevel.DEBUG, '[OrchestrationLogger.isEnabled] Cached logging status for ' + sessionId + ': ' + isEnabled);
        }
        return loggingEnabledCache.get(sessionId);
    }

    /**
     * Generates the next sequence number for log ordering within a session and turn.
     *
     * @param sessionId      The ChatSession__c Id for global sequence tracking.
     * @param turnIdentifier The turn identifier for turn-specific sequence tracking.
     * @return               The next sequence number for this session.
     * @sideeffect           Updates the sequence cache for both session and turn.
     */
    @TestVisible
    private static Integer getNextSequence(Id sessionId, String turnIdentifier) {
        if (sessionId == null) {
            return 1;
        }

        // Maintain global sequence per session for chronological ordering
        String sessionKey = String.valueOf(sessionId);
        Integer globalSequence = turnSequenceCache.get(sessionKey);
        if (globalSequence == null) {
            globalSequence = 0;
        }

        globalSequence++;
        turnSequenceCache.put(sessionKey, globalSequence);

        // Track turn-specific sequence for reference
        if (String.isNotBlank(turnIdentifier)) {
            String turnKey = sessionKey + ':' + turnIdentifier;
            Integer turnSequence = turnSequenceCache.get(turnKey);
            turnSequence = (turnSequence == null) ? 1 : turnSequence + 1;
            turnSequenceCache.put(turnKey, turnSequence);
        }

        return globalSequence;
    }

    /**
     * Logs a single orchestration step, automatically managing sequence and serializing payloads.
     *
     * @param sessionId         Chat session Id (required)
     * @param turnIdentifier    Turn identifier (required)
     * @param stepType          Step type constant (required)
     * @param status            Status constant (required)
     * @param details           Optional step description
     * @param inputPayload      Optional input data (JSON serialized)
     * @param outputPayload     Optional output data (JSON serialized)
     * @param errorMessage      Optional error message for failures
     * @param errorCode         Optional error code for failures
     * @param durationMs        Optional step duration in ms
     * @param chatMessageId     Optional related chat message Id
     * @param agentCapabilityId Optional related agent capability Id
     * @param llmConfigId       Optional related LLM config Id
     * @param toolCallId        Optional LLM tool call Id
     * @sideeffect              Buffers the log entry for later commit.
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
        // Generate sequence number for chronological ordering
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
     * Logs an orchestration step using ActionContext for session and turn information.
     *
     * @param context   ActionContext containing session and turn data.
     * @param stepType  Step type constant.
     * @param status    Status constant.
     * @param details   Optional step description.
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
     * Logs an orchestration step using OrchestrationContext for session and turn information.
     *
     * @param context   OrchestrationContext containing session and turn data.
     * @param stepType  Step type constant.
     * @param status    Status constant.
     * @param details   Optional step description.
     */
    public static void logFromOrchestrationContext(OrchestrationContext context, String stepType, String status, String details) {
        if (context == null)
            return;

        logStep(context.sessionId, context.turnIdentifier, stepType, status, details, null, null, null, null, null, null, null, null, null);
    }

    /**
     * Internal logging method with explicit sequence management. Used for backward compatibility and advanced scenarios.
     *
     * @param sessionId         Chat session Id
     * @param turnIdentifier    Turn identifier
     * @param sequence          Explicit sequence number
     * @param stepType          Step type constant
     * @param status            Status constant
     * @param details           Optional step description
     * @param inputPayload      Optional input data
     * @param outputPayload     Optional output data
     * @param errorMessage      Optional error message
     * @param errorCode         Optional error code
     * @param durationMs        Optional step duration
     * @param chatMessageId     Optional related chat message Id
     * @param agentCapabilityId Optional related agent capability Id
     * @param llmConfigId       Optional related LLM config Id
     * @param toolCallId        Optional LLM tool call Id
     * @sideeffect              Buffers the log entry for later commit.
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

        // Validate required parameters
        if (String.isBlank(turnIdentifier) || sequence == null || String.isBlank(stepType) || String.isBlank(status)) {
            System.debug(
                LoggingLevel.ERROR,
                '[OrchestrationLogger.logStepWithSequence] Skipping log: missing required parameter(s). ' +
                    'SessionId=' +
                    sessionId +
                    ', Turn=' +
                    turnIdentifier +
                    ', Seq=' +
                    sequence +
                    ', Type=' +
                    stepType +
                    ', Status=' +
                    status
            );
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

            // Serialize and truncate payload data
            if (inputPayload != null) {
                log.PayloadInput__c = serializeAndTruncate(inputPayload);
            }
            if (outputPayload != null) {
                log.PayloadOutput__c = serializeAndTruncate(outputPayload);
            }

            logBuffer.add(log);

            System.debug(
                LoggingLevel.DEBUG,
                '[OrchestrationLogger] Log buffered: SessionId=' +
                    sessionId +
                    ', Turn=' +
                    turnIdentifier +
                    ', Seq=' +
                    sequence +
                    ', Type=' +
                    stepType +
                    ', Status=' +
                    status
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[OrchestrationLogger.logStepWithSequence] Failed to create log for session ' +
                    sessionId +
                    ', turn ' +
                    turnIdentifier +
                    ', seq ' +
                    sequence +
                    ': ' +
                    e.getMessage()
            );
        }
    }

    /**
     * Commits all buffered log records to the database in partial success mode.
     *
     * @sideeffect   Clears the buffer after commit. Logs errors but never throws.
     * @debug        Outputs commit summary and any failures to debug logs.
     */
    public static void commitLogs() {
        if (logBuffer.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[OrchestrationLogger.commitLogs] No logs to commit (buffer is empty)');
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
                System.debug(LoggingLevel.ERROR, '[OrchestrationLogger.commitLogs] Log commit failures: ' + String.join(errorMessages, '; '));
            }

            System.debug(
                LoggingLevel.INFO,
                '[OrchestrationLogger.commitLogs] Log commit summary: duration=' +
                    duration +
                    'ms, total=' +
                    logsToInsert.size() +
                    ', success=' +
                    successCount +
                    ', failures=' +
                    failureCount
            );
        } catch (Exception e) {
            Long duration = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.ERROR,
                '[OrchestrationLogger.commitLogs] CRITICAL: Database insert failed after ' + duration + 'ms. Exception: ' + e.getMessage()
            );
        } finally {
            if (!logBuffer.isEmpty()) {
                System.debug(
                    LoggingLevel.WARN,
                    '[OrchestrationLogger.commitLogs] Buffer not empty after commit, clearing ' + logBuffer.size() + ' entries'
                );
                logBuffer.clear();
            }
        }
    }

    /**
     * Commits logs and cleans up sequence cache for a completed turn.
     *
     * @param turnIdentifier   The turn identifier to remove from the sequence cache.
     * @sideeffect            Commits logs and removes turn sequence from cache.
     */
    public static void commitLogsAndCleanupTurn(String turnIdentifier) {
        commitLogs();
        if (String.isNotBlank(turnIdentifier) && turnSequenceCache.containsKey(turnIdentifier)) {
            turnSequenceCache.remove(turnIdentifier);
            System.debug(LoggingLevel.DEBUG, '[OrchestrationLogger] Cleaned sequence cache for turn: ' + turnIdentifier);
        }
    }

    /**
     * Serializes an object to JSON, truncating if necessary and handling serialization errors gracefully.
     *
     * @param payload   The object to serialize.
     * @return          JSON string (possibly truncated), or error payload if serialization fails.
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
            System.debug(LoggingLevel.ERROR, errMsg);

            // Create safe error payload
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
     * Truncates a string to the specified length, appending a truncation indicator if needed.
     *
     * @param text       The text to truncate.
     * @param maxLength  The maximum allowed length.
     * @return           Truncated text or original if within limits.
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
        System.debug(LoggingLevel.WARN, '[OrchestrationLogger] Truncated text from ' + text.length() + ' to ' + truncated.length() + ' characters');

        return truncated;
    }

    // ============================================================================
    // --- Enhanced Utility Methods ---
    // ============================================================================

    /**
     * Logs the parsing and validation of tool calls from an LLM response.
     *
     * @param sessionId         The chat session Id.
     * @param turnIdentifier    The turn identifier.
     * @param toolCallsJson     The raw tool calls JSON from the LLM.
     * @param parsedActions     The parsed action requests.
     * @param validationResults Any validation results.
     * @param durationMs        Time taken to parse (ms).
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
     * Logs the start of an action execution, including context and arguments.
     *
     * @param context      The ActionContext for the execution.
     * @param actionName   The name of the action being executed.
     * @param arguments    The arguments passed to the action.
     * @param toolCallId   The LLM tool call ID.
     * @param actionConfig The action configuration.
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
     * Backward compatibility overload for simple action start logging (no toolCallId or config).
     */
    public static void logActionStart(ActionContext context, String actionName, String arguments) {
        logActionStart(context, actionName, arguments, null, null);
    }

    /**
     * Logs the result of an action execution, including success/failure and performance metrics.
     *
     * @param context     The ActionContext for the execution.
     * @param actionName  The name of the action that was executed.
     * @param result      The ActionResult from the execution.
     * @param durationMs  The execution duration in ms.
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
     * Logs a user prompt/message with full context for conversation tracking.
     *
     * @param sessionId        The chat session Id.
     * @param turnIdentifier   The turn identifier.
     * @param userMessage      The user's message content.
     * @param messageId        The ChatMessage__c Id.
     * @param relatedRecordId  Any related record context.
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
     * Logs the context gathering phase, including sources and retrieved data.
     *
     * @param sessionId        The chat session Id.
     * @param turnIdentifier   The turn identifier.
     * @param contextSources   List of context sources gathered.
     * @param contextData      The actual context data retrieved.
     * @param durationMs       Time taken to gather context (ms).
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
     * Logs the preparation of an LLM request, including prompts, history, and tool definitions.
     *
     * @param sessionId            The chat session Id.
     * @param turnIdentifier       The turn identifier.
     * @param systemPrompt         The system prompt used.
     * @param userPrompt           The user prompt/message.
     * @param conversationHistory  The conversation history included.
     * @param toolDefinitions      Available tool definitions.
     * @param llmConfigId          The LLM configuration used.
     * @param durationMs           Time taken to prepare request (ms).
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
     * Logs an LLM call attempt, including request details, status, and errors if any.
     *
     * @param sessionId      The chat session Id.
     * @param turnIdentifier The turn identifier.
     * @param requestPayload The complete request sent to LLM.
     * @param llmConfigId    The LLM configuration used.
     * @param status         The call status (STATUS_INIT, STATUS_SUCCESS, STATUS_FAILURE).
     * @param durationMs     The call duration (ms, null for start).
     * @param errorMessage   Any error message if failed.
     * @param errorCode      Any error code if failed.
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
     * Logs an LLM response, including request, response, and extracted analysis metrics.
     *
     * @param sessionId        The chat session Id.
     * @param turnIdentifier   The turn identifier.
     * @param requestPayload   The original request for context.
     * @param responsePayload  The complete LLM response.
     * @param llmConfigId      The LLM configuration used.
     * @param durationMs       The total interaction duration (ms).
     */
    public static void logLlmResponse(
        Id sessionId,
        String turnIdentifier,
        Object requestPayload,
        Object responsePayload,
        Id llmConfigId,
        Long durationMs
    ) {
        // Extract key metrics from response for better visibility
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
     * Analyzes an LLM response payload to extract key metrics for logging (tokens, tool calls, content, etc).
     *
     * @param responsePayload  The LLM response payload.
     * @return                 Map of extracted metrics.
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

                // Extract token usage
                if (response.containsKey('providerResult')) {
                    Map<String, Object> providerResult = (Map<String, Object>) response.get('providerResult');
                    if (providerResult?.containsKey('totalTokens')) {
                        analysis.put('totalTokens', providerResult.get('totalTokens'));
                    }

                    // Check for tool calls
                    if (providerResult?.containsKey('requestedActions')) {
                        List<Object> actions = (List<Object>) providerResult.get('requestedActions');
                        analysis.put('toolCallCount', actions?.size() ?? 0);
                        analysis.put('responseType', (actions?.size() ?? 0) > 0 ? 'tool_call' : 'content');
                    }

                    // Check for content
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
            System.debug(LoggingLevel.WARN, '[OrchestrationLogger] Failed to analyze LLM response: ' + e.getMessage());
        }

        return analysis;
    }

    /**
     * Logs a graph execution step, including node name, inputs, outputs, and duration.
     *
     * @param sessionId      The chat session Id.
     * @param turnIdentifier The turn identifier.
     * @param stepType       The type of graph step.
     * @param status         The status of the step.
     * @param nodeName       The name of the graph node.
     * @param nodeInputs     The inputs to the node.
     * @param nodeOutputs    The outputs from the node.
     * @param durationMs     The execution duration (ms).
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
     * Gets the current buffer size (number of logs currently buffered).
     *
     * @return   The number of logs currently buffered.
     */
    public static Integer getBufferSize() {
        return logBuffer.size();
    }

    /**
     * Gets the current sequence number for a turn (for debugging).
     *
     * @param turnIdentifier   The turn identifier.
     * @return                 The current sequence number for the turn.
     */
    @TestVisible
    public static Integer getCurrentSequence(String turnIdentifier) {
        return turnSequenceCache.get(turnIdentifier);
    }

    /**
     * Clears all caches and buffers (for testing or transaction resets).
     *
     * @sideeffect   Empties all internal caches and log buffer.
     */
    @TestVisible
    private static void clearCache() {
        loggingEnabledCache.clear();
        turnSequenceCache.clear();
        logBuffer.clear();
        System.debug(LoggingLevel.DEBUG, '[OrchestrationLogger] All caches and buffers cleared.');
    }

    /**
     * Emergency method to force commit logs if transaction is about to fail.
     * Should only be used in exception handlers as a last resort.
     *
     * @sideeffect   Attempts to commit all buffered logs immediately.
     */
    public static void emergencyCommit() {
        if (!logBuffer.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[OrchestrationLogger] Emergency commit triggered with ' + logBuffer.size() + ' logs');
            commitLogs();
        }
    }
}
