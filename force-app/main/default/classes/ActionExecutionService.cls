/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for executing a single Agent Action,
 *              including looking up the handler and invoking it.
 */
public inherited sharing class ActionExecutionService {
    /** @description General exception for this service */
    public class ActionExecutionException extends AIAgentException {
    }

    /**
     * @description Executes a single specified action synchronously.
     * @param capability The full AgentCapability__c record.
     * @param llmArgumentsJson Arguments JSON string provided by the LLM for this action call.
     * @param context The ActionContext for this execution.
     * @return ActionResult Result of the action's execution.
     */
    public ActionResult executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix = '[ActExecSvc Cap:' + capability?.Id + ' Turn:' + context?.chatSessionId + '] ';
        ActionResult result = null;
        Long startTime = System.currentTimeMillis();

        if (capability == null || context == null) {
            throw new IllegalArgumentException('AgentCapability and ActionContext are required.');
        }

        try {
            IAgentAction actionHandler = ActionRegistry.createActionHandler(capability);

            result = actionHandler.execute(capability.BackendConfiguration__c, llmArgumentsJson, context);

            Long duration = System.currentTimeMillis() - startTime;
            if (result == null) {
                result = new ActionResult(
                    'Action handler failed to return a result.',
                    'Handler returned null.',
                    AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT
                );
            } else {
            }
            return result;
        } catch (ActionRegistry.ActionRegistryException are) {
            throw are;
        } catch (Exception ex) {
            Long duration = System.currentTimeMillis() - startTime;
            String errMsg = 'Unexpected Exception during action execution: ' + ex.getMessage();

            return new ActionResult('Action execution failed due to an unexpected error.', errMsg, AIAgentConstants.ERR_CODE_ACTION_EXECUTION);
        }
    }
}
