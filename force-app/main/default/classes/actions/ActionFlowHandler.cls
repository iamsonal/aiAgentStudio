/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionFlowHandler is a robust Apex action for securely executing Salesforce Flows with comprehensive parameter validation, error handling, and admin-driven configuration.
 *
 * Responsibilities:
 *   - Validates and extracts the Flow API name from admin configuration (Implementation Detail field).
 *   - Validates and processes Flow input parameters for compatibility and naming conventions.
 *   - Executes the specified Flow, handling both success and fault scenarios with detailed diagnostics.
 *   - Returns a structured, LLM-friendly result object for downstream consumption or user display.
 *
 * Scope:
 *   - Strictly executes Flows as configured by admins; does not allow arbitrary Flow execution.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * Flow Conventions: Use 'faultMessage' for errors and 'outputResult' for success data.
 * Security: Flow name must be configured in Implementation Detail field by admin.
 *
 * @extends BaseAgentAction
 */
public class ActionFlowHandler extends BaseAgentAction {
    private static final String FAULT_MESSAGE_VAR = 'faultMessage';
    private static final String OUTPUT_RESULT_VAR = 'outputResult';

    /**
     * @description
     * Main entry point for Flow execution. Validates Flow name and parameters, executes the Flow, and processes results.
     *
     * @param params Map<String, Object> - Flow input variables.
     * @return Result<FlowResult> - Contains Flow output and execution details or error information.
     *
     * Side effects: Logs key steps, parameters, and performance metrics for troubleshooting and monitoring.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        ActionOutcome flowNameResult = validateFlowApiName();
        if (!flowNameResult.isSuccess) {
            return flowNameResult;
        }
        String flowApiName = (String) flowNameResult.data;

        Map<String, Object> flowParams = validateFlowParameters(params);

        System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Starting execution of Flow: "' + flowApiName + '"');
        System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Flow input parameters: ' + JSON.serialize(flowParams).abbreviate(500));

        ActionOutcome flowExecutionResult = executeFlow(flowApiName, flowParams);
        if (!flowExecutionResult.isSuccess) {
            return flowExecutionResult;
        }
        Flow.Interview flowInterview = (Flow.Interview) flowExecutionResult.data;

        ActionOutcome flowResultsResult = processFlowResults(flowInterview, flowApiName);
        if (!flowResultsResult.isSuccess) {
            return flowResultsResult;
        }
        Object flowResult = flowResultsResult.data;

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Flow execution for "' + flowApiName + '" completed in ' + executionTime + ' ms.');

        return ActionOutcome.success(new FlowResult(flowApiName, flowResult, 'Flow "' + flowApiName + '" completed successfully.'));
    }

    /**
     * @description
     * Validates and extracts the Flow API name from admin configuration (Implementation Detail field).
     *
     * @return ActionOutcome<String> - Valid Flow API name from admin configuration or error information.
     */
    private ActionOutcome validateFlowApiName() {
        String flowApiName = this.actionContext?.implementationDetail;

        if (String.isBlank(flowApiName)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Agent Capability is missing Implementation Detail. Admin must configure the Flow API Name.'
            );
        }

        if (flowApiName.contains(' ') || flowApiName.contains('.')) {
            System.debug(LoggingLevel.WARN, '[ActionFlowHandler] Flow API Name contains spaces or dots, which may cause issues: ' + flowApiName);
        }

