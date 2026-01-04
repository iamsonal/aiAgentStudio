/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Contract for agent-type-specific orchestrators in the AI agent framework.
 * Covers the full lifecycle of an agent: initiation, async processing, resume, and customization hooks.
 *
 * **Lifecycle Methods:**
 * - configure(): Configure orchestrator with agent definition
 * - start(): Start a new execution
 * - onChildComplete(): Handle async operation completion (workflow child agents)
 * - resume(): Resume a failed/paused execution
 * - runAsync(): Handle async queueable execution
 *
 * **Capability Query Methods:**
 * - canResume(): Check if an execution can be resumed
 * - supportsChildDelegation(): Whether this orchestrator uses onChildComplete()
 *
 * **Customization Hooks (called by shared services):**
 * - buildSystemPromptAdditions(): Agent-specific prompt modifications
 * - evaluateToolOutcome(): Agent-specific post-tool-execution behavior
 *
 * This design keeps shared services (OrchestrationService, LLMInteractionService, ToolCallResponseHandler)
 * agent-agnostic by delegating agent-specific decisions back to the orchestrator.
 */
public interface IAgentOrchestrator {
    // ===================================================================================
    // LIFECYCLE METHODS
    // ===================================================================================

    /**
     * Configures orchestrator with agent definition.
     *
     * @param agentDefinition Agent definition configuration
     */
    void configure(AIAgentDefinition__c agentDefinition);

    /**
     * Starts agent execution with DML and async handoff.
     *
     * @param agentDeveloperName Agent developer name
     * @param payload            Execution payload
     * @return                   Execution result
     */
    AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);

    /**
     * Handles async operation results (e.g., workflow child agent completion).
     * Not all orchestrators use this - check supportsChildDelegation() first.
     *
     * @param executionId  Execution ID
     * @param asyncPayload Async-specific context and results
     */
    void onChildComplete(Id executionId, Map<String, Object> asyncPayload);

    /**
     * Resumes a failed or paused execution from the point of failure.
     * Absorbs logic from FunctionExecutionResumeService and WorkflowResumeUtility.
     *
     * @param executionId The execution ID to resume
     * @param options     Resume options (retry strategy, etc.)
     * @return            Execution result indicating resume status
     */
    AgentExecutionService.ExecutionResult resume(Id executionId, BaseAgentOrchestrator.ResumeOptions options);

    /**
     * Executes agent-specific logic when invoked from a queueable job.
     * Called by UnifiedAgentQueueable to delegate all async execution to orchestrators.
     *
     * Each orchestrator implements its own queueable execution pattern:
     * - Conversational: LLM call processing
     * - Function: Deferred function execution
     * - Workflow: Child agent execution within workflow
     *
     * @param payload Job-specific execution parameters
     * @param logPrefix Logging prefix for debug output
     */
    void runAsync(Map<String, Object> payload, String logPrefix);

    // ===================================================================================
    // CAPABILITY QUERY METHODS
    // ===================================================================================

    /**
     * Checks if an execution can be resumed.
     * Validates execution state, agent type compatibility, and resumability conditions.
     *
     * @param executionId The execution ID to check
     * @return            True if execution can be resumed, false otherwise
     */
    Boolean canResume(Id executionId);

    /**
     * Indicates whether this orchestrator uses onChildComplete().
     * - Conversational: true (for async tool completion)
     * - Function: false (uses queueable chain instead)
     * - Workflow: true (for child agent completion)
     *
     * @return True if onChildComplete() is applicable
     */
    Boolean supportsChildDelegation();

    // ===================================================================================
    // CUSTOMIZATION HOOKS (called by shared services)
    // ===================================================================================

    /**
     * Returns agent-specific additions to the system prompt.
     * Called by LLMInteractionService to inject agent-type-specific instructions.
     *
     * Examples:
     * - Conversational: Summarization instructions for multi-step turns
     * - Function: No additions (autonomous multi-step reasoning)
     * - Workflow: Step context and chaining instructions
     *
     * @param context The orchestration context for the current turn
     * @return        String to append to system prompt, or empty string
     */
    String buildSystemPromptAdditions(OrchestrationContext context);

    /**
     * Handles agent-specific behavior after tool execution completes.
     * Called by ToolCallResponseHandler to delegate post-tool decisions.
     *
     * Examples:
     * - Conversational: Create assistant message for approval, complete turn
     * - Function/Workflow: Pause execution, no user message needed
     *
     * @param context     The orchestration context
     * @param toolResults Results from tool execution(s)
     * @param scenario    The scenario type (e.g., 'APPROVAL_REQUIRED', 'TOOL_COMPLETED')
     * @return            Outcome constant (OUTCOME_COMPLETED, OUTCOME_QUEUED_ACTION, etc.)
     */
    String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario);

    // ===================================================================================
    // ACCESSOR METHODS
    // ===================================================================================

    /**
     * Returns the agent definition this orchestrator was initialized with.
     * Useful for shared services that need agent configuration.
     *
     * @return The AIAgentDefinition__c record
     */
    AIAgentDefinition__c getAgentDefinition();
}
