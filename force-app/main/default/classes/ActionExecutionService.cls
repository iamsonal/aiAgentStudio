/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionExecutionService is responsible for orchestrating the execution of agent capabilities
 * within the AI Agent framework. It acts as a central router, dynamically dispatching actions
 * to the appropriate execution engine based on the capability's implementation type (Standard, Apex, Flow).
 * The class ensures robust error handling, consistent logging, and uniform result processing,
 * providing a single entry point for executing agent actions regardless of their underlying technology.
 *
 * Responsibilities:
 *   - Route agent capability execution requests to the correct handler (ActionRegistry, etc.)
 *   - Enforce input validation and context integrity
 *   - Provide detailed, actionable debug output for observability and troubleshooting
 *   - Normalize error handling and result construction across all execution paths
 *
 * This class is designed for extensibility and maintainability, serving as the backbone for agent-driven automation.
 */
public inherited sharing class ActionExecutionService {
    /**
     * @description
     * Executes a single agent capability by routing the request to the appropriate execution engine
     * based on the capability's implementation type. Handles all supported types (Standard, Apex, Flow)
     * and ensures consistent error handling and logging.
     *
     * @param capability         The AgentCapability__c record describing the action to execute. Must not be null.
     * @param llmArgumentsJson   JSON string of arguments provided by the LLM for this action call. May be null or empty if not required by the handler.
     * @param context            The ActionContext containing all relevant execution context. Must not be null.
     * @return                   ActionOutcome representing the outcome of the execution, including error details if applicable.
     * @throws IllegalArgumentException if capability or context is null.
     * @throws ActionRegistry.ActionRegistryException for configuration errors in the ActionRegistry.
     *
     * Side effects:
     *   - Writes detailed debug output to logs for observability.
     *   - May throw exceptions for unrecoverable configuration errors.
     */
    public ActionOutcome executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix =
            '[ActionExecutionService] [CapabilityId: ' +
            String.valueOf(capability?.Id) +
            ' | ExecutionId: ' +
            String.valueOf(context?.executionId) +
            '] ';

        // Validate required parameters
        if (capability == null || context == null) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Missing required input: capability or context is null.');
            throw new IllegalArgumentException('AgentCapability and ActionContext are required.');
        }

        try {
            // Route to the correct execution engine based on implementation type
            switch on capability.ImplementationType__c {
                when 'Standard', 'Apex', 'Flow' {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Dispatching to ActionRegistry for ' +
                            capability.ImplementationType__c +
                            ' capability: ' +
                            capability.CapabilityName__c
                    );
                    IAgentAction actionHandler = ActionRegistry.createActionHandler(capability);

                    // Execute the action handler and capture the outcome
                    ActionOutcome outcome = actionHandler.execute(capability.BackendConfiguration__c, llmArgumentsJson, context);

                    if (outcome == null) {
                        // Defensive: handler should never return null; treat as implementation bug
                        System.debug(
                            LoggingLevel.ERROR,
                            logPrefix + 'Action handler returned null outcome. This indicates a handler implementation bug.'
                        );
                        outcome = ActionOutcome.failure(
                            AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT,
                            'Action handler failed to return an outcome. Handler returned null. Check handler implementation for capability: ' + capability.CapabilityName__c
                        );
                    } else {
                        System.debug(LoggingLevel.DEBUG, logPrefix + 'Action handler returned outcome: ' + String.valueOf(outcome));
                    }
                    return outcome;
                }
                when else {
                    // Unsupported implementation type: log and return configuration error
                    String errorMsg =
                        'Unsupported ImplementationType__c: "' +
                        String.valueOf(capability.ImplementationType__c) +
                        '" for capability: ' +
                        capability.CapabilityName__c +
                        '. Valid types: Standard, Apex, Flow.';
                    System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, errorMsg);
                }
            }
        } catch (ActionRegistry.ActionRegistryException are) {
            // Configuration error in ActionRegistry: log and propagate
            System.debug(LoggingLevel.ERROR, logPrefix + 'ActionRegistry configuration error: ' + are.getMessage());
            throw are;
        } catch (Exception ex) {
            // Catch-all for unexpected errors: log with stack trace and return error outcome
            String errMsg = 'Unexpected error during action execution for capability: ' + capability.CapabilityName__c;
            System.debug(LoggingLevel.ERROR, logPrefix + errMsg + '. Exception: ' + ex.getMessage() + '\nStack Trace: ' + ex.getStackTraceString());
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                errMsg + ': ' + ex.getMessage()
            );
        }
    }
}
