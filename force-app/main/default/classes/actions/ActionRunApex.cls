/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionRunApex is a secure Apex action for executing pre-defined Invocable Apex methods, with strict admin configuration and robust error handling.
 *
 * Responsibilities:
 *   - Validates and extracts the fully qualified method name from admin configuration (Implementation Detail field).
 *   - Validates and processes input parameters for invocable methods.
 *   - Executes the invocable method with comprehensive error handling and logging.
 *   - Returns structured, LLM-friendly result data and meaningful error messages for downstream use.
 *
 * Scope:
 *   - Strictly focused on secure, admin-configured invocable method execution; does not allow arbitrary code execution.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * SECURITY: Method name MUST be configured by admin in Implementation Detail field. LLM can only provide parameters, preventing arbitrary code execution.
 *
 * @extends BaseAgentAction
 */
public class ActionRunApex extends BaseAgentAction {
    /**
     * @description
     * Main entry point for invocable method execution. Validates method name and parameters, executes the method, and processes results.
     *
     * @param params Map<String, Object> - Parameters for the invocable method.
     * @return ApexResult - Contains result, method name, and metadata.
     * @throws ValidationException for parameter, security, or execution errors.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Security: Get method name from admin-configured context
        String qualifiedMethodName = validateInvocableMethodName();
        // Parameter validation
        Map<String, Object> invocableParams = validateInvocableParameters(params);
        System.debug(LoggingLevel.INFO, '[ActionRunApex] Invoking method: ' + qualifiedMethodName);
        System.debug(LoggingLevel.DEBUG, '[ActionRunApex] Parameters: ' + JSON.serialize(invocableParams).abbreviate(500));

        // Execute invocable method
        List<Object> results = executeInvocableMethod(qualifiedMethodName, invocableParams);
        // Process results
        Object resultPayload = processInvocableResults(results, qualifiedMethodName);

        // Log performance metrics
        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionRunApex] Method execution for ' + qualifiedMethodName + ' completed in ' + executionTime + ' ms.');

        return new ApexResult(qualifiedMethodName, resultPayload, 'The Apex action ' + qualifiedMethodName + ' completed successfully.');
    }

    /**
     * @description
     * Validates and extracts the invocable method name from admin configuration (Implementation Detail field).
     *
     * @return String - The fully qualified method name.
     * @throws ValidationException if the method name is missing or not fully qualified.
     */
    private String validateInvocableMethodName() {
        String qualifiedMethodName = this.actionContext?.implementationDetail;

        if (String.isBlank(qualifiedMethodName)) {
            throw new ValidationException(
                'Agent Capability is missing Implementation Detail. Admin must configure the fully qualified Invocable Method name (e.g., MyClass.myMethod).',
                'ImplementationDetail__c'
            );
        }

        if (!qualifiedMethodName.contains('.')) {
            throw new ValidationException(
                'Implementation Detail must contain a fully qualified method name (e.g., MyClass.myMethod). Found: ' + qualifiedMethodName,
                'ImplementationDetail__c'
            );
        }

        return qualifiedMethodName;
    }

    /**
     * @description
     * Validates and processes invocable parameters for compatibility and serialization.
     *
     * @param params Map<String, Object> - Parameters for the invocable method.
     * @return Map<String, Object> - Validated and processed parameters.
     * @throws ValidationException if parameters are not serializable.
     */
    private Map<String, Object> validateInvocableParameters(Map<String, Object> params) {
        // Allow empty parameters for methods that don't require input
        if (params == null || params.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionRunApex] No parameters provided. Using empty map.');
            return new Map<String, Object>();
        }

        // Validate parameter structure
        for (String key : params.keySet()) {
            Object value = params.get(key);
            if (value != null) {
                // Ensure parameters are serializable for invocable methods
                try {
                    String testSerialization = JSON.serialize(value);
                } catch (Exception e) {
                    throw new ValidationException('Parameter "' + key + '" contains non-serializable data: ' + e.getMessage(), key);
                }
            }
        }

