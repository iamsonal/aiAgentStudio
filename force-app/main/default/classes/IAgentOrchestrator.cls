/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * IAgentOrchestrator defines the contract for agent-type-specific orchestrators in the unified AI agent framework.
 * Each agent type (Conversational, Batch, Email, Autonomous) has its own orchestrator implementation that handles:
 *   - Execution initiation and AgentExecution__c record creation (DML phase)
 *   - Immediate handoff to asynchronous context before callouts
 *   - Processing of asynchronous results and continuation of execution flow
 *
 * This interface enables the Strategy pattern for agent orchestration, allowing each agent type to define
 * its own async strategy (Platform Event vs Queueable) and execution flow while maintaining a consistent API.
 */
public interface IAgentOrchestrator {
    /**
     * Initiates a new agent execution. This method MUST:
     *   1. Create the AgentExecution__c record (DML)
     *   2. Create initial ExecutionStep__c records if needed (DML)
     *   3. Immediately hand off to async context (Platform Event or Queueable)
     *   4. Return before any HTTP callouts
     *
     * @param agentDeveloperName The developer name of the agent to execute
     * @param payload            ExecutionPayload containing all context and input data
     * @return                   ExecutionResult containing the execution ID and status
     * @throws                   AgentOrchestratorException for validation or configuration errors
     */
    AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);

    /**
     * Processes the result of an asynchronous operation. This method is called by async handlers
     * (AsyncFrameworkRequestTriggerHandler or Queueable jobs) to continue execution after async work completes.
     *
     * @param executionId The ID of the AgentExecution__c record
     * @param asyncPayload Map containing async-specific context and results
     * @throws            AgentOrchestratorException for processing errors
     */
    void processAsyncResult(Id executionId, Map<String, Object> asyncPayload);
}