        return ActionOutcome.success(flowApiName);
    }

    /**
     * @description
     * Validates and processes Flow input parameters for compatibility and naming conventions.
     *
     * @param params Map<String, Object> - Raw parameter map from action execution.
     * @return Map<String, Object> - Validated and Flow-compatible parameter map.
     */
    private Map<String, Object> validateFlowParameters(Map<String, Object> params) {
        if (params == null || params.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] No parameters provided - using empty map');
            return new Map<String, Object>();
        }

        Map<String, Object> validatedParams = new Map<String, Object>();

        for (String key : params.keySet()) {
            Object value = params.get(key);

            if (!isValidFlowVariableName(key)) {
                System.debug(LoggingLevel.WARN, '[ActionFlowHandler] Parameter name does not conform to Flow variable naming conventions: ' + key);
            }

            if (value != null) {
                try {
                    String testSerialization = JSON.serialize(value);
                    validatedParams.put(key, value);
                } catch (Exception e) {
                    System.debug(
                        LoggingLevel.WARN,
                        '[ActionFlowHandler] Parameter "' + key + '" could not be serialized for Flow: ' + e.getMessage()
                    );
                    validatedParams.put(key, String.valueOf(value));
                }
            } else {
                validatedParams.put(key, value);
            }
        }

        return validatedParams;
    }

    /**
     * @description
     * Validates Flow variable name format according to Salesforce naming conventions.
     *
     * @param name String - Variable name to validate.
     * @return Boolean - True if name follows Flow variable naming rules.
     */
    private Boolean isValidFlowVariableName(String name) {
        if (String.isBlank(name))
            return false;

        if (!name.substring(0, 1).isAlpha())
            return false;

        for (Integer i = 0; i < name.length(); i++) {
            String currentChar = name.substring(i, i + 1);
            if (!currentChar.isAlphanumeric() && currentChar != '_') {
                return false;
            }
        }
        return true;
    }

    /**
     * @description
     * Validates Flow parameters before execution by querying Flow metadata.
     *
     * @param flowApiName String - Name of the Flow to validate.
     * @param flowParams Map<String, Object> - Input parameters to validate.
     * @return ActionOutcome - Success if validation passes, failure with details otherwise.
     */
    private ActionOutcome validateFlowParameters(String flowApiName, Map<String, Object> flowParams) {
        try {
            // Query Flow metadata to get input variable definitions
            List<FlowDefinitionView> flowDefs = [
                SELECT ApiName, ActiveVersionId
                FROM FlowDefinitionView
                WHERE ApiName = :flowApiName
                WITH USER_MODE
                LIMIT 1
            ];

            if (flowDefs.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Flow "' + flowApiName + '" not found. Please verify the Flow API name is correct.'
                );
            }

            FlowDefinitionView flowDef = flowDefs[0];
            if (flowDef.ActiveVersionId == null) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Flow "' + flowApiName + '" has no active version. Please activate the Flow in Flow Builder.'
                );
            }

            // Query Flow variables for the active version
            List<FlowVariableView> flowVariables = [
                SELECT ApiName, DataType, IsInput
                FROM FlowVariableView
                WHERE FlowVersionViewId = :flowDef.ActiveVersionId
                AND IsInput = true
                WITH USER_MODE
            ];

            // Build a map of expected input variables
            Map<String, FlowVariableView> expectedInputs = new Map<String, FlowVariableView>();

            for (FlowVariableView var : flowVariables) {
                expectedInputs.put(var.ApiName, var);
            }

            // Warn about unexpected parameters
            List<String> unexpectedParams = new List<String>();
            for (String paramName : flowParams.keySet()) {
                if (!expectedInputs.containsKey(paramName)) {
                    unexpectedParams.add(paramName);
                }
            }

            if (!unexpectedParams.isEmpty()) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionFlowHandler] Flow "' + flowApiName + '" received unexpected parameters: ' +
                    String.join(unexpectedParams, ', ') + '. These will be ignored. ' +
                    'Expected inputs: ' + String.join(new List<String>(expectedInputs.keySet()), ', ')
                );
            }

            System.debug(
                LoggingLevel.DEBUG,
                '[ActionFlowHandler] Flow parameter validation passed. Expected inputs: ' +
                expectedInputs.size() + ', Provided: ' + flowParams.size()
            );

            return ActionOutcome.success();
        } catch (System.QueryException qe) {
            // If we can't query Flow metadata, log warning but allow execution to proceed
            System.debug(
                LoggingLevel.WARN,
                '[ActionFlowHandler] Unable to validate Flow parameters (metadata query failed): ' + qe.getMessage() +
                '. Proceeding with Flow execution.'
            );
            return ActionOutcome.success();
        }
    }

    /**
     * @description
     * Executes the Flow with comprehensive error handling and validation.
     *
     * @param flowApiName String - Name of the Flow to execute.
     * @param flowParams Map<String, Object> - Input parameters for the Flow.
     * @return ActionOutcome<Flow.Interview> - The Flow.Interview instance after execution or error information.
     */
    private ActionOutcome executeFlow(String flowApiName, Map<String, Object> flowParams) {
        // Validate Flow parameters against Flow metadata
        ActionOutcome validationResult = validateFlowParameters(flowApiName, flowParams);
        if (!validationResult.isSuccess) {
            return validationResult;
        }

        try {
            Flow.Interview flowInterview = Flow.Interview.createInterview(flowApiName, flowParams);

            if (flowInterview == null) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Failed to create Flow interview for: ' + flowApiName + '. ' +
                    'Please verify the Flow API name and that the Flow is active.'
                );
            }

            flowInterview.start();
            return ActionOutcome.success(flowInterview);
        } catch (Exception ex) {
            String enhancedMessage = 'Flow execution failed for "' + flowApiName + '": ' + ex.getMessage();

            // Provide more specific error context based on exception message
            if (ex.getMessage().containsIgnoreCase('variable')) {
                enhancedMessage += ' | This may indicate a parameter mismatch. ' +
                                  'Provided parameters: ' + String.join(new List<String>(flowParams.keySet()), ', ');
            } else if (ex.getMessage().containsIgnoreCase('not found') || ex.getMessage().containsIgnoreCase('does not exist')) {
                enhancedMessage += ' | Please verify the Flow API name is correct and the Flow is active.';
            }

            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] Flow execution error: ' + enhancedMessage);
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Exception stack trace: ' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, enhancedMessage);
        }
    }

    /**
     * @description
     * Processes Flow results and handles both success and fault scenarios.
     *
     * @param flowInterview Flow.Interview - Executed Flow interview instance.
     * @param flowApiName String - Flow name for error context.
     * @return ActionOutcome<Object> - Flow output result or error information.
     */
    private ActionOutcome processFlowResults(Flow.Interview flowInterview, String flowApiName) {
        Object faultMessageValue = flowInterview.getVariableValue(FAULT_MESSAGE_VAR);
        if (faultMessageValue instanceof String && String.isNotBlank((String) faultMessageValue)) {
            String faultMessage = (String) faultMessageValue;
            String enhancedError = 'Flow "' + flowApiName + '" reported failure via "' + FAULT_MESSAGE_VAR + '": ' + faultMessage;
            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] Flow reported failure: ' + enhancedError);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, enhancedError);
        }

        Object flowDataPayload = flowInterview.getVariableValue(OUTPUT_RESULT_VAR);

        if (flowDataPayload == null) {
            System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Flow completed with no output result. Returning default payload.');
            flowDataPayload = new Map<String, Object>{ 'flowCompleted' => true };
        }

        System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Flow "' + flowApiName + '" completed successfully. Returning output result.');
        return ActionOutcome.success(flowDataPayload);
    }

    /**
     * @description
     * Parses action configuration JSON if provided. This action does not require custom configuration,
     * but logs a debug message if configuration is present for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string (optional).
     * @param logPrefix String - Prefix for log output.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Action configuration JSON was provided but is not required for this action.');
        }
    }

    /**
     * @description
     * Result wrapper for successful Flow execution operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - flowName: String - The Flow API name executed.
     *   - result: Object - The output/result from the Flow.
     *   - message: String - User-facing message summarizing the result.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class FlowResult {
        public String flowName;
        public Object result;
        public String message; // Framework uses this for user display
        public Map<String, Object> metadata; // Additional context for LLMs

        public FlowResult(String flowName, Object result, String message) {
            this.flowName = flowName;
            this.result = result;
            this.message = message;
            this.metadata = new Map<String, Object>{
                'flowApiName' => flowName,
                'hasResult' => result != null,
                'resultType' => result != null ? String.valueOf(result).left(50) : 'null'
            };
        }
    }
}
