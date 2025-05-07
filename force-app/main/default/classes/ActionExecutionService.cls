/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
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
     * @param actionDefinitionId ID of the ActionDefinition__c.
     * @param bindingConfigJson Configuration JSON from the AgentCapabilityBinding__c (can be null).
     * @param llmArgumentsJson Arguments JSON string provided by the LLM for this action call.
     * @param context The ActionContext for this execution.
     * @return ActionResult Result of the action's execution.
     * @throws ActionRegistry.ActionRegistryException If handler lookup fails.
     * @throws ActionExecutionException for other critical errors during execution.
     * @throws Various exceptions from the underlying IAgentAction implementation.
     */
    public ActionResult executeSingleAction(Id actionDefinitionId, String bindingConfigJson, String llmArgumentsJson, ActionContext context) {
        String logPrefix = '[ActExecSvc Turn:' + context?.chatSessionId + ' ActionDef:' + actionDefinitionId + '] ';
        ActionResult result = null;
        Long startTime = System.currentTimeMillis();

        if (actionDefinitionId == null || context == null) {
            throw new IllegalArgumentException('ActionDefinitionId and ActionContext are required.');
        }

        IAgentAction actionHandler = null;
        try {
            actionHandler = ActionRegistry.createActionHandler(actionDefinitionId);

            result = actionHandler.execute(bindingConfigJson, llmArgumentsJson, context);

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
