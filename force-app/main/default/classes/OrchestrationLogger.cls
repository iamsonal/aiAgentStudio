/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Utility class for creating and saving OrchestrationLog__c records conditionally.
 *              Provides centralized logic for checking the logging flag, formatting payloads,
 *              managing sequence, and handling DML errors gracefully. Logs are buffered
 *              per transaction and committed explicitly.
 */
public inherited sharing class OrchestrationLogger {
    @TestVisible
    private static List<OrchestrationLog__c> logBuffer = new List<OrchestrationLog__c>();

    @TestVisible
    private static Map<Id, Boolean> loggingEnabledCache = new Map<Id, Boolean>();

    private static final Integer MAX_PAYLOAD_LENGTH = 131000;

    public static final String TYPE_USER_PROMPT = 'UserPrompt';
    public static final String TYPE_CONTEXT_GATHERING = 'ContextGathering';
    public static final String TYPE_LLM_PREP = 'LLMRequestPreparation';
    public static final String TYPE_LLM_CALL = 'LLMCallAttempt';
    public static final String TYPE_LLM_RESPONSE = 'LLMResponse';
    public static final String TYPE_ACTION_PARSE = 'ActionRequestParsing';
    public static final String TYPE_ACTION_START = 'ActionExecutionStart';
    public static final String TYPE_ACTION_RESULT = 'ActionExecutionResult';
    public static final String TYPE_TOOL_SAVE = 'ToolResultSaving';
    public static final String TYPE_DISPATCH = 'NextStepDispatch';
    public static final String TYPE_TURN_COMPLETE = 'TurnCompletion';
    public static final String TYPE_TURN_FAIL = 'TurnFailure';

    public static final String STATUS_INIT = 'Initiated';
    public static final String STATUS_SUCCESS = 'Success';
    public static final String STATUS_FAILURE = 'Failure';
    public static final String STATUS_SKIPPED = 'Skipped';

    /**
     * @description Checks if detailed logging is enabled for the given session ID.
     *              Uses a transaction-scoped cache to minimize queries.
     * @param sessionId ID of the ChatSession__c
     * @return Boolean True if enabled, false otherwise. Returns false if sessionId is null or record not found.
     */
    public static Boolean isEnabled(Id sessionId) {
        if (sessionId == null)
            return false;

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
                if (!sessions.isEmpty()) {
                    isEnabled = sessions[0].EnableOrchestrationLogging__c == true;
                } else {
                }
            } catch (Exception e) {
            }
            loggingEnabledCache.put(sessionId, isEnabled);
        }
        return loggingEnabledCache.get(sessionId);
    }

    /**
     * @description Logs a detailed step in the orchestration process IF logging is enabled for the session.
     *              Requires the caller to manage and pass the Sequence__c value.
     * @param sessionId - Chat Session ID (Required)
     * @param turnIdentifier - User Turn Identifier (Required)
     * @param sequence - Execution sequence number within the turn (Required by caller)
     * @param stepType - Picklist API Name from OrchestrationLog__c.StepType__c (Required, use constants)
     * @param status - Picklist API Name from OrchestrationLog__c.Status__c (Required, use constants)
     * @param details - Optional summary text
     * @param inputPayload - Optional input object (will be JSON serialized & truncated)
     * @param outputPayload - Optional output object (will be JSON serialized & truncated)
     * @param errorMessage - Optional error message text (if status=Failure)
     * @param errorCode - Optional error code (if status=Failure)
     * @param durationMs - Optional step duration
     * @param chatMessageId - Optional related ChatMessage__c ID
     * @param bindingId - Optional related AgentCapabilityBinding__c ID
     * @param actionDefId - Optional related ActionDefinition__c ID
     * @param llmConfigId - Optional related LLMConfiguration__c ID
     * @param toolCallId - Optional LLM Tool Call ID
     */
    public static void logStep(
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
        Id bindingId,
        Id actionDefId,
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
                Details__c = details?.abbreviate(131072),
                ErrorMessage__c = errorMessage?.abbreviate(131072),
                ErrorCode__c = errorCode,
                DurationMillis__c = durationMs,
                ChatMessage__c = chatMessageId,
                AgentCapabilityBinding__c = bindingId,
                ActionDefinition__c = actionDefId,
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
     *              This should be called at the end of a transaction (e.g., end of Queueable execute).
     *              Uses allOrNone=false and traps DML exceptions to prevent logging failures
     *              from disrupting the main agent flow. Clears the buffer after attempting insert.
     */
    public static void commitLogs() {
        if (logBuffer.isEmpty()) {
            return;
        }

        List<OrchestrationLog__c> logsToInsert = new List<OrchestrationLog__c>(logBuffer);

        logBuffer.clear();

        try {
            Database.SaveResult[] results = Database.insert(logsToInsert, false);

            Integer successCount = 0;
            List<String> errorMessages = new List<String>();
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    Database.Error err = results[i].getErrors()[0];
                    OrchestrationLog__c failedLog = logsToInsert[i];

                    String errMsg = String.format(
                        'Failed saving OrcheLog [Sess:{0}, Turn:{1}, Seq:{2}, Type:{3}]. Error: {4} - {5}',
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
        } catch (Exception e) {
        } finally {
            if (!logBuffer.isEmpty()) {
                logBuffer.clear();
            }
        }
    }

    /**
     * @description Safely serializes an object to JSON and truncates if necessary.
     * @param payload The object to serialize.
     * @return JSON String, truncated if exceeding MAX_PAYLOAD_LENGTH, or error message on failure.
     */
    @TestVisible
    private static String serializeAndTruncate(Object payload) {
        if (payload == null)
            return null;
        String jsonString = null;
        try {
            jsonString = JSON.serialize(payload, false);
            if (jsonString.length() > MAX_PAYLOAD_LENGTH) {
                jsonString = jsonString.left(MAX_PAYLOAD_LENGTH - 18) + '... [truncated]';
            }
        } catch (Exception e) {
            String errMsg = '[OrchestrationLogger] Payload serialization failed: ' + e.getMessage();

            jsonString = '{"error": "Failed to serialize payload", "details": "' + String.valueOf(e.getMessage()).escapeJava() + '"}';
        }
        return jsonString;
    }

    /**
     * @description Clears the logging enabled cache (for testing or specific transaction resets).
     */
    @TestVisible
    private static void clearCache() {
        loggingEnabledCache.clear();
        logBuffer.clear();
    }
}
