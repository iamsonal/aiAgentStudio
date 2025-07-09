/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Securely executes a pre-defined Invocable Apex method.
 *              This action serves as a generic bridge, allowing an AI agent to leverage existing
 *              Salesforce business logic encapsulated in invocable methods.
 *
 * @extends BaseAgentAction
 *
 * @security The specific Invocable Method to be executed (e.g., 'MyInvocableHandler.myMethod')
 *           MUST be defined by an administrator in the 'Implementation Detail' (ImplementationName__c)
 *           field of the linked ActionDefinition__c record. The AI/LLM can only provide the input
 *           parameters, not the name of the method to run, preventing arbitrary code execution.
 *
 * @convention **Input:** The LLM-provided arguments JSON is a map of key-value pairs that directly
 *           correspond to the input variables of the target Invocable Method.
 *
 * @convention **Output (Success):** The Invocable Method should return a serializable value (e.g., a primitive,
 *           a Map<String, Object>, or a custom wrapper class instance). This action will return the first
 *           element from the result list.
 *
 * @convention **Output (Failure):** For handled errors, the Invocable Method can return a Map<String, Object>
 *           containing `isSuccess: false` and an `errorMessage` key. This action will interpret that
 *           as a controlled failure and surface the error message. Unhandled exceptions will be
 *           caught and mapped automatically by the framework.
 */
public class ActionRunApex extends BaseAgentAction {
    protected override String getLogPrefixName() {
        return 'ActionRunApex';
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Inner class to hold the parsed map of arguments for the Invocable Method.
     */
    private class RunApexParsedArguments extends BaseAgentAction.ParsedArguments {
        Map<String, Object> invocableParams;

        public RunApexParsedArguments(String jsonArguments) {
            if (String.isBlank(jsonArguments)) {
                this.invocableParams = new Map<String, Object>();
            } else {
                try {
                    Object parsed = JSON.deserializeUntyped(jsonArguments);
                    if (parsed instanceof Map<String, Object>) {
                        this.invocableParams = (Map<String, Object>) parsed;
                    } else {
                        throw new ValidationException('Input arguments for ActionRunApex must be a valid JSON Object (Map).', null);
                    }
                } catch (Exception e) {
                    throw new ValidationException('Failed to parse arguments JSON for ActionRunApex: ' + e.getMessage(), null, e);
                }
            }
        }
    }

    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        return new RunApexParsedArguments(argumentsJson);
    }

    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        RunApexParsedArguments args = (RunApexParsedArguments) validatedArgs;

        String qualifiedMethodName = this.actionContext.implementationDetail;

        if (String.isBlank(qualifiedMethodName) || !qualifiedMethodName.contains('.')) {
            throw new ValidationException(
                'Agent Capability is missing a valid, fully qualified Invocable Method name in Implementation Detail (e.g., MyClass.myMethod).',
                'ImplementationDetail__c'
            );
        }

        Invocable.Action action = Invocable.Action.createCustomAction('apex', qualifiedMethodName);
        action.setInvocationParameter('inputs', new List<Map<String, Object>>{ args.invocableParams });

        List<Object> results;
        try {
            results = (List<Object>) action.invoke();
        } catch (Exception ex) {
            throw ex;
        }

        if (results == null || results.isEmpty()) {
            return this.runtimeError(
                'Invocable method ' + qualifiedMethodName + ' returned no result.',
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                null
            );
        }

        Object resultPayload = results[0];
        if (resultPayload instanceof Map<String, Object>) {
            Map<String, Object> resultMap = (Map<String, Object>) resultPayload;
            if (resultMap.get('isSuccess') == false) {
                String errorMessage = (String) resultMap.get('errorMessage');
                String internalDetails = 'Invocable method ' + qualifiedMethodName + ' reported a controlled failure: ' + errorMessage;

                return this.runtimeError(internalDetails, 'INVOCABLE_METHOD_FAILURE', null);
            }
        }

        String successMsg = 'The Apex action ' + qualifiedMethodName + ' completed successfully.';
        String internalDetails = 'Successfully invoked method ' + qualifiedMethodName + ' and received a result.';

        return this.success(resultPayload, successMsg, internalDetails);
    }
}
