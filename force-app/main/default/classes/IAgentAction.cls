/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Interface for all executable Agent Actions (Standard, Custom Apex, Flow Wrappers).
 *              Implementations handle specific logic based on configuration and LLM parameters.
 */
public interface IAgentAction {
    /**
     * @description Executes the core logic of the action.
     * @param actionConfigurationJson JSON String from AgentCapabilityBinding__c.ActionConfiguration__c associated with *this specific agent and action*. Can be null or blank if not configured on the binding.
     * @param argumentsJson The raw JSON string of arguments provided by the LLM (conforming to ActionDefinition__c.InputParameterSchema__c). The implementation is responsible for parsing this string.
     * @param context Shared ActionContext providing Session, User, Agent, and specific Action IDs.
     * @return ActionResult A structured object containing the execution outcome, output payload, and diagnostic details.
     * @throws ActionExecutionException for unrecoverable errors during execution (should be used sparingly; prefer returning a failed ActionResult).
     */
    ActionResult execute(String actionConfigurationJson, String argumentsJson, ActionContext context);
}
