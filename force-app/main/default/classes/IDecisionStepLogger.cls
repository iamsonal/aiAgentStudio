/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Interface abstraction for decision step logging with factory, types, and no-op implementation.
 * This allows AgentDecisionStepLogger to be moved to the addons package as optional functionality.
 *
 * When the addons package is deployed, the factory returns the real AgentDecisionStepLogger.
 * When only the core package is deployed, the factory returns a NoOp implementation that
 * safely does nothing, allowing the framework to function without the storyboard feature.
 *
 * Usage:
 *   IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(executionId, turnIdentifier, userId);
 *   logger.logUserInput('Title', 'User message', durationMs);
 *   logger.commitSteps();
 */
public inherited sharing class IDecisionStepLogger {
    // ==================== STEP TYPE ENUM ====================

    /**
     * Types of decision steps that can be logged during agent execution.
     */
    public enum StepType {
        USER_INPUT,
        CONTEXT_GATHERING,
        SYSTEM_PROMPT_CONSTRUCTION,
        LLM_REQUEST,
        LLM_RESPONSE,
        TOOL_SELECTION,
        TOOL_EXECUTION,
        APPROVAL_REQUIRED,
        TOOL_RESULT,
        ERROR,
        AVAILABLE_TOOLS,
        FINAL_RESPONSE,
        RESUME_APPROVED_FRAMEWORK_ACTION,
        HANDLE_REJECTED_FRAMEWORK_ACTION,
        FUNCTION_RESUMED,
        WORKFLOW_RESUMED
    }

    // ==================== LOGGER INTERFACE ====================

    /**
     * Interface for decision step logging implementations.
     * Provides the full API for logging agent decision steps.
     * Methods match the existing AgentDecisionStepLogger public API for backward compatibility.
     */
    public interface ILogger {
        /**
         * Initialize the logger with execution context.
         * Called by the factory after instantiation.
         */
        void initialize(Id executionId, String turnIdentifier, Id originalUserId);

        // ========== AUDIT CONTEXT METHODS ==========

        void setPIIMaskingApplied(Boolean applied);
        void setPromptSafetyContext(Decimal score, String level);
        void setRetryAttempt(Integer attempt);
        void setRateLimitDelay(Long delayMs);
        void setPayloadSizes(Integer requestSize, Integer responseSize);
        void setCachedResponse(Boolean cached);
        void resetAuditContext();

        // ========== USER INPUT LOGGING ==========

        void logUserInputWithContext(String title, String userMessage, Long durationMs, String userName, String agentName);
        void logUserInput(String title, String userMessage, Long durationMs);

        // ========== CONTEXT & PROMPT LOGGING ==========

        void logContextGathering(String title, String contextDescription, String contextJson, Long durationMs);
        void logContextGatheringWithFormatting(String title, String contextDescription, String rawContextJson, String formattedContext, Long durationMs);
        void logSystemPromptConstruction(String title, String promptDescription, String promptContent, Long durationMs);

        // ========== LLM INTERACTION LOGGING ==========

        void logLLMRequest(String title, String requestDescription, String requestJson, Long durationMs);
        void logLLMResponse(String title, String responseDescription, String responseJson, Long durationMs);
        void logLLMResponseWithMetrics(
            String title,
            String responseDescription,
            String responseJson,
            Long durationMs,
            Integer promptTokens,
            Integer completionTokens,
            Integer totalTokens,
            String modelIdentifier,
            String provider,
            Decimal temperature
        );
        void logAvailableTools(String title, String toolsDescription, String toolsJson, Long durationMs);

        // ========== TOOL EXECUTION LOGGING ==========

        void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage
        );
        void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId
        );
        void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String rationale
        );
        void logToolExecutionWithIndex(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String rationale,
            Integer toolCallIndex
        );

        // ========== TOOL RESULT LOGGING ==========

        void logToolResult(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage
        );
        void logToolResult(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId
        );
        void logToolResultWithContext(
            String title,
            String toolName,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String approverName
        );
        void logToolResultWithIndex(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            Integer toolCallIndex
        );

        // ========== APPROVAL LOGGING ==========

        void logApprovalRequired(String title, String description, String approvalDetailsJson, Id capabilityId, Long durationMs);
        void logApprovalRequiredWithContext(String title, String toolName, String approvalDetailsJson, Id capabilityId, Long durationMs);

        // ========== COMPLETION LOGGING ==========

        void logFinalResponse(String title, String responseDescription, String responseContent, Long durationMs);
        void logError(String title, String errorDescription, String errorCode, String errorMessage, String errorDetails, Long durationMs);

        // ========== RESUME LOGGING ==========

        void logResumeApprovedFrameworkAction(String title, String description, String actionDetails, Long durationMs);
        void logHandleRejectedFrameworkAction(String title, String description, String actionDetails, Long durationMs);
        void logFunctionResumed(String title, String description, String metadataJson, String detailedMessage, Long durationMs);
        void logWorkflowResumed(String title, String description, String metadataJson, String detailedMessage, Long durationMs);

        // ========== ADVANCED LOGGING ==========

        void logStepWithParent(
            StepType stepType,
            String title,
            String description,
            String contentJson,
            Long durationMs,
            Boolean isSuccess,
            Id parentStepId,
            String triggeringToolCallId
        );

        // ========== LIFECYCLE METHODS ==========

        void updateExecutionId(Id newExecutionId);
        void commitSteps();
        Id getLastLoggedStepId();
        void registerToolCall(String toolCallId, Id stepId);
    }

    // ==================== NO-OP IMPLEMENTATION ====================

    /**
     * No-operation implementation of ILogger.
     * Used when decision step logging is disabled or addons package is not deployed.
     * All methods safely do nothing.
     */
    public class NoOp implements ILogger {
        public void initialize(Id executionId, String turnIdentifier, Id originalUserId) {
        }

        // Audit context
        public void setPIIMaskingApplied(Boolean applied) {
        }
        public void setPromptSafetyContext(Decimal score, String level) {
        }
        public void setRetryAttempt(Integer attempt) {
        }
        public void setRateLimitDelay(Long delayMs) {
        }
        public void setPayloadSizes(Integer requestSize, Integer responseSize) {
        }
        public void setCachedResponse(Boolean cached) {
        }
        public void resetAuditContext() {
        }

        // User input
        public void logUserInputWithContext(String title, String userMessage, Long durationMs, String userName, String agentName) {
        }
        public void logUserInput(String title, String userMessage, Long durationMs) {
        }

        // Context & prompt
        public void logContextGathering(String title, String contextDescription, String contextJson, Long durationMs) {
        }
        public void logContextGatheringWithFormatting(
            String title,
            String contextDescription,
            String rawContextJson,
            String formattedContext,
            Long durationMs
        ) {
        }
        public void logSystemPromptConstruction(String title, String promptDescription, String promptContent, Long durationMs) {
        }

        // LLM interaction
        public void logLLMRequest(String title, String requestDescription, String requestJson, Long durationMs) {
        }
        public void logLLMResponse(String title, String responseDescription, String responseJson, Long durationMs) {
        }
        public void logLLMResponseWithMetrics(
            String title,
            String responseDescription,
            String responseJson,
            Long durationMs,
            Integer promptTokens,
            Integer completionTokens,
            Integer totalTokens,
            String modelIdentifier,
            String provider,
            Decimal temperature
        ) {
        }
        public void logAvailableTools(String title, String toolsDescription, String toolsJson, Long durationMs) {
        }

        // Tool execution
        public void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage
        ) {
        }
        public void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId
        ) {
        }
        public void logToolExecution(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String rationale
        ) {
        }
        public void logToolExecutionWithIndex(
            String title,
            String executionDescription,
            String executionJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String rationale,
            Integer toolCallIndex
        ) {
        }

        // Tool result
        public void logToolResult(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage
        ) {
        }
        public void logToolResult(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId
        ) {
        }
        public void logToolResultWithContext(
            String title,
            String toolName,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            String approverName
        ) {
        }
        public void logToolResultWithIndex(
            String title,
            String resultDescription,
            String resultJson,
            Long durationMs,
            Boolean isSuccess,
            String errorCode,
            String errorMessage,
            Id capabilityId,
            Integer toolCallIndex
        ) {
        }

        // Approval
        public void logApprovalRequired(String title, String description, String approvalDetailsJson, Id capabilityId, Long durationMs) {
        }
        public void logApprovalRequiredWithContext(String title, String toolName, String approvalDetailsJson, Id capabilityId, Long durationMs) {
        }

        // Completion
        public void logFinalResponse(String title, String responseDescription, String responseContent, Long durationMs) {
        }
        public void logError(String title, String errorDescription, String errorCode, String errorMessage, String errorDetails, Long durationMs) {
        }

        // Resume
        public void logResumeApprovedFrameworkAction(String title, String description, String actionDetails, Long durationMs) {
        }
        public void logHandleRejectedFrameworkAction(String title, String description, String actionDetails, Long durationMs) {
        }
        public void logFunctionResumed(String title, String description, String metadataJson, String detailedMessage, Long durationMs) {
        }
        public void logWorkflowResumed(String title, String description, String metadataJson, String detailedMessage, Long durationMs) {
        }

        // Advanced
        public void logStepWithParent(
            StepType stepType,
            String title,
            String description,
            String contentJson,
            Long durationMs,
            Boolean isSuccess,
            Id parentStepId,
            String triggeringToolCallId
        ) {
        }

        // Lifecycle
        public void updateExecutionId(Id newExecutionId) {
        }
        public void commitSteps() {
        }
        public Id getLastLoggedStepId() {
            return null;
        }
        public void registerToolCall(String toolCallId, Id stepId) {
        }
    }

    // ==================== FACTORY METHODS ====================

    private static final String ADDONS_LOGGER_CLASS = 'AgentDecisionStepLogger';

    /**
     * Factory method to create an appropriate ILogger instance.
     * Returns the real AgentDecisionStepLogger if addons is deployed and logging is enabled.
     * Otherwise returns a NoOp implementation.
     *
     * @param executionId The AgentExecution__c ID
     * @param turnIdentifier The turn identifier
     * @param originalUserId The ID of the user who initiated the conversation
     * @return An ILogger instance (real or no-op)
     */
    public static ILogger create(Id executionId, String turnIdentifier, Id originalUserId) {
        // Check feature toggle first
        if (!AIAgentFrameworkSettings.isDecisionStepLoggingEnabled()) {
            System.debug(LoggingLevel.DEBUG, '[IDecisionStepLogger] Decision step logging is disabled via settings');
            return new NoOp();
        }

        // Try to instantiate addons logger dynamically
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

        // Fallback to no-op
        return new NoOp();
    }

    /**
     * Convenience overload without originalUserId.
     */
    public static ILogger create(Id executionId, String turnIdentifier) {
        return create(executionId, turnIdentifier, null);
    }
}
