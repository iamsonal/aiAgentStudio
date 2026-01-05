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
 *
 * **Customization Hooks (called by shared services):**
 * - buildSystemPromptAdditions(): Agent-specific prompt modifications
 * - evaluateToolOutcome(): Agent-specific post-tool-execution behavior
 *
 * This design keeps shared services (OrchestrationService, LLMInteractionService, ToolCallResponseHandler)
 * agent-agnostic by delegating agent-specific decisions back to the orchestrator.
 *
 * **Design Note:**
 * All methods are defined in this single interface with virtual no-op defaults in BaseAgentOrchestrator.
 * This enables pure polymorphism - services can call methods blindly without instanceof checks.
 * Concrete orchestrators override only the methods they need:
 * - ConversationalOrchestrator: buildSystemPromptAdditions(), evaluateToolOutcome()
 * - FunctionOrchestrator: buildSystemPromptAdditions(), evaluateToolOutcome()
 * - WorkflowOrchestrator: onChildComplete()
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

    /**
     * Handles async operation results (e.g., workflow child agent completion, tool completion).
     * Called when a child agent or async operation completes and needs to notify the parent.
     *
     * Default implementation (in BaseAgentOrchestrator) is a no-op.
     * Override in orchestrators that support child delegation (e.g., WorkflowOrchestrator).
     *
     * @param executionId  Execution ID
     * @param asyncPayload Async-specific context and results
     */
    void onChildComplete(Id executionId, Map<String, Object> asyncPayload);

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
     * Default implementation (in BaseAgentOrchestrator) returns empty string.
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
     * - Function: Detect hallucination in content-only responses, enforce tool completion
     * - Workflow: Pause execution, no user message needed
     *
     * Default implementation (in BaseAgentOrchestrator) returns null (use default behavior).
     *
     * @param context     The orchestration context
     * @param toolResults Results from tool execution(s)
     * @param scenario    The scenario type (e.g., 'APPROVAL_REQUIRED', 'TOOL_COMPLETED', 'CONTENT_ONLY_RESPONSE')
     * @return            Outcome constant (OUTCOME_COMPLETED, OUTCOME_QUEUED_ACTION, OUTCOME_FAILED, etc.) or null for default behavior
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
