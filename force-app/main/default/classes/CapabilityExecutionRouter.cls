/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Routes execution of individual agent capabilities to appropriate handlers.
 * Dynamically dispatches capability executions based on implementation type (Standard, Apex, Flow).
 */
public inherited sharing class CapabilityExecutionRouter {
    /**
     * Executes a single agent capability by routing to appropriate execution engine.
     *
     * @param capability         Agent capability record
     * @param llmArgumentsJson   LLM arguments JSON
     * @param context            Action context
     * @return                   Action outcome
     */
    public ActionOutcome executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix =
            '[CapabilityExecutionRouter] [CapabilityId: ' +
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
                            'Action handler failed to return an outcome. Handler returned null. Check handler implementation for capability: ' +
                            capability.CapabilityName__c
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
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, errMsg + ': ' + ex.getMessage());
        }
    }
}
