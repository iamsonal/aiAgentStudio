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
 * Handles execution initiation, async handoff, and result processing.
 */
public interface IAgentOrchestrator {
    /**
     * Initializes orchestrator with agent definition.
     *
     * @param agentDefinition Agent definition configuration
     */
    void initialize(AIAgentDefinition__c agentDefinition);

    /**
     * Initiates agent execution with DML and async handoff.
     *
     * @param agentDeveloperName Agent developer name
     * @param payload            Execution payload
     * @return                   Execution result
     */
    AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload);

    /**
     * Processes async operation results.
     *
     * @param executionId  Execution ID
     * @param asyncPayload Async-specific context and results
     */
    void processAsyncResult(Id executionId, Map<String, Object> asyncPayload);
}