        return params;
    }

    /**
     * @description
     * Executes the invocable method with comprehensive error handling and logging.
     *
     * @param qualifiedMethodName String - The fully qualified method name.
     * @param invocableParams Map<String, Object> - Parameters for the invocable method.
     * @return List<Object> - The results of the method invocation.
     * @throws ValidationException or system exceptions if execution fails.
     */
    private List<Object> executeInvocableMethod(String qualifiedMethodName, Map<String, Object> invocableParams) {
        try {
            Invocable.Action action = Invocable.Action.createCustomAction('apex', qualifiedMethodName);
            action.setInvocationParameter('inputs', new List<Map<String, Object>>{ invocableParams });

            List<Object> results = (List<Object>) action.invoke();

            if (results == null) {
                throw new ValidationException('Invocable method ' + qualifiedMethodName + ' returned null result', null);
            }

            return results;
        } catch (System.CalloutException ce) {
            System.debug(LoggingLevel.ERROR, '[ActionRunApex] Callout error during method ' + qualifiedMethodName + ': ' + ce.getMessage());
            throw ce;
        } catch (System.LimitException le) {
            System.debug(LoggingLevel.ERROR, '[ActionRunApex] Limit exceeded during method ' + qualifiedMethodName + ': ' + le.getMessage());
            throw le;
        } catch (Exception ex) {
            String enhancedMessage = 'Failed to execute invocable method ' + qualifiedMethodName + ': ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, '[ActionRunApex] Unexpected error: ' + enhancedMessage);
            System.debug(LoggingLevel.DEBUG, '[ActionRunApex] Exception stack trace: ' + ex.getStackTraceString());
            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description
     * Processes invocable method results with enhanced validation and error handling.
     *
     * @param results List<Object> - The results returned by the invocable method.
     * @param qualifiedMethodName String - The fully qualified method name.
     * @return Object - The processed result payload.
     * @throws ValidationException if the result is empty or indicates a controlled failure.
     */
    private Object processInvocableResults(List<Object> results, String qualifiedMethodName) {
        if (results.isEmpty()) {
            throw new ValidationException('Invocable method ' + qualifiedMethodName + ' returned empty result list', null);
        }

        Object resultPayload = results[0];

        // Handle controlled failure pattern
        if (resultPayload instanceof Map<String, Object>) {
            Map<String, Object> resultMap = (Map<String, Object>) resultPayload;

            // Check for controlled failure pattern
            if (resultMap.containsKey('isSuccess') && resultMap.get('isSuccess') == false) {
                String errorMessage = (String) resultMap.get('errorMessage');
                String enhancedError = 'Invocable method ' + qualifiedMethodName + ' reported controlled failure';
                if (String.isNotBlank(errorMessage)) {
                    enhancedError += ': ' + errorMessage;
                }
                System.debug(LoggingLevel.WARN, '[ActionRunApex] Controlled failure: ' + enhancedError);
                throw new ValidationException(enhancedError, null);
            }
        }

        System.debug(LoggingLevel.INFO, '[ActionRunApex] Successfully invoked method: ' + qualifiedMethodName);
        return resultPayload;
    }

    /**
     * @description
     * Parses action configuration JSON if provided. This action does not require custom configuration,
     * but logs a debug message if configuration is present for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string (optional).
     * @param logPrefix String - Prefix for log output.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionRunApex] Action configuration JSON was provided but is not required for this action.');
        }
    }

    /**
     * @description
     * Result wrapper for successful invocable method execution. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - methodName: String - The fully qualified method name executed.
     *   - result: Object - The result returned by the method.
     *   - message: String - User-facing message summarizing the result.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class ApexResult {
        public String methodName;
        public Object result;
        public String message;
        public Map<String, Object> metadata;

        public ApexResult(String methodName, Object result, String message) {
            this.methodName = methodName;
            this.result = result;
            this.message = message;
            this.metadata = new Map<String, Object>{
                'invocableMethod' => methodName,
                'hasResult' => result != null,
                'resultType' => result != null ? String.valueOf(result).substring(0, Math.min(50, String.valueOf(result).length())) : 'null'
            };
        }
    }
}
