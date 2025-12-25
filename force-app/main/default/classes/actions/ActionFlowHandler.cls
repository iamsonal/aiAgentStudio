/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Executes Salesforce Flows with strongly-typed DTOs.
 * Uses DTOs for type-safe argument handling and flow input parameter processing.
 *
 * @ActionLabel Execute Flow
 * @ActionDescription Executes a Salesforce Flow and returns its output
 * @ActionRequiresSObject false
 * @ActionIsActive false
 * @ActionGuidance
 * <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; line-height: 1.6;"><div style="background: linear-gradient(135deg, #fa709a 0%, #fee140 100%); color: white; padding: 16px; border-radius: 8px 8px 0 0; margin: -8px -8px 16px -8px;"><h2 style="margin: 0; font-size: 18px; font-weight: 600;">⚡ Execute Flow</h2><p style="margin: 4px 0 0 0; font-size: 13px; opacity: 0.95;">Execute a Salesforce Flow with input/output variables</p></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">⚙️ Configuration Required</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">Implementation Detail</strong><br/><span style="font-size: 11px; color: #dc3545;">Required</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Select the Flow to execute using the picker. Only shows <strong>Autolaunched Flows</strong> that are active.<br/><span style="font-size: 12px; font-style: italic;">The Flow's API name will be stored in the configuration.</span></td></tr><tr><td style="padding: 8px;"><strong style="color: #495057;">Default Input Values</strong><br/><span style="font-size: 11px; color: #6c757d;">Optional</span></td><td style="padding: 8px; color: #6c757d;">JSON object with default values for Flow input variables. These are merged with AI-provided values.<br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">{ "varName": "defaultValue" }</code></td></tr></table></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">📋 Flow Requirements</h3><ul style="margin: 8px 0; padding-left: 20px; font-size: 13px; color: #6c757d;"><li style="margin-bottom: 8px;"><strong style="color: #495057;">Flow Type:</strong> Must be an <strong>Autolaunched Flow</strong> (not Screen Flow or Record-Triggered Flow)</li><li style="margin-bottom: 8px;"><strong style="color: #495057;">Status:</strong> Flow must be <strong>Active</strong> to be executable</li><li style="margin-bottom: 8px;"><strong style="color: #495057;">Input Variables:</strong> Mark variables as "Available for input" in Flow Builder</li><li style="margin-bottom: 8px;"><strong style="color: #495057;">Output Variables:</strong> Mark variables as "Available for output" to return values to AI</li></ul><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">📤 Supported Data Types</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 6px; border-bottom: 1px solid #e9ecef; width: 35%;"><span style="color: #28a745;">✓</span> Text, Number, Boolean</td><td style="padding: 6px; border-bottom: 1px solid #e9ecef;"><span style="color: #28a745;">✓</span> Date, DateTime</td></tr><tr><td style="padding: 6px; border-bottom: 1px solid #e9ecef;"><span style="color: #28a745;">✓</span> Record (SObject)</td><td style="padding: 6px; border-bottom: 1px solid #e9ecef;"><span style="color: #28a745;">✓</span> Record Collections</td></tr><tr><td style="padding: 6px;"><span style="color: #28a745;">✓</span> Text/Number Collections</td><td style="padding: 6px;"><span style="color: #ffc107;">⚠</span> Apex-Defined Types (limited)</td></tr></table></div><div style="background: #e7f1ff; border-left: 4px solid #0066cc; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #004085;"><strong>💡 How it works:</strong> The AI reads your Flow's variable names and descriptions to understand what inputs to provide. Clear variable names and descriptions help the AI use your Flow correctly.</p></div></div>
 */
public class ActionFlowHandler extends BaseAgentAction {
    private static final String FAULT_MESSAGE_VAR = 'faultMessage';
    private static final String OUTPUT_RESULT_VAR = 'outputResult';

    // Test support: allows tests to inject mock flow results
    @TestVisible
    private static FlowExecutionMock mockFlowExecution;

    private ConfigDTO config;

    /**
     * @description Interface for mocking Flow execution in tests
     */
    @TestVisible
    public interface FlowExecutionMock {
        MockFlowResult execute(String flowApiName, Map<String, Object> flowParams);
    }

    /**
     * @description Mock result container for test injection
     */
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

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.inputParameters = params.containsKey('inputParameters') && params.get('inputParameters') instanceof Map<String, Object>
            ? (Map<String, Object>) params.get('inputParameters')
            : new Map<String, Object>();

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
                WHERE FlowVersionViewId = :flowDef.ActiveVersionId AND IsInput = TRUE
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

            // Provide more specific error context based on exception message
            if (ex.getMessage().containsIgnoreCase('variable')) {
                enhancedMessage +=
                    ' | This may indicate a parameter mismatch. ' +
                    'Provided parameters: ' +
                    String.join(new List<String>(flowParams.keySet()), ', ');
            } else if (ex.getMessage().containsIgnoreCase('not found') || ex.getMessage().containsIgnoreCase('does not exist')) {
                enhancedMessage += ' | Please verify the Flow API name is correct and the Flow is active.';
            }

            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] Flow execution error: ' + enhancedMessage);
            System.debug(LoggingLevel.DEBUG, '[ActionFlowHandler] Exception stack trace: ' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, enhancedMessage);
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
     * Processes Flow results and handles both success and fault scenarios.
     *
     * @param flowInterview Flow.Interview - Executed Flow interview instance (or MockFlowInterviewWrapper in tests).
     * @param flowApiName String - Flow name for error context.
     * @return ActionOutcome<Object> - Flow output result or error information.
     */
    private ActionOutcome processFlowResults(Object flowInterviewOrMock, String flowApiName) {
        Object faultMessageValue;
        Object flowDataPayload;

        // Handle both real Flow.Interview and mock wrapper
        if (flowInterviewOrMock instanceof MockFlowInterviewWrapper) {
            MockFlowInterviewWrapper mockWrapper = (MockFlowInterviewWrapper) flowInterviewOrMock;
            faultMessageValue = mockWrapper.getVariableValue(FAULT_MESSAGE_VAR);
            flowDataPayload = mockWrapper.getVariableValue(OUTPUT_RESULT_VAR);
        } else {
            Flow.Interview flowInterview = (Flow.Interview) flowInterviewOrMock;
            faultMessageValue = flowInterview.getVariableValue(FAULT_MESSAGE_VAR);
            flowDataPayload = flowInterview.getVariableValue(OUTPUT_RESULT_VAR);
        }

        if (faultMessageValue instanceof String && String.isNotBlank((String) faultMessageValue)) {
            String faultMessage = (String) faultMessageValue;
            String enhancedError = 'Flow "' + flowApiName + '" reported failure via "' + FAULT_MESSAGE_VAR + '": ' + faultMessage;
            System.debug(LoggingLevel.ERROR, '[ActionFlowHandler] Flow reported failure: ' + enhancedError);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, enhancedError);
        }

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
