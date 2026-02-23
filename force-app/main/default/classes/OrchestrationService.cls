/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Coordinates AI agent action flow after LLM response processing. Manages turn lifecycle.
 */
public inherited sharing class OrchestrationService {
    public virtual class OrchestrationException extends AIAgentException {
    }

    public static final String OUTCOME_COMPLETED = 'COMPLETED';
    public static final String OUTCOME_FAILED = 'FAILED';
    public static final String OUTCOME_QUEUED_FOLLOWUP = 'QUEUED_FOLLOWUP';
    public static final String OUTCOME_QUEUED_ACTION = 'QUEUED_ACTION';
    public static final String OUTCOME_AWAITING_CONFIRMATION = 'AWAITING_CONFIRMATION';
    public static final String OUTCOME_IMMEDIATE_FOLLOWUP = 'IMMEDIATE_FOLLOWUP';
    private final AgentStateService agentStateSvc;
    private final CapabilityExecutionService actionExecSvc;
    private final AgentJobEnqueuer orchestrationDispatchSvc;
    private final ContextManagerService contextManagerSvc;

    public OrchestrationService() {
        this(new AgentStateService(), new CapabilityExecutionService(), new AgentJobEnqueuer(), new ContextManagerService());
    }
    public OrchestrationService(
        AgentStateService stateSvc,
        CapabilityExecutionService actionSvc,
        AgentJobEnqueuer dispatchSvc,
        ContextManagerService contextSvc
    ) {
        if (stateSvc == null || actionSvc == null || dispatchSvc == null || contextSvc == null) {
            throw new IllegalArgumentException('All service dependencies for OrchestrationService are required.');
        }
        this.agentStateSvc = stateSvc;
        this.actionExecSvc = actionSvc;
        this.orchestrationDispatchSvc = dispatchSvc;
        this.contextManagerSvc = contextSvc;
    }

    public String processLlmResult(
        LLMInteractionService.LLMInteractionResult llmInteractionResult,
        Id executionId,
        Id originalUserId,
        Id executionUserId,
        Id agentDefinitionId,
        String turnIdentifier,
        Integer currentTurnCount,
        LLMInteractionService.MessageData userMessageDataForTurn,
        Id currentPageRecordId,
        IDecisionStepLogger.ILogger decisionLogger
    ) {
        String logPrefix = '[OrchSvc Turn:' + turnIdentifier?.left(8) + ' Cycle:' + currentTurnCount + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting orchestration for LLM result. Page context: ' + currentPageRecordId);

        try {
            if (llmInteractionResult == null || !llmInteractionResult.isSuccess) {
                String failureReason = llmInteractionResult == null ? 'Unknown LLM interaction error' : llmInteractionResult.failureReason;
                String failureCode = llmInteractionResult == null ? AIAgentConstants.ERR_CODE_LLM_CALL_FAILED : llmInteractionResult.failureCode;
                System.debug(LoggingLevel.ERROR, logPrefix + failureReason + ' (Code: ' + failureCode + ')');

                decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ llmInteractionResult });

                this.agentStateSvc.failTurn(executionId, turnIdentifier, failureReason, failureCode, logPrefix);
                return OUTCOME_FAILED;
            }

            OrchestrationContext context = new OrchestrationContext(
                llmInteractionResult,
                executionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                turnIdentifier,
                currentTurnCount,
                userMessageDataForTurn,
                this.agentStateSvc,
                this.actionExecSvc,
                this.orchestrationDispatchSvc,
                this.contextManagerSvc,
                currentPageRecordId,
                decisionLogger
            );

            ILLMResponseHandler handler;
            if (llmInteractionResult.providerResult?.requestedActions != null && !llmInteractionResult.providerResult.requestedActions.isEmpty()) {
                handler = new ToolCallResponseHandler();
            } else {
                handler = new ContentResponseHandler();
            }

            String outcome = handler.handle(context);

            return outcome;
        } catch (Exception ex) {
            String errorMsg = ex.getTypeName() + ': ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\n' + ex.getStackTraceString());

            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ ex });

            try {
                this.agentStateSvc.failTurn(executionId, turnIdentifier, errorMsg, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failTurnEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state during error handling: ' + failTurnEx.getMessage());
            }
            return OUTCOME_FAILED;
        } finally {
            if (!TransactionContext.getInstance().isDeferredDMLMode()) {
                decisionLogger.commitSteps();
            }
        }
    }

    public static String serializeActionOutcome(ActionOutcome outcome, String logPrefix) {
        try {
            if (outcome == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Action outcome is null. Returning error response for LLM.');
                return JSON.serialize(
                    new Map<String, Object>{ 'success' => false, 'error' => 'Action execution did not return an outcome.', 'retryable' => false }
                );
            }

            if (outcome.isSuccess) {
                Map<String, Object> successOutput = new Map<String, Object>{ 'success' => true };
                if (outcome.data != null) {
                    successOutput.put('data', outcome.data);
                }
                return JSON.serialize(successOutput);
            } else {
                // retryable is the machine-readable signal the LLM needs to decide whether to retry.
                // code + error together give the LLM enough context to reason about the failure type.
                // Stack traces and internal class names are already stripped from errorMessage.
                String errorMsg = String.isNotBlank(outcome.errorMessage) ? outcome.errorMessage : 'An unexpected error occurred.';

                Map<String, Object> errorOutput = new Map<String, Object>{
                    'success' => false,
                    'code' => outcome.errorCode,
                    'error' => errorMsg,
                    'retryable' => ActionOutcome.isTransient(outcome.errorCode)
                };

                if (String.isNotBlank(outcome.correctionGuidance)) {
                    errorOutput.put('guidance', outcome.correctionGuidance);
                }

                return JSON.serialize(errorOutput);
            }
        } catch (Exception jsonEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to serialize action outcome for LLM. Error: ' + jsonEx.getMessage());
            return JSON.serialize(new Map<String, Object>{ 'success' => false, 'error' => 'Failed to serialize action result.', 'retryable' => false });
        }
    }

    public static Id extractRecordIdFromOutcome(ActionOutcome actionOutcome) {
        if (actionOutcome == null || !actionOutcome.isSuccess || actionOutcome.data == null || !(actionOutcome.data instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> outputMap = (Map<String, Object>) actionOutcome.data;
        if (!'SUCCESS'.equalsIgnoreCase(String.valueOf(outputMap.get('status'))) || !(outputMap.get('data') instanceof Map<String, Object>)) {
            return null;
        }

        Map<String, Object> dataMap = (Map<String, Object>) outputMap.get('data');

        if (dataMap.get('recordId') instanceof String) {
            try {
                return Id.valueOf((String) dataMap.get('recordId'));
            } catch (Exception e) {
            }
        }

        if (dataMap.get('records') instanceof List<Object>) {
            List<Object> recordsList = (List<Object>) dataMap.get('records');
            if (recordsList.size() == 1) {
                Object firstRecord = recordsList[0];

                if (firstRecord instanceof SObject) {
                    return (Id) ((SObject) firstRecord).get('Id');
                } else if (firstRecord instanceof Map<String, Object>) {
                    Map<String, Object> recordMap = (Map<String, Object>) firstRecord;
                    if (recordMap.get('Id') instanceof String) {
                        try {
                            return Id.valueOf((String) recordMap.get('Id'));
                        } catch (Exception e) {
                        }
                    }
                }
            }
        }

        if (dataMap.get('record') instanceof Map<String, Object>) {
            Map<String, Object> recordMap = (Map<String, Object>) dataMap.get('record');
            if (recordMap.get('Id') instanceof String) {
                try {
                    return Id.valueOf((String) recordMap.get('Id'));
                } catch (Exception e) {
                }
            }
        }

        return null;
    }

    /**
     * @description Determines if execution should halt on tool error.
     *
     * Two checks only:
     * 1. Agent-level mode: if ErrorRecoveryMode__c = 'Fail Fast', halt immediately.
     * 2. Safety ceiling: if successive failure count >= global MaxToolRetries, halt to prevent infinite loops.
     *
     * In all other cases, the error flows to the LLM — the LLM decides recovery.
     *
     * Pass preloadedFailureCount >= 0 to skip the SOQL-based count (avoids N+1 queries in loops).
     * Pass -1 to fall back to the SOQL-based count.
     */
    public static Boolean shouldFailFast(
        AgentCapability__c capability,
        AIAgentDefinition__c agentDefinition,
        ActionOutcome toolOutcome,
        Id executionId,
        Integer preloadedFailureCount,
        String logPrefix
    ) {
        if (toolOutcome == null || toolOutcome.isSuccess) {
            return false;
        }

        // Agent-level mode: Fail Fast halts immediately, no LLM recovery
        if ('Fail Fast'.equals(agentDefinition.ErrorRecoveryMode__c)) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'FAIL FAST mode: halting on tool error. Capability: "' + capability.CapabilityName__c + '", ErrorCode: ' + toolOutcome.errorCode
            );
            return true;
        }

        // Non-transient errors cannot resolve on retry — fail immediately regardless of retry budget
        if (!ActionOutcome.isTransient(toolOutcome.errorCode)) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    'NON-TRANSIENT error: halting immediately. Tool: "' +
                    capability.CapabilityName__c +
                    '", ErrorCode: ' +
                    toolOutcome.errorCode +
                    ' (retrying would not resolve this error)'
            );
            return true;
        }

        // Autonomous mode: global ceiling prevents infinite loops on transient errors
        Integer maxRetries = AIAgentFrameworkSettings.getMaxToolRetries();
        Integer failureCount = (preloadedFailureCount >= 0)
            ? preloadedFailureCount
            : countSuccessiveToolFailures(executionId, capability.CapabilityName__c, logPrefix);

        if (failureCount >= maxRetries) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    'CIRCUIT BREAKER: Tool "' +
                    capability.CapabilityName__c +
                    '" halted after ' +
                    failureCount +
                    '/' +
                    maxRetries +
                    ' failures. ErrorCode: ' +
                    toolOutcome.errorCode
            );
            return true;
        }

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'TO LLM: Tool "' +
                capability.CapabilityName__c +
                '" failed (' +
                toolOutcome.errorCode +
                '). Failure ' +
                failureCount +
                '/' +
                maxRetries +
                '. LLM will decide recovery.'
        );
        return false;
    }

    /**
     * @description Backward-compatible single-tool overload. Delegates to the preloaded-count overload
     * with -1 (fall back to SOQL). Retained for callers outside the batch-check loop.
     */
    public static Boolean shouldFailFast(
        AgentCapability__c capability,
        AIAgentDefinition__c agentDefinition,
        ActionOutcome toolOutcome,
        Id executionId,
        String logPrefix
    ) {
        return shouldFailFast(capability, agentDefinition, toolOutcome, executionId, -1, logPrefix);
    }

    /**
     * @description Bulk-loads successive failure counts for multiple tool names in a single SOQL.
     * Eliminates N+1 queries when checking the fail-fast policy for a batch of failed tools.
     *
     * Returns a Map<toolName, successiveFailureCount>. Tools with no history return 0.
     */
    /**
     * @description Backward-compatible overload. Delegates to the resumeAfter overload with null timestamp.
     */
    public static Map<String, Integer> loadSuccessiveFailureCounts(Id executionId, Set<String> toolNames, String logPrefix) {
        return loadSuccessiveFailureCounts(executionId, toolNames, null, logPrefix);
    }

    /**
     * @description Bulk-loads successive failure counts for multiple tool names in a single SOQL.
     * Eliminates N+1 queries when checking the fail-fast policy for a batch of failed tools.
     *
     * When resumeAfter is non-null, only failures that occurred AFTER that timestamp are counted.
     * This ensures pre-resume failures do not deplete the post-resume circuit breaker budget
     * when a Function agent resumes with the same execution ID.
     *
     * Returns a Map<toolName, successiveFailureCount>. Tools with no history return 0.
     */
    public static Map<String, Integer> loadSuccessiveFailureCounts(Id executionId, Set<String> toolNames, Datetime resumeAfter, String logPrefix) {
        Map<String, Integer> result = new Map<String, Integer>();
        if (executionId == null || toolNames == null || toolNames.isEmpty()) {
            return result;
        }

        try {
            // Single SOQL for all tool names — replaces one-per-tool SOQL calls in loops
            List<ExecutionStep__c> persistedSteps = [
                SELECT StepType__c, ToolName__c, IsError__c, Timestamp__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND StepType__c IN ('ToolCall', 'ToolResult') AND ToolName__c IN :toolNames
                ORDER BY Timestamp__c DESC, Id DESC
                LIMIT 1000
            ];

            // Group persisted steps by tool name
            Map<String, List<ExecutionStep__c>> persistedByTool = new Map<String, List<ExecutionStep__c>>();
            for (ExecutionStep__c step : persistedSteps) {
                if (!persistedByTool.containsKey(step.ToolName__c)) {
                    persistedByTool.put(step.ToolName__c, new List<ExecutionStep__c>());
                }
                persistedByTool.get(step.ToolName__c).add(step);
            }

            // Group buffered (not-yet-persisted) steps by tool name
            Map<String, List<ExecutionStep__c>> bufferedByTool = new Map<String, List<ExecutionStep__c>>();
            for (ExecutionStep__c step : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
                if (step.ToolName__c != null && toolNames.contains(step.ToolName__c) && (step.StepType__c == 'ToolCall' || step.StepType__c == 'ToolResult')) {
                    if (!bufferedByTool.containsKey(step.ToolName__c)) {
                        bufferedByTool.put(step.ToolName__c, new List<ExecutionStep__c>());
                    }
                    bufferedByTool.get(step.ToolName__c).add(step);
                }
            }

            // For each tool: merge buffered (newest first) + persisted, then count successive failures
            for (String toolName : toolNames) {
                List<ExecutionStep__c> allSteps = new List<ExecutionStep__c>();

                List<ExecutionStep__c> buffered = bufferedByTool.get(toolName);
                if (buffered != null && !buffered.isEmpty()) {
                    buffered.sort(new ExecutionStepTimestampComparator());
                    allSteps.addAll(buffered);
                }

                List<ExecutionStep__c> persisted = persistedByTool.get(toolName);
                if (persisted != null) {
                    allSteps.addAll(persisted);
                }

                result.put(toolName, countSuccessiveFailuresFromSteps(allSteps, resumeAfter));
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Bulk-loaded failure counts for ' + toolNames.size() + ' tool(s): ' + result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error bulk-loading tool failure counts: ' + e.getMessage());
        }

        return result;
    }

    /**
     * @description Backward-compatible overload. Delegates to the resumeAfter overload with null timestamp.
     */
    public static Integer countSuccessiveToolFailures(Id executionId, String toolName, String logPrefix) {
        return countSuccessiveToolFailures(executionId, toolName, null, logPrefix);
    }

    /**
     * @description Counts successive tool failures for a single tool, optionally scoped to after a resume timestamp.
     *
     * When resumeAfter is non-null, stops counting at the first step whose Timestamp__c is at or before
     * resumeAfter. This resets the effective circuit breaker window for Function agents that resume
     * with the same execution ID, so prior-session failures do not carry over.
     */
    public static Integer countSuccessiveToolFailures(Id executionId, String toolName, Datetime resumeAfter, String logPrefix) {
        if (executionId == null || String.isBlank(toolName)) {
            return 0;
        }

        try {
            // Get persisted records from database
            List<ExecutionStep__c> persistedSteps = [
                SELECT Id, StepType__c, ToolName__c, IsError__c, Timestamp__c, ToolCallId__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND StepType__c IN ('ToolCall', 'ToolResult') AND ToolName__c = :toolName
                ORDER BY Timestamp__c DESC, Id DESC
                LIMIT 100
            ];

            // Also get buffered steps not yet committed to database.
            // In multi-LLM optimization mode, tool results are buffered in TransactionContext
            // and only committed at the end. Without this, retry counting doesn't see
            // failures from earlier cycles in the same transaction.
            List<ExecutionStep__c> bufferedSteps = new List<ExecutionStep__c>();
            for (ExecutionStep__c step : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
                if (step.ToolName__c == toolName && (step.StepType__c == 'ToolCall' || step.StepType__c == 'ToolResult')) {
                    bufferedSteps.add(step);
                }
            }

            // Merge: buffered steps are newer (not yet persisted), so they come first
            List<ExecutionStep__c> allSteps = new List<ExecutionStep__c>();
            bufferedSteps.sort(new ExecutionStepTimestampComparator());
            allSteps.addAll(bufferedSteps);
            allSteps.addAll(persistedSteps);

            if (allSteps.isEmpty()) {
                return 0;
            }

            Integer failureCount = countSuccessiveFailuresFromSteps(allSteps, resumeAfter);

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Tool "' +
                    toolName +
                    '" has ' +
                    failureCount +
                    ' successive failure(s) in execution ' +
                    executionId +
                    ' (persisted: ' +
                    persistedSteps.size() +
                    ', buffered: ' +
                    bufferedSteps.size() +
                    (resumeAfter != null ? ', scoped after resume: ' + resumeAfter : '') +
                    ')'
            );

            return failureCount;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error counting tool failures: ' + e.getMessage());
            return 0;
        }
    }

    /**
     * @description Walks a pre-merged list of ExecutionStep__c records (sorted newest-first) and
     * returns the count of consecutive ToolResult errors at the head of the list.
     *
     * Stops at the first success OR at the first step whose Timestamp__c is at or before resumeAfter
     * (pre-resume steps are excluded from the count so that a human resume resets the effective
     * circuit breaker window without requiring a new execution ID).
     */
    private static Integer countSuccessiveFailuresFromSteps(List<ExecutionStep__c> steps, Datetime resumeAfter) {
        Integer failureCount = 0;
        for (ExecutionStep__c step : steps) {
            if (step.StepType__c == 'ToolResult') {
                // Stop at the resume boundary — pre-resume failures don't count against the current window
                if (resumeAfter != null && step.Timestamp__c != null && step.Timestamp__c <= resumeAfter) {
                    break;
                }
                if (step.IsError__c == true) {
                    failureCount++;
                } else {
                    break;
                }
            }
        }
        return failureCount;
    }

    // ─── Retry Enforcement ────────────────────────────────────────────────────

    /**
     * @description Lightweight value object representing a tool that failed with a retryable
     * error in the current turn but was not retried before the LLM returned a text response.
     */
    public class UnretriedFailure {
        /** Developer name of the tool (ToolName__c on ExecutionStep__c). */
        public String toolName;
        /** ToolCallId that links to the original ToolCall step. */
        public String toolCallId;
        /** JSON arguments from the original ToolCall step so the LLM can replay the call. */
        public String originalArguments;
    }

    /**
     * @description Detects tool failures in the current turn that are retryable (RetryPending__c=true)
     * but have NOT yet been retried. Also filters out any tools whose declared dependencies are not
     * yet satisfied — those cannot be retried until the prerequisite tools succeed first.
     *
     * Merges both committed DB rows and in-memory buffered steps (deferred DML mode).
     *
     * @param executionId     AgentExecution__c ID
     * @param agentDefinitionId  AIAgentDefinition__c ID for dependency-graph access
     * @param turnIdentifier  Current turn identifier
     * @param logPrefix       Caller-supplied log prefix for tracing
     * @return List of UnretriedFailure instances (never null; empty when nothing to retry)
     */
    public static List<UnretriedFailure> detectUnretriedFailures(Id executionId, Id agentDefinitionId, String turnIdentifier, String logPrefix) {
        List<UnretriedFailure> result = new List<UnretriedFailure>();
        if (executionId == null || String.isBlank(turnIdentifier)) {
            return result;
        }

        String pfx = logPrefix + '[detectUnretriedFailures] ';

        // ── 1. Collect candidate failure steps ────────────────────────────────
        // Use a Map keyed by ToolCallId to avoid duplicates when merging DB + buffer.
        Map<String, ExecutionStep__c> failureByCallId = new Map<String, ExecutionStep__c>();

        // Query committed steps from DB
        for (ExecutionStep__c s : [
            SELECT Id, ToolName__c, ToolCallId__c, Timestamp__c
            FROM ExecutionStep__c
            WHERE
                AgentExecution__c = :executionId
                AND TurnIdentifier__c = :turnIdentifier
                AND StepType__c = 'ToolResult'
                AND IsError__c = TRUE
                AND IsRetryable__c = TRUE
                AND RetryPending__c = TRUE
        ]) {
            if (String.isNotBlank(s.ToolCallId__c)) {
                failureByCallId.put(s.ToolCallId__c, s);
            }
        }

        // Merge buffered steps (deferred DML mode — not yet committed)
        for (ExecutionStep__c s : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
            if (
                s.StepType__c == 'ToolResult' &&
                s.TurnIdentifier__c == turnIdentifier &&
                s.IsError__c == true &&
                s.IsRetryable__c == true &&
                s.RetryPending__c == true &&
                String.isNotBlank(s.ToolCallId__c)
            ) {
                failureByCallId.put(s.ToolCallId__c, s);
            }
        }

        if (failureByCallId.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, pfx + 'No RetryPending steps found for this turn.');
            return result;
        }

        // ── 2. Check if any failure was actually retried ──────────────────────────
        // A failure is considered "already retried" if ANY later ToolResult (success or
        // failure) exists for the same tool name in this turn.  This covers repeated-failure
        // scenarios: when enforcement fires, the LLM retries the tool and it fails again —
        // the old pending entries should no longer appear (the new failure takes over).
        Set<String> toolCallIdsToRemove = new Set<String>();
        Set<String> failingToolNames = new Set<String>();
        for (String callId : failureByCallId.keySet()) {
            failingToolNames.add(failureByCallId.get(callId).ToolName__c);
        }

        // Track the latest ToolResult timestamp (any outcome) per tool name.
        // Also separately track which tools have had at least one success
        // (needed later for dependency satisfaction checks).
        Map<String, Datetime> latestResultByToolName = new Map<String, Datetime>();
        Set<String> successfulToolNames = new Set<String>();
        for (ExecutionStep__c s : [
            SELECT ToolName__c, Timestamp__c, IsError__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId AND TurnIdentifier__c = :turnIdentifier AND StepType__c = 'ToolResult' AND ToolName__c IN :failingToolNames
        ]) {
            Datetime existing = latestResultByToolName.get(s.ToolName__c);
            if (existing == null || (s.Timestamp__c != null && s.Timestamp__c > existing)) {
                latestResultByToolName.put(s.ToolName__c, s.Timestamp__c);
            }
            if (!s.IsError__c) {
                successfulToolNames.add(s.ToolName__c);
            }
        }
        // Also check the in-memory buffer
        for (ExecutionStep__c s : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
            if (s.StepType__c == 'ToolResult' && s.TurnIdentifier__c == turnIdentifier && failingToolNames.contains(s.ToolName__c)) {
                Datetime existing = latestResultByToolName.get(s.ToolName__c);
                if (existing == null || (s.Timestamp__c != null && s.Timestamp__c > existing)) {
                    latestResultByToolName.put(s.ToolName__c, s.Timestamp__c);
                }
                if (!s.IsError__c) {
                    successfulToolNames.add(s.ToolName__c);
                }
            }
        }

        // Keep only the failures that are the LATEST result for their tool name
        // (i.e. there is no newer result that proves a retry already happened)
        for (String callId : failureByCallId.keySet()) {
            ExecutionStep__c s = failureByCallId.get(callId);
            Datetime latestTs = latestResultByToolName.get(s.ToolName__c);
            if (latestTs != null && (s.Timestamp__c == null || latestTs > s.Timestamp__c)) {
                toolCallIdsToRemove.add(callId);
            }
        }
        for (String callId : toolCallIdsToRemove) {
            failureByCallId.remove(callId);
        }

        if (failureByCallId.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, pfx + 'All RetryPending failures have a later result — tool(s) already retried.');
            return result;
        }

        // ── 3. Fetch original ToolCall arguments (for enforcement message) ─────
        Set<String> remainingCallIds = failureByCallId.keySet();
        Map<String, String> argsByCallId = new Map<String, String>();
        for (ExecutionStep__c tc : [
            SELECT ToolCallId__c, ToolArguments__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId AND TurnIdentifier__c = :turnIdentifier AND StepType__c = 'ToolCall' AND ToolCallId__c IN :remainingCallIds
        ]) {
            argsByCallId.put(tc.ToolCallId__c, tc.ToolArguments__c);
        }
        // Merge buffered ToolCall steps
        for (ExecutionStep__c s : TransactionContext.getInstance().getBufferedExecutionSteps(executionId)) {
            if (s.StepType__c == 'ToolCall' && s.TurnIdentifier__c == turnIdentifier && remainingCallIds.contains(s.ToolCallId__c)) {
                argsByCallId.put(s.ToolCallId__c, s.ToolArguments__c);
            }
        }

        // ── 4. Dependency filter ───────────────────────────────────────────────
        // Only include failures whose own declared dependencies are currently satisfied.
        // Tools with unsatisfied deps can't be retried until the dependency is fixed.
        String graphJson = null;
        Boolean depValidationEnabled = false;
        if (agentDefinitionId != null) {
            try {
                AIAgentDefinition__c defn = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
                graphJson = defn.ToolDependencyGraph__c;
                depValidationEnabled = defn.EnableDependencyValidation__c == true;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, pfx + 'Could not load agent definition for dependency check: ' + e.getMessage());
            }
        }

        ToolDependencyValidator.DependencyGraph depGraph = null;
        if (depValidationEnabled && String.isNotBlank(graphJson)) {
            try {
                depGraph = ToolDependencyValidator.parseGraph(graphJson);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, pfx + 'Could not parse ToolDependencyGraph__c: ' + e.getMessage());
            }
        }

        // Build set of successfully executed tool names in this turn (for dependency satisfaction check)
        Set<String> satisfiedTools = new Set<String>(successfulToolNames);

        // ── 5. Build result list ───────────────────────────────────────────────
        for (String callId : failureByCallId.keySet()) {
            ExecutionStep__c s = failureByCallId.get(callId);
            String tName = s.ToolName__c;

            // Dependency filter: skip tools whose deps are not yet met
            if (depGraph != null && depGraph.hasDependencies()) {
                ToolDependencyValidator.ValidationResult vr = ToolDependencyValidator.validate(tName, satisfiedTools, graphJson);
                if (!vr.allowed) {
                    System.debug(
                        LoggingLevel.DEBUG,
                        pfx + 'Excluding ' + tName + ' from retry enforcement — dependencies not satisfied: ' + vr.missingDependencies
                    );
                    continue;
                }
            }

            UnretriedFailure failure = new UnretriedFailure();
            failure.toolName = tName;
            failure.toolCallId = callId;
            failure.originalArguments = argsByCallId.get(callId);
            result.add(failure);
            System.debug(LoggingLevel.DEBUG, pfx + 'Unretried retryable failure: ' + tName + ' (callId=' + callId + ')');
        }

        System.debug(LoggingLevel.INFO, pfx + 'Detected ' + result.size() + ' unretried retryable failure(s).');
        return result;
    }

    /**
     * @description Comparator class to sort ExecutionStep__c records by Timestamp__c descending (newest first).
     */
    private class ExecutionStepTimestampComparator implements Comparator<ExecutionStep__c> {
        public Integer compare(ExecutionStep__c a, ExecutionStep__c b) {
            // Null safety
            if (a.Timestamp__c == null && b.Timestamp__c == null) {
                return 0;
            }
            if (a.Timestamp__c == null) {
                return 1; // null goes last
            }
            if (b.Timestamp__c == null) {
                return -1;
            }
            // Descending order (newest first)
            if (a.Timestamp__c > b.Timestamp__c) {
                return -1;
            } else if (a.Timestamp__c < b.Timestamp__c) {
                return 1;
            }
            return 0;
        }
    }

    /**
     * @description Called by AsyncActionEngine after an async tool completes to atomically decrement the pending counter and trigger follow-up when all tools complete.
     */
    public static void onAsyncToolCompleted(Id executionId, String turnIdentifier, Integer currentTurnCount, String completedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool completed: ' + completedToolCallId + '. Atomically decrementing counter.');

            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c, SourceRecordId__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            if (String.isNotBlank(execution.AsyncToolTurnIdentifier__c) && !turnIdentifier.equals(execution.AsyncToolTurnIdentifier__c)) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Stale async tool completion detected. Expected turn: ' +
                        execution.AsyncToolTurnIdentifier__c +
                        ', Received: ' +
                        turnIdentifier +
                        '. Ignoring completion.'
                );
                return;
            }

            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Async tool counter decremented: ' + currentCount + ' -> ' + newCount);

            if (newCount == 0 && currentCount > 0) {
                // Check if there are pending HITL actions before triggering LLM
                // If HITL is pending, defer the LLM call - HITL completion will trigger it
                if (HITLGatewayService.hasPendingActions(executionId)) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'All async tools completed but HITL action(s) pending. Deferring LLM call to HITL completion.');
                } else {
                    System.debug(LoggingLevel.INFO, logPrefix + 'All async tools have completed. Triggering final follow-up LLM call.');
                    triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
                }
            } else if (newCount > 0) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Still waiting for ' + newCount + ' more async tool(s) to complete.');
            }
        } catch (QueryException qe) {
            if (qe.getMessage().contains('UNABLE_TO_LOCK_ROW')) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Record locked by concurrent transaction. Will retry via platform retry mechanism.');
                throw qe;
            }
            System.debug(LoggingLevel.ERROR, logPrefix + 'Query error in async tool completion: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in async tool completion check: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    /**
     * @description Decrements the async tool counter when a tool fails to queue, preventing execution hangs.
     */
    public static void decrementAsyncToolCounter(Id executionId, String turnIdentifier, Integer currentTurnCount, String failedToolCallId, String logPrefix) {
        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Decrementing counter for failed queue: ' + failedToolCallId);

            AgentExecution__c execution = [
                SELECT Id, PendingAsyncToolCount__c, AsyncToolTurnIdentifier__c, AIAgentDefinition__c, User__c, SourceRecordId__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                FOR UPDATE
            ];

            if (String.isNotBlank(execution.AsyncToolTurnIdentifier__c) && !turnIdentifier.equals(execution.AsyncToolTurnIdentifier__c)) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Turn identifier mismatch. Skipping decrement.');
                return;
            }

            Integer currentCount = execution.PendingAsyncToolCount__c != null ? (Integer) execution.PendingAsyncToolCount__c : 0;
            Integer newCount = Math.max(0, currentCount - 1);
            execution.PendingAsyncToolCount__c = newCount;
            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Counter decremented for queue failure: ' + currentCount + ' -> ' + newCount);

            if (newCount == 0 && currentCount > 0) {
                // Check if there are pending HITL actions before triggering LLM
                if (HITLGatewayService.hasPendingActions(executionId)) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'All async tools failed/completed but HITL action(s) pending. Deferring LLM call.');
                } else {
                    System.debug(LoggingLevel.INFO, logPrefix + 'All async tools failed to queue. Triggering follow-up for error handling.');
                    triggerFinalFollowUpLLMCallInternal(execution, turnIdentifier, currentTurnCount, logPrefix);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error decrementing counter: ' + e.getMessage());
        }
    }

    private static void triggerFinalFollowUpLLMCallInternal(AgentExecution__c execution, String turnIdentifier, Integer currentTurnCount, String logPrefix) {
        try {
            execution.AsyncToolTurnIdentifier__c = null;
            update execution;

            AgentStateService agentStateSvcLocal = new AgentStateService();
            agentStateSvcLocal.resumeForFollowUpLlmCall(execution.Id, turnIdentifier, null, logPrefix);

            AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(agentStateSvcLocal);
            orchestrationDispatchSvc.enqueueFollowUp(
                execution.Id,
                execution.User__c,
                execution.AIAgentDefinition__c,
                turnIdentifier,
                currentTurnCount + 1,
                logPrefix,
                false,
                execution.SourceRecordId__c
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Final follow-up LLM call queued for parallel execution completion');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error triggering final follow-up LLM call: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }
}
