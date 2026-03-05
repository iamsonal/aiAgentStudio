/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface abstraction for decision step logging.
 *
 * Design Philosophy:
 * - Core package defines WHAT happened (semantic events via EventType)
 * - Core passes domain objects as-is (the objects it already has)
 * - Addon decides EVERYTHING about storage: titles, descriptions, JSON structure, field extraction
 *
 * This completely decouples the core framework from the storyboard UI implementation.
 */
public inherited sharing class IDecisionStepLogger {
    /**
     * Semantic event types representing what happened during agent execution.
     * Core package emits these events; addon decides how to represent them.
     */
    public enum EventType {
        // Error events
        ERROR,
        // Tool lifecycle events
        TOOL_RESULT,
        APPROVAL_REQUESTED,
        APPROVAL_RESOLVED,
        // LLM interaction events
        LLM_REQUEST,
        LLM_RESPONSE,
        PII_MASKING,
        SAFETY_CHECK,
        SAFETY_BLOCKED, // Prompt safety blocked a message (returns safe response, not error)
        // Context preparation events
        SYSTEM_PROMPT_BUILT,
        CONTEXT_GATHERED,
        TOOLS_CONFIGURED,
        // Agent response events
        FINAL_RESPONSE,
        USER_INPUT,
        // Resume events (manual intervention)
        AGENT_RESUMED,
        // Framework enforcement events
        RETRY_ENFORCEMENT // Framework detected LLM ignored retryable failure(s) and injected a retry instruction
    }

    /**
     * Minimal interface - addon owns all storage/display decisions.
     */
    public interface ILogger {
        /**
         * Initialize the logger with execution context.
         * @param executionId The AgentExecution__c ID
         * @param turnIdentifier The turn identifier
         * @param originalUserId The ID of the user who initiated the conversation
         */
        void initialize(Id executionId, String turnIdentifier, Id originalUserId);

        /**
         * Log a semantic event with context objects.
         *
         * Core passes domain objects as-is. Addon casts based on EventType and extracts:
         * - Titles, descriptions (addon decides the wording)
         * - Field values (addon decides what to extract)
         * - JSON structure (addon decides the schema)
         *
         * @param eventType What type of event occurred
         * @param context List of domain objects relevant to this event (addon casts as needed)
         */
        void log(EventType eventType, List<Object> context);

        /**
         * Update the execution ID for all collected (but not yet committed) decision steps.
         * @param newExecutionId The new execution ID to set
         */
        void updateExecutionId(Id newExecutionId);

        /**
         * Commit all collected steps in a single bulk DML operation.
         */
        void commitSteps();

        /**
         * Get the ID of the last logged step (for causality tracking).
         * @return The ID of the last logged step, or null
         */
        Id getLastLoggedStepId();
    }

    /**
     * No-operation implementation when decision step logging is disabled or addon not installed.
     */
    public class NoOp implements ILogger {
        public void initialize(Id executionId, String turnIdentifier, Id originalUserId) {
        }
        public void log(EventType eventType, List<Object> context) {
        }
        public void updateExecutionId(Id newExecutionId) {
        }
        public void commitSteps() {
        }
        public Id getLastLoggedStepId() {
            return null;
        }
    }

    /**
     * Factory method to create the appropriate logger implementation.
     */
    private static final String ADDONS_LOGGER_CLASS = 'AgentDecisionStepLogger';

    public static ILogger create(Id executionId, String turnIdentifier, Id originalUserId) {
        if (!AIAgentFrameworkSettings.isDecisionStepLoggingEnabled()) {
            System.debug(LoggingLevel.DEBUG, '[IDecisionStepLogger] Decision step logging is disabled via settings');
            return new NoOp();
        }

        Type loggerType = Type.forName(ADDONS_LOGGER_CLASS);
        if (loggerType != null) {
            try {
                ILogger logger = (ILogger) loggerType.newInstance();
                logger.initialize(executionId, turnIdentifier, originalUserId);
                return logger;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[IDecisionStepLogger] Failed to instantiate ' + ADDONS_LOGGER_CLASS + ': ' + e.getMessage());
            }
        } else {
            System.debug(LoggingLevel.DEBUG, '[IDecisionStepLogger] Addons logger class not found (' + ADDONS_LOGGER_CLASS + '). Using NoOp.');
        }

        return new NoOp();
    }

    public static ILogger create(Id executionId, String turnIdentifier) {
        return create(executionId, turnIdentifier, null);
    }
}
