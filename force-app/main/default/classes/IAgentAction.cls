/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * IAgentAction defines the contract for all executable AI agent actions within the framework.
 *
 * Responsibilities:
 *   - Serves as the core interface for Standard Actions, Custom Apex implementations, and Flow-based actions
 *   - Enforces a consistent method signature for action execution, configuration parsing, and error handling
 *   - Ensures that all implementations can be invoked generically by the agent orchestration engine
 *
 * Implementations must handle:
 *   - Parsing and validating configuration and input parameters
 *   - Executing the core business logic for the action
 *   - Returning a structured ActionOutcome with success/failure state and data
 *   - Consistent error handling (prefer returning failed ActionOutcome; throw only for unrecoverable errors)
 */
public interface IAgentAction {
    /**
     * Executes the core logic of the agent action.
     *
     * @param actionConfigurationJson  JSON string from AgentCapabilityBinding__c.ActionConfiguration__c for this agent/action binding. May be null or blank if not configured.
     * @param argumentsJson            Raw JSON string of arguments provided by the LLM, conforming to ActionDefinition__c.InputParameterSchema__c. Implementation must parse and validate.
     * @param context                  Shared ActionContext providing session, user, agent, and action identifiers.
     * @return ActionOutcome           Structured outcome containing success/failure status, data payload, and error information.
     * @throws ActionExecutionException For unrecoverable errors during execution (should be rare; prefer returning a failed ActionOutcome).
     *
     * Implementations should:
     *   - Parse and validate all inputs
     *   - Handle all expected error conditions gracefully
     *   - Return a failed ActionOutcome for recoverable errors, and throw only for truly unrecoverable conditions
     */
    ActionOutcome execute(String actionConfigurationJson, String argumentsJson, ActionContext context);
}
