/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard IAgentAction handler for executing Salesforce Flows.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              Uses the ImplementationName__c from the related ActionDefinition__c record
 *              as the Flow API Name. Follows standard conventions for Flow input/output variables.
 *
 * @convention **Input Mapping:** Keys in the arguments map correspond to Flow Input Variable API Names.
 * @convention **Output Mapping (Success):** Flow MUST set `outputResult` Flow Variable (Serializable Type).
 * @convention **Output Mapping (Failure):** Flow MUST set `faultMessage` Flow Variable (Text Type).
 *
 * @extends BaseAgentAction
 */
public class ActionFlowHandler extends BaseAgentAction {
    private static final String FAULT_MESSAGE_VAR = 'faultMessage';
    private static final String OUTPUT_RESULT_VAR = 'outputResult';

    private static final String ERR_CODE_CONFIG = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_FLOW_FAULT = 'FLOW_FAULT';
    private static final String ERR_CODE_RUNTIME = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionFlowHandler'
     */
    protected override String getLogPrefixName() {
        return 'ActionFlowHandler';
    }

    /**
     * @description Parses ActionConfiguration. FlowHandler generally doesn't need config.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is provided but invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Defines the structure for arguments specific to FlowHandler.
     *              Holds the deserialized map of arguments to pass to the Flow.
     */
    class FlowHandlerParsedArguments extends BaseAgentAction.ParsedArguments {
        Map<String, Object> flowParams = new Map<String, Object>();

        /**
         * @description Constructor that parses the JSON arguments.
         * @param jsonArguments JSON string containing arguments map for the Flow.
         * @throws ValidationException If arguments JSON is invalid.
         */
        public FlowHandlerParsedArguments(String jsonArguments) {
            if (String.isNotBlank(jsonArguments)) {
                try {
                    Object parsed = JSON.deserializeUntyped(jsonArguments);
                    if (parsed instanceof Map<String, Object>) {
                        this.flowParams = (Map<String, Object>) parsed;
                    } else {
                        throw new ValidationException('Input arguments JSON must be a valid JSON Object (Map).', null);
                    }
                } catch (Exception e) {
                    throw new ValidationException(
                        'Failed to parse arguments JSON for Flow: ' + e.getMessage() + '. JSON: ' + jsonArguments?.abbreviate(500),
                        null
                    );
                }
            }
        }
    }

    /**
     * @description Parses the LLM arguments into a map to be passed to the Flow.
     * @param argumentsJson Raw JSON string from the LLM (expected to be a map).
     * @param logPrefix Logging prefix.
     * @return FlowHandlerParsedArguments instance.
     * @throws ValidationException If arguments JSON is invalid.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            return new FlowHandlerParsedArguments(argumentsJson);
        } catch (ValidationException ve) {
            throw ve;
        } catch (Exception e) {
            throw new ValidationException('Failed to parse arguments for FlowHandler: ' + e.getMessage(), null);
        }
    }

    /**
     * @description Core logic: Retrieves Flow API Name from Action Definition, executes the Flow,
     *              and processes results based on standard Flow variable conventions (`faultMessage`, `outputResult`).
     * @param validatedArgs Parsed arguments (must be cast to FlowHandlerParsedArguments).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result containing Flow output or error details.
     * @throws Exception For unexpected errors during Flow execution or Action Definition retrieval (will be mapped by base).
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        FlowHandlerParsedArguments args = (FlowHandlerParsedArguments) validatedArgs;
        Object resultOutputForLlm = null;
        String flowApiName = null;

        ActionDefinition__c actionDef = findActionDefinition(this.actionContext.actionDefinitionId);
        flowApiName = actionDef?.ImplementationName__c;

        if (String.isBlank(flowApiName)) {
            throw new ValidationException(
                'Flow API Name (ImplementationName__c) is missing in the linked Action Definition (' + this.actionContext.actionDefinitionId + ').',
                'ImplementationName__c'
            );
        }

        Flow.Interview flowInterview = Flow.Interview.createInterview(flowApiName, args.flowParams);
        flowInterview.start();

        String faultMessageText = null;
        Object faultMessageValue = flowInterview.getVariableValue(FAULT_MESSAGE_VAR);
        if (faultMessageValue instanceof String && String.isNotBlank((String) faultMessageValue)) {
            faultMessageText = (String) faultMessageValue;
        }

        if (faultMessageText != null) {
            String details = 'Flow "' + flowApiName + '" reported failure via "' + FAULT_MESSAGE_VAR + '": ' + faultMessageText;
            String summaryForLlm = 'Flow execution reported a failure: ' + faultMessageText.abbreviate(100);

            return this.runtimeError(details, ERR_CODE_FLOW_FAULT, null);
        } else {
            resultOutputForLlm = flowInterview.getVariableValue(OUTPUT_RESULT_VAR);
            String internalDetails;

            if (resultOutputForLlm != null) {
                internalDetails = 'Flow "' + flowApiName + '" completed. Retrieved output from variable "' + OUTPUT_RESULT_VAR + '".';
            } else {
                internalDetails = 'Flow "' + flowApiName + '" completed without output in variable "' + OUTPUT_RESULT_VAR + '".';
                resultOutputForLlm = new Map<String, Object>{ 'message' => 'Flow ' + flowApiName + ' completed successfully.' };
            }
            return this.success(resultOutputForLlm, internalDetails);
        }
    }

    private static ActionDefinition__c findActionDefinition(Id actionDefinitionId) {
        if (actionDefinitionId == null)
            return null;
        try {
            List<ActionDefinition__c> definitions = [
                SELECT ImplementationName__c
                FROM ActionDefinition__c
                WHERE Id = :actionDefinitionId AND IsActive__c = TRUE
                LIMIT 1
            ];
            return definitions.isEmpty() ? null : definitions[0];
        } catch (Exception e) {
            return null;
        }
    }
}
