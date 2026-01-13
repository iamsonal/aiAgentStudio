/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Singleton class that tracks transaction state for multi-LLM optimization.
 * Manages deferred DML mode, LLM call counting, and tool safety detection
 * using the Limits class to check for DML/callouts.
 *
 * Usage:
 *   TransactionContext ctx = TransactionContext.getInstance();
 *   ctx.enableDeferredDMLMode();
 *   ctx.incrementLLMCallCount();
 *   ctx.capturePreToolLimits();
 *   // ... execute tool ...
 *   if (!ctx.toolPerformedDMLOrCallout() && ctx.canMakeAnotherLLMCall()) {
 *       // Safe to call LLM again in this transaction
 *   }
 *
 * Thread Safety:
 *   Apex is single-threaded within a transaction, so no synchronization is needed.
 *   The static instance is reset between transactions automatically.
 */
public inherited sharing class TransactionContext {
    private static TransactionContext instance;

    // Deferred DML mode flag
    private Boolean deferredDMLMode;

    // LLM call tracking
    private Integer llmCallCount;

    // Limits tracking for tool safety detection
    private Integer dmlCountBeforeTool;
    private Integer calloutCountBeforeTool;

    // DML buffer for deferred inserts (multi-LLM optimization)
    private List<SObject> insertBuffer;

    /**
     * Private constructor to enforce singleton pattern.
     */
    private TransactionContext() {
        this.deferredDMLMode = false;
        this.llmCallCount = 0;
        this.dmlCountBeforeTool = 0;
        this.calloutCountBeforeTool = 0;
        this.insertBuffer = new List<SObject>();
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

    // ===================================================================================
    // DEFERRED DML MODE MANAGEMENT
    // ===================================================================================

    /**
     * Enables deferred DML mode for this transaction.
     * When enabled, services like ExecutionStepService and AgentStateService
     * will buffer their DML operations instead of executing immediately.
     */
    public void enableDeferredDMLMode() {
        this.deferredDMLMode = true;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Deferred DML mode ENABLED');
    }

    /**
     * Disables deferred DML mode for this transaction.
     * After disabling, services will execute DML immediately as normal.
     */
    public void disableDeferredDMLMode() {
        this.deferredDMLMode = false;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] Deferred DML mode DISABLED');
    }

    /**
     * Checks if deferred DML mode is currently enabled.
     *
     * @return True if deferred DML mode is enabled, false otherwise.
     */
    public Boolean isDeferredDMLMode() {
        return this.deferredDMLMode;
    }

    // ===================================================================================
    // LLM CALL TRACKING
    // ===================================================================================

    /**
     * Increments the LLM call counter.
     * Call this each time an LLM callout is made in the transaction.
     */
    public void incrementLLMCallCount() {
        this.llmCallCount++;
        System.debug(LoggingLevel.DEBUG, '[TransactionContext] LLM call count: ' + this.llmCallCount);
    }

    /**
     * Gets the current LLM call count for this transaction.
     *
     * @return The number of LLM calls made in this transaction.
     */
    public Integer getLLMCallCount() {
        return this.llmCallCount;
    }

    /**
     * Checks if another LLM call can be made in this transaction.
     * Uses the configured MaxLLMCallsPerTransaction setting.
     *
     * @return True if under the limit, false if limit reached.
     */
    public Boolean canMakeAnotherLLMCall() {
        Integer maxCalls = AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction();
        Boolean canCall = this.llmCallCount < maxCalls;

        if (!canCall) {
            System.debug(LoggingLevel.INFO, '[TransactionContext] Max LLM calls reached (' + maxCalls + ')');
        }

        return canCall;
    }

    // ===================================================================================
    // TOOL SAFETY DETECTION (using Limits class)
    // ===================================================================================

    /**
     * Captures the current DML and callout counts from the Limits class.
     * Call this BEFORE executing a tool to establish a baseline.
     */
    public void capturePreToolLimits() {
        this.dmlCountBeforeTool = Limits.getDMLStatements();
        this.calloutCountBeforeTool = Limits.getCallouts();
        System.debug(
            LoggingLevel.DEBUG,
            '[TransactionContext] Captured pre-tool limits - DML: ' + this.dmlCountBeforeTool + ', Callouts: ' + this.calloutCountBeforeTool
        );
    }

    /**
     * Checks if the most recently executed tool performed any DML or callouts.
     * Call this AFTER executing a tool to determine if it's safe to continue.
     *
     * @return True if the tool performed DML or callouts, false if safe.
     */
    public Boolean toolPerformedDMLOrCallout() {
        Integer currentDML = Limits.getDMLStatements();
        Integer currentCallouts = Limits.getCallouts();

        Boolean performedDML = currentDML > this.dmlCountBeforeTool;
        Boolean performedCallout = currentCallouts > this.calloutCountBeforeTool;

        if (performedDML || performedCallout) {
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
                    ' calls)'
            );
        } else {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Tool is safe (no DML or callouts detected)');
        }

        return performedDML || performedCallout;
    }

    /**
     * Convenience method that combines the multi-LLM eligibility checks.
     * Returns true if:
     * 1. Deferred DML mode is enabled
     * 2. The tool did not perform DML or callouts
     * 3. We haven't reached the max LLM calls limit
     *
     * @return True if another immediate LLM call is allowed, false otherwise.
     */
    public Boolean canContinueWithImmediateFollowUp() {
        if (!this.deferredDMLMode) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: deferred DML mode not enabled');
            return false;
        }

        if (toolPerformedDMLOrCallout()) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: tool performed DML or callout');
            return false;
        }

        if (!canMakeAnotherLLMCall()) {
            System.debug(LoggingLevel.DEBUG, '[TransactionContext] Cannot continue: max LLM calls reached');
            return false;
        }

        return true;
    }

    // ===================================================================================
    // DML BUFFER MANAGEMENT (for deferred inserts)
    // ===================================================================================

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

    // ===================================================================================
    // LIFECYCLE MANAGEMENT
    // ===================================================================================

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
