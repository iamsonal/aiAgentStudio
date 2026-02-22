/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Executes Salesforce Flows with strongly-typed DTOs.
 * @ActionLabel Execute Flow
 * @ActionDescription Executes a Salesforce Flow and returns its output
 * @ActionRequiresSObject false
 * @ActionIsActive false
 * @ActionInternal true
 */
public with sharing class ActionFlowHandler extends BaseAgentAction {
    private static final String FAULT_MESSAGE_VAR = 'faultMessage';
    private static final String OUTPUT_RESULT_VAR = 'outputResult';

    @TestVisible
    private static FlowExecutionMock mockFlowExecution;

    private ConfigDTO config;

    // Cached output variable names for the Flow being executed
    private List<String> outputVariableNames;

    @TestVisible
    public interface FlowExecutionMock {
        MockFlowResult execute(String flowApiName, Map<String, Object> flowParams);
    }

    @TestVisible
    public class MockFlowResult {
        public Boolean success;
        public Object outputResult;
        public String faultMessage;
        public String errorCode;
        public String errorMessage;

        public MockFlowResult() {
            this.success = true;
        }

        public MockFlowResult setSuccess(Object outputResult) {
            this.success = true;
            this.outputResult = outputResult;
            return this;
        }

        public MockFlowResult setFault(String faultMessage) {
            this.success = true;
            this.faultMessage = faultMessage;
            return this;
        }

        public MockFlowResult setFailure(String errorCode, String errorMessage) {
            this.success = false;
            this.errorCode = errorCode;
            this.errorMessage = errorMessage;
            return this;
        }
    }

    /**
     * DTO for strongly-typed backend configuration (admin-configured)
     * Note: Flow API name comes from implementationDetail field, not ConfigDTO
     */
    public class ConfigDTO {
        // No configuration needed - Flow API name comes from implementationDetail field
        // Reserved for future configuration options
    }

    /**
     * DTO for strongly-typed arguments (AI-provided parameters at runtime)
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Input Parameters
         * @FieldType object
         * @FieldHelp Flow input variables as key-value pairs. Names must match Flow input variable names exactly.
         */
        public Map<String, Object> inputParameters;
    }

    /**
     * @description
     * Main entry point for Flow execution using strongly-typed DTOs.
     * Validates Flow name and parameters, executes the Flow, and processes results.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<FlowResult> - Contains Flow output and execution details or error information
     *
     * Side effects: Logs key steps, parameters, and performance metrics for troubleshooting and monitoring
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        ActionOutcome flowNameResult = validateFlowApiName();
        if (!flowNameResult.isSuccess) {
            return flowNameResult;
        }
        String flowApiName = (String) flowNameResult.data;

        // Two-Pass Hybrid Deserialization: Use params directly as Flow inputs
        ArgumentsDTO args = new ArgumentsDTO();
        args.inputParameters = params != null ? params : new Map<String, Object>();

        // Validate and prepare flow parameters from DTO
        Map<String, Object> flowParams = validateFlowParameters(args.inputParameters);

        System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Starting execution of Flow: "' + flowApiName + '"');
        System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Flow input parameters: ' + JSON.serialize(flowParams).abbreviate(500));

        ActionOutcome flowExecutionResult = executeFlow(flowApiName, flowParams);
        if (!flowExecutionResult.isSuccess) {
            return flowExecutionResult;
        }
        Object flowInterviewOrMock = flowExecutionResult.data;

        ActionOutcome flowResultsResult = processFlowResults(flowInterviewOrMock, flowApiName);
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
                    System.debug(LoggingLevel.WARN, '[ActionFlowHandler] Parameter "' + key + '" could not be serialized for Flow: ' + e.getMessage());
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
     * Also caches output variable names for result processing.
     *
     * @param flowApiName String - Name of the Flow to validate.
     * @param flowParams Map<String, Object> - Input parameters to validate.
     * @return ActionOutcome - Success if validation passes, failure with details otherwise.
     */
    private ActionOutcome validateFlowParameters(String flowApiName, Map<String, Object> flowParams) {
        try {
            // Query Flow metadata to get active version
            // Note: Using SYSTEM_MODE as Flow metadata may require elevated access
            List<FlowDefinitionView> flowDefs = [
                SELECT ApiName, ActiveVersionId
                FROM FlowDefinitionView
                WHERE ApiName = :flowApiName
                WITH SYSTEM_MODE
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

            // Query ALL Flow variables for the active version
            // Note: FlowVariableView doesn't support OR conditions, so we query all and filter in Apex
            List<FlowVariableView> flowVariables = [
                SELECT ApiName, DataType, IsInput, IsOutput
                FROM FlowVariableView
                WHERE FlowVersionViewId = :flowDef.ActiveVersionId
                WITH SYSTEM_MODE
            ];

            // Build maps of expected input and output variables by filtering in code
            Map<String, FlowVariableView> expectedInputs = new Map<String, FlowVariableView>();
            this.outputVariableNames = new List<String>();

            for (FlowVariableView var : flowVariables) {
                if (var.IsInput == true) {
                    expectedInputs.put(var.ApiName, var);
                }
                if (var.IsOutput == true) {
                    this.outputVariableNames.add(var.ApiName);
                }
            }

            System.debug(
                LoggingLevel.DEBUG,
                '[ActionFlowHandler] Flow "' +
                    flowApiName +
                    '" has ' +
                    this.outputVariableNames.size() +
                    ' output variables: ' +
                    String.join(this.outputVariableNames, ', ')
            );

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
                    '[ActionFlowHandler] Flow "' +
                        flowApiName +
                        '" received unexpected parameters: ' +
                        String.join(unexpectedParams, ', ') +
                        '. These will be ignored. ' +
                        'Expected inputs: ' +
                        String.join(new List<String>(expectedInputs.keySet()), ', ')
                );
            }

            System.debug(
                LoggingLevel.DEBUG,
                '[ActionFlowHandler] Flow parameter validation passed. Expected inputs: ' + expectedInputs.size() + ', Provided: ' + flowParams.size()
            );

            return ActionOutcome.success();
        } catch (System.QueryException qe) {
            // If we can't query Flow metadata, log warning but allow execution to proceed
            System.debug(
                LoggingLevel.WARN,
                '[ActionFlowHandler] Unable to validate Flow parameters (metadata query failed): ' + qe.getMessage() + '. Proceeding with Flow execution.'
            );
            this.outputVariableNames = new List<String>();
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
        // Test support: use mock if available
        if (Test.isRunningTest() && mockFlowExecution != null) {
            MockFlowResult mockResult = mockFlowExecution.execute(flowApiName, flowParams);
            if (!mockResult.success) {
                return ActionOutcome.failure(mockResult.errorCode, mockResult.errorMessage);
            }
            // Return a wrapper that processFlowResults can handle
            return ActionOutcome.success(new MockFlowInterviewWrapper(mockResult));
        }

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
                    'Failed to create Flow interview for: ' + flowApiName + '. ' + 'Please verify the Flow API name and that the Flow is active.'
                );
            }

            flowInterview.start();
            return ActionOutcome.success(flowInterview);
        } catch (Exception ex) {
            String enhancedMessage = 'Flow execution failed for "' + flowApiName + '": ' + ex.getMessage();

            if (ex.getMessage().containsIgnoreCase('variable')) {
                enhancedMessage +=
                    ' | This may indicate a parameter mismatch. ' +
                    'Provided parameters: ' +
                    String.join(new List<String>(flowParams.keySet()), ', ');
            } else if (ex.getMessage().containsIgnoreCase('not found') || ex.getMessage().containsIgnoreCase('does not exist')) {
                enhancedMessage += ' | Please verify the Flow API name is correct and the Flow is active.';
            }

            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] ' + enhancedMessage);
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] ' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_FLOW_FAULT, enhancedMessage);
        }
    }

    /**
     * @description Wrapper class to simulate Flow.Interview for testing
     */
    @TestVisible
    private class MockFlowInterviewWrapper {
        private MockFlowResult mockResult;

        public MockFlowInterviewWrapper(MockFlowResult mockResult) {
            this.mockResult = mockResult;
        }

        public Object getVariableValue(String variableName) {
            if (variableName == FAULT_MESSAGE_VAR) {
                return mockResult.faultMessage;
            } else if (variableName == OUTPUT_RESULT_VAR) {
                return mockResult.outputResult;
            }
            return null;
        }
    }

    /**
     * @description
     * Processes Flow results by capturing ALL output variables (not just outputResult).
     * Handles both success and fault scenarios.
     *
     * @param flowInterview Flow.Interview - Executed Flow interview instance (or MockFlowInterviewWrapper in tests).
     * @param flowApiName String - Flow name for error context.
     * @return ActionOutcome<Object> - Flow output result or error information.
     */
    private ActionOutcome processFlowResults(Object flowInterviewOrMock, String flowApiName) {
        Object faultMessageValue;
        Map<String, Object> allOutputs = new Map<String, Object>();

        // Handle both real Flow.Interview and mock wrapper
        if (flowInterviewOrMock instanceof MockFlowInterviewWrapper) {
            MockFlowInterviewWrapper mockWrapper = (MockFlowInterviewWrapper) flowInterviewOrMock;
            faultMessageValue = mockWrapper.getVariableValue(FAULT_MESSAGE_VAR);

            // For mocks, check legacy outputResult
            Object legacyOutput = mockWrapper.getVariableValue(OUTPUT_RESULT_VAR);
            if (legacyOutput != null) {
                allOutputs.put(OUTPUT_RESULT_VAR, legacyOutput);
            }
        } else {
            Flow.Interview flowInterview = (Flow.Interview) flowInterviewOrMock;
            faultMessageValue = flowInterview.getVariableValue(FAULT_MESSAGE_VAR);

            // Capture ALL output variables from the Flow
            if (this.outputVariableNames != null && !this.outputVariableNames.isEmpty()) {
                for (String outputVarName : this.outputVariableNames) {
                    try {
                        Object outputValue = flowInterview.getVariableValue(outputVarName);
                        if (outputValue != null) {
                            allOutputs.put(outputVarName, outputValue);
                        }
                    } catch (Exception e) {
                        System.debug(LoggingLevel.WARN, '[ActionFlowHandler] Could not retrieve output variable "' + outputVarName + '": ' + e.getMessage());
                    }
                }
            } else {
                // Fallback: check for legacy outputResult variable
                Object legacyOutput = flowInterview.getVariableValue(OUTPUT_RESULT_VAR);
                if (legacyOutput != null) {
                    allOutputs.put(OUTPUT_RESULT_VAR, legacyOutput);
                }
            }
        }

        // Check for Flow-reported faults
        if (faultMessageValue instanceof String && String.isNotBlank((String) faultMessageValue)) {
            String faultMessage = (String) faultMessageValue;
            String enhancedError = 'Flow "' + flowApiName + '" reported failure via "' + FAULT_MESSAGE_VAR + '": ' + faultMessage;
            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] Flow reported failure: ' + enhancedError);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_FLOW_FAULT, enhancedError);
        }

        // Build the result payload
        Object flowDataPayload;
        if (allOutputs.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Flow completed with no output variables. Returning default payload.');
            flowDataPayload = new Map<String, Object>{ 'flowCompleted' => true };
        } else if (allOutputs.size() == 1 && allOutputs.containsKey(OUTPUT_RESULT_VAR)) {
            // Single outputResult variable - return it directly for backward compatibility
            flowDataPayload = allOutputs.get(OUTPUT_RESULT_VAR);
            System.debug(LoggingLevel.INFO, '[ActionFlowHandler] Flow "' + flowApiName + '" completed with single outputResult variable.');
        } else {
            // Multiple outputs or different variable names - return all of them
            flowDataPayload = allOutputs;
            System.debug(
                LoggingLevel.INFO,
                '[ActionFlowHandler] Flow "' +
                    flowApiName +
                    '" completed with ' +
                    allOutputs.size() +
                    ' output variables: ' +
                    String.join(new List<String>(allOutputs.keySet()), ', ')
            );
        }

        return ActionOutcome.success(flowDataPayload);
    }

    /**
     * @description
     * Parses action configuration JSON if provided. This action does not require custom configuration,
     * but logs a debug message if configuration is present for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string (optional)
     * @param logPrefix String - Prefix for log output
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // No configuration needed for this action. Flow name comes from ActionContext.implementationDetail.
        // Flow input parameters are passed via ArgumentsDTO at runtime.
        if (String.isNotBlank(actionConfigurationJson)) {
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Action configuration JSON was provided but is not used by this action.');
        }
    }

    /**
     * @description
     * Result wrapper for successful Flow execution operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - flowName: String - The Flow API name executed.
     *   - result: Object - The output/result from the Flow (all output variables).
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

            // Build informative metadata
            this.metadata = new Map<String, Object>{ 'flowApiName' => flowName, 'hasResult' => result != null };

            // Add output variable names if result is a map of outputs
            if (result instanceof Map<String, Object>) {
                Map<String, Object> resultMap = (Map<String, Object>) result;
                this.metadata.put('outputVariables', new List<String>(resultMap.keySet()));
                this.metadata.put('outputCount', resultMap.size());
            } else if (result != null) {
                this.metadata.put('resultType', String.valueOf(result).left(100));
            }
        }
    }
}
