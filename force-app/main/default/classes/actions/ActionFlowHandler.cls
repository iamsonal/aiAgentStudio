/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Executes Salesforce Flows with intelligent parameter processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *
 *              CONVENTIONS: Flow must use 'faultMessage' for errors and 'outputResult' for success data.
 *              SECURITY: Flow name MUST be configured by admin in Implementation Detail field.
 *
 *              MAINTAINS: Full Flow conventions, error handling, and security model.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionFlowHandler extends BaseAgentAction {
    private static final String FAULT_MESSAGE_VAR = 'faultMessage';
    private static final String OUTPUT_RESULT_VAR = 'outputResult';

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains Flow conventions and error handling while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String flowApiName = validateFlowApiName();

        Map<String, Object> flowParams = validateFlowParameters(params);

        Flow.Interview flowInterview = executeFlow(flowApiName, flowParams);

        Object flowResult = processFlowResults(flowInterview, flowApiName);

        Long executionTime = System.currentTimeMillis() - startTime;

        return new FlowResult(flowApiName, flowResult, 'Flow "' + flowApiName + '" completed successfully.');
    }

    /**
     * @description Validates the Flow API name from admin configuration
     */
    private String validateFlowApiName() {
        String flowApiName = this.actionContext?.implementationDetail;

        if (String.isBlank(flowApiName)) {
            throw new ValidationException(
                'Agent Capability is missing Implementation Detail. Admin must configure the Flow API Name.',
                'ImplementationDetail__c'
            );
        }

        if (flowApiName.contains(' ') || flowApiName.contains('.')) {
        }

        return flowApiName;
    }

    /**
     * @description Validates and processes Flow input parameters
     */
    private Map<String, Object> validateFlowParameters(Map<String, Object> params) {
        if (params == null || params.isEmpty()) {
            return new Map<String, Object>();
        }

        Map<String, Object> validatedParams = new Map<String, Object>();

        for (String key : params.keySet()) {
            Object value = params.get(key);

            if (!isValidFlowVariableName(key)) {
            }

            if (value != null) {
                try {
                    String testSerialization = JSON.serialize(value);
                    validatedParams.put(key, value);
                } catch (Exception e) {
                    validatedParams.put(key, String.valueOf(value));
                }
            } else {
                validatedParams.put(key, value);
            }
        }

        return validatedParams;
    }

    /**
     * @description Validates Flow variable name format
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
     * @description Executes the Flow with enhanced error handling
     */
    private Flow.Interview executeFlow(String flowApiName, Map<String, Object> flowParams) {
        try {
            Flow.Interview flowInterview = Flow.Interview.createInterview(flowApiName, flowParams);

            if (flowInterview == null) {
                throw new ValidationException('Failed to create Flow interview for: ' + flowApiName, 'ImplementationDetail__c');
            }

            flowInterview.start();
            return flowInterview;
        } catch (Exception ex) {
            String enhancedMessage = 'Flow execution failed for "' + flowApiName + '": ' + ex.getMessage();

            throw new ValidationException(enhancedMessage, 'ImplementationDetail__c');
        }
    }

    /**
     * @description Processes Flow results with enhanced validation
     */
    private Object processFlowResults(Flow.Interview flowInterview, String flowApiName) {
        Object faultMessageValue = flowInterview.getVariableValue(FAULT_MESSAGE_VAR);
        if (faultMessageValue instanceof String && String.isNotBlank((String) faultMessageValue)) {
            String faultMessage = (String) faultMessageValue;
            String enhancedError = 'Flow "' + flowApiName + '" reported failure via "' + FAULT_MESSAGE_VAR + '": ' + faultMessage;

            throw new ValidationException(enhancedError, FAULT_MESSAGE_VAR);
        }

        Object flowDataPayload = flowInterview.getVariableValue(OUTPUT_RESULT_VAR);

        if (flowDataPayload == null) {
            flowDataPayload = new Map<String, Object>{ 'flowCompleted' => true };
        }

        return flowDataPayload;
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    public class FlowResult {
        public String flowName;
        public Object result;
        public String message;
        public Map<String, Object> metadata;

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
