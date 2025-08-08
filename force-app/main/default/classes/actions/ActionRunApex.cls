/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Securely executes pre-defined Invocable Apex methods.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *
 *              SECURITY: Method name MUST be configured by admin in Implementation Detail field.
 *              LLM can only provide parameters, preventing arbitrary code execution.
 *
 *              MAINTAINS: Full security model, error handling, and invocable method conventions.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionRunApex extends BaseAgentAction {
    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains security and error handling while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String qualifiedMethodName = validateInvocableMethodName();

        Map<String, Object> invocableParams = validateInvocableParameters(params);

        List<Object> results = executeInvocableMethod(qualifiedMethodName, invocableParams);

        Object resultPayload = processInvocableResults(results, qualifiedMethodName);

        Long executionTime = System.currentTimeMillis() - startTime;

        return new ApexResult(qualifiedMethodName, resultPayload, 'The Apex action ' + qualifiedMethodName + ' completed successfully.');
    }

    /**
     * @description Validates the invocable method name from admin configuration
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
     * @description Validates and processes invocable parameters
     */
    private Map<String, Object> validateInvocableParameters(Map<String, Object> params) {
        if (params == null || params.isEmpty()) {
            return new Map<String, Object>();
        }

        for (String key : params.keySet()) {
            Object value = params.get(key);
            if (value != null) {
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
     * @description Executes the invocable method with enhanced error handling
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
            throw ce;
        } catch (System.LimitException le) {
            throw le;
        } catch (Exception ex) {
            String enhancedMessage = 'Failed to execute invocable method ' + qualifiedMethodName + ': ' + ex.getMessage();

            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description Processes invocable method results with enhanced validation
     */
    private Object processInvocableResults(List<Object> results, String qualifiedMethodName) {
        if (results.isEmpty()) {
            throw new ValidationException('Invocable method ' + qualifiedMethodName + ' returned empty result list', null);
        }

        Object resultPayload = results[0];

        if (resultPayload instanceof Map<String, Object>) {
            Map<String, Object> resultMap = (Map<String, Object>) resultPayload;

            if (resultMap.containsKey('isSuccess') && resultMap.get('isSuccess') == false) {
                String errorMessage = (String) resultMap.get('errorMessage');
                String enhancedError = 'Invocable method ' + qualifiedMethodName + ' reported controlled failure';
                if (String.isNotBlank(errorMessage)) {
                    enhancedError += ': ' + errorMessage;
                }

                throw new ValidationException(enhancedError, null);
            }
        }

        return resultPayload;
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

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
