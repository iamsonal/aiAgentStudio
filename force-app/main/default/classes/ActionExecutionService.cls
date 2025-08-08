/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for executing a single Agent Action.
 *              It acts as a router, delegating execution to the correct handler
 *              based on the capability's implementation type (Graph, Standard, Apex, etc.).
 */
public inherited sharing class ActionExecutionService {
    public class ActionExecutionException extends AIAgentException {
    }

    /**
     * @description Routes and executes a single specified capability.
     * @param capability The full AgentCapability__c record defining the action or graph.
     * @param llmArgumentsJson Arguments JSON string provided by the LLM for this action call.
     * @param context The ActionContext for this execution.
     * @return ActionResult Result of the action or graph execution.
     */
    public ActionResult executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix = '[ActExecSvc Cap:' + capability?.Id + ' Turn:' + context?.chatSessionId + '] ';

        if (capability == null || context == null) {
            throw new IllegalArgumentException('AgentCapability and ActionContext are required.');
        }

        try {
            switch on capability.ImplementationType__c {
                when 'Graph' {
                    GraphExecutionService graphService = new GraphExecutionService();
                    return graphService.startGraphRun(capability, llmArgumentsJson, context);
                }
                when 'Standard', 'Apex', 'Flow' {
                    IAgentAction actionHandler = ActionRegistry.createActionHandler(capability);

                    ActionResult result = actionHandler.execute(capability.BackendConfiguration__c, llmArgumentsJson, context);
                    if (result == null) {
                        result = new ActionResult(
                            'Action handler failed to return a result.',
                            'Handler returned null.',
                            AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT
                        );
                    }
                    return result;
                }
                when else {
                    String errorMsg = 'Unsupported Implementation Type on AgentCapability: "' + capability.ImplementationType__c + '"';

                    return new ActionResult('Configuration Error', errorMsg, AIAgentConstants.ERR_CODE_CONFIG_ERROR);
                }
            }
        } catch (ActionRegistry.ActionRegistryException are) {
            throw are;
        } catch (Exception ex) {
            String errMsg = 'Unexpected Exception during action routing/execution: ' + ex.getMessage();

            return new ActionResult('Action execution failed due to an unexpected error.', errMsg, AIAgentConstants.ERR_CODE_ACTION_EXECUTION);
        }
    }
}
