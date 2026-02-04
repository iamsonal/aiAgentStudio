/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Singleton class that tracks transaction state for multi-LLM optimization. Manages deferred DML mode, LLM call counting, and tool safety detection.
 */
public inherited sharing class TransactionContext {
    private static TransactionContext instance;
    private Boolean deferredDMLMode;
    private Integer llmCallCount;
    private Integer dmlCountBeforeTool;
    private Integer calloutCountBeforeTool;
    private Integer emailCountBeforeTool;
    private List<SObject> insertBuffer;
    private Boolean hasPreExistingExecution;
    private Map<Id, Set<String>> executedToolsByExecution;

    /**
     * Sticky flag that tracks if ANY tool in this turn performed DML or callouts.
     * Once set to true, remains true until explicitly reset via resetTurnSafetyTracking().
     * This prevents the bug where checking only the last tool's operations would
     * incorrectly allow a follow-up LLM call after earlier tools performed DML.
     */
    private Boolean unsafeOperationsOccurredThisTurn;

    private TransactionContext() {
        this.deferredDMLMode = false;
        this.llmCallCount = 0;
        this.dmlCountBeforeTool = 0;
        this.calloutCountBeforeTool = 0;
        this.emailCountBeforeTool = 0;
        this.insertBuffer = new List<SObject>();
        this.hasPreExistingExecution = false;
        this.executedToolsByExecution = new Map<Id, Set<String>>();
        this.unsafeOperationsOccurredThisTurn = false;
    }

    /**
     * Gets the singleton instance of the context.
     * Creates a new instance if one doesn't exist.
     *
     * @return The singleton TransactionContext instance.
     */
    public static TransactionContext getInstance() {
        if (instance == null) {
            instance = new TransactionContext();
        }
        return instance;
    }

    // DEFERRED DML MODE MANAGEMENT

    /**
     * Enables deferred DML mode for this transaction.
     * When enabled, services like ExecutionStepService and AgentStateService
     * will buffer their DML operations instead of executing immediately.
     */
    public void enableDeferredDMLMode() {
        this.deferredDMLMode = true;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Deferred DML mode ENABLED');
    }

    public void disableDeferredDMLMode() {
        this.deferredDMLMode = false;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Deferred DML mode DISABLED');
    }

    public Boolean isDeferredDMLMode() {
        return this.deferredDMLMode;
    }

    public void incrementLLMCallCount() {
        this.llmCallCount++;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] LLM call count: ' + this.llmCallCount);
    }

    public Integer getLLMCallCount() {
        return this.llmCallCount;
    }

    public Boolean canMakeAnotherLLMCall() {
        Integer maxCalls = AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction();
        Boolean canCall = this.llmCallCount < maxCalls;

        if (!canCall) {
            System.debug(LoggingLevel.INFO, '[TransactionContext] Max LLM calls reached (' + maxCalls + ')');
        }

        return canCall;
    }

    // PRE-EXISTING EXECUTION TRACKING

    /**
     * Sets whether a pre-existing execution record was provided at the start of this transaction.
     * When true, indicates the execution was created in a previous transaction (workflow/bulk context).
     * When false, indicates the execution will be created during this transaction.
     *
     * This flag is used by canContinueWithImmediateFollowUp() to ensure that newly created
     * executions are committed before making follow-up LLM calls in a new transaction.
     *
     * @param hasPreExisting True if execution record existed before this transaction started.
     */
    public void setHasPreExistingExecution(Boolean hasPreExisting) {
        this.hasPreExistingExecution = hasPreExisting;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Pre-existing execution flag set to: ' + hasPreExisting);
    }

    /**
     * Returns whether a pre-existing execution record was provided.
     *
     * @return True if execution existed before this transaction, false otherwise.
     */
    public Boolean hasPreExistingExecution() {
        return this.hasPreExistingExecution;
    }

    /**
     * Captures current DML and callout counts as baselines for tool safety detection.
     * Called before individual tool executions to track per-tool operations.
     *
     * Note: This method does NOT reset the unsafeOperationsOccurredThisTurn flag.
     * That flag is sticky and only resets via resetTurnSafetyTracking() at turn start.
     */
    public void capturePreToolLimits() {
        this.dmlCountBeforeTool = Limits.getDMLStatements();
        this.calloutCountBeforeTool = Limits.getCallouts();
        this.emailCountBeforeTool = Limits.getEmailInvocations();
        System.debug(
            LoggingLevel.DEBUG,
            '[TransactionContext] Captured pre-tool limits - DML: ' +
                this.dmlCountBeforeTool +
                ', Callouts: ' +
                this.calloutCountBeforeTool +
                ', Emails: ' +
                this.emailCountBeforeTool
        );
    }

    /**
     * Resets turn safety tracking for a new turn/iteration.
     * Should be called by orchestrators at the START of each LLM turn, BEFORE any tools execute.
     * This clears the sticky unsafeOperationsOccurredThisTurn flag and captures fresh baselines.
     */
    public void resetTurnSafetyTracking() {
        this.unsafeOperationsOccurredThisTurn = false;
        this.dmlCountBeforeTool = Limits.getDMLStatements();
        this.calloutCountBeforeTool = Limits.getCallouts();
        this.emailCountBeforeTool = Limits.getEmailInvocations();
        System.debug(
            LoggingLevel.DEBUG,
            '[TransactionContext] Turn safety tracking reset - DML baseline: ' +
                this.dmlCountBeforeTool +
                ', Callout baseline: ' +
                this.calloutCountBeforeTool +
                ', Email baseline: ' +
                this.emailCountBeforeTool
        );
    }

    /**
     * Checks if the most recently executed tool performed DML or callouts.
     * If unsafe operations are detected, sets the sticky unsafeOperationsOccurredThisTurn flag.
     *
     * @return True if the tool performed DML or callouts, false otherwise.
     */
    public Boolean toolPerformedDMLOrCallout() {
        Integer currentDML = Limits.getDMLStatements();
        Integer currentCallouts = Limits.getCallouts();
        Integer currentEmails = Limits.getEmailInvocations();

        Boolean performedDML = currentDML > this.dmlCountBeforeTool;
        Boolean performedCallout = currentCallouts > this.calloutCountBeforeTool;
        Boolean performedEmail = currentEmails > this.emailCountBeforeTool;

        if (performedDML || performedCallout || performedEmail) {
            // Set sticky flag - once unsafe, the entire turn is unsafe
            this.unsafeOperationsOccurredThisTurn = true;

            System.debug(
                LoggingLevel.INFO,
                '[TransactionContext] Tool performed unsafe operations - DML: ' +
                    performedDML +
                    ' (' +
                    (currentDML - this.dmlCountBeforeTool) +
                    ' statements), Callout: ' +
                    performedCallout +
                    ' (' +
                    (currentCallouts - this.calloutCountBeforeTool) +
                    ' calls), Email: ' +
                    performedEmail +
                    ' (' +
                    (currentEmails - this.emailCountBeforeTool) +
                    ' sends). Sticky flag set.'
            );
        } else {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Tool is safe (no DML, callouts, or emails detected)');
        }

        return performedDML || performedCallout || performedEmail;
    }

    /**
     * Marks the current turn as unsafe for immediate follow-up, regardless of limits.
     * Use when a tool performs operations that Salesforce treats as uncommitted work.
     *
     * @param reason Human-readable reason for logging
     */
    public void markUnsafeOperation(String reason) {
        this.unsafeOperationsOccurredThisTurn = true;
        System.debug(LoggingLevel.INFO, '[TransactionContext] Unsafe operation flagged manually' + (String.isNotBlank(reason) ? (': ' + reason) : ''));
    }

    /**
     * Returns whether ANY tool in this turn has performed unsafe operations (DML or callouts).
     * This is a sticky flag - once true, remains true until resetTurnSafetyTracking() is called.
     *
     * @return True if any tool this turn performed DML or callouts.
     */
    public Boolean hasUnsafeOperationsThisTurn() {
        return this.unsafeOperationsOccurredThisTurn;
    }

    @TestVisible
    private void setUnsafeOperationsForTest(Boolean isUnsafe) {
        this.unsafeOperationsOccurredThisTurn = isUnsafe == true;
    }

    /**
     * Convenience method that combines the multi-LLM eligibility checks.
     * Returns true if:
     * 1. Deferred DML mode is enabled
     * 2. A pre-existing execution record was provided (not created in this transaction)
     * 3. NO tool in this turn performed DML or callouts (sticky flag check)
     * 4. We haven't reached the max LLM calls limit
     *
     * IMPORTANT: Uses the sticky hasUnsafeOperationsThisTurn flag, which tracks if ANY
     * tool in this turn performed unsafe operations, not just the last tool. This prevents
     * the bug where Tool A performs DML, Tool B doesn't, and we incorrectly allow follow-up.
     *
     * @return True if another immediate LLM call is allowed, false otherwise.
     */
    public Boolean canContinueWithImmediateFollowUp() {
        if (!this.deferredDMLMode) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: deferred DML mode not enabled');
            return false;
        }

        if (!this.hasPreExistingExecution) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: no pre-existing execution record (will commit and use new transaction)');
            return false;
        }

        // Use sticky flag instead of fresh check - this ensures we catch DML from ANY tool in this turn
        if (this.unsafeOperationsOccurredThisTurn) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: unsafe operations occurred this turn (DML or callout)');
            return false;
        }

        if (!canMakeAnotherLLMCall()) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: max LLM calls reached');
            return false;
        }

        return true;
    }

    // DML BUFFER MANAGEMENT (for deferred inserts)

    /**
     * Buffers an SObject record for deferred insert.
     * The record will be inserted when commitBuffer() is called.
     *
     * @param record The SObject record to buffer for insert.
     */
    public void bufferInsert(SObject record) {
        if (record != null) {
            this.insertBuffer.add(record);
        }
    }

    /**
     * Commits all buffered DML operations.
     * Clears the buffer after successful commit.
     */
    public void commitBuffer() {
        if (!this.insertBuffer.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[TransactionContext] Committing ' + this.insertBuffer.size() + ' buffered inserts');
            insert this.insertBuffer;
            this.insertBuffer.clear();
        }
    }

    /**
     * Gets buffered ExecutionStep__c records for a specific execution.
     * Used by ExecutionStepService.getHistory() to include buffered (not yet persisted)
     * steps in the conversation history sent to the LLM.
     *
     * @param executionId The AgentExecution__c ID to filter by
     * @return List of buffered ExecutionStep__c records for the given execution.
     */
    public List<ExecutionStep__c> getBufferedExecutionSteps(Id executionId) {
        List<ExecutionStep__c> result = new List<ExecutionStep__c>();
        if (executionId == null) {
            return result;
        }
        for (SObject record : this.insertBuffer) {
            if (record.getSObjectType() == ExecutionStep__c.SObjectType) {
                ExecutionStep__c step = (ExecutionStep__c) record;
                if (step.AgentExecution__c == executionId) {
                    result.add(step);
                }
            }
        }
        return result;
    }

    // TOOL EXECUTION TRACKING (for dependency validation)

    /**
     * Tracks a tool as executed for a given execution within this transaction.
     * Used for same-transaction dependency validation before steps are persisted to DB.
     *
     * @param executionId The AgentExecution__c ID
     * @param toolName The name of the tool that was executed successfully
     */
    public void trackExecutedTool(Id executionId, String toolName) {
        if (executionId == null || String.isBlank(toolName)) {
            return;
        }
        if (!this.executedToolsByExecution.containsKey(executionId)) {
            this.executedToolsByExecution.put(executionId, new Set<String>());
        }
        this.executedToolsByExecution.get(executionId).add(toolName);
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Tracked executed tool: ' + toolName + ' for execution: ' + executionId);
    }

    /**
     * Gets the set of tools executed in this transaction for a given execution.
     * Used for dependency validation to include tools that haven't been persisted yet.
     *
     * @param executionId The AgentExecution__c ID
     * @return Set of tool names executed in this transaction, or null if none
     */
    public Set<String> getExecutedTools(Id executionId) {
        if (executionId == null) {
            return null;
        }
        return this.executedToolsByExecution.get(executionId);
    }

    // LIFECYCLE MANAGEMENT

    /**
     * Resets all context state to initial values.
     * Useful when starting a new logical operation within the same transaction.
     */
    public void reset() {
        this.deferredDMLMode = false;
        this.llmCallCount = 0;
        this.dmlCountBeforeTool = 0;
        this.calloutCountBeforeTool = 0;
        this.insertBuffer.clear();
        this.hasPreExistingExecution = false;
        this.executedToolsByExecution.clear();
        this.unsafeOperationsOccurredThisTurn = false;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Context reset to initial state');
    }

    /**
     * Resets the singleton instance for testing purposes.
     * This allows tests to start with a clean context.
     */
    @TestVisible
    private static void resetInstance() {
        instance = null;
    }
}
