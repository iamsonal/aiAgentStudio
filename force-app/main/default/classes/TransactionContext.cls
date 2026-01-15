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
    private List<SObject> insertBuffer;
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

    public void capturePreToolLimits() {
        this.dmlCountBeforeTool = Limits.getDMLStatements();
        this.calloutCountBeforeTool = Limits.getCallouts();
        System.debug(
            LoggingLevel.DEBUG,
            '[TransactionContext] Captured pre-tool limits - DML: ' + this.dmlCountBeforeTool + ', Callouts: ' + this.calloutCountBeforeTool
        );
    }

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
